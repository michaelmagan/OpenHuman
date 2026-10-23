import AppKit
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized)
struct SettingsWindowTests {
    private func fixedWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 800, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func theHooksMakeTheWindowResizableAndKeepItsOtherStyle() {
        let window = fixedWindow()
        SettingsWindowHooks.configure(window)
        #expect(window.styleMask.contains(.resizable))
        #expect(window.styleMask.contains(.titled) && window.styleMask.contains(.closable))
        SettingsWindowHooks.configure(window)
        #expect(window.styleMask == [.titled, .closable, .resizable], "configuring again changes nothing")
    }

    @Test func theHookViewMakesItsWindowResizableAgainAfterTheSceneResetsIt() async throws {
        let window = fixedWindow()
        defer { window.orderOut(nil) }
        let content = Color.clear.frame(width: 800, height: 560).background(SettingsWindowHook())
        window.contentView = NSHostingView(rootView: content)
        window.orderFrontRegardless()
        try await until { window.styleMask.contains(.resizable) }
        let hook = try #require(Self.hookView(in: window.contentView), "the hook sits in the window's content")
        hook.applyToWindow()
        window.styleMask.remove(.resizable)
        try await until { window.styleMask.contains(.resizable) }
    }

    private static func hookView(in view: NSView?) -> SettingsWindowHookView? {
        guard let view else { return nil }
        return (view as? SettingsWindowHookView) ?? view.subviews.lazy.compactMap { hookView(in: $0) }.first
    }
}
