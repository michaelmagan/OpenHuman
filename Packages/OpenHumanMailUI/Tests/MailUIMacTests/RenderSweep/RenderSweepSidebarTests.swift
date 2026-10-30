import AppKit
import Foundation
import MailFakes
import MailFeatures
import MailModel
import MailUI
import Testing
@testable import MailUIMac

extension SweepTheme {
    static let sidebar: [SweepTheme] = builtIns + accessibility.filter { $0.increaseContrast && !$0.isDark }
}

extension RenderSweepTests {
    @Test(arguments: SweepTheme.sidebar)
    func sidebarOneAccount(_ theme: SweepTheme) async throws {
        let environment = AppEnvironment.fake(corpus: .make(threadCount: 60, now: Date(timeIntervalSince1970: 1_791_000_000)),
                                              options: .init(remoteAck: .immediate), featureFlags: FeatureFlags())
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        w.router.isLabelSidebarVisible = true
        await awaitObserved("one account with its counts") { w.router.accounts.count == 1 && w.router.active?.counts != nil }
        w.window.makeKeyAndOrderFront(nil)
        try await shootSidebar(w.window, screen: "sidebar-one-account", theme: theme)
    }

    @Test(arguments: SweepTheme.sidebar)
    func sidebarTwoAccountsLabelsAndInactiveWindow(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment(calendar: true)
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        w.router.isLabelSidebarVisible = true
        await awaitObserved("two accounts with their counts and labels") {
            w.router.showsAllInboxes && w.router.accounts.allSatisfy { $0.counts != nil }
                && w.router.active?.labels.contains { $0.name == "Projects/Atlas" } == true
        }
        w.window.makeKeyAndOrderFront(nil)
        try await shootSidebar(w.window, screen: "sidebar-two-accounts", theme: theme)

        let atlas = try #require(w.router.active?.labels.first { $0.name == "Projects/Atlas" })
        w.router.go(to: .label(atlas.labelID))
        await awaitObserved("the label's list is shown") {
            w.router.list?.location == .label(atlas.labelID) && w.router.list?.state == .loaded
        }
        try await shootSidebar(w.window, screen: "sidebar-label-selected", theme: theme)

        let other = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 240, height: 120), styleMask: [.titled],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.orderOut(nil) }
        other.makeKeyAndOrderFront(nil)
        w.content.tableView.listController?.selectionEmphasisOverride = false
        try await shootSidebar(w.window, screen: "sidebar-inactive-window", theme: theme)
    }

    private func shootSidebar(_ window: NSWindow, screen: String, theme: SweepTheme) async throws {
        try await sweepShoot(window, screen: screen, theme: theme, settle: .milliseconds(600))
        let directory = try SweepOutput.directory()
        let source = directory.appendingPathComponent("\(screen)--\(theme.slug).png")
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: source)))
        let scale = CGFloat(rep.pixelsWide) / window.frame.width
        let width = min(CGFloat(rep.pixelsWide), (NativeMetrics.Sidebar.maxWidth + 40) * scale)
        let crop = CGRect(x: 0, y: 0, width: width, height: CGFloat(rep.pixelsHigh))
        let cropped = try #require(rep.cgImage?.cropping(to: crop))
        let png = try #require(NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]))
        let file = "\(screen)-crop--\(theme.slug).png"
        try png.write(to: directory.appendingPathComponent(file))
        try SweepIndex.record(SweepIndexEntry(screen: "\(screen)-crop", theme: theme.name, file: file), in: directory)
    }
}
