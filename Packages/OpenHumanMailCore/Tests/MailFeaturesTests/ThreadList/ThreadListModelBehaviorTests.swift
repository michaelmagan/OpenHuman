import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
private func loadedModel(_ store: FakeMailStore, count: Int, location: MailLocation = .system(.inbox),
                         now: @escaping @Sendable () -> Date = { fixedNow }) async -> ThreadListModel {
    let model = ThreadListModel(data: store, location: location, account: AccountID(1), now: now)
    model.start()
    await eventually { model.rows.count == min(count, ThreadListModel.initialLimit) }
    return model
}

private struct NoPagingSource: MailDataSource {
    let base: FakeMailStore
    func accounts() -> AsyncThrowingStream<[Account], Error> { base.accounts() }
    func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
        base.threadWindow(location, account: account, limit: limit)
    }
    func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> { base.threadDetail(key) }
    func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> { base.body(key) }
}

private struct FailingSource: MailDataSource {
    func accounts() -> AsyncThrowingStream<[Account], Error> { AsyncThrowingStream { $0.finish() } }
    func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
        AsyncThrowingStream { $0.finish(throwing: MailPortError.unavailable("disk")) }
    }
    func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> { AsyncThrowingStream { $0.finish() } }
    func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> { AsyncThrowingStream { $0.finish() } }
}

@MainActor
private final class EventRecorder {
    var events: [String] = []
}

@MainActor
@Suite struct ThreadListOptimisticTests {
    @Test func markDoneHidesTheRowInTheSameTurnAndTheStoreSettlesIt() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 10, now: fixedNow), options: .manual)
        let model = await loadedModel(store, count: 10)
        let recorder = EventRecorder()
        model.addListener(recorder) { event in
            switch event {
            case .rows: recorder.events.append("rows")
            case .cursor: recorder.events.append("cursor")
            }
        }
        model.moveCursor(by: 2)
        let target = try #require(model.cursor)
        let below = model.rows[3].id
        recorder.events.removeAll()

        let ticket = model.applyOptimistic(.markDone([target]))
        #expect(ticket != nil)
        #expect(model.rows.count == 9)
        #expect(model.index(of: target) == nil)
        #expect(model.cursor == below)
        #expect(recorder.events == ["rows", "cursor"])
        #expect(model.lastChange == .update(ThreadListEdit(removed: IndexSet(integer: 2))))
        #expect(model.totalCount == 9)

        _ = try await store.apply(.markDone([target]))
        await eventually { model.optimisticKeys.isEmpty }
        #expect(model.rows.count == 9)
        #expect(model.cursor == below)
    }

    @Test func aFailedActionPutsTheRowBackInItsPlace() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 6, now: fixedNow))
        let model = await loadedModel(store, count: 6)
        let target = model.rows[1].id
        let ticket = try #require(model.applyOptimistic(.trash([target])))
        #expect(model.rows.count == 5)
        model.revertOptimistic(ticket)
        await eventually { model.rows.count == 6 }
        #expect(model.index(of: target) == 1)
    }

    @Test func unconfirmedChangesExpireAfterTenSeconds() async throws {
        let clock = FakeClock(fixedNow)
        let store = FakeMailStore(corpus: .make(threadCount: 4, now: fixedNow))
        let model = await loadedModel(store, count: 4, now: { clock.now })
        let target = model.rows[0].id
        model.applyOptimistic(.markDone([target]))
        #expect(model.rows.count == 3)
        clock.advance(by: 9)
        model.expireOptimistic(now: clock.now)
        #expect(model.rows.count == 3)
        clock.advance(by: 1.5)
        model.expireOptimistic(now: clock.now)
        await eventually { model.rows.count == 4 }
        #expect(model.rows[0].id == target)
    }

    @Test func patchesShowAtOnceAndSettle() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 5, now: fixedNow))
        let model = await loadedModel(store, count: 5)
        let target = model.rows[2].id
        let starredBefore = try #require(model.row(for: target)).isStarred
        model.applyOptimistic(starredBefore ? .unstar([target]) : .star([target]))
        #expect(model.row(for: target)?.isStarred == !starredBefore)
        #expect(model.lastChange == .update(ThreadListEdit(reconfigured: IndexSet(integer: 2))))
        _ = try await store.apply(starredBefore ? .unstar([target]) : .star([target]))
        await eventually { model.optimisticKeys.isEmpty }
        #expect(model.row(for: target)?.isStarred == !starredBefore)
    }

    @Test func anUndoBeforeTheStoreAnsweredIsNotHidden() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 3, now: fixedNow))
        let model = await loadedModel(store, count: 3)
        let target = model.rows[0].id
        model.applyOptimistic(.markDone([target]))
        model.clearOptimistic(for: [target])
        await eventually { model.rows.count == 3 }
    }

    @Test func commandsForRowsNotShownChangeNothing() async throws {
        let store = FakeMailStore(corpus: .small)
        let model = ThreadListModel(data: store, location: .system(.starred), account: AccountID(1))
        model.start()
        await eventually { model.state == .loaded }
        try #require(!model.rows.isEmpty)
        let stranger = ThreadKey(account: AccountID(1), rowID: 99_999, gmailThreadID: GmailThreadID("x"))
        #expect(model.applyOptimistic(.markDone([stranger])) == nil)
        #expect(model.applyOptimistic(.markDone(model.rows.map(\.id))) == nil, "Mark done keeps a starred thread starred")
    }
}

@MainActor
@Suite struct ThreadListPagingTests {
    @Test func placeholdersCoverTheLocationAndPagesFillThemInOrder() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 3_000, now: fixedNow))
        let model = await loadedModel(store, count: 3_000)
        #expect(model.totalCount == 3_000)
        #expect(model.displayCount == 3_000, "the scroller covers every thread from the first window")
        #expect(model.placeholderCount == 2_900)

        model.visibleRangeDidChange(2_400..<2_430)
        #expect(model.limit == ThreadListModel.maximumLiveWindow)
        await eventually(timeout: .seconds(20)) { model.rows.count == 3_000 }
        #expect(model.placeholderCount == 0)
        #expect(!model.hasMore)
        #expect(Set(model.rows.map(\.id)).count == 3_000, "no duplicates where pages overlap the live window")
        let order = model.rows.map { ($0.sortAt, $0.id.rowID) }
        #expect(zip(order, order.dropFirst()).allSatisfy { $0 > $1 }, "newest first across the live window and pages")
    }

    @Test func newMailAtTheTopKeepsPagedRows() async throws {
        let corpus = FakeCorpus.make(threadCount: 2_301, now: fixedNow)
        let store = FakeMailStore(corpus: FakeCorpus(account: corpus.account, threads: Array(corpus.threads.dropFirst())))
        let model = await loadedModel(store, count: 2_300)
        model.visibleRangeDidChange(2_200..<2_299)
        await eventually(timeout: .seconds(20)) { model.rows.count == 2_300 }
        store.insertAtTop(corpus.threads[0])
        await eventually { model.rows.first?.id == corpus.threads[0].row.id }
        #expect(model.rows.count == 2_301)
        #expect(Set(model.rows.map(\.id)).count == 2_301)
    }

    @Test func aSourceWithoutPagingEndsAtTheLiveWindow() async throws {
        let base = FakeMailStore(corpus: .make(threadCount: 2_100, now: fixedNow))
        let model = ThreadListModel(data: NoPagingSource(base: base), location: .system(.inbox), account: AccountID(1))
        model.start()
        await eventually { model.rows.count == 100 }
        model.visibleRangeDidChange(2_050..<2_060)
        await eventually(timeout: .seconds(10)) { model.isPagingUnavailable }
        await eventually { model.rows.count == 2_000 }
        #expect(model.placeholderCount == 0, "no placeholders that could never load")
        #expect(model.hasMore)
        #expect(model.totalCount == 2_100)
    }

    @Test func aPagedRowTouchedByAnActionIsFetchedAgain() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 2_200, now: fixedNow))
        let model = await loadedModel(store, count: 2_200)
        model.visibleRangeDidChange(2_100..<2_199)
        await eventually(timeout: .seconds(20)) { model.rows.count == 2_200 }
        let paged = model.rows[2_150]
        let command: MailCommand = paged.isUnread ? .markRead([paged.id]) : .markUnread([paged.id])
        model.applyOptimistic(command)
        #expect(model.row(for: paged.id)?.isUnread == !paged.isUnread)
        _ = try await store.apply(command)
        await eventually(timeout: .seconds(10)) { model.optimisticKeys.isEmpty }
        #expect(model.row(for: paged.id)?.isUnread == !paged.isUnread)
    }

    @Test func liveWindowFailureIsReported() async throws {
        let model = ThreadListModel(data: FailingSource(), location: .system(.inbox), account: AccountID(1))
        model.start()
        await eventually { if case .failed = model.state { true } else { false } }
    }
}

@MainActor
@Suite struct ThreadListSelectionTests {
    @Test func xExtendAllAndEscape() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 8, now: fixedNow))
        let model = await loadedModel(store, count: 8)
        let keys = model.rows.map(\.id)
        #expect(model.toggleCheck())
        #expect(model.isChecked(keys[0]))
        #expect(model.extendCheck(by: 1))
        #expect(model.extendCheck(by: 1))
        #expect(model.cursor == keys[2])
        #expect(model.selection.checked == Set(keys[0...2]))
        #expect(model.actionTargets == Array(keys[0...2]))
        model.checkAll()
        #expect(model.checkedCount == 8)
        #expect(model.clearChecks())
        #expect(!model.clearChecks())
        #expect(model.actionTargets == [keys[2]], "no checks: the cursor row")
    }

    @Test func clicksWithModifiers() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 8, now: fixedNow))
        let model = await loadedModel(store, count: 8)
        let keys = model.rows.map(\.id)
        model.click(keys[1])
        #expect(model.cursor == keys[1] && model.checkedCount == 0)
        model.click(keys[4], extending: true)
        #expect(model.selection.checked == Set(keys[1...4]))
        model.click(keys[6], toggling: true)
        #expect(model.selection.checked == Set(keys[1...4]).union([keys[6]]))
        model.click(keys[2])
        #expect(model.checkedCount == 0 && model.cursor == keys[2])
    }

    @Test func checksOfRowsThatLeaveArePruned() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 6, now: fixedNow))
        let model = await loadedModel(store, count: 6)
        let keys = model.rows.map(\.id)
        model.click(keys[0], toggling: true)
        model.click(keys[1], toggling: true)
        model.applyOptimistic(.markDone([keys[0]]))
        #expect(model.selection.checked == [keys[1]])
    }

    @Test func theAccountsSelectionDecidesWhatMarkDoneTouches() async throws {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 6, now: fixedNow), options: .init(remoteAck: .immediate))
        let router = AppRouter(environment: env)
        router.start()
        await eventually { router.list?.rows.count == 6 }
        let list = try #require(router.list)
        let account = try #require(router.active)
        list.attach(selection: account.selection)
        let keys = list.rows.map(\.id)
        list.click(keys[1], toggling: true)
        list.click(keys[3], toggling: true)
        #expect(account.selection.checked == [keys[1], keys[3]])
        #expect(router.perform(.markDone))
        await eventually { router.list?.rows.count == 4 }
        #expect(router.list?.index(of: keys[1]) == nil && router.list?.index(of: keys[3]) == nil)
    }
}

@MainActor
@Suite struct ThreadListHiddenCountTests {
    @Test func hiddenRowsAreCountedWhileTheOverlayHidesThemAndForgottenOnExpiry() async throws {
        let clock = FakeClock(fixedNow)
        let store = FakeMailStore(corpus: .make(threadCount: 4, now: fixedNow))
        let model = await loadedModel(store, count: 4, now: { clock.now })
        #expect(model.optimisticHiddenCount == 0)
        model.applyOptimistic(.markDone([model.rows[0].id]))
        #expect(model.optimisticHiddenCount == 1)
        clock.advance(by: 11)
        model.expireOptimistic(now: clock.now)
        await eventually { model.rows.count == 4 }
        #expect(model.optimisticHiddenCount == 0)
    }

    @Test func tabTotalDropsHiddenRowsButNeverBelowZeroOrFromAnUnknownTotal() {
        let tab = MailTab(location: .system(.inbox), title: "Important", unread: 1, total: 1)
        #expect(tab.withHiddenRows(1).count(.all) == 0)
        #expect(tab.withHiddenRows(5).count(.all) == 0)
        #expect(tab.withHiddenRows(0).count(.all) == 1)
        #expect(MailTab(location: .system(.inbox), title: "x", unread: 0).withHiddenRows(2).total == nil)
    }
}
