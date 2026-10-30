import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import Testing
@testable import MailUI
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.builtIns)
    func shellReaderToolbar(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let (thread, _) = try await w.longestConversation()
        _ = try await w.open(thread)
        try await settleWindowChrome(of: w.window)
        try await sweepShoot(w.window, screen: "shell-reader", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func shellSearchFieldInTheToolbar(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        #expect(w.router.perform(.search))
        try await until { w.content.searchField(in: w.window) != nil }
        try await sweepShoot(w.window, screen: "shell-search-field", theme: theme)
    }

    @Test(arguments: SweepTheme.systemLightAndDark)
    func shellSplitPickerMacOS26AndMacOS27(_ theme: SweepTheme) async throws {
        let variants: [(NativeFeatures, String)] = [(.macOS26, "26"), (.macOS27, "27")]
        for (features, slug) in variants {
            try await NativeFeatures.withOverride(features) {
                let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
                defer { w.close() }
                try await addSplits(to: w, count: 6)
                try await sweepShoot(w.window, screen: "shell-split-tabs-\(slug)", theme: theme)
                let state = try #require(w.router.active)
                let overflow = SplitInboxPicker.layout(state.tabs, active: state.location).overflow
                if let last = overflow.last {
                    w.router.go(to: last.location)
                    try await until { w.router.list?.location == last.location && w.router.list?.state == .loaded }
                    try await sweepShoot(w.window, screen: "shell-split-tabs-more-\(slug)", theme: theme)
                }
            }
        }
    }

    @Test(arguments: SweepTheme.builtIns)
    func shellInspectorWithTheContactPanel(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment()
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(environment.actions.perform(.toggleContextSidebar, source: .menu, host: w.router))
        try await sweepShoot(w.window, screen: "shell-inspector-contact", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func shellOfflineBanner(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment(liveConnectivity: true)
        let store = try #require(environment.data as? FakeMailStore)
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        store.setOffline(true)
        try await until { w.router.banner()?.kind == .offline }
        try await sweepShoot(w.window, screen: "shell-banner-offline", theme: theme)
    }

    @Test(arguments: SweepTheme.selected(SweepTheme.allBuiltIns, slugs: "light,dark,system-light"))
    func shellSidebarHidden(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        w.router.isLabelSidebarVisible = true
        try await sweepShoot(w.window, screen: "shell-sidebar-shown", theme: theme)
        w.router.isLabelSidebarVisible = false
        try await sweepShoot(w.window, screen: "shell-sidebar-hidden", theme: theme)
    }

    // Full screen needs a real display; on a headless runner the window never gets there and nothing is recorded
    @Test(arguments: SweepTheme.selected(SweepTheme.allBuiltIns, slugs: "system-light"))
    func shellFullScreen(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        guard let screen = NSScreen.main else { return }
        w.window.setFrame(screen.visibleFrame, display: true)
        w.window.collectionBehavior.insert(.fullScreenPrimary)
        w.window.toggleFullScreen(nil)
        guard (try? await until(timeout: .seconds(10), { w.window.styleMask.contains(.fullScreen) })) != nil else { return }
        try await settleWindowChrome(of: w.window)
        try await sweepShoot(w.window, screen: "shell-full-screen", theme: theme)
        #expect(w.content.searchField(in: w.window) == nil)
        #expect(w.router.perform(.search))
        try await until { w.content.searchField(in: w.window) != nil }
        try await sweepShoot(w.window, screen: "shell-full-screen-search", theme: theme)
        w.window.toggleFullScreen(nil)
        try await until(timeout: .seconds(10)) { !w.window.styleMask.contains(.fullScreen) }
    }

    private func addSplits(to w: InlineReplyWindow, count: Int) async throws {
        let store = try #require(w.environment.data as? FakeMailStore)
        let account = try #require(w.router.active?.id)
        let before = w.router.active?.tabs.count ?? 0
        for index in 0..<count {
            _ = try await store.upsertSplit(SplitDefinition(account: account, name: "Project \(index + 1)",
                                                            ruleText: "subject:project\(index + 1)"))
        }
        try await until { (w.router.active?.tabs.count ?? 0) >= before + count }
    }
}
