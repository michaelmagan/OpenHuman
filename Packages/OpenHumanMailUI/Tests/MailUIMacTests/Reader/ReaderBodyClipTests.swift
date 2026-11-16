import AppKit
import MailFeatures
import MailTheme
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized)
struct ReaderBodyClipTests {
    @Test func aBodyTallerThanTheReaderIsDrawnOnlyBetweenTheToolbarAndTheFooter() throws {
        let theme = ThemeTokens.light
        let size = NSSize(width: 900, height: 600)
        let footerHeight = CGFloat(theme.footerHeight)
        let toolbarHeight: CGFloat = 60
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Why: a snapshot takes the screen's space (Display P3 on a MacBook), where sRGB red reads 0.92, 0.2, 0.14
        window.colorSpace = .sRGB
        defer { window.close() }
        let root = BandView(.white, frame: NSRect(origin: .zero, size: size))
        window.contentView = root
        let footer = BandView(NSColor(srgbRed: 0, green: 0.6, blue: 0, alpha: 1),
                              frame: NSRect(x: 0, y: 0, width: size.width, height: footerHeight))
        let toolbar = BandView(NSColor(srgbRed: 0, green: 0, blue: 0.6, alpha: 1),
                               frame: NSRect(x: 0, y: size.height - toolbarHeight, width: size.width, height: toolbarHeight))
        root.addSubview(footer)
        root.addSubview(toolbar)
        let reader = ReaderViewController(theme: theme, webKit: TestWebKit.noNetwork, preferences: ReaderPreferences(defaults: nil))
        reader.view.frame = NSRect(x: 0, y: footerHeight, width: size.width, height: size.height - footerHeight - toolbarHeight)
        root.addSubview(reader.view)

        let document = reader.focusView
        let scrollView = try #require(document.enclosingScrollView)
        let body = NSView(frame: NSRect(x: 40, y: 120, width: 600, height: 2000))
        document.addSubview(body)
        document.heightAnchor.constraint(equalToConstant: body.frame.maxY + 200).isActive = true
        root.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 200))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let full = body.convert(body.bounds, to: root)
        try #require(full.minY < footer.frame.maxY, "the body runs on under the footer")
        try #require(full.maxY > toolbar.frame.minY, "the body starts above the reader, under the toolbar")
        let visible = body.convert(body.visibleRect, to: root)
        #expect(visible.minY >= footer.frame.maxY && visible.maxY <= toolbar.frame.minY, "visible part \(visible)")

        let shot = NSImage(size: body.bounds.size, flipped: false) { rect in
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let rep = try SnapshotRenderTests.cacheDisplay(root, shots: [(body, shot)])
        let columns = Array(stride(from: full.minX + 2, to: full.maxX - 2, by: 7))
        func drawsBody(in band: NSRect) -> Bool {
            stride(from: band.minY + 0.5, to: band.maxY, by: 2).contains { y in
                columns.contains { x in Self.isBody(Self.color(rep, at: NSPoint(x: x, y: y), in: root.bounds)) }
            }
        }
        #expect(!drawsBody(in: footer.frame), "nothing of the body is drawn over the footer")
        #expect(!drawsBody(in: toolbar.frame), "nothing of the body is drawn over the toolbar")
        #expect(Self.isBody(Self.color(rep, at: NSPoint(x: full.midX, y: footer.frame.maxY + 3), in: root.bounds)),
                "the body shows right down to the footer")
        #expect(Self.isBody(Self.color(rep, at: NSPoint(x: full.midX, y: toolbar.frame.minY - 3), in: root.bounds)),
                "the body shows right up to the toolbar")
    }

    static func color(_ rep: NSBitmapImageRep, at point: NSPoint, in bounds: NSRect) -> NSColor? {
        let x = Int(point.x / bounds.width * CGFloat(rep.pixelsWide))
        let y = Int((bounds.height - point.y) / bounds.height * CGFloat(rep.pixelsHigh))
        guard (0..<rep.pixelsWide).contains(x), (0..<rep.pixelsHigh).contains(y) else { return nil }
        return rep.colorAt(x: x, y: y)
    }

    static func isBody(_ color: NSColor?) -> Bool {
        guard let c = color?.usingColorSpace(.sRGB) else { return false }
        return c.redComponent > 0.9 && c.greenComponent < 0.2 && c.blueComponent < 0.2
    }
}

private final class BandView: NSView {
    let color: NSColor

    init(_ color: NSColor, frame: NSRect) {
        self.color = color
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}
