import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private final class DebounceGate: Sendable {
    let asked: AsyncStream<Duration>
    private let askedContinuation: AsyncStream<Duration>.Continuation
    private let waiters = Mutex<[CheckedContinuation<Void, Error>]>([])

    init() { (asked, askedContinuation) = AsyncStream.makeStream() }

    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            waiters.withLock { $0.append(waiter) }
            askedContinuation.yield(duration)
        }
    }

    func release() {
        let all = waiters.withLock { list -> [CheckedContinuation<Void, Error>] in defer { list = [] }; return list }
        for waiter in all { waiter.resume() }
    }
}

private struct PendingSource: MailDataSource {
    let base = FakeMailStore(corpus: .make(threadCount: 3, now: fixedNow))
    let counts: AsyncStream<[AccountID: Int]>
    let states: AsyncStream<[AccountID: ConnectivityState]>

    func accounts() -> AsyncThrowingStream<[Account], Error> { base.accounts() }
    func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
        base.threadWindow(location, account: account, limit: limit)
    }
    func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> { base.threadDetail(key) }
    func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> { base.body(key) }
    func connectivity() -> AsyncStream<[AccountID: ConnectivityState]> { states }
    func pendingChanges() -> AsyncStream<[AccountID: Int]> { counts }
}

private let one = AccountID(1)
private let two = AccountID(2)
private let online = ConnectivityState.online(syncing: false, lastSyncAt: nil)

@MainActor
private func model(sleeper: DebounceGate = DebounceGate()) -> (StatusModel, DebounceGate) {
    let source = PendingSource(counts: AsyncStream { $0.finish() }, states: AsyncStream { $0.finish() })
    return (StatusModel(data: source, sleep: { try await sleeper.sleep($0) }), sleeper)
}

@Test func pendingTextWordsTheCountAndTheConnection() {
    #expect(StatusModel.pendingText(count: 0, connectivity: online) == nil)
    #expect(StatusModel.pendingText(count: 1, connectivity: online) == "Syncing 1 change to Gmail")
    #expect(StatusModel.pendingText(count: 3, connectivity: online) == "Syncing 3 changes to Gmail")
    #expect(StatusModel.pendingText(count: 3, connectivity: nil) == "Syncing 3 changes to Gmail")
    #expect(StatusModel.pendingText(count: 2, connectivity: .offline(since: fixedNow)) == "2 changes waiting for a connection")
    #expect(StatusModel.pendingText(count: 1, connectivity: .rateLimited(until: nil)) == "1 change waiting for a connection")
    #expect(StatusModel.pendingText(count: 3, connectivity: .needsReauth) == "3 changes waiting for you to sign in")
}

@MainActor
@Test func theLineWaitsForTheDebounceAndHidesAtOnceWhenEmpty() async {
    let (status, sleeper) = model()
    var asked = sleeper.asked.makeAsyncIterator()
    status.setPending([one: 3])
    #expect(await asked.next() == StatusModel.pendingDebounce)
    #expect(StatusModel.pendingDebounce == .milliseconds(400))
    #expect(status.pendingLine == nil)
    sleeper.release()
    await status.pendingDebounceFinished()
    #expect(status.pendingLine == "Syncing 3 changes to Gmail")
    status.setPending([one: 1])
    #expect(status.pendingLine == "Syncing 1 change to Gmail")
    status.setPending([:])
    #expect(status.pendingLine == nil)
    #expect(!status.isVisible)
}

@MainActor
@Test func anInstantSyncNeverShowsTheLine() async {
    let (status, sleeper) = model()
    var asked = sleeper.asked.makeAsyncIterator()
    status.setPending([one: 2])
    _ = await asked.next()
    status.setPending([:])
    sleeper.release()
    await status.pendingDebounceFinished()
    #expect(status.pendingLine == nil)
    #expect(!status.pendingSettled)
}

@MainActor
@Test func countsSumAcrossAccountsAndTheTooltipListsThemOnlyWhenSeveralHaveChanges() async {
    let (status, sleeper) = model()
    var asked = sleeper.asked.makeAsyncIterator()
    status.setPending([one: 2])
    _ = await asked.next()
    sleeper.release()
    await status.pendingDebounceFinished()
    #expect(status.pendingHelp == "Changes are saved on this Mac and sent to Gmail in the background.")
    status.setPending([one: 2, two: 1, AccountID(3): 0])
    #expect(status.pendingLine == "Syncing 3 changes to Gmail")
    #expect(status.pendingHelp.hasSuffix("Account 1: 2, Account 2: 1."))
}

@MainActor
@Test func theWorstConnectionAmongAccountsWithChangesDecidesTheWording() async {
    let source = PendingSource(counts: AsyncStream { $0.finish() }, states: AsyncStream { continuation in
        continuation.yield([one: online, two: .offline(since: fixedNow)])
        continuation.finish()
    })
    let sleeper = DebounceGate()
    let status = StatusModel(data: source, sleep: { try await sleeper.sleep($0) })
    await status.run()
    var asked = sleeper.asked.makeAsyncIterator()
    status.setPending([one: 1])
    _ = await asked.next()
    sleeper.release()
    await status.pendingDebounceFinished()
    #expect(status.pendingLine == "Syncing 1 change to Gmail")
    status.setPending([one: 1, two: 2])
    #expect(status.pendingLine == "3 changes waiting for a connection")
}

@MainActor
@Test func theLineFollowsTheSourceStream() async {
    let (counts, feed) = AsyncStream<[AccountID: Int]>.makeStream()
    let source = PendingSource(counts: counts, states: AsyncStream { $0.finish() })
    let sleeper = DebounceGate()
    let status = StatusModel(data: source, sleep: { try await sleeper.sleep($0) })
    var asked = sleeper.asked.makeAsyncIterator()
    let run = Task { await status.run() }
    feed.yield([one: 2])
    _ = await asked.next()
    sleeper.release()
    await status.pendingDebounceFinished()
    #expect(status.pendingLine == "Syncing 2 changes to Gmail")
    feed.finish()
    await run.value
}

@MainActor
@Test func theSwitchHidesTheLine() async {
    let settings = FakeMailStore(corpus: .make(threadCount: 1, now: fixedNow))
    let sleeper = DebounceGate()
    let source = PendingSource(counts: AsyncStream { $0.finish() }, states: AsyncStream { $0.finish() })
    let status = StatusModel(data: source, settings: settings, sleep: { try await sleeper.sleep($0) })
    var asked = sleeper.asked.makeAsyncIterator()
    status.setPending([one: 2])
    _ = await asked.next()
    sleeper.release()
    await status.pendingDebounceFinished()
    #expect(status.pendingLine != nil)
    #expect(AppSettings.showPendingSync.name == "ui.show_pending_sync")
    #expect(AppSettings.showPendingSync.defaultValue == true)
    await status.showPendingSync.set(false)
    #expect(status.pendingLine == nil)
}

@Test func theFakeStoreCountsOnlyQueuedOperationsAndFinishesWithoutLiveConnectivity() async {
    var quiet = FakeMailStore(corpus: .make(threadCount: 2, now: fixedNow)).pendingChanges().makeAsyncIterator()
    #expect(await quiet.next() == nil)
    let live = FakeMailStore(corpus: .make(threadCount: 2, now: fixedNow), options: .init(liveConnectivity: true))
    var first = live.pendingChanges().makeAsyncIterator()
    #expect(await first.next() == [:])
}
