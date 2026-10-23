import AppKit
import MailUI
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.systemLightAndDark)
    func inboxMacOS26(_ theme: SweepTheme) async throws {
        try await NativeFeatures.withOverride(.macOS26) {
            #expect(NativeFeatures.current == .macOS26)
            let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
            defer { w.close() }
            try await w.cursorAndHover()
            try await sweepShoot(w.window, screen: "inbox-macos26", theme: theme)
        }
    }
}
