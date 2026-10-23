import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI
import Testing
@testable import MailUIMac

extension SweepTheme {
    static let lightDarkAndPaper: [SweepTheme] = selected(allBuiltIns.filter { ["light", "dark", "paper"].contains($0.slug) })
}

extension RenderSweepTests {
    private func shownPalette(_ w: InlineReplyWindow) throws -> PaletteController {
        if case .palette(let palette) = w.environment.overlays.overlay { return palette }
        throw SweepFixtureError(description: "the palette is not shown")
    }

    @Test(arguments: SweepTheme.lightDarkAndPaper)
    func nativePalette(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepOverlayFixture.environment(), theme: theme)
        defer { w.close() }
        SweepOverlayFixture.pinClock(w.environment.overlays)
        let list = try #require(w.router.list)
        let longest = try #require(list.rows.max { $0.subject.count < $1.subject.count })
        list.setCursor(longest.id)

        #expect(w.router.perform(.commandPalette))
        let first = try shownPalette(w)
        first.query = "star"
        #expect(first.performSelected(), "a command run from the palette becomes a recent one")
        try await until { !w.environment.overlays.isShowing }

        #expect(w.router.perform(.commandPalette))
        let palette = try shownPalette(w)
        try await until { palette.entries.contains { $0.group == .recent } }
        try await sweepShoot(w.window, screen: "palette-native-suggested", theme: theme)
        #expect(palette.scopeSummary?.isEmpty == false, "the scope chip names the conversation")
        try await sweepShoot(w.window, screen: "palette-native-long-chip", theme: theme)

        palette.query = "mark"
        try await sweepShoot(w.window, screen: "palette-native-filtered", theme: theme)
        palette.query = "qzxqzx"
        try await sweepShoot(w.window, screen: "palette-native-empty", theme: theme)
        palette.close()
    }

    @Test(arguments: SweepTheme.lightDarkAndPaper)
    func nativeRemindPicker(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepOverlayFixture.environment(), theme: theme)
        defer { w.close() }
        let overlays = w.environment.overlays
        SweepOverlayFixture.pinClock(overlays)
        w.router.perform(.nextThread)
        #expect(w.router.perform(.remind))
        let picker = try SweepOverlayFixture.timePicker(overlays)
        try await sweepShoot(w.window, screen: "remind-native", theme: theme)
        picker.text = "fri 3pm"
        try await sweepShoot(w.window, screen: "remind-native-typed", theme: theme)
        picker.text = ""
        picker.openDatePick()
        try await sweepShoot(w.window, screen: "remind-native-date-picker", theme: theme)
        overlays.dismiss()
    }
}
