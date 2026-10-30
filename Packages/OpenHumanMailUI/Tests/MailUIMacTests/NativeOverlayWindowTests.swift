import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI
@testable import MailUIMac

@MainActor
private final class SurfaceRecord {
    var surface: NativeOverlaySurface?
}

/// The palette and the pickers float on Liquid Glass (or the material under Reduce Transparency), follow the
/// window's appearance, use the system font, and never move the list under them.
@MainActor
@Suite(.serialized) struct NativeOverlayWindowTests {
    static let frameName = "dev.openhuman.tests.native-overlays"
    nonisolated static let now = Date(timeIntervalSince1970: 1_791_000_000)
    static let opened: [(ActionID, String)] = [(.commandPalette, "palette"), (.remind, "remind"), (.snooze, "snooze"),
                                               (.label, "label"), (.move, "move"), (.shortcutHelp, "shortcuts"),
                                               (.getMeToZero, "zero")]

    private func environment() async -> AppEnvironment {
        let env = AppEnvironment.fake(corpus: .rich(threadCount: 60, now: Self.now), options: .init(remoteAck: .immediate),
                                      featureFlags: FeatureFlags())
        env.overlays.now = { Self.now }
        env.overlays.timeZone = TimeZone(identifier: "UTC")!
        env.overlays.locale = Locale(identifier: "en_US_POSIX")
        env.router.start()
        while env.router.active?.list?.state != .loaded { await Task.yield() }
        env.router.go(to: .system(.inbox))
        while env.router.active?.list?.state != .loaded || env.router.list?.rows.isEmpty != false { await Task.yield() }
        return env
    }

    private func surface(of center: OverlayCenter, requested: NativeOverlaySurface) async throws -> NativeOverlaySurface? {
        let record = SurfaceRecord()
        let root = OverlayHostView(center: center)
            .environment(\.theme, .light)
            .environment(\.nativeOverlaySurface, requested)
            .onPreferenceChange(OverlaySurfacePreference.self) { value in
                MainActor.assumeIsolated { record.surface = value }
            }
        let size = NSSize(width: 1100, height: 760)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        hosting.layoutSubtreeIfNeeded()
        try await until(timeout: testBackstop) {
            hosting.layoutSubtreeIfNeeded()
            // Wait for the signal; Reduce Transparency can resolve the requested glass to material.
            return record.surface != nil
        }
        return record.surface
    }

    @Test func everyOverlayFloatsOnGlassAndTheRenderFallbackIsTheMaterial() async throws {
        let env = await environment()
        let glassSurface: NativeOverlaySurface = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? .material : .glass
        for (action, name) in Self.opened {
            #expect(env.router.perform(action), "\(name) opens")
            #expect(env.overlays.isShowing, "\(name) is shown")
            #expect(try await surface(of: env.overlays, requested: .glass) == glassSurface, "\(name) is drawn on glass")
            #expect(try await surface(of: env.overlays, requested: .material) == .material, "\(name) can draw on the material")
            env.overlays.dismiss()
        }
    }

    @Test func reduceTransparencyAlwaysGetsTheMaterial() {
        #expect(NativeOverlaySurface.resolve(.glass, reduceTransparency: false) == .glass)
        #expect(NativeOverlaySurface.resolve(.glass, reduceTransparency: true) == .material)
        #expect(NativeOverlaySurface.resolve(.material, reduceTransparency: false) == .material)
        #expect(NativeOverlaySurface.resolve(.material, reduceTransparency: true) == .material)
    }

    private func overlayField(_ w: InlineReplyWindow) async throws -> NSTextField {
        try await until { OverlayFocusKeeper.control(of: w.window.firstResponder) is NSTextField }
        return try #require(OverlayFocusKeeper.control(of: w.window.firstResponder) as? NSTextField)
    }

    private func listFrame(_ w: InlineReplyWindow) throws -> NSRect {
        let scroll = try #require(w.content.tableView.enclosingScrollView)
        w.window.contentView?.layoutSubtreeIfNeeded()
        return scroll.convert(scroll.bounds, to: nil)
    }

    @Test func thePaletteAndTheRemindPickerFloatWithoutMovingTheList() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, exclusive: true)
        defer { w.close() }
        try await until { w.window.firstResponder === w.content.tableView }
        let before = try listFrame(w)
        for action in [ActionID.commandPalette, .remind, .snooze] {
            #expect(w.router.perform(action))
            _ = try await overlayField(w)
            #expect(try listFrame(w) == before, "\(action) leaves the list where it was")
            w.environment.overlays.dismiss()
            try await until { w.window.firstResponder === w.content.tableView }
            #expect(try listFrame(w) == before)
        }
    }

    @Test(arguments: [AppearanceMode.light, .dark])
    func theFieldFollowsTheWindowAppearanceAndUsesTheSystemFont(mode: AppearanceMode) async throws {
        let w = try await InlineReplyWindow.make(mode: mode, frameName: Self.frameName, exclusive: true)
        defer { w.close() }
        for action in [ActionID.commandPalette, .remind] {
            #expect(w.router.perform(action))
            let field = try await overlayField(w)
            let expected: NSAppearance.Name = mode == .dark ? .darkAqua : .aqua
            #expect(field.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected, "\(action) in \(mode)")
            let font = try #require(field.font)
            #expect(font.pointSize == NativeMetrics.Overlay.paletteFieldTextSize)
            #expect(!font.fontDescriptor.symbolicTraits.contains(.monoSpace), "the system font, not a monospaced one")
            #expect(font.familyName == NSFont.systemFont(ofSize: font.pointSize).familyName)
            w.environment.overlays.dismiss()
            try await until { !(OverlayFocusKeeper.control(of: w.window.firstResponder) is NSTextField) }
        }
    }

    @Test func everyRowSymbolIsAnSFSymbol() {
        let kinds: [TimePickerModel.Row.Kind] = [.parsed(Self.now), .pickDate, .clearReminder, .wakeNow, .snoozeAgain, .someday]
        var symbols = kinds.map { TimePickerView.symbol($0, id: "") }
        for id in ["laterToday", "thisEvening", "tomorrowMorning", "tomorrowAfternoon", "weekend", "nextWeek", "monday",
                   "inAMonth", "inAnHour", "inTwoDays"] {
            symbols.append(TimePickerView.symbol(.preset(Self.now), id: id))
        }
        symbols += [LabelPickerModel.CheckState.on, .mixed, .off].map { LabelPickerView.checkSymbol($0) }
        symbols += [TimePickerView.symbol(.remind), TimePickerView.symbol(.snooze), TimePickerView.symbol(.sendLater)]
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol) is an SF Symbol here")
        }
    }
}
