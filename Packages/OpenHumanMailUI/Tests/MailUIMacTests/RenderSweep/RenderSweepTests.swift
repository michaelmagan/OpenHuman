import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] != nil))
struct RenderSweepTests {
    @Test func refusesAnOutputFolderInsideAGitWorkTree() throws {
        let here = (#filePath as NSString).deletingLastPathComponent
        let tree = try #require(SweepOutput.gitWorkTree(containing: here), "this source file is in a checkout")
        let inside = (here as NSString).appendingPathComponent("renders-\(UUID().uuidString)")
        #expect(throws: SweepOutput.Refusal.self) { try SweepOutput.checkedDirectory(inside) }
        #expect(!FileManager.default.fileExists(atPath: inside), "nothing was created inside the checkout")
        #expect(throws: SweepOutput.Refusal.self) { try SweepOutput.checkedDirectory(tree) }
        #expect(throws: SweepOutput.Refusal.self) { try SweepOutput.checkedDirectory(nil) }

        let outside = (NSTemporaryDirectory() as NSString).appendingPathComponent("oh-render-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: outside) }
        if SweepOutput.gitWorkTree(containing: outside) == nil {
            let url = try SweepOutput.checkedDirectory(outside)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        _ = try SweepOutput.directory()
    }

    @Test(arguments: SweepTheme.builtIns + SweepTheme.accessibility)
    func inbox(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        try await w.cursorAndHover()
        try await sweepShoot(w.window, screen: "inbox", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func toolbar(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        try await settleWindowChrome(of: w.window)
        try await sweepShoot(w.window, screen: "toolbar", theme: theme)
        let strip = TitleBarMetrics.stripHeight(of: w.window)
        #expect(strip > 0, "the toolbar reaches over the full-size content (content \(w.window.contentView?.bounds.height ?? -1), layout \(w.window.contentLayoutRect), frame \(w.window.frame))")
        let directory = try SweepOutput.directory()
        let source = directory.appendingPathComponent("toolbar--\(theme.slug).png")
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: source)))
        let scale = CGFloat(rep.pixelsWide) / SweepWindow.size.width
        let crop = CGRect(x: 0, y: 0, width: SweepWindow.size.width * scale, height: (strip + 120) * scale)
        let cropped = try #require(rep.cgImage?.cropping(to: crop))
        let png = try #require(NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]))
        let name = "toolbar-crop--\(theme.slug).png"
        try png.write(to: directory.appendingPathComponent(name))
        try SweepIndex.record(SweepIndexEntry(screen: "toolbar-crop", theme: theme.name, file: name), in: directory)
    }

    @Test(arguments: SweepTheme.builtIns)
    func listRowActions(_ theme: SweepTheme) async throws {
        for density in ThemeDensity.allCases {
            var preferences = theme.preferences
            preferences.density = density
            let variant = SweepTheme(name: "\(theme.name), \(density.rawValue)", slug: "\(theme.slug)-\(density.rawValue)",
                                     preferences: preferences)
            let w = try await SweepWindow.make(SweepWindow.environment(), theme: variant)
            defer { w.close() }
            w.content.tableView.listController?.selectionEmphasisOverride = true
            try await w.cursorAndHover(steps: 2, offset: 2)
            try await w.hoverCursorRow()
            try await sweepShoot(w.window, screen: "list-row-actions", theme: variant)
            guard density == .default else { continue }
            w.window.setContentSize(NSSize(width: 860, height: SweepWindow.size.height))
            try await sweepShoot(w.window, screen: "list-row-actions-narrow", theme: variant)
        }
    }

    @Test(arguments: SweepTheme.builtIns)
    func snoozedAndMuted(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        w.router.go(to: .system(.snoozed))
        try await until { w.router.list?.location == .system(.snoozed) && w.router.list?.state == .loaded }
        try await w.cursorAndHover(steps: 1, offset: 2)
        try await sweepShoot(w.window, screen: "list-snoozed", theme: theme)

        w.router.go(to: .system(.inbox))
        try await until { w.router.list?.location == .system(.inbox) && w.router.list?.state == .loaded }
        w.router.perform(.nextThread)
        w.router.perform(.toggleMute)
        try await Task.sleep(for: .milliseconds(300))
        guard w.router.perform(.goMuted) else {
            Issue.record("Go to Muted did not run (is the mute module on in FeatureFlags()?)")
            return
        }
        try await until { w.router.list?.location != .system(.inbox) && w.router.list?.state == .loaded }
        try await sweepShoot(w.window, screen: "list-muted", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func emptyLoadingAndOffline(_ theme: SweepTheme) async throws {
        do {
            let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
            defer { w.close() }
            let store = try #require(w.environment.data as? FakeMailStore)
            let account = try #require(w.router.accounts.first?.account)
            let inbox = try await w.environment.data.threadPage(.system(.inbox), account: account.id, after: nil, limit: 5000)
            store.removeThreads(Set(inbox.rows.map(\.id)))
            try await until { w.router.list?.state == .loaded && w.router.list?.rows.isEmpty == true }
            try await sweepShoot(w.window, screen: "list-empty", theme: theme, settle: .milliseconds(700))

            let emptyRoot = try #require(w.window.contentView)
            let emptyView = try #require(subviews(of: ThreadListEmptyView.self, in: emptyRoot).first)
            emptyView.show(ThreadListEmptyState(style: .inboxClear, title: "Nothing in GitHub.", symbol: "tray"), now: Date())
            try await sweepShoot(w.window, screen: "list-empty-tab", theme: theme, settle: .milliseconds(400))
            emptyView.show(ThreadListEmptyState(style: .message, title: "No mail matches “zz”.",
                                                subtitle: "Check the spelling, or try fewer words.", symbol: "magnifyingglass"),
                           now: Date())
            try await sweepShoot(w.window, screen: "list-empty-search", theme: theme, settle: .milliseconds(400))

            let root = try #require(w.window.contentView)
            let empty = try #require(subviews(of: ThreadListEmptyView.self, in: root).first)
            empty.show(ThreadListEmptyState(style: .progress, title: String(localized: "Loading…")), now: Date())
            try await sweepShoot(w.window, screen: "list-loading", theme: theme)
        }
        do {
            let w = try await SweepWindow.make(SweepWindow.environment(liveConnectivity: true), theme: theme)
            defer { w.close() }
            let store = try #require(w.environment.data as? FakeMailStore)
            store.setOffline(true)
            try await until { w.router.banner()?.kind == .offline }
            try await sweepShoot(w.window, screen: "offline", theme: theme)
        }
    }

    @Test(arguments: SweepTheme.builtIns + SweepTheme.accessibility)
    func reader(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(heldSends: .manual), theme: theme)
        defer { w.close() }
        let (thread, messages) = try await w.longestConversation()
        let model = try await w.open(thread)
        try await sweepShoot(w.window, screen: "reader-cards", theme: theme)
        guard !theme.increaseContrast && !theme.reduceMotion else { return }

        let middle = messages[messages.count - 2]
        model.reveal(middle.id)
        model.focus(middle.id)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        let editor = try #require(w.editors.first)
        editor.insertText("Thursday at 10 works for me. I'll bring the draft agenda.", replacementRange: editor.selectedRange())
        try await sweepShoot(w.window, screen: "reader-reply-attached", theme: theme)

        #expect(w.environment.compose.perform(.send, in: composer.session, source: .keyboard))
        try await until { w.router.mode == .list }
        try await sweepShoot(w.window, screen: "sent-back-to-list", theme: theme)
        _ = try await w.open(thread)
        try await until { w.reader.outgoingViews.count == 1 }
        try await sweepShoot(w.window, screen: "reader-sent-card", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func sending(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(heldSends: .manual), theme: theme)
        defer { w.close() }
        let compose = w.environment.compose
        let (thread, _) = try await w.longestConversation()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        let editor = try #require(w.editors.first)
        editor.insertText("Thursday at 10 works for me. I'll bring the draft agenda.", replacementRange: editor.selectedRange())
        try await until { composer.session.plainText.contains("Thursday") }
        #expect(compose.perform(.send, in: composer.session, source: .keyboard))
        try await until { w.router.mode == .list && w.environment.notices.toasts.contains { $0.secondaryActionTitle == "View" } }
        try await sweepShoot(w.window, screen: "toast-sending", theme: theme)

        #expect(compose.showSending())
        try await sweepShoot(w.window, screen: "sending-view-queued", theme: theme)

        let queued = try #require(compose.shownSending)
        compose.closeSendingView()
        let store = theme.makeStore()
        for (screen, state) in [("sending-view-sent", SendingMessage.State.sent),
                                ("sending-view-failed", .failed),
                                ("sending-view-scheduled", .scheduled(at: Date().addingTimeInterval(86_400)))] {
            let message = SendingMessage(id: queued.id, draft: queued.draft, account: queued.account, thread: queued.thread,
                                         mode: queued.mode, from: queued.from, to: queued.to, cc: queued.cc,
                                         bcc: queued.bcc, subject: queued.subject, text: queued.text,
                                         attachmentNames: ["agenda.pdf"], date: queued.date, state: state)
            let card = sweepStandaloneWindow(SendingCard(message: message, manager: compose).padding(24), store: store,
                                             size: NSSize(width: 820, height: 520))
            defer { card.orderOut(nil) }
            try await sweepShoot(card, screen: screen, theme: theme)
        }
    }

    @Test(arguments: SweepTheme.builtIns)
    func newMessagesPill(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        model.noteInteraction()
        let store = try #require(w.environment.data as? FakeMailStore)
        let account = try #require(w.router.accounts.first?.id)
        for minutes in [1.0, 2, 3] {
            store.deliverMessage(account: account, to: thread, from: EmailAddress(name: "Dana Reyes", email: "dana@example.org"),
                                 at: Date().addingTimeInterval(minutes * 60))
        }
        try await until { model.pendingMessages.count == 3 }
        try await sweepShoot(w.window, screen: "reader-new-messages-pill", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func composer(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let compose = w.environment.compose
        #expect(w.router.perform(.compose))
        try await until { compose.windowSession?.placement == .modal }
        let session = try #require(compose.windowSession)
        await session.settle()
        try await sweepShoot(w.window, screen: "composer-empty", theme: theme)

        session.to.setTokens([EmailAddress(name: "Dana Reyes", email: "dana@example.org"),
                              EmailAddress(name: "Sam Lee", email: "sam@example.org")])
        session.showCc()
        session.cc.setTokens([EmailAddress(name: "Ops Desk", email: "ops@example.org")])
        session.subject = "Agenda for Thursday"
        if let editor = w.editors.first {
            editor.insertText("Hi both,\nHere is the agenda for Thursday. Comments welcome before noon.",
                              replacementRange: editor.selectedRange())
        }
        try await sweepShoot(w.window, screen: "composer-recipients", theme: theme)

        compose.toggleFormatBar()
        try await sweepShoot(w.window, screen: "composer-format-bar", theme: theme)
        compose.toggleFormatBar()

        session.notice = ComposeSession.Notice(.error, "Couldn't send. The connection dropped; your draft is kept.",
                                               offersSendAgain: true)
        try await sweepShoot(w.window, screen: "composer-error", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func quickReplies(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let held = try await StripStage.make(script: ReplyScript(holdsFirst: true), theme: store.resolved)
        held.window.appearance = appearance
        try await sweepShoot(held.window, screen: "composer-quick-replies-waiting", theme: theme)
        held.close()

        let ready = try await StripStage.make(theme: store.resolved)
        defer { ready.close() }
        ready.window.appearance = appearance
        try await sweepShoot(ready.window, screen: "composer-quick-replies-ready", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func commandPalette(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.commandPalette))
        guard case .palette(let palette) = w.environment.overlays.overlay else {
            Issue.record("the palette is up")
            return
        }
        palette.query = "done"
        try await sweepShoot(w.window, screen: "palette", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func toasts(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        w.router.perform(.nextThread)
        w.router.perform(.markDone)
        try await until { w.environment.notices.toasts.contains { $0.style == .undo } }
        try await sweepShoot(w.window, screen: "toast-undo", theme: theme)

        let notices = w.environment.notices
        for toast in notices.toasts { notices.dismiss(toast.id) }
        notices.post("Marked 3 conversations done.", style: .undo, actionTitle: "Undo", shortcut: "⌘Z", duration: nil,
                     holdsWindow: true)
        notices.post("Label “Clients” added.", style: .info, duration: nil)
        try await until { notices.toasts.count == 2 }
        try await sweepShoot(w.window, screen: "toast-pair", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func footer(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        try await w.cursorAndHover(steps: 1, offset: 2)

        let store = theme.makeStore()
        let hints = HintBarModel(router: w.router)
        hints.start()
        let height = FooterView.height
        let strip = sweepStandaloneWindow(FooterView(status: w.environment.status, hints: hints, theme: store.resolved.tokens),
                                          store: store, size: NSSize(width: SweepWindow.size.width, height: height))
        defer { strip.orderOut(nil) }
        try await sweepShoot(strip, screen: "footer", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func liveAccountWindow(_ theme: SweepTheme) async throws {
        let store = FakeMailStore(corpus: .small, options: .init(remoteAck: .immediate))
        let environment = AppEnvironment(data: store, commands: store, accounts: store, settings: store, isFake: true,
                                         featureFlags: FeatureFlags(), isLiveAccount: true)
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        try await sweepShoot(w.window, screen: "window-live-account", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func calendarSidebar(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment(calendar: true)
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let model = try #require(environment.calendarSidebar)
        #expect(environment.actions.perform(.calendarToggleSidebar, source: .menu, host: environment.router))
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        try await until { model.thread == thread && model.state == .loaded }
        await model.beginDraft(for: thread)
        #expect(model.draft != nil)
        try await sweepShoot(w.window, screen: "calendar-sidebar-create-event", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func signInAndStartUp(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let size = NSSize(width: 960, height: 640)
        for (screen, status) in [("sign-in", OAuthClientStatus.configured(source: .environment)), ("sign-in-needs-client", .missing)] {
            let model = SignInModel(accounts: SweepAccounts(status: status))
            await model.run()
            let window = sweepStandaloneWindow(SignInView(model: model, theme: store.resolved.tokens), store: store, size: size)
            defer { window.orderOut(nil) }
            try await sweepShoot(window, screen: screen, theme: theme)
        }

        let problem = StartupProblem(
            title: "Mail couldn't open your mail on this Mac",
            message: "Another copy of Mail is using the mail database. Quit the other copy, then try again.",
            details: "store.open: database is locked (SQLITE_BUSY)",
            action: (title: "Try Again", run: {}))
        let error = sweepStandaloneWindow(StartupProblemView(problem: problem, quit: {}, copy: { _ in }), store: store, size: size)
        defer { error.orderOut(nil) }
        try await sweepShoot(error, screen: "start-up-error", theme: theme)

        for (screen, keychain) in [("keychain-explainer", StartupProblem.keychainExplainer(continue: {})),
                                   ("keychain-refused", StartupProblem.keychainRefused(tryAgain: {}, signInAgain: {}))] {
            let window = sweepStandaloneWindow(StartupProblemView(problem: keychain, quit: {}, copy: { _ in }),
                                               store: store, size: size)
            defer { window.orderOut(nil) }
            try await sweepShoot(window, screen: screen, theme: theme)
        }

        let launching = sweepStandaloneWindow(LaunchingView(), store: store, size: size)
        defer { launching.orderOut(nil) }
        try await sweepShoot(launching, screen: "launching", theme: theme, settle: .seconds(1))
    }
}

private struct SweepAccounts: AccountManaging {
    let status: OAuthClientStatus

    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        let status = status
        return AsyncStream { $0.yield(status); $0.finish() }
    }

    func importOAuthClient(json: Data) async throws {}
    func addAccount(loginHint: String?) async throws -> AccountID { AccountID(1) }
}
