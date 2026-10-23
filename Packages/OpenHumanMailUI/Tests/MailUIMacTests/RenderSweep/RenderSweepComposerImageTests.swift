import AppKit
import MailFeatures
import MailModel
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    // A drawn stand-in for a Retina screenshot: 1840 by 1000 pixels at 144 dpi
    static func sweepScreenshot() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1840, pixelsHigh: 1000, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: 920, height: 500)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 920, height: 500).fill()
        NSColor(calibratedWhite: 0.17, alpha: 1).setFill()
        NSRect(x: 0, y: 440, width: 920, height: 60).fill()
        NSBezierPath(roundedRect: NSRect(x: 300, y: 120, width: 520, height: 260), xRadius: 12, yRadius: 12).fill()
        NSColor.systemOrange.setFill()
        NSBezierPath(roundedRect: NSRect(x: 330, y: 300, width: 44, height: 22), xRadius: 11, yRadius: 11).fill()
        NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
        for row in 0..<6 { NSRect(x: 60, y: 380 - row * 36, width: 160, height: 10).fill() }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func composerPastedImage(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let (thread, _) = try await w.longestConversation()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        _ = try await w.inlineComposer()
        let editor = try #require(w.editors.first)
        #expect(w.window.makeFirstResponder(editor))
        editor.insertText("Quick update on our end. I know", replacementRange: editor.selectedRange())
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.setData(try Self.sweepScreenshot(), forType: .png)
        defer { board.releaseGlobally() }
        editor.pasteboard = { board }
        editor.paste(nil)
        let index = (editor.string as NSString).range(of: "\u{FFFC}").location
        try #require(index != NSNotFound, "the picture went in")
        let shown = try #require(editor.imageFrame(at: index))
        #expect(shown.width <= editor.imageColumn * 0.6 + 1, "starts at Medium, not the column's full width")
        try await sweepShoot(w.window, screen: "composer-pasted-image", theme: theme)

        editor.setSelectedRange(NSRange(location: index, length: 1))
        editor.updateImageOverlay()
        #expect(!editor.imageOverlay.isHidden)
        try await sweepShoot(w.window, screen: "composer-image-size-overlay", theme: theme)
    }
}
