import AppKit
import MailFeatures
import MailRender
import MailTheme

@MainActor
public final class PlainTextMessageView: NSView, NSTextViewDelegate {
    static let foldURL = URL(string: "oh-fold:quotes")!
    static let quoteLevelKey = NSAttributedString.Key("dev.openhuman.plainText.quoteLevel")

    public let textView: NSTextView
    private let document: PlainTextDocument
    private let layoutLines: PlainTextLayout
    private let theme: ThemeTokens
    private let bars = QuoteBarsView()
    private var heightConstraint: NSLayoutConstraint!
    private var lastWidth: CGFloat = -1
    public private(set) var quotesExpanded: Bool
    public private(set) var zoom: CGFloat
    var onLink: (URL) -> Void = { url in
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
    }
    var onToggleQuotes: (() -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?
    var onSelectionChange: ((String) -> Void)?
    private var lastSelection = ""

    public func textViewDidChangeSelection(_ notification: Notification) {
        let range = textView.selectedRange()
        let text = range.length > 0 ? (textView.string as NSString).substring(with: range) : ""
        guard text != lastSelection else { return }
        lastSelection = text
        onSelectionChange?(text)
    }

    public init(_ document: PlainTextDocument, theme: ThemeTokens, quotesExpanded: Bool = true, zoom: CGFloat = 1) {
        self.document = document
        self.layoutLines = PlainTextLayout(document)
        self.theme = theme
        self.quotesExpanded = quotesExpanded
        self.zoom = zoom
        textView = ReaderTextView(usingTextLayoutManager: true)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.delegate = self
        (textView as? ReaderTextView)?.owner = self
        textView.textStorage?.setAttributedString(Self.attributed(document, theme: theme, quotesExpanded: quotesExpanded, zoom: zoom))
        textView.setAccessibilityLabel("Message body")
        bars.color = theme.readerQuoteBorder.nsColor
        addSubview(bars)
        addSubview(textView)
        heightConstraint = heightAnchor.constraint(equalToConstant: 22)
        heightConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(quotesExpanded: Bool, zoom: CGFloat) {
        guard quotesExpanded != self.quotesExpanded || zoom != self.zoom else { return }
        self.quotesExpanded = quotesExpanded
        self.zoom = zoom
        textView.textStorage?.setAttributedString(Self.attributed(document, theme: theme, quotesExpanded: quotesExpanded, zoom: zoom))
        lastWidth = -1
        needsLayout = true
        superview?.needsLayout = true
    }

    public var hasFoldedText: Bool { layoutLines.foldStart != nil }

    var quoteBarRects: [CGRect] { bars.bars }

    static func attributed(_ document: PlainTextDocument, theme: ThemeTokens, quotesExpanded: Bool = true,
                           zoom: CGFloat = 1) -> NSAttributedString {
        let style = theme.typeReader
        let font = NSFont(descriptor: style.font.fontDescriptor, size: style.font.pointSize * zoom) ?? style.font
        let lineHeight = style.lineHeight * zoom
        let layout = PlainTextLayout(document)
        var paragraphs: [(content: NSAttributedString, lineBreak: [NSAttributedString.Key: Any])] = []
        var direction: TextDirection?
        for (index, line) in layout.lines.enumerated() {
            if index == layout.foldStart {
                let pillStyle = paragraphStyle(lineHeight: lineHeight, indent: 0, rightToLeft: false)
                let pillBreak: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: pillStyle]
                paragraphs.append((pill(theme: theme, font: font, paragraph: pillStyle, expanded: quotesExpanded), pillBreak))
                if !quotesExpanded { break }
            }
            let color: ThemeColor
            switch line.role {
            case .body: color = theme.textPrimary
            case .quote: color = theme.textSecondary
            case .signature: color = theme.textTertiary
            }
            direction = TextDirection.firstStrong(in: line.text) ?? direction
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color.nsColor,
                .paragraphStyle: paragraphStyle(lineHeight: lineHeight, indent: CGFloat(PlainTextLayout.indent(depth: line.depth)),
                                                rightToLeft: direction == .rightToLeft),
            ]
            if line.depth > 0 { attributes[quoteLevelKey] = min(line.depth, PlainTextLayout.maxQuoteLevels) }
            paragraphs.append((NSAttributedString(string: line.text, attributes: attributes), attributes))
        }
        let out = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            out.append(paragraph.content)
            if index < paragraphs.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: paragraph.lineBreak))
            }
        }
        for link in PlainTextLinks.detect(in: out.string) {
            out.addAttributes([.link: link.url, .foregroundColor: theme.component.link.text.nsColor], range: link.range)
        }
        return out
    }

    static func paragraphStyle(lineHeight: CGFloat, indent: CGFloat, rightToLeft: Bool) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.paragraphSpacing = 0
        paragraph.baseWritingDirection = rightToLeft ? .rightToLeft : .natural
        return paragraph
    }

    static func pill(theme: ThemeTokens, font: NSFont, paragraph: NSParagraphStyle, expanded: Bool) -> NSAttributedString {
        NSAttributedString(string: " ••• ", attributes: [
            .font: NSFont.systemFont(ofSize: font.pointSize * 0.75, weight: .semibold),
            .foregroundColor: theme.textTertiary.nsColor,
            .link: foldURL, .toolTip: expanded ? "Hide quoted text  ." : "Show quoted text  .",
            .paragraphStyle: paragraph,
        ])
    }

    public override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0 else { return }
        if width != lastWidth {
            lastWidth = width
            let height = Self.height(of: textView, width: width)
            if heightConstraint.constant != height {
                heightConstraint.constant = height
                superview?.needsLayout = true
            }
            bars.bars = Self.quoteBars(in: textView)
        }
        textView.frame = NSRect(x: 0, y: 0, width: width, height: heightConstraint.constant)
        bars.frame = textView.frame
    }

    public var measuredHeight: CGFloat { heightConstraint.constant }

    static func height(of textView: NSTextView, width: CGFloat) -> CGFloat {
        guard let manager = textView.textLayoutManager else { return 22 }
        textView.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: manager.documentRange)
        return max(22, manager.usageBoundsForTextContainer.height.rounded(.up))
    }

    static func quoteBars(in textView: NSTextView) -> [CGRect] {
        guard let storage = textView.textStorage, let manager = textView.textLayoutManager,
              let content = manager.textContentManager, storage.length > 0 else { return [] }
        var rects: [CGRect] = []
        storage.enumerateAttribute(quoteLevelKey, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            guard let level = value as? Int, level > 0,
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            var run: CGRect?
            manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                run = run.map { $0.union(frame) } ?? frame
                return true
            }
            guard let run else { return }
            for k in 0..<level {
                rects.append(CGRect(x: CGFloat(Double(k) * PlainTextLayout.quoteIndent), y: run.minY,
                                    width: CGFloat(PlainTextLayout.quoteBarWidth), height: run.height))
            }
        }
        return rects
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return true }
        if url == Self.foldURL {
            onToggleQuotes?()
            return true
        }
        onLink(url)
        return true
    }

    static let dateScheme = "x-openhuman-date"
    private(set) var dateSpans: [CalendarDateSpan] = []

    func markDates(timeZone: TimeZone) {
        guard let storage = textView.textStorage else { return }
        let spans = CalendarDateMentions.spans(in: textView.string, timeZone: timeZone)
        dateSpans = spans
        guard !spans.isEmpty else { return }
        storage.beginEditing()
        for (index, span) in spans.enumerated() where NSMaxRange(span.range) <= storage.length {
            guard storage.attribute(.link, at: span.range.location, effectiveRange: nil) == nil,
                  let url = URL(string: "\(Self.dateScheme):\(index)") else { continue }
            storage.addAttributes([.link: url,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .toolTip: String(localized: "Show on the calendar")],
                                  range: span.range)
        }
        storage.endEditing()
    }

    static func dateIndex(_ url: URL) -> Int? {
        guard url.scheme == dateScheme else { return nil }
        return Int(url.absoluteString.dropFirst(dateScheme.count + 1))
    }

    func ranges(of text: String) -> [NSRange] {
        guard !text.isEmpty, let string = textView.textStorage?.string as NSString? else { return [] }
        var out: [NSRange] = []
        var search = NSRange(location: 0, length: string.length)
        while search.length > 0 {
            let found = string.range(of: text, options: [.caseInsensitive, .diacriticInsensitive], range: search)
            guard found.location != NSNotFound else { break }
            out.append(found)
            let next = found.location + max(found.length, 1)
            search = NSRange(location: next, length: string.length - next)
        }
        return out
    }

    func select(_ range: NSRange) -> CGRect? {
        textView.setSelectedRange(range)
        textView.showFindIndicator(for: range)
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        var rect: CGRect?
        manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            rect = rect.map { $0.union(frame) } ?? frame
            return true
        }
        return rect.map { textView.convert($0, to: self) }
    }

    public override var isFlipped: Bool { true }
}

@MainActor
final class ReaderTextView: NSTextView {
    weak var owner: PlainTextMessageView?

    override func keyDown(with event: NSEvent) {
        if owner?.keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor
final class QuoteBarsView: NSView {
    var bars: [CGRect] = [] {
        didSet { if bars != oldValue { needsDisplay = true } }
    }
    var color: NSColor = .separatorColor {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        for bar in bars where bar.intersects(dirtyRect) { NSBezierPath.fill(bar) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
