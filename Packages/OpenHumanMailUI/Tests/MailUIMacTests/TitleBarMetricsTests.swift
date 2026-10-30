import AppKit
import Testing
@testable import MailUIMac

@MainActor
private final class FakeMeasuredWindow: TitleBarMeasuring {
    var contentViewHeight: CGFloat
    var layoutRectMaxY: CGFloat
    var isFullScreen: Bool
    init(content: CGFloat, layoutMaxY: CGFloat, fullScreen: Bool = false) {
        contentViewHeight = content
        layoutRectMaxY = layoutMaxY
        isFullScreen = fullScreen
    }
}

@MainActor
struct TitleBarMetricsTests {
    @Test func theStripIsWhatLiesAboveTheLayoutRect() {
        #expect(TitleBarMetrics.stripHeight(of: FakeMeasuredWindow(content: 860, layoutMaxY: 832)) == 28)
    }

    @Test func aLargerTitleBarGivesALargerStrip() {
        #expect(TitleBarMetrics.stripHeight(of: FakeMeasuredWindow(content: 860, layoutMaxY: 822)) == 38)
    }

    @Test func fullScreenHasNoStripSoTheContentDoesNotJumpWhenTheTitleBarSlidesIn() {
        #expect(TitleBarMetrics.stripHeight(of: FakeMeasuredWindow(content: 1080, layoutMaxY: 1052, fullScreen: true)) == 0)
    }

    @Test func nothingAboveTheLayoutRectIsNoStrip() {
        #expect(TitleBarMetrics.stripHeight(of: FakeMeasuredWindow(content: 700, layoutMaxY: 700)) == 0)
        #expect(TitleBarMetrics.stripHeight(of: FakeMeasuredWindow(content: 700, layoutMaxY: 710)) == 0)
    }

    @Test func aFractionalHeightRoundsUpToWholePoints() {
        #expect(TitleBarMetrics.stripHeight(of: FakeMeasuredWindow(content: 860, layoutMaxY: 832.4)) == 28)
    }

    @Test func aRealFullSizeContentWindowMeasuresItsTitleBar() {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        let strip = TitleBarMetrics.stripHeight(of: window)
        #expect(strip > 0)
        #expect(strip >= 20 && strip < 80, "a title bar's height, not a fixed number")
    }

    @Test func aPlainTitledWindowHasNoStrip() {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        #expect(TitleBarMetrics.stripHeight(of: window) == 0)
    }

    @Test func theMainWindowHookLeavesTheTitleBarAndBackgroundToTheSystem() {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let background = window.backgroundColor
        MainWindowHooks.configure(window, theme: .dark, restoreFrame: false)
        #expect(!window.styleMask.contains(.fullSizeContentView) && !window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .visible, "the title shows in the toolbar")
        #expect(window.backgroundColor == background, "the theme colours the content, not the window")
        #expect(window.appearance?.name == .darkAqua)
    }
}
