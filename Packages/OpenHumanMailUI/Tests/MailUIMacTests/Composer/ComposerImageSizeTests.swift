import AppKit
import MailFeatures
import MailModel
import MailRender
import Testing
@testable import MailUIMac

@MainActor
@Suite struct ComposerImageSizeTests {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 700), styleMask: [.titled],
                          backing: .buffered, defer: false)

    init() { window.isReleasedWhenClosed = false }

    var undo: UndoManager? { window.undoManager }

    // A screenshot of 1840 by 1000 pixels; a Retina capture says 144 dpi, so it is 920 by 500 points
    static func screenshot(retina: Bool = true) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1840, pixelsHigh: 1000, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = retina ? NSSize(width: 920, height: 500) : NSSize(width: 1840, height: 1000)
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }

    static func content(_ data: Data) -> InlineImageContent? {
        NSImage(data: data).map { InlineImageContent(image: $0, data: data, fileExtension: "png") }
    }

    func editor(width: CGFloat) -> ComposerTextView {
        let text = ComposerTextView.make()
        text.bridge = AttributedBridge(font: .systemFont(ofSize: 14))
        text.textContainer?.widthTracksTextView = true
        text.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        window.contentView?.addSubview(text)
        return text
    }

    func pasting(_ data: Data, into text: ComposerTextView) {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.setData(data, forType: .png)
        defer { board.releaseGlobally() }
        text.pasteboard = { board }
        text.onInlineImageData = { _, _ in InlineImageRef(contentID: "shot@openhuman", alt: "Pasted image") }
        text.inlineImageProvider = { _ in Self.content(data) }
        text.paste(nil)
    }

    func image(_ text: ComposerTextView) -> InlineImageRef? {
        for case .image(let ref) in text.document.blocks { return ref }
        return nil
    }

    func imageAt(_ text: ComposerTextView) -> Int? {
        let found = (text.string as NSString).range(of: "\u{FFFC}").location
        return found == NSNotFound ? nil : found
    }

    func event(_ body: () -> Void) async {
        body()
        await runLoopGoesIdle()
        #expect(undo?.groupingLevel == 0, "the event's undo group is closed")
    }

    @Test func aPastedScreenshotStartsAtMediumOfTheColumnMeasuredInPoints() throws {
        let text = editor(width: 400)
        pasting(Self.screenshot(), into: text)
        let ref = try #require(image(text))
        #expect(ref.width == 240 && ref.height == 130, "60 percent of a 400 pt column: \(ref)")
        let index = try #require(imageAt(text))
        #expect(text.imageFrame(at: index)?.size == CGSize(width: 240, height: 130), "shown at the size it is sent")
        let html = ComposeSerializer.html(text.document, signature: nil)
        #expect(html.contains("width=\"240\" height=\"130\""), "\(html)")
    }

    @Test func originalIsThePointSizeNotThePixelSizeAndIsShownNoWiderThanTheColumn() throws {
        let text = editor(width: 400)
        text.pastedImageSize = .original
        pasting(Self.screenshot(), into: text)
        let ref = try #require(image(text))
        #expect(ref.width == 920 && ref.height == 500, "points, not 1840 pixels: \(ref)")
        let index = try #require(imageAt(text))
        #expect(text.imageFrame(at: index)?.width == 400, "like the reader's max-width, it fits the column")

        let flat = editor(width: 400)
        flat.pastedImageSize = .original
        pasting(Self.screenshot(retina: false), into: flat)
        #expect(image(flat)?.width == 1840, "a capture without Retina density is its pixel size")
        let retina = try #require(NSImage(data: Self.screenshot()))
        #expect(AttributedBridge.naturalSize(retina) == CGSize(width: 920, height: 500))
    }

    @Test func aSmallPictureIsNeverMadeLarger() throws {
        let text = editor(width: 400)
        text.pastedImageSize = .large
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        pasting(try #require(rep.representation(using: .png, properties: [:])), into: text)
        #expect(image(text)?.width == 32 && image(text)?.height == 24)
    }

    @Test func aDraftShowsAPictureAtTheSizeItIsSent() throws {
        let data = Self.screenshot()
        let text = editor(width: 700)
        text.inlineImageProvider = { _ in Self.content(data) }
        let sent = InlineImageRef(contentID: "shot@openhuman", width: 480, height: 261)
        text.load(RichTextDocument(blocks: [.paragraph([.text("Before", [])]), .image(sent)]))
        let index = try #require(imageAt(text))
        #expect(text.imageFrame(at: index)?.size == CGSize(width: 480, height: 261),
                "not the picture's own 920 points, which ran past the column")
        text.frame.size.width = 300
        #expect(text.imageFrame(at: index)?.width == 300, "a narrow window shows it smaller")
        #expect(image(text) == sent, "and still sends the chosen size")
    }

    @Test func choosingASizeShowsTheOverlayAndUndoAndRedoCoverIt() async throws {
        let data = Self.screenshot()
        let text = editor(width: 700)
        text.inlineImageProvider = { _ in Self.content(data) }
        text.load(RichTextDocument(blocks: [.paragraph([.text("Hi", [])]),
                                            .image(InlineImageRef(contentID: "shot@openhuman", width: 480, height: 261))]))
        #expect(window.makeFirstResponder(text))
        let index = try #require(imageAt(text))
        let before = text.imageFrame(at: index)
        text.setSelectedRange(NSRange(location: index, length: 1))
        text.updateImageOverlay()
        #expect(!text.imageOverlay.isHidden && text.imageOverlay.control.selectedSegment == -1, "480 is none of the four")
        #expect(text.imageOverlay.imageRect.size == CGSize(width: 480, height: 261))
        #expect(text.imageFrame(at: index) == before && text.imageOverlay.imageRect == before,
                "the overlay never moves the text")
        #expect(text.imageOverlay.control.accessibilityLabel() == "Image size")

        await event { text.applyImageSize(.small) }
        #expect(image(text) == InlineImageRef(contentID: "shot@openhuman", width: 210, height: 114), "30 percent of 700")
        #expect(text.selectedRange() == NSRange(location: index, length: 1), "the picture stays selected")
        text.updateImageOverlay()
        #expect(text.imageOverlay.control.selectedSegment == 0)

        await event { text.resizeImage(at: index, to: CGSize(width: 350, height: 190)) }
        #expect(image(text)?.width == 350)

        await event { undo?.undo() }
        #expect(image(text)?.width == 210, "one undo per resize")
        await event { undo?.undo() }
        #expect(image(text)?.width == 480)
        await event { undo?.redo() }
        #expect(image(text)?.width == 210)

        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.updateImageOverlay()
        #expect(text.imageOverlay.isHidden, "gone once the picture is not selected")
    }

    @Test func dragHandlesKeepTheAspectRatioAndTabReachesTheSizes() throws {
        let data = Self.screenshot()
        let text = editor(width: 700)
        text.inlineImageProvider = { _ in Self.content(data) }
        text.load(RichTextDocument(blocks: [.image(InlineImageRef(contentID: "shot@openhuman", width: 480, height: 261))]))
        #expect(window.makeFirstResponder(text))
        text.setSelectedRange(NSRange(location: 0, length: 1))
        text.updateImageOverlay()
        let overlay = text.imageOverlay
        #expect(overlay.resizedSize?(240) == CGSize(width: 240, height: 131))
        #expect(overlay.resizedSize?(5000).width == 700, "no wider than the column")
        let corner = overlay.handleRect(.bottomRight)
        #expect(overlay.corner(at: NSPoint(x: corner.midX, y: corner.midY)) == .bottomRight)
        #expect(overlay.hitTest(text.convert(NSPoint(x: 200, y: 120), from: overlay)) == nil,
                "a click inside the picture goes to the text")

        text.insertTab(nil)
        #expect(window.firstResponder === overlay.control, "Tab moves to the size buttons")
        #expect(text.string == "\u{FFFC}", "and types no tab")
        overlay.control.onLeave?()
        #expect(window.firstResponder === text && text.selectedRange() == NSRange(location: 0, length: 1))
    }

    @Test func theContextMenuOffersTheSizes() throws {
        let data = Self.screenshot()
        let text = editor(width: 700)
        text.inlineImageProvider = { _ in Self.content(data) }
        text.load(RichTextDocument(blocks: [.image(InlineImageRef(contentID: "shot@openhuman", width: 420, height: 228))]))
        let item = text.imageSizeMenuItem(at: 0)
        #expect(item.title == "Image Size")
        #expect(item.submenu?.items.map(\.title) == ["Small", "Medium", "Large", "Original"])
        #expect(item.submenu?.items.map(\.state) == [.off, .on, .off, .off], "420 is Medium of a 700 pt column")
    }
}
