import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanLinks
import Testing
@testable import MailFeatures

@MainActor
@Suite struct AppRouterTests {
    let corpus = FakeCorpus.rich(threadCount: 120, now: fixedNow)

    func shell(_ navigation: (any NavigationStateStoring)? = nil,
               options: FakeMailStore.Options = .init()) async -> (AppEnvironment, AppRouter) {
        let env = AppEnvironment.fake(corpus: corpus, options: options, navigationStore: navigation)
        let router = env.router
        router.start()
        await eventually { router.accounts.count == 2 && router.list?.state == .loaded }
        return (env, router)
    }

    func loaded(_ router: AppRouter, atLeast rows: Int = 1) async {
        await eventually { router.list?.state == .loaded && (router.list?.rows.count ?? 0) >= rows }
    }

    @Test func switchingAccountsRestoresEachAccountsTabCursorAndConversation() async throws {
        let (_, router) = await shell()
        let work = try #require(router.active)
        #expect(work.account.alias == "Work")
        #expect(router.showsAccountSwitcher)
        #expect(work.tabs.map(\.title) == ["Important", "Newsletters", "Other"])
        #expect(router.location == work.tabs[0].location, "first launch starts on the first split tab")

        #expect(router.perform(.previousSplit))
        #expect(router.location == .splitOther)
        await loaded(router, atLeast: 4)
        router.perform(.nextThread)
        router.perform(.nextThread)
        let workCursor = try #require(router.list?.cursor)
        #expect(router.list?.cursorIndex == 2)

        #expect(router.perform(.switchToAccount(2)))
        let personal = try #require(router.active)
        #expect(personal.account.alias == "Personal")
        await loaded(router, atLeast: 2)
        #expect(personal.location == personal.firstTab)
        #expect(personal.tabs.map(\.title) == ["Important", "Other"])
        router.perform(.nextThread)
        #expect(router.perform(.openThread))
        let personalThread = try #require(router.reader?.thread)

        #expect(router.perform(.switchToAccount(1)))
        #expect(router.active === work)
        #expect(router.location == .splitOther)
        #expect(router.mode == .list)
        #expect(router.list?.cursor == workCursor)

        #expect(router.perform(.switchToAccount(2)))
        #expect(router.mode == .reader)
        #expect(router.reader?.thread == personalThread)
        #expect(!router.perform(.switchToAccount(3)), "no third account: the key passes through")
        #expect(router.isEnabled(.switchToAccount(2)))
        #expect(!router.isEnabled(.switchToAccount(3)))
    }

    @Test func oneAccountHasNoSwitcher() async {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 5, now: fixedNow))
        let router = env.router
        router.start()
        await eventually { router.list?.state == .loaded }
        #expect(!router.showsAccountSwitcher)
        #expect(!router.isEnabled(.switchToAccount(1)))
        #expect(router.active?.tabs.map(\.title) == ["Important", "Other"])
    }

    @Test func tabKeyCyclesSplitsAndGChordsGoToLocations() async throws {
        let (_, router) = await shell()
        let work = try #require(router.active)
        let tabs = work.tabs.map(\.location)
        #expect(router.perform(.nextSplit))
        #expect(router.location == tabs[1])
        router.perform(.nextSplit)
        #expect(router.location == tabs[2])
        router.perform(.nextSplit)
        #expect(router.location == tabs[0], "⇥ wraps")
        router.perform(.previousSplit)
        #expect(router.location == tabs[2])

        await eventually { work.counts != nil }
        let counts = try #require(work.counts)
        #expect(work.tabs.last?.unread == counts.otherUnread)
        if case .split(let key) = tabs[0] { #expect(work.tabs[0].unread == counts.splitUnread[key] ?? 0) }

        router.perform(.nextSplit)
        router.perform(.nextSplit)
        #expect(router.perform(.goStarred))
        #expect(router.location == .system(.starred))
        #expect(!work.isOnTab)
        #expect(router.windowTitle == "Starred — robin@example.com")
        #expect(router.perform(.goInbox))
        #expect(router.location == tabs[1], "G I returns to the inbox tab last shown")
        router.perform(.goSent)
        #expect(router.perform(.nextSplit))
        #expect(router.location == tabs[0], "⇥ from a non-tab location goes to the first tab")
        for (action, location) in [(ActionID.goDrafts, MailLocation.system(.drafts)), (.goAllMail, .system(.allMail)),
                                   (.goSnoozed, .system(.snoozed)), (.goReminders, .system(.reminders)),
                                   (.goScheduled, .system(.scheduled)), (.goReview, .reviewQueue(nil))] {
            #expect(router.perform(action))
            #expect(router.location == location)
        }

        router.go(to: tabs[0])
        await loaded(router)
        router.perform(.openThread)
        #expect(!router.perform(.nextSplit))
        #expect(router.location == tabs[0])
    }

    @Test func sidebarListsTabsSystemViewsAndUserLabels() async throws {
        let (_, router) = await shell()
        let work = try #require(router.active)
        await eventually { !work.labels.isEmpty && work.counts != nil }
        let titles = work.sidebarItems.map(\.title)
        #expect(Array(titles.prefix(3)) == ["Important", "Newsletters", "Other"])
        for title in ["Starred", "Snoozed", "Reminders", "Scheduled", "Drafts", "Sent", "Done", "All mail", "Spam", "Trash",
                      "Clients", "Atlas"] {
            #expect(titles.contains(title), "missing \(title)")
        }
        #expect(!titles.contains { $0.hasPrefix("OpenHuman") }, "Mail's own labels stay hidden")
        let atlas = try #require(work.sidebarItems.first { $0.title == "Atlas" })
        #expect(atlas.depth == 1)
        #expect(router.isLabelSidebarVisible, "the sidebar is shown by default")
        #expect(router.perform(.toggleLabelSidebar))
        #expect(!router.isLabelSidebarVisible)
    }

    @Test func placesAreRestoredOnRelaunch() async throws {
        let navigation = InMemoryNavigationStore()
        var openThread: ThreadKey?
        do {
            let (_, router) = await shell(navigation)
            router.perform(.nextSplit)
            router.perform(.switchToAccount(2))
            #expect(router.perform(.nextSplit), "consumed, but the tabs are not known yet")
            await loaded(router)
            #expect(router.location == router.active?.firstTab)
            router.perform(.nextSplit)
            await loaded(router, atLeast: 3)
            router.perform(.nextThread)
            router.perform(.openThread)
            openThread = router.reader?.thread
            router.isLabelSidebarVisible = false
            router.stop()
        }
        let saved = try #require(navigation.load())
        #expect(saved.activeAccount == AccountID(2))
        #expect(saved.place(for: AccountID(2))?.openThread == openThread)

        let (_, second) = await shell(navigation)
        #expect(second.active?.account.alias == "Personal")
        #expect(second.location == .splitOther)
        #expect(!second.isLabelSidebarVisible, "the hidden sidebar is kept")
        await eventually { second.mode == .reader }
        #expect(second.reader?.thread == openThread)
        await eventually { second.list?.cursor == openThread }
        second.perform(.switchToAccount(1))
        await loaded(second)
        #expect(second.location == second.active?.tabs[1].location, "Work kept Newsletters")
    }

    @Test func searchesAndDeletedSplitsAreNotRestored() async throws {
        let navigation = InMemoryNavigationStore(NavigationSnapshot(activeAccount: AccountID(1), places: [
            AccountPlace(account: AccountID(1), location: .split(SplitKey("split-999"))),
            AccountPlace(account: AccountID(2), location: .search("dinner")),
        ]))
        let (_, router) = await shell(navigation)
        await eventually { router.location == router.active?.firstTab }
        router.perform(.switchToAccount(2))
        await loaded(router)
        #expect(router.location == router.active?.firstTab)
        router.go(to: .search("plans"))
        router.persist()
        #expect(navigation.load()?.place(for: AccountID(2))?.location == router.active?.firstTab)
    }

    @Test func userDefaultsStoreRoundTripsAndIgnoresOtherVersions() throws {
        let suite = ScopedDefaults("dev.openhuman.mail.tests.navigation")
        defer { suite.cleanup() }
        let store = UserDefaultsNavigationStore(scope: "fake", suiteName: suite.name)
        #expect(store.key == "dev.openhuman.mail.navigation.fake")
        #expect(store.load() == nil)
        let key = ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("t7"))
        let snapshot = NavigationSnapshot(activeAccount: AccountID(1), labelSidebarVisible: true, places: [
            AccountPlace(account: AccountID(1), location: .label(GmailLabelID("Label_3")), cursor: key, scrollTop: key,
                         openThread: key),
        ])
        store.save(snapshot)
        #expect(store.load() == snapshot)
        #expect(UserDefaultsNavigationStore(scope: "live", suiteName: suite.name).load() == nil, "scopes never mix")
        var future = snapshot
        future.version = 99
        store.save(future)
        #expect(store.load() == nil)
    }

    @Test func bannersFollowTheFakeStoreByPriority() async throws {
        let (env, router) = await shell(options: .init(liveConnectivity: true))
        let store = try #require(env.data as? FakeMailStore)
        let follower = Task { await env.status.run() }
        defer { follower.cancel() }
        await eventually { env.status.connectivity.count == 2 }
        #expect(router.banner() == nil)

        store.setConnectivity(.syncFailing(code: "server_503", failures: 3, lastSyncAt: nil), for: AccountID(1))
        await eventually { router.banner()?.kind == .syncFailing }
        #expect(router.banner()?.message == "Gmail is having trouble. Retrying.")
        #expect(router.banner()?.detail == "server_503")
        #expect(router.banner()?.tone == .warning)

        store.setConnectivity(.rateLimited(until: fixedNow.addingTimeInterval(30)), for: AccountID(1))
        await eventually { router.banner()?.kind == .rateLimited }
        #expect(router.banner(now: fixedNow)?.message == "Gmail asked us to slow down. Retrying in 30 s.")

        store.setOffline(true)
        await eventually { router.banner()?.kind == .offline }
        #expect(router.banner()?.tone == .neutral)
        #expect(router.banner()?.message == "Offline. Your changes are saved and will sync when you're back.")

        store.expireAuth(AccountID(1))
        await eventually { router.banner()?.kind == .auth }
        #expect(router.banner()?.message == "Work account needs you to sign in again.")
        #expect(router.banner()?.actionTitle == "Sign in")

        router.perform(.switchToAccount(2))
        #expect(router.banner()?.kind == .offline, "auth is the active account's banner")
        store.setOffline(false)
        await eventually { router.banner() == nil }
    }

    @Test func markDoneRemovesTheRowAndUndoPutsItAndTheCursorBack() async throws {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 10, now: fixedNow), options: .init(remoteAck: .immediate))
        let router = AppRouter(environment: env)
        router.start()
        await eventually { router.list?.rows.count == 10 }
        router.perform(.nextThread)
        let target = try #require(router.list?.cursor)
        #expect(router.isEnabled(.markDone))
        #expect(!router.isEnabled(.undo))
        #expect(router.perform(.markDone))
        await eventually { router.list?.rows.count == 9 }
        #expect(router.list?.index(of: target) == nil)
        #expect(router.list?.cursorIndex == 1, "the next (older) row takes the cursor")
        await eventually { env.notices.toasts.contains { $0.message == "Marked done" && $0.style == .undo } }
        #expect(env.notices.toasts.last?.shortcut == "⌘Z")

        #expect(router.isEnabled(.undo))
        #expect(router.perform(.undo))
        await eventually { router.list?.rows.count == 10 }
        await eventually { router.list?.cursor == target }

        #expect(router.perform(.redo))
        await eventually { router.list?.rows.count == 9 }

        router.perform(.trash)
        await eventually { env.notices.toasts.contains { $0.message == "Moved to Trash" } }
        await eventually { router.list?.rows.count == 8 }
    }

    @Test func markDoneInAConversationOpensTheNextOne() async throws {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 6, now: fixedNow), options: .init(remoteAck: .immediate))
        let router = AppRouter(environment: env)
        router.start()
        await eventually { router.list?.rows.count == 6 }
        let rows = try #require(router.list?.rows.map(\.id))
        router.perform(.nextThread)
        router.perform(.openThread)
        #expect(router.reader?.thread == rows[1])
        #expect(router.perform(.markDone))
        #expect(router.mode == .reader)
        #expect(router.reader?.thread == rows[2], "the next (older) conversation opens at once")
        await eventually { router.list?.rows.count == 5 }
    }

    @Test func aPortRefusalRestoresTheRowAndSaysItFailed() async throws {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 5, now: fixedNow))
        let store = try #require(env.commands as? FakeMailStore)
        let router = AppRouter(environment: env)
        router.start()
        await eventually { router.list?.rows.count == 5 }
        store.failNextCommand(.notAllowed("this change"))
        #expect(await env.actions.run(.markDone, source: .keyboard, host: router))
        #expect(env.notices.toasts.contains { $0.message == "Couldn't mark 1 conversation done" && $0.style == .error })
        #expect(router.list?.optimisticKeys.isEmpty == true)
        await untilObserved { router.list?.rows.count == 5 }
        #expect(env.undo?.canUndo == false)
    }

    @Test func linksNavigateAndNeverMutate() async throws {
        let base = FakeMailStore(corpus: corpus)
        let recorder = RecordingCommands(base)
        let env = AppEnvironment(data: base, commands: recorder, accounts: base, settings: base, isFake: true)
        let router = env.router
        router.start()
        await eventually { router.accounts.count == 2 && router.list?.state == .loaded }
        let work = try #require(router.active)

        let row = try #require(router.list?.rows.dropFirst(2).first)
        let opened = router.route(.thread(account: AccountRef("ROBIN@example.com"), threadID: row.id.gmailThreadID.rawValue))
        #expect(opened == LinkOutcome("Opened thread \(row.id.gmailThreadID.rawValue).", handled: true))
        #expect(router.mode == .reader)
        #expect(router.reader?.thread == row.id)

        let inbox = Set(try await base.threadPage(.system(.inbox), account: work.id, after: nil, limit: 1_000).rows.map(\.id))
        let all = try await base.threadPage(.system(.allMail), account: work.id, after: nil, limit: 1_000).rows
        let outside = try #require(all.first { !inbox.contains($0.id) })
        let fetching = router.route(.thread(account: AccountRef("Work"), threadID: outside.id.gmailThreadID.rawValue))
        #expect(fetching.handled)
        await eventually { router.reader?.thread == outside.id }

        let personalRow = try await base.threadPage(.system(.inbox), account: AccountID(2), after: nil, limit: 1).rows.first
        let other = try #require(personalRow)
        #expect(router.route(.thread(account: AccountRef("Personal"), threadID: other.id.gmailThreadID.rawValue)).handled)
        #expect(router.activeAccountID == AccountID(2))
        await eventually { router.reader?.thread == other.id }

        #expect(router.route(.thread(account: AccountRef("nobody@example.org"), threadID: "x"))
            == LinkOutcome("No account named “nobody@example.org”.", handled: false))
        #expect(router.route(.search(query: "budget", account: AccountRef("robin@example.com")))
            == LinkOutcome("Showing search results.", handled: true))
        #expect(router.activeAccountID == work.id)
        #expect(router.location == .search("budget"))
        #expect(router.mode == .list)
        #expect(router.route(.draft(account: AccountRef("Work"), draftID: "d1"))
            == LinkOutcome("Opening draft d1…", handled: true))
        await eventually { env.notices.toasts.contains { $0.message == "Draft not found" } }
        let review = router.route(.review([DraftRef(account: AccountRef("Work"), draftID: "d1"),
                                           DraftRef(account: AccountRef("nobody@example.org"), draftID: "d2")]))
        #expect(review == LinkOutcome("Showing 2 drafts to review.", handled: true))
        #expect(router.location == .reviewQueue([DraftKey("d1"), DraftKey("d2")]))
        #expect(env.review.rows.map(\.target.draftID) == ["d1", "d2"])
        await eventually { env.review.rows.map(\.state) == [.notFound, .accountNotSetUp] }
        #expect(router.route(.review([DraftRef(account: AccountRef("nobody@example.org"), draftID: "d1")]))
            == LinkOutcome("No account named “nobody@example.org”.", handled: false))
        let compose = router.route(.compose(ComposePrefill(to: ["a@example.com"], droppedBcc: true)))
        #expect(compose == LinkOutcome("Opened a new message from the link.", handled: true))
        let session = try #require(env.composeIfStarted?.windowSession)
        #expect(session.linkRecipients?.map(\.email) == ["a@example.com"])
        #expect(session.bcc.tokens.isEmpty && session.linkTriedBcc)
        #expect(router.route(.compose(ComposePrefill(account: AccountRef("nobody@example.org")))).handled == false)
        #expect(!recorder.calls.isEmpty)
        #expect(recorder.calls.allSatisfy { $0 == "fetchThreadNow" || $0 == "fetchDraftNow" },
                "links only navigate and pre-fill: \(recorder.calls)")
        #expect(base.pendingOperationCount == 0)
    }
}
