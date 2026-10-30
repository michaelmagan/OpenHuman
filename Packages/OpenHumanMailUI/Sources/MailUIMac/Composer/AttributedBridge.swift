import AppKit
import MailRender
import MailTheme

public struct InlineImageContent {
    public var image: NSImage
    public var data: Data?
    public var fileExtension: String

    public init(image: NSImage, data: Data?, fileExtension: String) {
        self.image = image
        self.data = data
        self.fileExtension = fileExtension
    }

    public static func load(_ url: URL?) -> InlineImageContent? {
        guard let url, let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        return InlineImageContent(image: image, data: data, fileExtension: url.pathExtension.lowercased())
    }
}

@MainActor
public struct AttributedBridge {
    public let font: NSFont
    public let textColor: NSColor
    public let linkColor: NSColor
    public let placeholderColor: NSColor
    public let ghostColor: NSColor
    public let lineHeight: CGFloat?
    public let maxImageFraction: CGFloat

    public static let quoteKey = NSAttributedString.Key("dev.openhuman.mail.composer.quote")
    public static let inlineImageKey = NSAttributedString.Key("dev.openhuman.mail.composer.inlineImage")
    public static let inlineImageAltKey = NSAttributedString.Key("dev.openhuman.mail.composer.inlineImageAlt")
    static let quoteIndent: CGFloat = 12
    static let listIndent: CGFloat = 24
    static let markerGap: CGFloat = 6
    static let unsizedImageWidth: CGFloat = 480

    public init(theme: ThemeTokens) {
        font = theme.typeBody.font
        textColor = theme.textPrimary.nsColor
        linkColor = theme.component.link.text.nsColor
        placeholderColor = theme.textTertiary.nsColor
        ghostColor = theme.textSecondary.nsColor
        lineHeight = theme.typeBody.lineHeight
        maxImageFraction = Self.imageFraction(percent: theme.readerMaxImageWidth)
    }

    // The reader's own image cap, so a draft shows a picture as wide as the sent copy will be
    static func imageFraction(percent: Double) -> CGFloat {
        percent.isFinite && percent > 0 ? CGFloat(min(max(percent, 10), 100)) / 100 : 1
    }

    public init(font: NSFont, textColor: NSColor = .textColor, linkColor: NSColor = .linkColor,
                placeholderColor: NSColor = .placeholderTextColor, lineHeight: CGFloat? = nil,
                ghostColor: NSColor = .secondaryLabelColor, maxImageFraction: CGFloat = 1) {
        self.font = font
        self.maxImageFraction = maxImageFraction
        self.textColor = textColor
        self.linkColor = linkColor
        self.placeholderColor = placeholderColor
        self.ghostColor = ghostColor
        self.lineHeight = lineHeight
    }

    public var typingAttributes: [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        if let style = paragraphStyle() { attrs[.paragraphStyle] = style }
        return attrs
    }

    public var placeholderAttributes: [NSAttributedString.Key: Any] {
        var attrs = typingAttributes
        attrs[.foregroundColor] = placeholderColor
        return attrs
    }

    public var ghostAttributes: [NSAttributedString.Key: Any] {
        var attrs = typingAttributes
        attrs[.foregroundColor] = ghostColor
        return attrs
    }

    public var lineHeightValue: CGFloat {
        lineHeight ?? ceil(font.ascender - font.descender + font.leading)
    }

    func paragraphStyle(lists: [NSTextList] = [], quoted: Bool = false) -> NSMutableParagraphStyle? {
        guard lineHeight != nil || !lists.isEmpty || quoted else { return nil }
        let style = NSMutableParagraphStyle()
        if let lineHeight {
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
        }
        var indent: CGFloat = quoted ? Self.quoteIndent : 0
        if !lists.isEmpty {
            style.textLists = lists
            indent += CGFloat(lists.count) * Self.listIndent
            // Right-aligned so a wide number such as "10." still ends before the item text
            style.tabStops = [NSTextTab(textAlignment: .right, location: indent - Self.markerGap),
                              NSTextTab(textAlignment: .left, location: indent)]
            style.defaultTabInterval = Self.listIndent
            style.headIndent = indent
            style.firstLineHeadIndent = quoted ? Self.quoteIndent : 0
        } else {
            style.headIndent = indent
            style.firstLineHeadIndent = indent
        }
        return style
    }

    public func attributedString(_ document: RichTextDocument,
                                 images: (InlineImageRef) -> InlineImageContent? = { _ in nil }) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let blocks = document.blocks
        for (index, block) in blocks.enumerated() {
            append(block, to: out, lists: [], images: images)
            if index < blocks.count - 1 { out.append(NSAttributedString(string: "\n", attributes: typingAttributes)) }
        }
        Self.uncapLineHeights(in: out)
        return out
    }

    private func append(_ block: RichTextDocument.Block, to out: NSMutableAttributedString, lists: [NSTextList],
                        images: (InlineImageRef) -> InlineImageContent?) {
        switch block {
        case .paragraph(let inlines):
            let start = out.length
            for inline in inlines { append(inline, marks: [], link: nil, to: out) }
            applyParagraph(lists: lists, to: out, from: start)
        case .list(let ordered, let items, let first):
            let list = NSTextList(markerFormat: Self.markerFormat(ordered: ordered, depth: lists.count), options: 0)
            let number = RichTextDocument.listStart(first, ordered: ordered) ?? 1
            list.startingItemNumber = number
            let levels = lists + [list]
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(NSAttributedString(string: "\n", attributes: typingAttributes)) }
                var start = out.length
                let marker = Self.marker(list, number: number + i)
                out.append(NSAttributedString(string: marker, attributes: typingAttributes))
                let paragraphs = item.isEmpty ? [RichTextDocument.Block.paragraph([])] : item
                for (j, inner) in paragraphs.enumerated() {
                    if j > 0, !Self.isImage(inner), !Self.isImage(paragraphs[j - 1]) {
                        out.append(NSAttributedString(string: "\n", attributes: typingAttributes))
                        if case .list = paragraphs[j - 1] { start = out.length }
                    }
                    if case .paragraph(let inlines) = inner {
                        for inline in inlines { append(inline, marks: [], link: nil, to: out) }
                    } else if case .list = inner {
                        applyParagraph(lists: levels, to: out, from: start)
                        append(inner, to: out, lists: levels, images: images)
                        start = out.length
                    } else {
                        append(inner, to: out, lists: levels, images: images)
                    }
                }
                applyParagraph(lists: levels, to: out, from: start)
            }
        case .quote(let inner):
            let start = out.length
            for (i, b) in inner.enumerated() {
                if i > 0 { out.append(NSAttributedString(string: "\n", attributes: typingAttributes)) }
                append(b, to: out, lists: lists, images: images)
            }
            if out.length > start {
                let range = NSRange(location: start, length: out.length - start)
                out.addAttribute(Self.quoteKey, value: true, range: range)
                if let style = paragraphStyle(lists: lists, quoted: true) { out.addAttribute(.paragraphStyle, value: style, range: range) }
            }
        case .image(let ref):
            out.append(imageCharacter(ref, content: images(ref)))
        }
    }

    static func isImage(_ block: RichTextDocument.Block) -> Bool {
        if case .image = block { return true }
        return false
    }

    func imageCharacter(_ ref: InlineImageRef, content: InlineImageContent?) -> NSAttributedString {
        let attachment = InlineImageAttachment()
        var wrapper: FileWrapper?
        if let content, let data = content.data {
            wrapper = FileWrapper(regularFileWithContents: data)
            wrapper?.preferredFilename = Self.attachmentName(contentID: ref.contentID, fileExtension: content.fileExtension)
        }
        attachment.show(content?.image ?? Self.missingImage, file: wrapper)
        let size = Self.displaySize(ref: ref, image: content?.image)
        attachment.size = size
        attachment.natural = content.flatMap { Self.naturalSize($0.image) } ?? size
        attachment.maxFraction = maxImageFraction
        attachment.bounds = CGRect(origin: .zero, size: size)
        var attrs = typingAttributes
        attrs[.attachment] = attachment
        attrs[Self.inlineImageKey] = ref.contentID
        if let alt = ref.alt, !alt.isEmpty { attrs[Self.inlineImageAltKey] = alt }
        return NSAttributedString(string: "\u{FFFC}", attributes: attrs)
    }

    static let missingImage: NSImage = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        ?? NSImage(size: NSSize(width: 24, height: 24))

    static func displaySize(ref: InlineImageRef, image: NSImage?) -> CGSize {
        if let size = ref.size { return InlineImageSizing.fit(size, maxWidth: InlineImageSizing.maximumSide) }
        let natural = image.flatMap(naturalSize) ?? CGSize(width: 24, height: 24)
        return InlineImageSizing.fit(natural, maxWidth: unsizedImageWidth)
    }

    // In points: a Retina screenshot of 1840 pixels says 144 dpi and is 920 points wide
    static func naturalSize(_ image: NSImage) -> CGSize? {
        let size = image.size
        if size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite { return size }
        guard let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    static func attachmentName(contentID: String, fileExtension: String) -> String {
        fileExtension.isEmpty ? contentID : contentID + "." + fileExtension
    }

    static func contentID(fromAttachmentName name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? nil : base
    }

    static func uncapLineHeights(in text: NSMutableAttributedString, range: NSRange? = nil) {
        let scope = range ?? NSRange(location: 0, length: text.length)
        guard scope.length > 0, NSMaxRange(scope) <= text.length else { return }
        let ns = text.string as NSString
        var paragraphs: [NSRange] = []
        text.enumerateAttribute(inlineImageKey, in: scope) { value, found, _ in
            guard value != nil else { return }
            paragraphs.append(ns.paragraphRange(for: found))
        }
        for paragraph in paragraphs where paragraph.length > 0 {
            let current = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            let style = (current?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            guard style.maximumLineHeight != 0 || current == nil else { continue }
            style.maximumLineHeight = 0
            text.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
    }

    private func applyParagraph(lists: [NSTextList], to out: NSMutableAttributedString, from start: Int) {
        guard !lists.isEmpty, out.length > start, let style = paragraphStyle(lists: lists) else { return }
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
    }

    private func append(_ inline: RichTextDocument.Inline, marks: RichTextDocument.Marks, link: URL?,
                        to out: NSMutableAttributedString) {
        switch inline {
        case .text(let text, let own):
            out.append(NSAttributedString(string: text, attributes: attributes(marks.union(own), link: link)))
        case .link(let url, let inner):
            for i in inner { append(i, marks: marks, link: url, to: out) }
        case .lineBreak:
            out.append(NSAttributedString(string: "\u{2028}", attributes: attributes(marks, link: nil)))
        case .mention(let mention):
            let label = "@" + ((mention.name?.isEmpty == false ? mention.name : nil) ?? mention.email)
            out.append(NSAttributedString(string: label,
                                          attributes: attributes(marks, link: URL(string: "mailto:" + mention.email))))
        }
    }

    func attributes(_ marks: RichTextDocument.Marks, link: URL?) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: textColor]
        if let style = paragraphStyle() { attrs[.paragraphStyle] = style }
        var f = marks.contains(.code) ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : font
        var traits: NSFontDescriptor.SymbolicTraits = []
        if marks.contains(.bold) { traits.insert(.bold) }
        if marks.contains(.italic) { traits.insert(.italic) }
        if !traits.isEmpty {
            let descriptor = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(traits))
            f = NSFont(descriptor: descriptor, size: f.pointSize) ?? f
        }
        attrs[.font] = f
        if marks.contains(.underline) { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if marks.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link {
            attrs[.link] = link
            attrs[.foregroundColor] = linkColor
        }
        return attrs
    }

    public func document(_ text: NSAttributedString) -> RichTextDocument {
        let ns = text.string as NSString
        var paragraphs: [NSRange] = []
        var start = 0
        for i in 0..<ns.length {
            let c = ns.character(at: i)
            if c == 0x0A || c == 0x2029 || c == 0x0D {
                paragraphs.append(NSRange(location: start, length: i - start))
                start = i + 1
            }
        }
        paragraphs.append(NSRange(location: start, length: ns.length - start))

        var blocks: [RichTextDocument.Block] = []
        var quoted: [RichTextDocument.Block]?
        var openList: (top: NSTextList, entries: [ListEntry])?
        func emit(_ block: RichTextDocument.Block) {
            if quoted != nil { quoted?.append(block) } else { blocks.append(block) }
        }
        func flushList() {
            if let list = openList, !list.entries.isEmpty { emit(Self.listBlock(list.entries[...], depth: 0)) }
            openList = nil
        }
        func flushQuote() {
            flushList()
            if let inner = quoted, !inner.isEmpty { blocks.append(.quote(inner)) }
            quoted = nil
        }
        for range in paragraphs {
            let style = range.location < text.length
                ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil
            let isQuote = range.location < text.length && text.attribute(Self.quoteKey, at: range.location, effectiveRange: nil) != nil
            if isQuote != (quoted != nil) {
                if isQuote { flushList(); quoted = [] } else { flushQuote() }
            }
            let lists = style?.textLists ?? []
            if let top = lists.first {
                let content = self.blocks(in: text.attributedSubstring(from: Self.droppingMarker(range, in: ns)))
                if openList == nil || openList?.top !== top {
                    flushList()
                    openList = (top, [])
                }
                openList?.entries.append(ListEntry(lists: lists, content: content))
            } else {
                flushList()
                for block in self.blocks(in: text.attributedSubstring(from: range)) { emit(block) }
            }
        }
        flushQuote()
        flushList()
        if blocks == [.paragraph([])] { blocks = [] }
        return RichTextDocument(blocks: blocks).normalized
    }

    func blocks(in paragraph: NSAttributedString) -> [RichTextDocument.Block] {
        let ns = paragraph.string as NSString
        var out: [RichTextDocument.Block] = []
        var start = 0
        var hasImage = false
        func text(upTo end: Int) {
            guard end > start else { return }
            let inlines = self.inlines(paragraph.attributedSubstring(from: NSRange(location: start, length: end - start)))
            if !inlines.isEmpty { out.append(.paragraph(inlines)) }
        }
        paragraph.enumerateAttribute(Self.inlineImageKey, in: NSRange(location: 0, length: paragraph.length)) { value, range, _ in
            guard let contentID = value as? String else { return }
            for index in range.location..<NSMaxRange(range) where ns.character(at: index) == 0xFFFC {
                text(upTo: index)
                out.append(.image(imageRef(contentID, at: index, in: paragraph)))
                hasImage = true
                start = index + 1
            }
        }
        guard hasImage else { return [.paragraph(inlines(paragraph))] }
        text(upTo: ns.length)
        return out
    }

    func imageRef(_ contentID: String, at index: Int, in text: NSAttributedString) -> InlineImageRef {
        let attachment = text.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment
        let alt = text.attribute(Self.inlineImageAltKey, at: index, effectiveRange: nil) as? String
        let size = (attachment as? InlineImageAttachment)?.size ?? attachment?.bounds.size ?? .zero
        return InlineImageRef(contentID: contentID, width: size.width > 0 ? Int(size.width.rounded()) : nil,
                              height: size.height > 0 ? Int(size.height.rounded()) : nil,
                              alt: alt?.isEmpty == false ? alt : nil)
    }

    func inlines(_ text: NSAttributedString) -> [RichTextDocument.Inline] {
        var out: [RichTextDocument.Inline] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let raw = (text.string as NSString).substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
            let marks = Self.marks(attrs)
            var runs: [RichTextDocument.Inline] = []
            let pieces = raw.components(separatedBy: "\u{2028}")
            for (i, piece) in pieces.enumerated() {
                if i > 0 { runs.append(.lineBreak) }
                if !piece.isEmpty { runs.append(.text(piece, marks)) }
            }
            if let url = Self.link(attrs[.link]), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                if case .link(let previous, let inner)? = out.last, previous == url {
                    out[out.count - 1] = .link(url, inner + runs)
                } else {
                    out.append(.link(url, runs))
                }
            } else {
                out.append(contentsOf: runs)
            }
        }
        return out
    }

    static func marks(_ attrs: [NSAttributedString.Key: Any]) -> RichTextDocument.Marks {
        var marks: RichTextDocument.Marks = []
        if let font = attrs[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.bold) { marks.insert(.bold) }
            if traits.contains(.italic) { marks.insert(.italic) }
            if traits.contains(.monoSpace) { marks.insert(.code) }
        }
        if let underline = attrs[.underlineStyle] as? Int, underline != 0 { marks.insert(.underline) }
        if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 { marks.insert(.strikethrough) }
        return marks
    }

    static func link(_ value: Any?) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    struct ListEntry {
        var lists: [NSTextList]
        var content: [RichTextDocument.Block]
    }

    static func listBlock(_ entries: ArraySlice<ListEntry>, depth: Int) -> RichTextDocument.Block {
        let own = entries.first.map { $0.lists[min(depth, $0.lists.count - 1)] }
        var items: [[RichTextDocument.Block]] = []
        var i = entries.startIndex
        while i < entries.endIndex {
            let entry = entries[i]
            guard entry.lists.count > depth + 1 else {
                items.append(entry.content)
                i += 1
                continue
            }
            let nestedTop = entry.lists[depth + 1]
            var j = i
            while j < entries.endIndex, entries[j].lists.count > depth + 1, entries[j].lists[depth + 1] === nestedTop { j += 1 }
            if items.isEmpty { items.append([]) }
            items[items.count - 1].append(listBlock(entries[i..<j], depth: depth + 1))
            i = j
        }
        let ordered = own.map(isOrdered) ?? false
        return .list(ordered: ordered, items: items, start: RichTextDocument.listStart(own?.startingItemNumber, ordered: ordered))
    }

    // A fresh list from 1, so the shown number never depends on how AppKit applies startingItemNumber
    static func marker(_ list: NSTextList, number: Int) -> String {
        let text = NSTextList(markerFormat: list.markerFormat, options: 0).marker(forItemNumber: number)
        let numbered = isOrdered(list) && text.last.map { $0.isNumber || $0.isLetter } == true
        return "\t" + (numbered ? text + "." : text) + "\t"
    }

    // The period is part of the format so every marker TextKit makes for the list carries it too
    static let numberedFormat = NSTextList.MarkerFormat("{decimal}.")

    static func markerFormat(ordered: Bool, depth: Int) -> NSTextList.MarkerFormat {
        if ordered { return numberedFormat }
        switch depth % 3 {
        case 0: return .disc
        case 1: return .circle
        default: return .square
        }
    }

    // The regular bullet is a faint speck next to body text
    static func bulletFont(size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .black) }

    static func isOrdered(_ list: NSTextList) -> Bool {
        list.markerFormat != .disc && list.markerFormat != .circle && list.markerFormat != .square
            && list.markerFormat != .hyphen && list.markerFormat != .diamond && list.markerFormat != .box
            && list.markerFormat != .check
    }

    static func droppingMarker(_ range: NSRange, in ns: NSString) -> NSRange {
        let line = ns.substring(with: range)
        guard line.hasPrefix("\t"), let second = line.dropFirst().firstIndex(of: "\t") else { return range }
        let skip = line.distance(from: line.startIndex, to: line.index(after: second))
        let utf16Skip = (String(line[..<line.index(line.startIndex, offsetBy: skip)]) as NSString).length
        return NSRange(location: range.location + utf16Skip, length: max(0, range.length - utf16Skip))
    }
}

// Holds the size the author chose, which is also the size sent. Like the reader's max-width, it is shown smaller when
// the column is narrower, and the chosen size comes back when the column widens again.
final class InlineImageAttachment: NSTextAttachment {
    var size: CGSize = .zero
    var natural: CGSize = .zero
    var maxFraction: CGFloat = 1
    var picture: NSImage?

    // Setting `image` and `fileWrapper` each clears the other, and the file wrapper's name carries the content id that a
    // copy or a drag pastes back. So the picture is drawn from here, never from the file at its own size.
    func show(_ picture: NSImage, file: FileWrapper?) {
        allowsTextAttachmentView = false
        if let file { fileWrapper = file } else { image = picture }
        self.picture = picture
    }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> NSImage? {
        picture ?? super.image(for: bounds, attributes: attributes, location: location, textContainer: textContainer)
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> NSImage? {
        picture ?? super.image(forBounds: imageBounds, textContainer: textContainer, characterIndex: charIndex)
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        let room = proposedLineFragment.width > 1 ? proposedLineFragment.width * maxFraction : size.width
        return CGRect(origin: .zero, size: InlineImageSizing.fit(size, maxWidth: room))
    }

    func resized(to size: CGSize) -> InlineImageAttachment {
        let copy = InlineImageAttachment()
        if let picture { copy.show(picture, file: fileWrapper) }
        copy.size = size
        copy.natural = natural
        copy.maxFraction = maxFraction
        copy.bounds = CGRect(origin: .zero, size: size)
        return copy
    }
}
