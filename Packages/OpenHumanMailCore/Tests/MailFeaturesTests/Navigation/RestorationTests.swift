import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

final class ManualSleeper: Sendable {
    private struct Waiter { let id: Int; let duration: Duration; let continuation: CheckedContinuation<Void, any Error> }
    private let state = Mutex((next: 0, waiters: [Waiter]()))

    func sleep(_ duration: Duration) async throws {
        let id = state.withLock { s -> Int in s.next += 1; return s.next }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = Task.isCancelled
                if cancelled { continuation.resume(throwing: CancellationError()); return }
                state.withLock { $0.waiters.append(Waiter(id: id, duration: duration, continuation: continuation)) }
            }
        } onCancel: {
            let waiter = state.withLock { s -> Waiter? in
                guard let index = s.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return s.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    var waiting: Int { state.withLock { $0.waiters.count } }
    func waiting(for duration: Duration) -> Int { state.withLock { $0.waiters.filter { $0.duration == duration }.count } }

    @discardableResult
    func release(upTo duration: Duration = .seconds(60)) -> Int {
        let ready = state.withLock { s -> [Waiter] in
            let ready = s.waiters.filter { $0.duration <= duration }
            s.waiters.removeAll { $0.duration <= duration }
            return ready
        }
        for waiter in ready { waiter.continuation.resume() }
        return ready.count
    }
}

@MainActor
final class FakeReader: ReaderStateRestorable {
    let restorableThread: ThreadKey
    var place: ReaderPlace
    var restored: ReaderPlace?

    init(thread: ThreadKey, place: ReaderPlace = ReaderPlace()) {
        restorableThread = thread
        self.place = place
    }

    func captureReaderPlace() -> ReaderPlace { place }
    func restoreReaderPlace(_ place: ReaderPlace) {
        restored = place
        self.place = place
    }
}

func temporaryStateDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("oh-state-\(UUID().uuidString)", isDirectory: true)
}

@MainActor
@Suite struct RestorationTests {
    let corpus = FakeCorpus.rich(threadCount: 120, now: fixedNow)

    func router(_ store: any NavigationStateStoring, sleeper: ManualSleeper = ManualSleeper()) async -> (AppRouter, ManualSleeper) {
        let env = AppEnvironment.fake(corpus: corpus)
        let router = AppRouter(environment: env, location: nil, restoring: store, persistSleep: sleeper.sleep)
        router.start()
        await eventually { router.accounts.count == 2 && router.list?.state == .loaded }
        return (router, sleeper)
    }

    func settle(_ store: any NavigationStateStoring, _ sleeper: ManualSleeper,
                until matches: @escaping (NavigationSnapshot) -> Bool) async {
        await eventually {
            sleeper.release()
            return store.load().map(matches) ?? false
        }
    }

    @Test func everyFieldRoundTripsThroughTheFileStore() throws {
        let key = ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("t7"))
        let other = ThreadKey(account: AccountID(1), rowID: 9, gmailThreadID: GmailThreadID("t9"))
        let place = AccountPlace(
            account: AccountID(1), location: .label(GmailLabelID("Label_3")), cursor: key, scrollTop: other, openThread: key,
            cursorFallback: other, checked: [key, other], scrollOffset: 12.5,
            reader: ReaderPlace(expandedMessageIDs: ["m1", "m3"], scrollAnchorMessageID: "m3", scrollOffset: 40),
            searchText: "dinner plans", searchOpen: true)
        let window = WindowPlace(frame: CGRect(x: 40, y: 60, width: 1200, height: 800), displayID: 77, isFullScreen: false,
                                 isZoomed: true)
        let panels = PanelsPlace(checklistOpen: true, checklistItemID: "list.scroll", feedbackOpen: true, feedbackText: "typed")
        let snapshot = NavigationSnapshot(activeAccount: AccountID(1), labelSidebarVisible: true, places: [place],
                                          window: window, panels: panels, openDraftIDs: ["d1"])
        let directory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileNavigationStore(directory: directory, scope: "fake")
        #expect(store.load() == nil)
        store.save(snapshot)
        #expect(store.load() == snapshot)
        #expect(FileNavigationStore(directory: directory, scope: "live").load() == nil, "data modes never mix")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == ["navigation.fake.json"], "no temp file is left behind")
    }

    @Test func savedStateHoldsIdsAndCountsNeverSubjectsOrAddresses() throws {
        let key = ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("t7"))
        let snapshot = NavigationSnapshot(activeAccount: AccountID(1), places: [
            AccountPlace(account: AccountID(1), location: .system(.inbox), cursor: key),
        ])
        let json = String(decoding: try #require(snapshot.encoded()), as: UTF8.self)
        #expect(!json.contains("@"))
        #expect(json.contains("t7"))
    }

    @Test func aKilledProcessRestoresFromWhatTheDebounceAlreadyWrote() async throws {
        let directory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileNavigationStore(directory: directory, scope: "fake")
        var expectedPlace: AccountPlace?
        var checkedKey: ThreadKey?
        var scrollKey: ThreadKey?
        let readerPlace = ReaderPlace(expandedMessageIDs: ["a", "b"], scrollAnchorMessageID: "b", scrollOffset: 33)
        let window = WindowPlace(frame: CGRect(x: 50, y: 70, width: 1100, height: 700), displayID: 1, isFullScreen: false,
                                 isZoomed: false)
        do {
            let (first, sleeper) = await router(store)
            first.perform(.nextSplit)
            await eventually { first.list?.state == .loaded && (first.list?.rows.count ?? 0) > 6 }
            first.perform(.nextThread)
            first.perform(.nextThread)
            let rows = try #require(first.list?.rows)
            checkedKey = rows[4].id
            scrollKey = rows[3].id
            first.active?.selection.toggle(rows[4].id)
            first.active?.selection.scrollTop = rows[3].id
            first.active?.selection.scrollOffset = 7.5
            first.active?.searchText = "dinner"
            first.active?.searchOpen = true
            first.isLabelSidebarVisible = false
            first.windowPlace = window
            first.openDraftIDs = ["draft-1"]
            first.panelsSource = { PanelsPlace(checklistOpen: true, checklistItemID: "x.y", feedbackOpen: true, feedbackText: "unsent") }
            #expect(first.perform(.openThread))
            let reader = FakeReader(thread: try #require(first.reader?.thread), place: readerPlace)
            first.attachReader(reader)
            let openThread = first.reader?.thread
            await settle(store, sleeper) { $0.panels?.feedbackText == "unsent" && $0.place(for: AccountID(1))?.openThread == openThread
                && $0.place(for: AccountID(1))?.reader == readerPlace && $0.window == window }
            expectedPlace = store.load()?.place(for: AccountID(1))
        }
        let saved = try #require(expectedPlace)
        #expect(saved.checked == [try #require(checkedKey)])
        #expect(saved.scrollTop == scrollKey && saved.scrollOffset == 7.5)
        #expect(saved.searchText == "dinner" && saved.searchOpen)

        let (second, _) = await router(store)
        #expect(second.activeAccountID == AccountID(1))
        #expect(second.location == saved.location)
        #expect(!second.isLabelSidebarVisible, "the hidden sidebar is kept")
        #expect(second.windowPlace == window)
        #expect(second.restoredWindowPlace == window)
        #expect(second.openDraftIDs == ["draft-1"])
        #expect(second.restoredPanels == PanelsPlace(checklistOpen: true, checklistItemID: "x.y", feedbackOpen: true,
                                                     feedbackText: "unsent"))
        let active = try #require(second.active)
        #expect(active.searchText == "dinner" && active.searchOpen)
        #expect(active.selection.scrollTop == scrollKey && active.selection.scrollOffset == 7.5)
        await eventually { second.mode == .reader && second.reader?.thread == saved.openThread }
        await eventually { second.list?.cursor == saved.cursor }
        await eventually { active.selection.checked == Set(saved.checked) }
        #expect(second.location == .splitOther || second.location == saved.location)
        let reader = FakeReader(thread: try #require(saved.openThread))
        second.attachReader(reader)
        #expect(reader.restored == readerPlace)
        let again = FakeReader(thread: try #require(saved.openThread))
        second.attachReader(again)
        #expect(again.restored == nil, "given back once")
    }

    @Test func restoringNeverAsksForTheNetworkOrWritesMail() async throws {
        let store = InMemoryNavigationStore()
        let (first, sleeper) = await router(store)
        first.perform(.nextThread)
        #expect(first.perform(.openThread))
        await settle(store, sleeper) { $0.place(for: AccountID(1))?.openThread != nil }
        let fake = FakeMailStore(corpus: corpus)
        let recording = RecordingCommands(fake)
        let env = AppEnvironment(data: fake, commands: recording, accounts: fake, settings: fake, isFake: true,
                                 navigationStore: store)
        let second = env.router
        second.start()
        await eventually { second.mode == .reader }
        #expect(recording.calls.isEmpty, "restoring sends no command and asks for no fetch")
    }

    @Test func corruptEmptyAndFutureDataStartCleanWithoutCrashing() throws {
        let directory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileNavigationStore(directory: directory, scope: "live")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for garbage in [Data(), Data("not json".utf8), Data("{\"version\":2".utf8), Data("[1,2,3]".utf8),
                        Data("{\"version\":2,\"places\":\"nope\"}".utf8), Data(repeating: 0xFF, count: 64)] {
            try garbage.write(to: store.url)
            #expect(store.load() == nil)
        }
        var future = NavigationSnapshot(activeAccount: AccountID(1))
        future.version = NavigationSnapshot.currentVersion + 1
        store.save(future)
        #expect(store.load() == nil, "written by a newer build: ignored")
        var zero = NavigationSnapshot(activeAccount: AccountID(1))
        zero.version = 0
        store.save(zero)
        #expect(store.load() == nil)
        try Data("not json".utf8).write(to: store.url)
        let good = NavigationSnapshot(activeAccount: AccountID(2), labelSidebarVisible: true)
        store.save(good)
        #expect(store.load() == good)
    }

    @Test func versionOneDataStillRestoresWhatItHad() throws {
        let json = """
        {"version":1,"activeAccount":2,"labelSidebarVisible":true,"places":[]}
        """
        let snapshot = try #require(NavigationSnapshot.decode(Data(json.utf8)))
        #expect(snapshot.activeAccount == AccountID(2) && snapshot.labelSidebarVisible)
        #expect(snapshot.window == nil && snapshot.panels == nil && snapshot.openDraftIDs.isEmpty)
    }

    @Test func aRouterOverGarbageStartsOnTheFirstTab() async throws {
        let directory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileNavigationStore(directory: directory, scope: "fake")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("\u{0}garbage".utf8).write(to: store.url)
        let (router, _) = await router(store)
        #expect(router.location == router.active?.firstTab)
        #expect(router.isLabelSidebarVisible, "nothing saved, so the sidebar is shown")
    }

    @Test func theLegacyUserDefaultsValueIsReadUntilTheFileExists() throws {
        let suite = ScopedDefaults("dev.openhuman.mail.tests.restoration")
        defer { suite.cleanup() }
        let legacy = UserDefaultsNavigationStore(scope: "fake", suiteName: suite.name)
        legacy.save(NavigationSnapshot(activeAccount: AccountID(2), labelSidebarVisible: true))
        let directory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileNavigationStore(directory: directory, scope: "fake", legacy: legacy)
        #expect(store.load()?.activeAccount == AccountID(2))
        store.save(NavigationSnapshot(activeAccount: AccountID(1)))
        #expect(store.load()?.activeAccount == AccountID(1), "the file wins once it exists")
    }

    @Test func aBurstOfChangesIsOneWrite() async throws {
        let store = InMemoryNavigationStore()
        let (router, sleeper) = await router(store)
        await eventually { sleeper.release(); return store.saveCount >= 1 }
        let before = store.saveCount
        for _ in 0..<5 { router.perform(.nextThread) }
        router.isLabelSidebarVisible = false
        router.active?.searchText = "burst"
        await eventually { sleeper.waiting(for: PersistDebouncer.standardDelay) == 1 }
        #expect(store.saveCount == before, "nothing is written while the burst is still debouncing")
        sleeper.release(upTo: PersistDebouncer.standardDelay)
        await eventually { store.saveCount == before + 1 }
        sleeper.release()
        await eventually { sleeper.waiting == 0 }
        #expect(store.saveCount == before + 1, "one write for the whole burst")
        #expect(store.load()?.labelSidebarVisible == false)
        #expect(store.load()?.place(for: AccountID(1))?.searchText == "burst")
    }

    @Test func aLongBurstStillSavesAtTheCeiling() async throws {
        let sleeper = ManualSleeper()
        let counter = Mutex(0)
        let debouncer = PersistDebouncer(sleep: sleeper.sleep) { counter.withLock { $0 += 1 } }
        for _ in 0..<10 { debouncer.schedule() }
        await eventually { sleeper.waiting(for: PersistDebouncer.standardMaxDelay) == 1 }
        #expect(counter.withLock { $0 } == 0)
        sleeper.release(upTo: PersistDebouncer.standardMaxDelay)
        await eventually { counter.withLock { $0 } == 1 }
        #expect(!debouncer.isPending)
    }

    @Test func flushWritesAPendingSaveNowAndNothingOtherwise() async throws {
        let sleeper = ManualSleeper()
        let counter = Mutex(0)
        let debouncer = PersistDebouncer(sleep: sleeper.sleep) { counter.withLock { $0 += 1 } }
        debouncer.flush()
        #expect(counter.withLock { $0 } == 0)
        debouncer.schedule()
        debouncer.flush()
        #expect(counter.withLock { $0 } == 1)
        debouncer.flush()
        #expect(counter.withLock { $0 } == 1)
    }

    @Test func theFinalFlushSavesOnceAndFreezesTheState() async throws {
        let store = InMemoryNavigationStore()
        let (router, sleeper) = await router(store)
        router.isLabelSidebarVisible = false
        router.finalFlush()
        #expect(store.load()?.labelSidebarVisible == false, "saved without waiting for the debounce")
        router.isLabelSidebarVisible = true
        router.perform(.nextSplit)
        router.persist()
        sleeper.release()
        #expect(store.load()?.labelSidebarVisible == false, "nothing is written after the last flush")
    }

    @Test func aFrameOnAnAttachedScreenIsKept() {
        let screens = [CGRect(x: 0, y: 0, width: 1728, height: 1080), CGRect(x: 1728, y: 0, width: 1920, height: 1080)]
        let place = WindowPlace(frame: CGRect(x: 1800, y: 100, width: 1000, height: 700))
        #expect(place.validatedFrame(screens: screens) == place.frame)
    }

    @Test func aFrameOnAMissingScreenIsBroughtBackCentered() throws {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 875)]
        let place = WindowPlace(frame: CGRect(x: 3000, y: 200, width: 1000, height: 700), displayID: 9)
        let fixed = try #require(place.validatedFrame(screens: screens))
        #expect(screens[0].contains(fixed))
        #expect(fixed.size == place.frame.size)
        #expect(fixed.midX == screens[0].midX && fixed.midY == screens[0].midY)
    }

    @Test func aMostlyOffscreenFrameAndAnOversizedFrameAreCorrected() throws {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let barelyOn = WindowPlace(frame: CGRect(x: 1430, y: 100, width: 1000, height: 700))
        let a = try #require(barelyOn.validatedFrame(screens: [screen]))
        #expect(screen.contains(a))
        let huge = WindowPlace(frame: CGRect(x: 0, y: 25, width: 5000, height: 4000))
        let b = try #require(huge.validatedFrame(screens: [screen]))
        #expect(b.width <= screen.width && b.height <= screen.height && b.maxY <= screen.maxY)
        let aboveTop = WindowPlace(frame: CGRect(x: 100, y: 600, width: 1000, height: 700))
        let c = try #require(aboveTop.validatedFrame(screens: [screen]))
        #expect(c.maxY <= screen.maxY)
        #expect(WindowPlace(frame: CGRect(x: 0, y: 0, width: 100, height: 100)).validatedFrame(screens: []) == nil)
        #expect(WindowPlace(frame: CGRect(x: Double.nan, y: 0, width: 100, height: 100)).validatedFrame(screens: [screen]) == nil)
    }

    func otherRows() async throws -> [ThreadKey] {
        let (probe, _) = await router(InMemoryNavigationStore())
        probe.perform(.previousSplit)
        await eventually { probe.location == .splitOther && probe.list?.state == .loaded && (probe.list?.rows.count ?? 0) > 5 }
        return try #require(probe.list?.rows).map(\.id)
    }

    @Test func aMissingCursorFallsBackToItsNeighbourAndAMissingConversationStaysClosed() async throws {
        let rows = try await otherRows()
        let gone = ThreadKey(account: AccountID(1), rowID: 987_654, gmailThreadID: GmailThreadID("gone"))
        let store = InMemoryNavigationStore(NavigationSnapshot(activeAccount: AccountID(1), places: [
            AccountPlace(account: AccountID(1), location: .splitOther, cursor: gone, openThread: gone,
                         cursorFallback: rows[3]),
        ]))
        let (router, _) = await router(store)
        await eventually { router.list?.cursor == rows[3] }
        await eventually { router.mode == .list }
        #expect(router.location == .splitOther)
        #expect(router.reader == nil)
        #expect(router.accountsError == nil)
    }

    @Test func aMissingCursorWithoutANeighbourLandsOnTheListTop() async throws {
        let rows = try await otherRows()
        let gone = ThreadKey(account: AccountID(1), rowID: 987_654, gmailThreadID: GmailThreadID("gone"))
        let goneToo = ThreadKey(account: AccountID(1), rowID: 987_655, gmailThreadID: GmailThreadID("gone2"))
        let store = InMemoryNavigationStore(NavigationSnapshot(activeAccount: AccountID(1), places: [
            AccountPlace(account: AccountID(1), location: .splitOther, cursor: gone, scrollTop: goneToo, cursorFallback: goneToo),
        ]))
        let (router, _) = await router(store)
        await eventually { router.list?.cursor == rows.first }
        #expect(router.mode == .list)
        router.persist()
        #expect(store.load()?.place(for: AccountID(1))?.cursor == rows.first)
    }

    @Test func sigtermFlushesThenExits() async throws {
        let flushed = Mutex(0)
        let exitCode = Mutex<Int32?>(nil)
        let handler = TerminationSignalHandler(signals: [SIGUSR2], flush: { flushed.withLock { $0 += 1 } },
                                               terminate: { code in exitCode.withLock { $0 = code } })
        kill(getpid(), SIGUSR2)
        await eventually { exitCode.withLock { $0 } != nil }
        #expect(flushed.withLock { $0 } == 1)
        #expect(exitCode.withLock { $0 } == 0)
        withExtendedLifetime(handler) {}
    }
}
