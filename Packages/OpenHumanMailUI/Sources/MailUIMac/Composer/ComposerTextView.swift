import AppKit
import MailActions
import MailFeatures
import MailModel
import MailRender

@MainActor
public final class ComposerTextView: NSTextView {
    public var onCommand: ((ActionID) -> Bool)?
    public var commandKeys: [KeyChord: ActionID]?
    public var translation: KeyTranslation?

    static let catalogKeys = KeyTable.composer(ActionCatalog.all)
    public var onEscape: (() -> Void)?
    public var onFiles: (([URL]) -> Void)?
    public var onTyped: ((String, Int) -> Void)?
    public var pickerKeys: ((PickerKey) -> Bool)?
    public var suggestionKeys: ((InstantReplyModel.Key) -> Bool)?
    public var onInlineImageFile: ((URL) -> InlineImageRef?)?
    public var onInlineImageData: ((Data, String) -> InlineImageRef?)?
    public var inlineImageKnown: ((String) -> Bool)?
    public var inlineImageProvider: ((InlineImageRef) -> InlineImageContent?)?
    public var onPasteCleaned: ((ComposePaste.Report) -> Void)?
    public var onReload: (() -> Void)?
    public var pastedImageSize: InlineImageSize = .pastedDefault

    public enum PickerKey { case up, down, choose, close }

    public var bridge = AttributedBridge(font: .systemFont(ofSize: 14)) {
        didSet {
            typingAttributes = bridge.typingAttributes
            updateHint()
        }
    }

    public var showLinkPanel: (ComposerTextView) -> Void = { $0.orderFrontLinkPanel(nil) }

    public var pasteboard: () -> NSPasteboard = { NSPasteboard.general }

    public var placeholder = "" {
        didSet { if placeholder != oldValue { updateHint() } }
    }

    // Off until the composer allows it: the system may send the text off this Mac
    public var allowsWritingTools = false {
        didSet { writingToolsBehavior = allowsWritingTools ? .complete : .none }
    }

    public var ghostText: String? {
        didSet { if ghostText != oldValue { updateHint() } }
    }

    let hintView = ComposerHintView()
    let imageOverlay = InlineImageOverlay()
    var imageOverlayScheduled = false
    weak var announcedImage: NSTextAttachment?

    public var spokenPlaceholder: String?

    public override func accessibilityPlaceholderValue() -> String? {
        spokenPlaceholder ?? (placeholder.isEmpty ? super.accessibilityPlaceholderValue() : placeholder)
    }

    public static func make() -> ComposerTextView {
        let view = ComposerTextView(usingTextLayoutManager: true)
        view.configure()
        return view
    }

    func configure() {
        // List markers are part of the text; otherwise TextKit 2 draws its own and pushes the item text out of view
        textContentStorage?.includesTextListMarkers = true
        textContentStorage?.delegate = self
        isRichText = true
        allowsUndo = true
        isEditable = true
        isSelectable = true
        importsGraphics = true
        usesFindBar = true
        configure(with: .standard)
        drawsBackground = false
        textContainerInset = NSSize(width: 0, height: Self.verticalInset)
        textContainer?.lineFragmentPadding = 0
        typingAttributes = bridge.typingAttributes
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setAccessibilityLabel("Message body")
        addSubview(hintView, positioned: .below, relativeTo: nil)
        configureImageOverlay()
        NotificationCenter.default.addObserver(self, selector: #selector(textStorageDidEdit(_:)),
                                               name: NSTextStorage.didProcessEditingNotification, object: textStorage)
        updateHint()
    }

    @objc private func textStorageDidEdit(_ notification: Notification) {
        updateHint()
    }

    public private(set) var textFlags: ComposeTextFlags?

    public var isPlainTextMode = false

    public func configure(with flags: ComposeTextFlags) {
        guard flags != textFlags else { return }
        textFlags = flags
        isContinuousSpellCheckingEnabled = flags.continuousSpelling
        isGrammarCheckingEnabled = flags.grammar
        isAutomaticSpellingCorrectionEnabled = flags.autocorrect
        isAutomaticTextReplacementEnabled = flags.textReplacement
        isAutomaticQuoteSubstitutionEnabled = flags.quoteSubstitution
        isAutomaticDashSubstitutionEnabled = flags.dashSubstitution
        isAutomaticLinkDetectionEnabled = flags.linkDetection
        writingToolsBehavior = flags.writingTools ? .complete : .none
    }

    static let rewritingResults: NSTextCheckingResult.CheckingType = [.correction, .replacement, .quote, .dash]

    public override func handleTextCheckingResults(_ results: [NSTextCheckingResult], forRange range: NSRange,
                                                   types checkingTypes: NSTextCheckingTypes,
                                                   options: [NSSpellChecker.OptionKey: Any],
                                                   orthography: NSOrthography, wordCount: Int) {
        super.handleTextCheckingResults(Self.protecting(results, in: string), forRange: range, types: checkingTypes,
                                        options: options, orthography: orthography, wordCount: wordCount)
    }

    static func protecting(_ results: [NSTextCheckingResult], in text: String) -> [NSTextCheckingResult] {
        guard results.contains(where: { !$0.resultType.intersection(rewritingResults).isEmpty }) else { return results }
        let protected = ProtectedTextRanges.find(in: text)
        guard !protected.isEmpty else { return results }
        return results.filter { result in
            result.resultType.intersection(rewritingResults).isEmpty || !ProtectedTextRanges.touches(result.range, protected)
        }
    }

    private static var sharedSpellTag: Int?

    public override var spellCheckerDocumentTag: Int {
        if let tag = Self.sharedSpellTag { return tag }
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        Self.sharedSpellTag = tag
        return tag
    }

    static let verticalInset: CGFloat = 8

    private var undoObservers: [NSObjectProtocol] = []

    // Programmatic undo/redo changes text without telling the delegate, so report it like typing
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = []
        guard window != nil else { return }
        undoObservers = [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: nil) { [weak self] note in
                let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
                MainActor.assumeIsolated {
                    guard let self, let manager = self.undoManager, sender == ObjectIdentifier(manager) else { return }
                    self.didChangeText()
                }
            }
        }
    }

    public var dateTimeZone: TimeZone? {
        didSet { if dateTimeZone != oldValue { scheduleDateScan(after: .zero) } }
    }
    public private(set) var dateSpans: [CalendarDateSpan] = []
    public var onDateClicked: ((CalendarDateSpan) -> Void)?
    public var onCaretDate: ((CalendarDateSpan?, NSRect) -> Void)?
    private var dateScan: Task<Void, Never>?
    private var caretDate: CalendarDateSpan?
    static let dateScanDelay: Duration = .milliseconds(300)

    func scheduleDateScan(after delay: Duration = ComposerTextView.dateScanDelay) {
        dateScan?.cancel()
        guard let zone = dateTimeZone else {
            if !dateSpans.isEmpty { dateSpans = []; applyDateMarks() }
            return
        }
        let text = string
        dateScan = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let spans = await Task.detached(priority: .utility) {
                CalendarDateMentions.spans(in: text, timeZone: zone)
            }.value
            guard !Task.isCancelled, let self, self.string == text else { return }
            self.dateSpans = spans
            self.applyDateMarks()
            self.followCaretDate()
        }
    }

    private func applyDateMarks() {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return }
        layout.removeRenderingAttribute(.underlineStyle, for: layout.documentRange)
        let length = (string as NSString).length
        for span in dateSpans where NSMaxRange(span.range) <= length {
            guard let start = content.location(content.documentRange.location, offsetBy: span.range.location),
                  let end = content.location(start, offsetBy: span.range.length),
                  let range = NSTextRange(location: start, end: end) else { continue }
            layout.addRenderingAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                         for: range)
        }
    }

    func followCaretDate() {
        let selection = selectedRange()
        let span = selection.length == 0 ? CalendarDateMentions.span(at: selection.location, in: dateSpans) : nil
        guard span != caretDate else { return }
        caretDate = span
        guard let span else {
            onCaretDate?(nil, .zero)
            return
        }
        let caret = firstRect(forCharacterRange: NSRange(location: selection.location, length: 0), actualRange: nil)
        onCaretDate?(span, caret == .zero ? firstRect(forCharacterRange: span.range, actualRange: nil) : caret)
    }

    public override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        if event.clickCount == 1, modifiers.isEmpty, selectedRange().length == 0, let image = imageIndex(at: point) {
            setSelectedRange(NSRange(location: image, length: 1))
            return
        }
        guard event.clickCount == 1, modifiers.isEmpty, onDateClicked != nil else { return }
        let selection = selectedRange()
        guard selection.length == 0,
              let span = dateSpans.first(where: { selection.location >= $0.range.location
                                                  && selection.location < NSMaxRange($0.range) }) else { return }
        onDateClicked?(span)
    }

    func updateHint() {
        let empty = (textStorage?.length ?? 0) == 0
        let ghost = ghostText.flatMap { $0.isEmpty ? nil : $0 }
        var shown: NSAttributedString?
        if empty, let ghost {
            shown = NSAttributedString(string: ghost, attributes: bridge.ghostAttributes)
        } else if empty, !placeholder.isEmpty {
            shown = NSAttributedString(string: placeholder, attributes: bridge.placeholderAttributes)
        }
        hintView.text = shown
        hintView.isHidden = shown == nil
        layoutHint(ghost: empty && ghost != nil)
    }

    private func layoutHint(ghost: Bool) {
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        let width = max(bounds.width - origin.x * 2 - padding * 2, 1)
        let height = ghost ? max(bounds.maxY - textContainerInset.height - origin.y, bridge.lineHeightValue)
                           : bridge.lineHeightValue * 2
        let frame = NSRect(x: origin.x + padding, y: origin.y, width: width, height: height)
        if hintView.frame != frame { hintView.frame = frame }
    }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        scheduleImageOverlay()
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        scheduleImageOverlay()
        return resigned
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let index = imageIndex(at: convert(event.locationInWindow, from: nil)) else { return menu }
        setSelectedRange(NSRange(location: index, length: 1))
        let out = menu ?? NSMenu()
        out.insertItem(imageSizeMenuItem(at: index), at: 0)
        out.insertItem(.separator(), at: 1)
        return out
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutHint(ghost: !hintView.isHidden && ghostText?.isEmpty == false)
        scheduleImageOverlay()
    }

    public override func didChangeText() {
        super.didChangeText()
        updateHint()
        scheduleImageOverlay()
    }

    public func contentHeight(forWidth width: CGFloat) -> CGFloat {
        let padding = textContainer?.lineFragmentPadding ?? 0
        let available = max(width - textContainerInset.width * 2, 1)
        let line = bridge.lineHeightValue
        guard (textStorage?.length ?? 0) > 0 else { return line + textContainerInset.height * 2 }
        let height = ceil(laidOutHeight(containerWidth: available, padding: padding))
        return max(height, line) + textContainerInset.height * 2
    }

    private func laidOutHeight(containerWidth: CGFloat, padding: CGFloat) -> CGFloat {
        if let manager = textLayoutManager, let container = textContainer,
           abs(container.size.width - containerWidth) < 0.5 {
            manager.ensureLayout(for: manager.documentRange)
            return manager.usageBoundsForTextContainer.height
        }
        let content = NSTextContentStorage()
        content.includesTextListMarkers = true
        content.delegate = self
        let manager = NSTextLayoutManager()
        content.addTextLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: containerWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = padding
        manager.textContainer = container
        content.attributedString = attributedString()
        manager.ensureLayout(for: manager.documentRange)
        return manager.usageBoundsForTextContainer.height
    }

    public func revealCaretInEnclosingScrollViews() {
        guard let window, let enclosing = enclosingScrollView else { return }
        let screen = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        guard screen != .zero else { return }
        var caret = convert(window.convertFromScreen(screen), from: nil)
        caret.size.width = max(caret.width, 1)
        var view = enclosing.superview
        while let current = view {
            if let scroll = current as? NSScrollView, let document = scroll.documentView {
                document.scrollToVisible(convert(caret, to: document).insetBy(dx: 0, dy: -bridge.lineHeightValue))
            }
            view = current.superview
        }
    }

    var enclosingClipViews: [NSClipView] {
        var clips: [NSClipView] = []
        var view: NSView? = superview
        while let current = view {
            if let clip = current as? NSClipView { clips.append(clip) }
            view = current.superview
        }
        return clips
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard !hasMarkedText() else { return }
        if Self.typed(string) == " " { autoListAfterSpace() }
        onTyped?(self.string, selectedRange().location)
    }

    static func typed(_ value: Any) -> String? {
        (value as? String) ?? (value as? NSAttributedString)?.string
    }

    public override func deleteBackward(_ sender: Any?) {
        if autoListBackspace() { return }
        super.deleteBackward(sender)
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting {
            keepTheLastEmptyLineOutOfLists()
            scheduleImageOverlay()
        }
    }

    public override func moveUp(_ sender: Any?) {
        if pickerKeys?(.up) == true { return }
        super.moveUp(sender)
    }

    public override func moveDown(_ sender: Any?) {
        if pickerKeys?(.down) == true { return }
        super.moveDown(sender)
    }

    public override func insertNewline(_ sender: Any?) {
        if pickerKeys?(.choose) == true { return }
        if suggestionKeys?(.use) == true { return }
        if autoListReturn() { return }
        super.insertNewline(sender)
    }

    public override func insertTab(_ sender: Any?) {
        if pickerKeys?(.choose) == true { return }
        if focusImageSizes() { return }
        if suggestionKeys?(.next) == true { return }
        if autoListTab(outdent: false) { return }
        super.insertTab(sender)
    }

    public override func insertBacktab(_ sender: Any?) {
        if suggestionKeys?(.previous) == true { return }
        if autoListTab(outdent: true) { return }
        super.insertBacktab(sender)
    }

    public override func cancelOperation(_ sender: Any?) {
        if pickerKeys?(.close) == true { return }
        if suggestionKeys?(.clear) == true { return }
        onEscape?()
    }

    public override func complete(_ sender: Any?) {
        cancelOperation(sender)
    }

    public override func keyDown(with event: NSEvent) {
        if handleCommandKey(event) { return }
        if event.keyCode == Self.tabKeyCode, !hasMarkedText(),
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == .shift,
           suggestionKeys?(.previous) == true { return }
        super.keyDown(with: event)
    }

    static let tabKeyCode: UInt16 = 48

    @discardableResult
    public func handleCommandKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              let chord = KeyChord(event: event) else { return false }
        let keys = commandKeys ?? Self.catalogKeys
        let reading = translation ?? .system
        guard let action = ([chord] + reading.alternates(for: event, chord)).compactMap({ keys[$0] }).first else {
            return false
        }
        if action == .discardDraft {
            guard discardsOnCommandDelete, !event.isARepeat else { return false }
            return onCommand?(.discardDraft) ?? false
        }
        if event.isARepeat { return true }
        if applyFormatting(action) { return true }
        return onCommand?(action) ?? false
    }

    @discardableResult
    public func applyFormatting(_ action: ActionID) -> Bool {
        switch action {
        case .formatBold: toggle(.bold)
        case .formatItalic: toggle(.italic)
        case .formatUnderline: toggle(.underline)
        case .formatStrikethrough: toggle(.strikethrough)
        case .formatBulletedList: toggleList(ordered: false)
        case .formatNumberedList: toggleList(ordered: true)
        case .formatQuote: toggleQuote()
        case .formatIndent: changeListLevel(outdent: false)
        case .formatOutdent: changeListLevel(outdent: true)
        case .formatLink: showLinkPanel(self)
        case .clearFormatting: clearFormatting()
        default: return false
        }
        return true
    }

    var discardsOnCommandDelete: Bool {
        selectedRange() == NSRange(location: 0, length: 0)
    }

    public func apply(_ command: ComposeFormatCommand) {
        switch command {
        case .bold: toggle(.bold)
        case .italic: toggle(.italic)
        case .underline: toggle(.underline)
        case .strikethrough: toggle(.strikethrough)
        case .link: showLinkPanel(self)
        case .bulletList: toggleList(ordered: false)
        case .numberedList: toggleList(ordered: true)
        case .quote: toggleQuote()
        case .clearFormatting: clearFormatting()
        }
    }

    public var formatState: ComposeFormatState {
        let range = selectedRange()
        let attrs: [NSAttributedString.Key: Any]
        if range.length > 0, let storage = textStorage, range.location < storage.length {
            attrs = storage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attrs = typingAttributes
        }
        let lists = (attrs[.paragraphStyle] as? NSParagraphStyle)?.textLists ?? []
        let list: ComposeFormatState.ListKind? = lists.first.map { AttributedBridge.isOrdered($0) ? .numbered : .bullet }
        return ComposeFormatState(marks: AttributedBridge.marks(attrs), isLink: AttributedBridge.link(attrs[.link]) != nil,
                                  list: list, isQuote: attrs[AttributedBridge.quoteKey] != nil, hasSelection: range.length > 0)
    }

    public func toggle(_ mark: RichTextDocument.Marks) {
        let range = selectedRange()
        guard let storage = textStorage else { return }
        let reference = range.length > 0 ? storage.attributes(at: range.location, effectiveRange: nil) : typingAttributes
        let on = !AttributedBridge.marks(reference).contains(mark)
        if range.length == 0 {
            typingAttributes = Self.setting(mark, on, in: typingAttributes, bridge: bridge)
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attrs, sub, _ in
            storage.setAttributes(Self.setting(mark, on, in: attrs, bridge: bridge), range: sub)
        }
        storage.endEditing()
        didChangeText()
    }

    static func setting(_ mark: RichTextDocument.Marks, _ on: Bool, in attrs: [NSAttributedString.Key: Any],
                        bridge: AttributedBridge) -> [NSAttributedString.Key: Any] {
        var marks = AttributedBridge.marks(attrs)
        if on { marks.insert(mark) } else { marks.remove(mark) }
        var out = bridge.attributes(marks, link: AttributedBridge.link(attrs[.link]))
        for key in Self.structuralKeys { if let value = attrs[key] { out[key] = value } }
        return out
    }

    static var structuralKeys: [NSAttributedString.Key] {
        [.paragraphStyle, AttributedBridge.quoteKey, .attachment, AttributedBridge.inlineImageKey,
         AttributedBridge.inlineImageAltKey]
    }

    public func clearFormatting() {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage, shouldChangeText(in: range, replacementString: nil) else {
            typingAttributes = bridge.typingAttributes
            return
        }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attrs, sub, _ in
            var plain = bridge.attributes([], link: AttributedBridge.link(attrs[.link]))
            for key in Self.structuralKeys { if let value = attrs[key] { plain[key] = value } }
            storage.setAttributes(plain, range: sub)
        }
        storage.endEditing()
        didChangeText()
    }

    public func toggleList(ordered: Bool) {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let paragraphs = ns.paragraphRange(for: selectedRange())
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        if ranges.isEmpty { ranges = [NSRange(location: paragraphs.location, length: 0)] }
        let first = ranges[0].location < storage.length
            ? storage.attribute(.paragraphStyle, at: ranges[0].location, effectiveRange: nil) as? NSParagraphStyle : nil
        let removing = first?.textLists.first.map { AttributedBridge.isOrdered($0) == ordered } ?? false
        let list = NSTextList(markerFormat: AttributedBridge.markerFormat(ordered: ordered, depth: 0), options: 0)
        guard shouldChangeText(in: paragraphs, replacementString: nil) else { return }
        storage.beginEditing()
        for (index, range) in ranges.enumerated().reversed() {
            let current = range.location < storage.length
                ? storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil
            if !(current?.textLists.isEmpty ?? true) {
                let marker = AttributedBridge.droppingMarker(range, in: storage.string as NSString)
                storage.deleteCharacters(in: NSRange(location: range.location, length: marker.location - range.location))
            }
            let quoted = range.location < storage.length
                && storage.attribute(AttributedBridge.quoteKey, at: range.location, effectiveRange: nil) != nil
            if !removing {
                let marker = AttributedBridge.marker(list, number: index + 1)
                var attrs = bridge.typingAttributes
                if quoted { attrs[AttributedBridge.quoteKey] = true }
                storage.insert(NSAttributedString(string: marker, attributes: attrs), at: range.location)
            }
            let style = bridge.paragraphStyle(lists: removing ? [] : [list], quoted: quoted) ?? NSMutableParagraphStyle()
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0))
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
        AttributedBridge.uncapLineHeights(in: storage)
        storage.endEditing()
        didChangeText()
    }

    static let maxListDepth = 6

    public func changeListLevel(outdent: Bool) {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let paragraphs = ns.paragraphRange(for: selectedRange())
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        if ranges.isEmpty { ranges = [NSRange(location: paragraphs.location, length: 0)] }
        func lists(at location: Int) -> [NSTextList] {
            guard location < storage.length else { return [] }
            return (storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.textLists ?? []
        }
        func paragraphBefore(_ location: Int) -> Int? {
            location > 0 ? ns.paragraphRange(for: NSRange(location: location - 1, length: 0)).location : nil
        }
        var previous = paragraphBefore(paragraphs.location).map(lists(at:)) ?? []
        var plan: [(range: NSRange, lists: [NSTextList])] = []
        for range in ranges {
            let current = lists(at: range.location)
            var next: [NSTextList]?
            if !current.isEmpty {
                if outdent {
                    if current.count > 1 { next = Array(current.dropLast()) }
                } else if current.count < Self.maxListDepth, previous.count >= current.count,
                          zip(previous, current).allSatisfy({ $0 === $1 }) {
                    next = previous.count > current.count
                        ? Array(previous.prefix(current.count + 1))
                        : current + [NSTextList(markerFormat: AttributedBridge.markerFormat(
                            ordered: AttributedBridge.isOrdered(current[current.count - 1]), depth: current.count), options: 0)]
                }
            }
            if let next { plan.append((range, next)) }
            previous = next ?? current
        }
        guard !plan.isEmpty, shouldChangeText(in: paragraphs, replacementString: nil) else { return }
        var planned: [Int: [NSTextList]] = [:]
        for item in plan { planned[item.range.location] = item.lists }
        func number(_ location: Int, in levels: [NSTextList]) -> Int {
            var count = 1
            var at = location
            while let before = paragraphBefore(at) {
                let l = planned[before] ?? lists(at: before)
                guard l.count >= levels.count, zip(l, levels).allSatisfy({ $0 === $1 }) else { break }
                if l.count == levels.count { count += 1 }
                at = before
            }
            return count
        }
        let markers = plan.map { item in
            let list = item.lists[item.lists.count - 1]
            return AttributedBridge.marker(list, number: number(item.range.location, in: item.lists) + list.startingItemNumber - 1)
        }
        let selection = selectedRange()
        var shift = 0
        storage.beginEditing()
        for (item, marker) in zip(plan, markers).reversed() {
            let range = item.range
            let quoted = range.location < storage.length
                && storage.attribute(AttributedBridge.quoteKey, at: range.location, effectiveRange: nil) != nil
            let text = AttributedBridge.droppingMarker(range, in: storage.string as NSString)
            var attrs = bridge.typingAttributes
            if quoted { attrs[AttributedBridge.quoteKey] = true }
            storage.replaceCharacters(in: NSRange(location: range.location, length: text.location - range.location),
                                      with: NSAttributedString(string: marker, attributes: attrs))
            if range.location < selection.location {
                shift += (marker as NSString).length - (text.location - range.location)
            }
            let style = bridge.paragraphStyle(lists: item.lists, quoted: quoted) ?? NSMutableParagraphStyle()
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0))
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
        AttributedBridge.uncapLineHeights(in: storage)
        storage.endEditing()
        setSelectedRange(NSRange(location: max(0, selection.location + shift),
                                 length: selection.length))
        didChangeText()
    }

    public func toggleQuote() {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let paragraphs = ns.paragraphRange(for: selectedRange())
        let first = paragraphs.location < storage.length
            && storage.attribute(AttributedBridge.quoteKey, at: paragraphs.location, effectiveRange: nil) != nil
        let quoting = !first
        guard paragraphs.length > 0 else {
            if quoting {
                typingAttributes[AttributedBridge.quoteKey] = true
                typingAttributes[.paragraphStyle] = bridge.paragraphStyle(quoted: true)
            } else {
                typingAttributes = bridge.typingAttributes
            }
            return
        }
        guard shouldChangeText(in: paragraphs, replacementString: nil) else { return }
        storage.beginEditing()
        ns.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            let lists = (enclosing.location < storage.length
                ? storage.attribute(.paragraphStyle, at: enclosing.location, effectiveRange: nil) as? NSParagraphStyle : nil)?
                .textLists ?? []
            if quoting {
                storage.addAttribute(AttributedBridge.quoteKey, value: true, range: enclosing)
            } else {
                storage.removeAttribute(AttributedBridge.quoteKey, range: enclosing)
            }
            let style = self.bridge.paragraphStyle(lists: lists, quoted: quoting) ?? NSMutableParagraphStyle()
            storage.addAttribute(.paragraphStyle, value: style, range: enclosing)
        }
        AttributedBridge.uncapLineHeights(in: storage)
        storage.endEditing()
        didChangeText()
    }

    @discardableResult
    public func insert(_ insertion: ComposeSession.SnippetInsertion) -> [String] {
        let body = NSMutableAttributedString(attributedString: bridge.attributedString(insertion.document))
        let replacements = SnippetExpander.replacements(in: body.string, variables: insertion.snippet.variables,
                                                        context: insertion.context)
        for r in replacements.reversed() {
            let range = NSRange(location: r.range.lowerBound, length: r.range.count)
            let attrs = range.location < body.length ? body.attributes(at: range.location, effectiveRange: nil)
                                                     : bridge.typingAttributes
            body.replaceCharacters(in: range, with: NSAttributedString(string: r.text, attributes: attrs))
        }
        var unresolved: [(NSRange, String)] = []
        var delta = 0
        for r in replacements {
            let length = (r.text as NSString).length
            if !r.isResolved, let name = r.name {
                unresolved.append((NSRange(location: r.range.lowerBound + delta, length: length), name))
            }
            delta += length - r.range.count
        }
        let total = (string as NSString).length
        var target = insertion.range.map { NSRange(location: $0.lowerBound, length: $0.count) } ?? selectedRange()
        target.location = min(target.location, total)
        target.length = min(target.length, total - target.location)
        guard let storage = textStorage, shouldChangeText(in: target, replacementString: body.string) else { return [] }
        storage.replaceCharacters(in: target, with: body)
        didChangeText()
        if let first = unresolved.first {
            setSelectedRange(NSRange(location: target.location + first.0.location, length: first.0.length))
        } else {
            setSelectedRange(NSRange(location: target.location + body.length, length: 0))
        }
        typingAttributes = bridge.typingAttributes
        return unresolved.map(\.1)
    }

    @discardableResult
    public func replaceText(in range: NSRange, with text: String) -> Bool {
        let total = (string as NSString).length
        guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= total,
              let storage = textStorage else { return false }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
            breakUndoCoalescing()
        }
        guard shouldChangeText(in: range, replacementString: text) else { return false }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: bridge.typingAttributes))
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: (text as NSString).length))
        typingAttributes = bridge.typingAttributes
        return true
    }

    public func load(_ document: RichTextDocument) {
        textStorage?.setAttributedString(bridge.attributedString(document, images: { inlineImageProvider?($0) }))
        typingAttributes = bridge.typingAttributes
        undoManager?.removeAllActions(withTarget: textStorage as Any)
        onReload?()
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        updateHint()
    }

    public var document: RichTextDocument {
        bridge.document(textStorage ?? NSAttributedString())
    }

    static let pasteTypes: [NSPasteboard.PasteboardType] = [.fileURL, .html, .rtfd, .rtf, .png, .tiff, .string]

    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { Self.pasteTypes }

    public override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        var types = super.acceptableDragTypes
        for type in Self.pasteTypes where !types.contains(type) { types.append(type) }
        return types
    }

    public override func dragOperation(for dragInfo: any NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        let operation = super.dragOperation(for: dragInfo, type: type)
        guard operation.isEmpty, isEditable, Self.pasteTypes.contains(type) else { return operation }
        return .copy
    }

    public override func paste(_ sender: Any?) {
        let board = pasteboard()
        guard isEditable else { return }
        if linkSelection(from: board) { return }
        guard let type = preferredPasteboardType(from: board.types ?? [], restrictedToTypesFrom: Self.pasteTypes)
        else { return }
        _ = readSelection(from: board, type: type)
    }

    func linkSelection(from board: NSPasteboard) -> Bool {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage, NSMaxRange(range) <= storage.length,
              let raw = board.string(forType: .string), let url = ComposePaste.linkURL(fromPastedText: raw),
              !storage.containsAttachments(in: range) else { return false }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: nil) else { return false }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attrs, sub, _ in
            var linked = bridge.attributes(AttributedBridge.marks(attrs), link: url)
            for key in Self.structuralKeys { if let value = attrs[key] { linked[key] = value } }
            storage.setAttributes(linked, range: sub)
        }
        storage.endEditing()
        didChangeText()
        breakUndoCoalescing()
        return true
    }

    public override func pasteAsPlainText(_ sender: Any?) {
        guard isEditable else { return }
        _ = readPlainText(from: pasteboard())
    }

    public override func pasteAsRichText(_ sender: Any?) {
        paste(sender)
    }

    public override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        switch type {
        case .fileURL:
            return readFiles(from: pboard)
        case .html:
            return readHTML(from: pboard) || readImage(from: pboard) || readPlainText(from: pboard)
        case .rtfd, .rtf:
            return readRichText(from: pboard, type: type) || readPlainText(from: pboard)
        case .png, .tiff:
            return readImage(from: pboard)
        case .string:
            return readPlainText(from: pboard)
        default:
            return super.readSelection(from: pboard, type: type)
        }
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !urls.isEmpty, onFiles != nil {
            if urls.contains(where: InlineImages.canInline) {
                let point = convert(sender.draggingLocation, from: nil)
                setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
            }
            insertFiles(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    func readFiles(from board: NSPasteboard) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty else {
            return false
        }
        insertFiles(urls)
        return true
    }

    func insertFiles(_ urls: [URL]) {
        let pictures = onInlineImageFile == nil ? [] : urls.filter(InlineImages.canInline)
        let files = urls.filter { !pictures.contains($0) }
        let refs = pictures.compactMap { onInlineImageFile?($0) }
        if !refs.isEmpty { insertPasted(RichTextDocument(blocks: refs.map { .image($0) })) }
        if !files.isEmpty { onFiles?(files) }
    }

    func readHTML(from board: NSPasteboard) -> Bool {
        guard let html = board.string(forType: .html) else { return false }
        let pasted = ComposePaste.document(fromHTML: html)
        guard !pasted.document.blocks.isEmpty else { return false }
        insertPasted(pasted.document)
        onPasteCleaned?(pasted.report)
        return true
    }

    func readRichText(from board: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let data = board.data(forType: type) else { return false }
        let read = type == .rtfd ? NSAttributedString(rtfd: data, documentAttributes: nil)
                                 : NSAttributedString(rtf: data, documentAttributes: nil)
        guard let read else { return false }
        let marked = NSMutableAttributedString(attributedString: read)
        var report = ComposePaste.Report()
        markInlineImages(in: marked, report: &report)
        let cleaned = ComposePaste.clean(bridge.document(marked))
        guard !cleaned.document.blocks.isEmpty else { return false }
        insertPasted(cleaned.document)
        onPasteCleaned?(report + cleaned.report)
        return true
    }

    func markInlineImages(in text: NSMutableAttributedString, report: inout ComposePaste.Report) {
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length), options: [.reverse]) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if let ref = inlineImageRef(for: attachment) {
                text.addAttribute(AttributedBridge.inlineImageKey, value: ref.contentID, range: range)
                if let alt = ref.alt { text.addAttribute(AttributedBridge.inlineImageAltKey, value: alt, range: range) }
            } else {
                text.deleteCharacters(in: range)
                report.droppedImages += 1
            }
        }
    }

    func inlineImageRef(for attachment: NSTextAttachment) -> InlineImageRef? {
        let wrapper = attachment.fileWrapper
        let name = wrapper?.preferredFilename ?? wrapper?.filename ?? ""
        if let contentID = AttributedBridge.contentID(fromAttachmentName: name), inlineImageKnown?(contentID) == true {
            return InlineImageRef(contentID: contentID)
        }
        guard let bytes = wrapper?.regularFileContents ?? attachment.contents ?? attachment.image?.tiffRepresentation,
              let picture = Self.pictureData(bytes, name: name) else { return nil }
        return onInlineImageData?(picture.data, picture.fileExtension)
    }

    func readImage(from board: NSPasteboard) -> Bool {
        let candidates: [(type: NSPasteboard.PasteboardType, name: String)] = [(.png, "image.png"), (.tiff, "image.tiff")]
        for (type, name) in candidates {
            guard let bytes = board.data(forType: type), let picture = Self.pictureData(bytes, name: name),
                  let ref = onInlineImageData?(picture.data, picture.fileExtension) else { continue }
            insertPasted(RichTextDocument(blocks: [.image(ref)]))
            return true
        }
        return false
    }

    static func pictureData(_ bytes: Data, name: String) -> (data: Data, fileExtension: String)? {
        let ext = (name as NSString).pathExtension.lowercased()
        if InlineImages.fileExtensions.contains(ext), NSImage(data: bytes) != nil { return (bytes, ext) }
        guard let rep = NSBitmapImageRep(data: bytes), let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return (png, "png")
    }

    func readPlainText(from board: NSPasteboard) -> Bool {
        guard let raw = board.string(forType: .string) else { return false }
        let text = ComposePaste.plainText(raw)
        guard !text.isEmpty else { return false }
        replaceSelection(with: NSAttributedString(string: text, attributes: plainPasteAttributes))
        return true
    }

    var plainPasteAttributes: [NSAttributedString.Key: Any] {
        var attrs = bridge.attributes(AttributedBridge.marks(typingAttributes), link: nil)
        if let style = typingAttributes[.paragraphStyle] { attrs[.paragraphStyle] = style }
        if typingAttributes[AttributedBridge.quoteKey] != nil { attrs[AttributedBridge.quoteKey] = true }
        return attrs
    }

    func insertPasted(_ document: RichTextDocument) {
        let document = sizingNewImages(document)
        let piece = NSMutableAttributedString(attributedString: bridge.attributedString(document,
                                                                                       images: { inlineImageProvider?($0) }))
        guard piece.length > 0 else { return }
        let range = selectedRange()
        let ns = string as NSString
        let startsMidLine = range.location > 0 && range.location <= ns.length && ns.character(at: range.location - 1) != 0x0A
        let endsMidLine = NSMaxRange(range) < ns.length && ns.character(at: NSMaxRange(range)) != 0x0A
        if startsMidLine, let first = document.blocks.first, !Self.isParagraph(first) {
            piece.insert(NSAttributedString(string: "\n", attributes: bridge.typingAttributes), at: 0)
        }
        if endsMidLine, let last = document.blocks.last, !Self.isParagraph(last) {
            piece.append(NSAttributedString(string: "\n", attributes: bridge.typingAttributes))
        }
        replaceSelection(with: piece)
    }

    static func isParagraph(_ block: RichTextDocument.Block) -> Bool {
        if case .paragraph = block { return true }
        return false
    }

    func replaceSelection(with text: NSAttributedString) {
        let range = selectedRange()
        guard let storage = textStorage else { return }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: text.string) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: text)
        AttributedBridge.uncapLineHeights(in: storage, range: NSRange(location: range.location, length: text.length))
        storage.endEditing()
        didChangeText()
        setSelectedRange(NSRange(location: range.location + text.length, length: 0))
        breakUndoCoalescing()
    }
}

final class ComposerHintView: NSView {
    var text: NSAttributedString? {
        didSet { if text != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        identifier = NSUserInterfaceItemIdentifier("composer.bodyHint")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        text?.draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
