import AppKit
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct RenderSweepCaptureTests {
    private func window(_ style: NSWindow.StyleMask) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 400, height: 300), styleMask: style,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.systemTeal.cgColor
        window.contentView = content
        return window
    }

    @Test func aTitledWindowIsCapturedWithItsTitleBarAndToolbar() throws {
        let window = window([.titled, .closable, .miniaturizable, .resizable])
        window.toolbar = NSToolbar(identifier: "render-sweep-capture-test")
        window.toolbarStyle = .unified
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        let root = try sweepCaptureRoot(window)
        #expect(root === content.superview)
        #expect(root.bounds.height > content.bounds.height, "the title bar and toolbar are inside the capture")
        let rep = try #require(NSBitmapImageRep(data: try sweepCapture(window)))
        let scale = CGFloat(rep.pixelsWide) / root.bounds.width
        #expect(abs(CGFloat(rep.pixelsHigh) - root.bounds.height * scale) <= 1)
    }

    @Test func theSidebarPaneIsDrawnUnderTheCapture() throws {
        let window = window([.titled, .resizable, .fullSizeContentView])
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        split.isVertical = true
        let sidebar = NSScrollView(frame: NSRect(x: 0, y: 0, width: 120, height: 300))
        let detail = NSView(frame: NSRect(x: 121, y: 0, width: 279, height: 300))
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(detail)
        window.contentView = split
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        split.adjustSubviews()
        let root = try sweepCaptureRoot(window)
        #expect(sweepSidebarPane(in: root) === sidebar)
        let underlays = sweepSidebarUnderlays(in: root)
        #expect(underlays.first?.fill == true && underlays.first?.image == nil, "the column's flat background first")
        #expect(underlays.dropFirst().contains { $0.image != nil && abs($0.rect.width - sidebar.bounds.width) < 0.5 })
        _ = try sweepCapture(window)
    }

    @Test func aBorderlessWindowIsCapturedThroughItsContent() throws {
        let window = window([.borderless])
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let root = try sweepCaptureRoot(window)
        #expect(root === window.contentView)
        let rep = try #require(NSBitmapImageRep(data: try sweepCapture(window)))
        let scale = CGFloat(rep.pixelsWide) / root.bounds.width
        #expect(abs(CGFloat(rep.pixelsHigh) - root.bounds.height * scale) <= 1)
    }
}
