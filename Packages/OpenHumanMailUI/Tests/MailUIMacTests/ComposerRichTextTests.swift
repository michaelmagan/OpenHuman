import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailRender
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
@Suite struct ComposerRichTextTests {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 600), styleMask: [.titled],
                          backing: .buffered, defer: false)
    let bridge = AttributedBridge(font: .systemFont(ofSize: 14))

    init() { window.isReleasedWhenClosed = false }

    func until(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        let clock = ContinuousClock()
        let deadline = clock.now + testBackstop
        while !condition() {
            if clock.now > deadline {
                Issue.record("condition not met within 15 s", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func editor(bridge: AttributedBridge? = nil) -> ComposerTextView {
        let text = ComposerTextView.make()
        text.bridge = bridge ?? self.bridge
        text.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView?.addSubview(text)
        return text
    }

    func clipboard(for text: ComposerTextView, _ fill: (NSPasteboard) throws -> Void) rethrows -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        try fill(board)
        text.pasteboard = { board }
        return board
    }

    static func pngData(width: Int = 4, height: Int = 3) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }

    func key(_ chars: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 100,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func inlineImagesRoundTripAtTheirShownSize() throws {
        let photo = InlineImageContent(image: NSImage(size: NSSize(width: 800, height: 600)), data: Self.pngData(),
                                       fileExtension: "png")
        let document = RichTextDocument(blocks: [
            .paragraph([.text("Before", [])]),
            .image(InlineImageRef(contentID: "a@openhuman", width: 320, height: 200, alt: "Chart")),
            .image(InlineImageRef(contentID: "b@openhuman", alt: "Photo")),
            .list(ordered: false, items: [[.paragraph([.text("item", [])]),
                                           .image(InlineImageRef(contentID: "c@openhuman", width: 20, height: 10))]]),
            .paragraph([.text("After", [])]),
        ])
        let themed = AttributedBridge(theme: ThemeTokens.light)
        let attributed = themed.attributedString(document) { ref in ref.contentID == "b@openhuman" ? photo : nil }
        let back = themed.document(attributed)
        #expect(back == RichTextDocument(blocks: [
            .paragraph([.text("Before", [])]),
            .image(InlineImageRef(contentID: "a@openhuman", width: 320, height: 200, alt: "Chart")),
            .image(InlineImageRef(contentID: "b@openhuman", width: 480, height: 360, alt: "Photo")),
            .list(ordered: false, items: [[.paragraph([.text("item", [])]),
                                           .image(InlineImageRef(contentID: "c@openhuman", width: 20, height: 10))]]),
            .paragraph([.text("After", [])]),
        ]), "a wide picture is shown, and sent, at most 480 wide: \(back)")
        #expect(themed.document(themed.attributedString(back)) == back, "stable once sized")

        var positions: [String: Int] = [:]
        attributed.enumerateAttribute(AttributedBridge.inlineImageKey, in: NSRange(location: 0, length: attributed.length)) {
            value, range, _ in
            if let id = value as? String { positions[id] = range.location }
        }
        let photoAt = try #require(positions["b@openhuman"])
        let attachment = try #require(attributed.attribute(.attachment, at: photoAt, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.fileWrapper?.preferredFilename == "b@openhuman.png", "the bytes travel under the content id")
        #expect(attachment.image(forBounds: .zero, textContainer: nil, characterIndex: photoAt) === photo.image,
                "and the picture is still what is drawn")
        let resized = try #require(attachment as? InlineImageAttachment).resized(to: CGSize(width: 240, height: 180))
        #expect(resized.fileWrapper?.preferredFilename == "b@openhuman.png", "a new size keeps the content id")
        #expect(AttributedBridge.contentID(fromAttachmentName: "b@openhuman.png") == "b@openhuman")
        let style = try #require(attributed.attribute(.paragraphStyle, at: photoAt, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.maximumLineHeight == 0 && style.minimumLineHeight == 18, "the picture's line is not cut to 18 pt")
        let html = ComposeSerializer.html(back, signature: nil)
        #expect(html.contains("<img src=\"cid:b@openhuman\" alt=\"Photo\" width=\"480\" height=\"360\">"))
    }

    @Test func textAroundAPictureInOneParagraphBecomesTheParagraphsBeforeAndAfterIt() {
        let text = NSMutableAttributedString(string: "foo", attributes: bridge.typingAttributes)
        text.append(bridge.imageCharacter(InlineImageRef(contentID: "x@openhuman", width: 10, height: 10), content: nil))
        text.append(NSAttributedString(string: "bar", attributes: bridge.typingAttributes))
        #expect(bridge.document(text) == RichTextDocument(blocks: [
            .paragraph([.text("foo", [])]), .image(InlineImageRef(contentID: "x@openhuman", width: 10, height: 10)),
            .paragraph([.text("bar", [])]),
        ]))
        let foreign = NSMutableAttributedString(string: "a", attributes: bridge.typingAttributes)
        foreign.append(NSAttributedString(attachment: NSTextAttachment()))
        #expect(bridge.document(foreign) == RichTextDocument(blocks: [.paragraph([.text("a", [])])]))
    }

    @Test func richPasteKeepsBoldLinksAndListsInTheComposersOwnStyle() throws {
        let text = editor()
        let board = clipboard(for: text) { board in
            board.setString("<p><span style=\"font-family:Times;font-size:30px;color:red;font-weight:bold\">Big</span> news: "
                            + "<a href=\"https://example.com/x?utm_source=a\">read</a></p><ul><li>one</li></ul>",
                            forType: .html)
            board.setString("Big news: read\none", forType: .string)
        }
        defer { board.releaseGlobally() }
        var reports: [ComposePaste.Report] = []
        text.onPasteCleaned = { reports.append($0) }
        text.paste(nil)
        #expect(text.document == RichTextDocument(blocks: [
            .paragraph([.text("Big", .bold), .text(" news: ", []),
                        .link(URL(string: "https://example.com/x")!, [.text("read", [])])]),
            .list(ordered: false, items: [[.paragraph([.text("one", [])])]]),
        ]), "\(text.document)")
        #expect(reports == [ComposePaste.Report(removedParameters: 1)])
        let font = try #require(text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 14 && font.fontDescriptor.symbolicTraits.contains(.bold), "the composer's font, bold")
        let color = text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == bridge.textColor, "never the page's color")
    }

    @Test func pasteAndMatchStyleInsertsThePlainTextInTheStyleAtTheCaret() {
        let text = editor()
        let board = clipboard(for: text) { board in
            board.setString("<b>rich</b>", forType: .html)
            board.setString("plain\u{200B} words\r\nnext", forType: .string)
        }
        defer { board.releaseGlobally() }
        text.insertText("Hi ", replacementRange: NSRange(location: 0, length: 0))
        text.toggle(.italic)
        text.pasteAsPlainText(nil)
        #expect(text.document == RichTextDocument(blocks: [
            .paragraph([.text("Hi ", []), .text("plain words", .italic)]),
            .paragraph([.text("next", .italic)]),
        ]), "\(text.document)")
    }

    @Test func richTextFromOtherAppsKeepsItsMarksAndLinksButNotItsFonts() throws {
        let text = editor()
        let source = NSMutableAttributedString(string: "Bold ", attributes: [
            .font: NSFont(name: "Helvetica-Bold", size: 30) ?? NSFont.boldSystemFont(ofSize: 30),
            .foregroundColor: NSColor.systemRed,
        ])
        source.append(NSAttributedString(string: "link", attributes: [
            .font: NSFont(name: "Helvetica", size: 30) ?? NSFont.systemFont(ofSize: 30),
            .link: URL(string: "https://example.com/?gclid=1&q=2")!,
        ]))
        let rtf = try #require(source.rtf(from: NSRange(location: 0, length: source.length), documentAttributes: [:]))
        let board = clipboard(for: text) { $0.setData(rtf, forType: .rtf) }
        defer { board.releaseGlobally() }
        text.paste(nil)
        #expect(text.document == RichTextDocument(blocks: [.paragraph([
            .text("Bold ", .bold), .link(URL(string: "https://example.com/?q=2")!, [.text("link", [])]),
        ])]), "\(text.document)")
        let font = try #require(text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 14, "the composer's size, not 30 pt")
    }

    @Test func aPastedPictureBecomesAnInlineImageOnItsOwnLine() throws {
        let text = editor()
        let board = clipboard(for: text) { $0.setData(Self.pngData(width: 8, height: 6), forType: .png) }
        defer { board.releaseGlobally() }
        var added: [String] = []
        text.onInlineImageData = { _, fileExtension in
            added.append(fileExtension)
            return InlineImageRef(contentID: "pasted@openhuman", alt: "Pasted image")
        }
        text.insertText("Before", replacementRange: NSRange(location: 0, length: 0))
        text.paste(nil)
        #expect(added == ["png"])
        let blocks = text.document.blocks
        #expect(blocks.count == 2 && blocks.first == .paragraph([.text("Before", [])]), "\(blocks)")
        guard case .image(let ref)? = blocks.last else {
            Issue.record("no inline image: \(blocks)")
            return
        }
        #expect(ref.contentID == "pasted@openhuman" && ref.alt == "Pasted image")
        #expect(text.string.hasPrefix("Before\n") && text.string.hasSuffix("\u{FFFC}"), "the picture got its own line")
    }

    @Test func pastedFilesArePicturesInTheTextOrAttachments() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oh-composer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let map = folder.appendingPathComponent("Map.png")
        try Self.pngData().write(to: map)
        let notes = folder.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: notes)

        let text = editor()
        var attached: [String] = []
        text.onFiles = { urls in attached += urls.map(\.lastPathComponent) }
        text.onInlineImageFile = { url in
            InlineImageRef(contentID: "map@openhuman", alt: InlineImages.altText(forFilename: url.lastPathComponent))
        }
        let board = clipboard(for: text) { $0.writeObjects([map as NSURL, notes as NSURL]) }
        defer { board.releaseGlobally() }
        text.paste(nil)
        #expect(attached == ["notes.txt"], "a file that is no picture is an attachment")
        #expect(text.document.blocks == [.image(InlineImageRef(contentID: "map@openhuman", width: 24, height: 24, alt: "Map"))],
                "\(text.document)")
    }

    @Test func theBarsCommandsAreTheKeysEditsAndTheStateFollowsTheSelection() {
        let text = editor()
        var commands: [ActionID] = []
        text.onCommand = { commands.append($0); return true }
        text.handleCommandKey(key("F", code: 3, modifiers: [.command, .shift]))
        #expect(!text.handleCommandKey(key("f", code: 3, modifiers: [.command, .option])), "⌥⌘F goes on to the card")
        #expect(!commands.contains(.toggleFormatBar))

        text.insertText("word here", replacementRange: NSRange(location: 0, length: 0))
        text.setSelectedRange(NSRange(location: 0, length: 4))
        #expect(text.formatState == ComposeFormatState(hasSelection: true))
        text.apply(.bold)
        text.apply(.italic)
        #expect(text.formatState.marks == [.bold, .italic] && text.formatState.hasSelection)
        text.apply(.bulletList)
        #expect(text.document == RichTextDocument(blocks: [.list(ordered: false, items: [[
            .paragraph([.text("word", [.bold, .italic]), .text(" here", [])]),
        ]])]))
        text.apply(.numberedList)
        #expect(text.document == RichTextDocument(blocks: [.list(ordered: true, items: [[
            .paragraph([.text("word", [.bold, .italic]), .text(" here", [])]),
        ]])]), "a bulleted list becomes a numbered one")
        var panels = 0
        text.showLinkPanel = { _ in panels += 1 }
        text.apply(.link)
        #expect(panels == 1, "the link button opens the link panel, like ⇧⌘K")
    }

    @Test func formattingNeverTakesAPictureOrAQuoteAway() {
        let text = editor()
        let picture = RichTextDocument.Block.image(InlineImageRef(contentID: "c@openhuman", width: 40, height: 30))
        text.load(RichTextDocument(blocks: [.quote([.paragraph([.text("quoted", [])])]), picture]))
        text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
        text.apply(.bold)
        #expect(text.document == RichTextDocument(blocks: [.quote([.paragraph([.text("quoted", .bold)])]), picture]),
                "\(text.document)")
        text.apply(.clearFormatting)
        #expect(text.document == RichTextDocument(blocks: [.quote([.paragraph([.text("quoted", [])])]), picture]))
        text.setSelectedRange(NSRange(location: 0, length: 6))
        #expect(text.formatState.isQuote && text.formatState.list == nil)
    }

    @Test func theFloatingBarSitsAboveTheSelectionAndBelowItWithoutRoom() {
        let size = NSSize(width: 300, height: FormatBarMetrics.height + 2 * FormatBarRoot.shadowRoom)
        let frame = window.frame
        let line = NSRect(x: frame.minX + 100, y: frame.minY + 200, width: 80, height: 18)
        let above = FormatBarPanel.origin(for: size, over: line, in: window)
        #expect(above.y + FormatBarRoot.shadowRoom >= line.maxY, "the bar's bottom edge is above the line")
        let top = NSRect(x: frame.minX + 100, y: frame.maxY - 20, width: 80, height: 18)
        let below = FormatBarPanel.origin(for: size, over: top, in: window)
        #expect(below.y + size.height - FormatBarRoot.shadowRoom <= top.minY, "below the line when the top is too close")
    }

    @Test func theFormattingBarRendersInBothStyles() {
        for style in [FormatBarView.Style.floating, .inline] {
            let host = NSHostingView(rootView: FormatBarView(state: ComposeFormatState(marks: .bold), style: style) { _ in }
                .environment(\.theme, ResolvedTheme.light))
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 48)
            window.contentView?.addSubview(host)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height >= FormatBarMetrics.height && host.fittingSize.width > 9 * 28)
            host.removeFromSuperview()
        }
    }

    @Test func theEditorIsTheSessionsFormatterAndReportsTheSelection() async throws {
        let env = AppEnvironment.fake(corpus: .small, options: .init(remoteAck: .immediate))
        env.router.start()
        await until { env.router.list?.state == .loaded }
        let manager = env.compose
        let session = try #require(manager.openNew(placement: .modal))
        let host = NSHostingView(rootView: ComposerHostView(manager: manager).frame(width: 900, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let text = try #require(ComposerTests.descendants(of: host).compactMap { $0 as? ComposerTextView }.first)
        #expect(session.formatter != nil)
        text.insertText("make this bold", replacementRange: NSRange(location: 0, length: 0))
        text.setSelectedRange(NSRange(location: 10, length: 4))
        await until { session.formatState.hasSelection }
        #expect(!session.formatState.isActive(.bold))
        session.applyFormat(.bold)
        #expect(session.document == RichTextDocument(blocks: [.paragraph([.text("make this ", []), .text("bold", .bold)])]))
        await until { session.formatState.isActive(.bold) }
        manager.close(session)
        host.removeFromSuperview()
    }
}
