import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailUI
import MailUIMac
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanLinks
import OpenHumanStore
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

@MainActor
@Suite(.serialized)
struct AppShellTests {
    @Test func fakeDataOpensTwoAccountsWithAnInMemoryNavigationStoreUnderTests() async throws {
        let app = CompositionRoot.makeApp(arguments: ["-UseFakeData"], environment: ["XCTestConfigurationFilePath": "x"])
        guard case .mail(let environment) = app.screen else { Issue.record("not the mail screen"); return }
        #expect(environment.navigationStore is InMemoryNavigationStore)
        #expect(environment.commands != nil && environment.undo != nil)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-nav-\(UUID().uuidString)").path
        let live = CompositionRoot.navigationStore("live", ["OPENHUMAN_HOME": home]) as? FileNavigationStore
        #expect(live?.url.path == home + "/State/navigation.live.json")
        let router = try #require(app.router)
        router.start()
        await eventually("two accounts") { router.accounts.count == 2 && router.list?.state == .loaded }
        #expect(router.showsAccountSwitcher)
        #expect(router.active?.tabs.map(\.title) == ["Important", "Newsletters", "Other"])
    }

    @Test func linksFromLaunchServicesRouteInsideTheWindow() async throws {
        let corpus = FakeCorpus.make(threadCount: 12)
        let app = AppModel(screen: .mail(.fake(corpus: corpus)))
        let router = try #require(app.router)
        router.start()
        await eventually("list") { router.list?.state == .loaded }
        let target = corpus.threads[2].row.id
        let opened = AppDelegate.open(try #require(URL(string: "openhuman://thread/robin@example.com/\(target.gmailThreadID.rawValue)")),
                                      in: app)
        #expect(opened.handled)
        await eventually("opened") { router.reader?.thread == target }

        guard case .mail(let environment) = app.screen else { return }
        let compose = AppDelegate.open(try #require(URL(string: "openhuman://compose?to=a@example.com&bcc=spy@example.com")),
                                       in: app)
        #expect(compose.handled)
        let session = try #require(environment.composeIfStarted?.windowSession)
        #expect(session.linkRecipients?.map(\.email) == ["a@example.com"])
        #expect(session.bcc.tokens.isEmpty)
        let mailto = AppDelegate.open(try #require(URL(string: "mailto:dana@example.test?subject=Lunch%3F&body=Noon%0D%0Aworks&bcc=spy@example.test")),
                                      in: app)
        #expect(mailto.handled)
        let drafted = try #require(environment.composeIfStarted?.windowSession)
        #expect(drafted !== session && drafted.linkRecipients?.map(\.email) == ["dana@example.test"])
        #expect(drafted.subject == "Lunch?" && drafted.bcc.tokens.isEmpty && drafted.linkTriedBcc)
        #expect(!drafted.isLinkConfirmationShown, "a mailto link only opens a draft")
        let bad = AppDelegate.open(try #require(URL(string: "openhuman://nowhere/x")), in: app)
        #expect(!bad.handled)
        #expect(environment.notices.toasts.last?.message == "Mail can't open that link.")
        let hostile = AppDelegate.open(try #require(URL(string: "mailto:a@example.test%0D%0ABcc:%20spy@example.test")), in: app)
        #expect(!hostile.handled && environment.composeIfStarted?.windowSession === drafted)
        let none = AppDelegate.open(try #require(URL(string: "openhuman://search?q=x")),
                                    in: AppModel(screen: .notice(StartupProblem(title: "t", message: "m"))))
        #expect(none == LinkOutcome("No mail window is open.", handled: false))
    }

    @Test func aReviewLinkShowsTheThreeDraftQueueAndABareIDIsRejected() async throws {
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 60, now: Date(timeIntervalSince1970: 1_791_000_000)))
        let app = AppModel(screen: .mail(environment))
        let router = try #require(app.router)
        router.start()
        await eventually("list") { router.list?.state == .loaded }
        var pending: [DraftSummary] = []
        for try await rows in environment.data.reviewQueue(AccountID(1)) { pending = rows; break }
        let three = Array(pending.prefix(3))
        #expect(three.count == 3)
        let ids = three.map(\.id.rawValue).joined(separator: ",")

        let bare = AppDelegate.open(try #require(URL(string: "openhuman://review?ids=\(ids)")), in: app)
        #expect(!bare.handled && !environment.review.isOpen, "a bare id without account= is rejected as a whole")

        let opened = AppDelegate.open(try #require(URL(string: "openhuman://review?account=robin%40example.com&ids=\(ids)")), in: app)
        #expect(opened.handled)
        await eventually("three ready rows") { environment.review.rows.count == 3 && environment.review.rows.allSatisfy(\.isActionable) }
        #expect(environment.review.rows.compactMap { $0.draft?.id } == three.map(\.id))
        #expect(router.location == .reviewQueue(three.map(\.id)))
        #expect(router.actionContext().scope == .review)
        var after: [DraftSummary] = []
        for try await rows in environment.data.reviewQueue(AccountID(1)) { after = rows; break }
        #expect(after.map(\.id) == pending.map(\.id) && after.allSatisfy { $0.review == .pending })
    }

    @Test func theMenuBarListsTheCatalog() throws {
        var menus: [String: [NSMenuItem]] = [:]
        for item in NSApp.mainMenu?.items ?? [] { menus[item.title] = item.submenu?.items ?? [] }
        let message = try #require(menus["Message"], "menu bar: \(menus.keys.sorted())")
        let go = try #require(menus["Go"])
        let view = try #require(menus["View"])
        let file = try #require(menus["File"])
        let format = try #require(menus["Format"], "the composer's formatting (keymap fixes, decision K11)")
        let titles = Set((message + go + view + file + format).map(\.title))
        for descriptor in ActionCatalog.all where descriptor.id.accountPosition == nil && descriptor.appearsInMenu {
            #expect(titles.contains { $0.hasPrefix(descriptor.title) }, "\(descriptor.title) is not in the menu bar")
        }
        let sidebar = try #require(view.first { $0.title.hasPrefix("Label Sidebar") })
        #expect(sidebar.keyEquivalent.lowercased() == "s")
        #expect(sidebar.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) == [.control, .command])
        let done = try #require(message.first { $0.title.hasPrefix("Mark done") })
        #expect(done.keyEquivalent.isEmpty, "single keys are never key equivalents")
        let newMessage = try #require(file.first { $0.title.hasPrefix("New message") && !$0.title.contains("window") })
        #expect(newMessage.keyEquivalent.lowercased() == "n")
        #expect(newMessage.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) == [.command])
        let search = try #require(go.first { $0.title.hasPrefix("Search") })
        #expect(search.keyEquivalent.isEmpty, "⌘F stays free for the text's find outside the list")
        #expect(format.filter { !$0.isSeparatorItem }.allSatisfy { $0.keyEquivalent.isEmpty })
    }

    @Test func noTwoMenuItemsShareAKeyEquivalent() {
        var seen: [String: String] = [:]
        var duplicates: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu) }
                guard !item.keyEquivalent.isEmpty, !item.isHidden else { continue }
                let mask = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
                let key = "\(mask.rawValue)+\(item.keyEquivalent.lowercased())"
                if let other = seen[key], other != item.title { duplicates.append("\(other) / \(item.title)") }
                seen[key] = item.title
            }
        }
        if let menu = NSApp.mainMenu { walk(menu) }
        let catalogTitles = Set(ActionCatalog.all.map(\.title))
        let ours = duplicates.filter { pair in catalogTitles.contains { pair.contains($0) } }
        #expect(ours.isEmpty, "catalog key equivalents that another menu item also has: \(ours)")
    }

    @Test func theSceneWindowIsTheShell() async throws {
        await eventually("main window") { Self.mainWindow != nil && MailApp.app.router?.list?.state == .loaded }
        let window = try #require(Self.mainWindow)
        let router = try #require(MailApp.app.router)
        await eventually("title") { window.title == ShellTitles.title(router) && window.subtitle == ShellTitles.subtitle(router) }
        let account = try #require(router.account)
        #expect(window.subtitle.hasPrefix(ShellTitles.accountName(account)), "the subtitle names the account: \(window.subtitle)")
        #expect(window.toolbar != nil && window.toolbarStyle == .unified, "the unified toolbar holds the window's controls")
        #expect(window.titleVisibility == .visible, "the title shows in the toolbar")
        let appearance: NSAppearance.Name = AppThemes.store.resolved.appearance == .dark ? .darkAqua : .aqua
        #expect(window.appearance?.name == appearance)
        #expect(!window.frameAutosaveName.isEmpty)
        print("scene window: frameAutosaveName=\(window.frameAutosaveName)")
    }

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(DevFeedbackRuntime.mainWindowID) == true && $0.isVisible }
    }

    @Test(.timeLimit(.minutes(2))) func theArchiveKeyTakesTheRowOutThroughTheWindow() async throws {
        let corpus = FakeCorpus.make(threadCount: 20)
        let gmail = FakeGmail(accountEmail: corpus.account.email)
        await FakeGmailLaunch.seed(gmail, corpus: corpus)
        let running = try FakeGmailLaunch.makeSession(store: try MailStore.openInMemoryForTesting(), gmail: gmail)
        let environment = running.session.environment
        await running.session.start()
        defer { Task { await running.session.stop() } }

        let content = MainContentViewController(environment: environment)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1000, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content.view
        QuietTestHost.prepareTestWindow(window)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        content.keyRouter.isMailWindow = { $0 === window }
        let router = content.router
        await eventually("first split tab") { if case .split = router.location { return true }; return false }
        router.go(to: .system(.inbox))
        await eventually("rows") { router.list?.rows.count == 20 }
        #expect(router.location == .system(.inbox))
        func key(_ chars: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: chars,
                                          charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        }
        #expect(router.isEnabled(.markDone))
        #expect(content.keyRouter.route(try key("e", 14)) == nil)
        #expect(router.list?.rows.count == 19, "the conversation leaves the inbox at once")
    }
}
