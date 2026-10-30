#if os(macOS)
import AppKit
import MailFeatures
import MailTheme
import SwiftUI
import Testing
@testable import MailUI

@MainActor
@Suite struct OnlyIfNoReplyRowTests {
    private func host(dark: Bool, on: Bool) -> NSHostingView<some View> {
        let view = OnlyIfNoReplyRow(isOn: .constant(on))
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: 420, height: OverlayMetrics.rowHeight)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: OverlayMetrics.rowHeight)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private func inkPixels(dark: Bool, on: Bool) throws -> Int {
        let hosting = host(dark: dark, on: on)
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let reference = try #require(rep.colorAt(x: Int(rep.pixelsWide) - 2, y: 2)?.usingColorSpace(.deviceRGB))
        func luma(_ c: NSColor) -> CGFloat { 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent }
        var count = 0
        for x in 0..<Int(rep.pixelsWide) {
            for y in 0..<Int(rep.pixelsHigh) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(luma(c) - luma(reference)) > 0.35 { count += 1 }
            }
        }
        return count
    }

    @Test(arguments: [false, true])
    func theLabelIsDrawnWhetherTheBoxIsTickedOrNot(dark: Bool) throws {
        #expect(try inkPixels(dark: dark, on: true) > 40, "label pixels, ticked, dark \(dark)")
        #expect(try inkPixels(dark: dark, on: false) > 40, "label pixels, unticked, dark \(dark)")
    }
}
#endif
