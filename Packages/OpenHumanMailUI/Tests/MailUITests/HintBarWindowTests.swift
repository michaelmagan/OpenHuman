#if os(macOS)
import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import SwiftUI
import Testing
@testable import MailUI

@MainActor
@Test func theHintStripIsPartOfTheWindowAndFollowsTheSetting() async throws {
    let env = AppEnvironment.fake(corpus: .make(threadCount: 10))
    let router = env.router
    router.start()
    await awaitObserved("the list loads") { router.list?.state == .loaded }

    let hints = HintBarModel(router: router)
    hints.start()
    let hosting = SizeReportingHostingView(rootView: ShellDetailColumn(router: router, hints: hints) {
        Color.clear.frame(width: 900, height: 400)
    })
    hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    hosting.layoutSubtreeIfNeeded()
    let withHints = hosting.fittingSize.height
    if let dir = ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"],
       let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("hint-bar-window.png"))
    }

    let settings = try #require(env.settings)
    try await settings.set(AppSettings.showShortcutHints, false)
    await hosting.layout { hosting.fittingSize.height != withHints }
    #expect(withHints - hosting.fittingSize.height == NativeMetrics.HintLine.height,
            "the hint line is `NativeMetrics.HintLine.height` and gone with the setting")

    try await settings.set(AppSettings.showShortcutHints, true)
    await hosting.layout { hosting.fittingSize.height == withHints }
    #expect(hosting.fittingSize.height == withHints, "turned back on in Settings")
}
#endif
