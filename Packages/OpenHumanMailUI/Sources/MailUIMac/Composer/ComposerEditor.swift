import AppKit
import MailActions
import MailFeatures
import MailModel
import MailRender
import MailTheme
import SwiftUI

struct ComposerBody: View {
    let session: ComposeSession
    let manager: ComposeManager
    let theme: ThemeTokens
    let focusOnAppear: Bool
    var placeholder: String = ""
    var growsWithContent = false
    var minHeight: CGFloat = 0
    var maxHeight: CGFloat = .greatestFiniteMagnitude
    let onClose: () -> Void

    var body: some View {
        ComposerEditor(session: session, manager: manager, theme: theme, focusOnAppear: focusOnAppear,
                       placeholder: placeholder, growsWithContent: growsWithContent, minHeight: minHeight,
                       maxHeight: maxHeight, onClose: onClose)
    }
}

public struct ComposerEditor: NSViewRepresentable {
    let session: ComposeSession
    let manager: ComposeManager
    let theme: ThemeTokens
    let revision: Int
    let pendingSnippet: UUID?
    let keymapRevision: Int
    let document: RichTextDocument
    let showsFormatBar: Bool
    let focusOnAppear: Bool
    let placeholder: String
    let ghostText: String?
    let spokenPlaceholder: String?
    let growsWithContent: Bool
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let allowsWritingTools: Bool
    let onClose: () -> Void
    let textFlags: ComposeTextFlags
    let isPlainText: Bool
    let pastedImageSize: InlineImageSize

    public init(session: ComposeSession, manager: ComposeManager, theme: ThemeTokens, focusOnAppear: Bool,
                placeholder: String = "", growsWithContent: Bool = false, minHeight: CGFloat = 0,
                maxHeight: CGFloat = .greatestFiniteMagnitude, onClose: @escaping () -> Void) {
        self.session = session
        self.manager = manager
        self.theme = theme
        self.revision = session.documentRevision
        self.pendingSnippet = session.pendingSnippet?.id
        self.keymapRevision = manager.actionKeymapRevision
        self.document = session.document
        self.showsFormatBar = manager.showsFormatBar
        self.focusOnAppear = focusOnAppear
        let strip = manager.instantReply(for: session)
        // The tip names ⌘J, so it steps aside while the AI panel it opens is showing
        self.placeholder = session.aiPanel != nil ? "" : strip?.placeholder ?? placeholder
        self.ghostText = strip?.ghostText
        self.spokenPlaceholder = strip?.accessibilityPlaceholder
        self.growsWithContent = growsWithContent
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.allowsWritingTools = manager.allowsWritingTools(in: session)
        self.onClose = onClose
        var flags = manager.textSettings.flags(for: session.account)
        flags.writingTools = manager.allowsWritingTools(in: session)
        self.textFlags = flags
        self.isPlainText = session.isPlainText
        self.pastedImageSize = manager.textSettings.pastedImageSize
    }

    public static func placeholder(for mode: DraftMode) -> String {
        String(localized: "Tip: Hit ⌘J for AI")
    }

    public func makeCoordinator() -> Coordinator { Coordinator(session: session, manager: manager) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComposerScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let text = ComposerTextView.make()
        text.configure(with: textFlags)
        text.isPlainTextMode = isPlainText
        text.pastedImageSize = pastedImageSize
        text.bridge = AttributedBridge(theme: theme)
        text.placeholder = placeholder
        text.allowsWritingTools = allowsWritingTools
        text.ghostText = ghostText
        text.spokenPlaceholder = spokenPlaceholder
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        context.coordinator.theme = theme
        context.coordinator.attach(text, onClose: onClose)
        if focusOnAppear {
            DispatchQueue.main.async { text.window?.makeFirstResponder(text) }
        }
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.theme = theme
        let bridge = AttributedBridge(theme: theme)
        if text.bridge.font != bridge.font || text.bridge.textColor != bridge.textColor
            || text.bridge.placeholderColor != bridge.placeholderColor || text.bridge.ghostColor != bridge.ghostColor {
            text.bridge = bridge
            context.coordinator.reload(text)
        }
        text.placeholder = placeholder
        if context.coordinator.keymapRevision != keymapRevision {
            context.coordinator.keymapRevision = keymapRevision
            text.commandKeys = KeyTable.composer(manager.actionDescriptors)
        }
        if text.allowsWritingTools != allowsWritingTools { text.allowsWritingTools = allowsWritingTools }
        text.configure(with: textFlags)
        text.isPlainTextMode = isPlainText
        text.pastedImageSize = pastedImageSize
        text.ghostText = ghostText
        text.spokenPlaceholder = spokenPlaceholder
        context.coordinator.growsWithContent = growsWithContent
        (scroll as? ComposerScrollView)?.growsUpTo = growsWithContent ? max(maxHeight, minHeight) : nil
        context.coordinator.sync(text)
        context.coordinator.updateFloatingBar(text)
    }

    public static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.hideFloatingBar()
        coordinator.dateTip.hide()
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard growsWithContent, let text = nsView.documentView as? ComposerTextView else { return nil }
        let width = proposal.width ?? nsView.bounds.width
        guard width.isFinite, width > 0 else { return nil }
        let height = min(max(text.contentHeight(forWidth: width), minHeight), max(maxHeight, minHeight))
        return CGSize(width: width, height: height)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        let session: ComposeSession
        let manager: ComposeManager
        var growsWithContent = false
        var theme: ThemeTokens = .light
        private var appliedRevision = -1
        private var appliedSnippet: UUID?
        weak var textView: ComposerTextView?
        let floatingBar = FormatBarPanel()
        private var images: [String: InlineImageContent] = [:]

        var keymapRevision = -1

        init(session: ComposeSession, manager: ComposeManager) {
            self.session = session
            self.manager = manager
        }

        func attach(_ text: ComposerTextView, onClose: @escaping () -> Void) {
            text.delegate = self
            textView = text
            session.editor = self
            session.formatter = self
            let session = self.session
            let manager = self.manager
            text.commandKeys = KeyTable.composer(manager.actionDescriptors)
            keymapRevision = manager.actionKeymapRevision
            text.onCommand = { id in manager.perform(id, in: session, source: .keyboard) }
            text.onEscape = {
                if let panel = session.aiPanel { panel.close() } else { onClose() }
            }
            text.onFiles = { urls in session.attach(urls) }
            text.onTyped = { [weak self] string, caret in self?.typed(string, caret: caret, in: text) }
            text.pickerKeys = { key in
                if let mention = session.mentionPicker {
                    switch key {
                    case .up: mention.moveCursor(by: -1)
                    case .down: mention.moveCursor(by: 1)
                    case .choose: return mention.confirm()
                    case .close: session.dismissMention()
                    }
                    return true
                }
                guard let picker = session.snippetPicker, session.snippetTriggerRange != nil else { return false }
                switch key {
                case .up: picker.moveCursor(by: -1)
                case .down: picker.moveCursor(by: 1)
                case .choose: picker.confirm()
                case .close: picker.close()
                }
                return true
            }
            text.onInlineImageFile = { url in session.addInlineImage(file: url) }
            text.onInlineImageData = { data, fileExtension in session.addInlineImage(data: data, fileExtension: fileExtension) }
            text.inlineImageKnown = { contentID in session.hasInlineImage(contentID) }
            text.inlineImageProvider = { [weak self] ref in self?.image(ref) }
            text.onPasteCleaned = { report in session.didPaste(report) }
            text.onReload = { session.dropMentionUndo() }
            if let sidebar = manager.calendarSidebar {
                text.dateTimeZone = sidebar.timeZone
                text.onDateClicked = { span in manager.openEvent(at: span.mention, from: session) }
                text.onCaretDate = { [weak self, weak text] span, caret in
                    guard let self, let text else { return }
                    self.caretDateChanged(span, caret: caret, in: text)
                }
            }
            text.suggestionKeys = { [weak text] key in
                guard let strip = manager.instantReply(for: session), strip.handle(key) else { return false }
                switch key {
                case .next, .previous:
                    if let text, let words = strip.previewAnnouncement { Coordinator.announce(words, from: text) }
                case .use, .clear:
                    break
                }
                return true
            }
            sync(text)
        }

        static func announce(_ words: String, from view: NSView) {
            NSAccessibility.post(element: view, notification: .announcementRequested,
                                 userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }

        private func image(_ ref: InlineImageRef) -> InlineImageContent? {
            if let known = images[ref.contentID] { return known }
            guard let content = InlineImageContent.load(session.inlineImageFile(ref.contentID)) else { return nil }
            images[ref.contentID] = content
            return content
        }

        func sync(_ text: ComposerTextView) {
            if session.documentRevision != appliedRevision {
                if let reply = session.pendingReply, reply.revision == session.documentRevision {
                    insertPendingReply(reply, in: text)
                } else {
                    appliedRevision = session.documentRevision
                    if text.document != session.document { text.load(session.document) }
                }
            }
            if let insertion = session.pendingSnippet, insertion.id != appliedSnippet {
                appliedSnippet = insertion.id
                let unresolved = text.insert(insertion)
                session.updateBody(text.document)
                session.didInsertSnippet(insertion, unresolved: unresolved)
                text.window?.makeFirstResponder(text)
            }
        }

        private func insertPendingReply(_ reply: ComposeSession.PendingReply, in text: ComposerTextView, attempt: Int = 0) {
            guard text.window != nil || attempt >= 10 else {
                if text.document != reply.base { text.load(reply.base) }
                DispatchQueue.main.async { [weak self, weak text] in
                    guard let self, let text, self.session.pendingReply == reply else { return }
                    guard reply.revision == self.session.documentRevision else { return self.sync(text) }
                    self.insertPendingReply(reply, in: text, attempt: attempt + 1)
                }
                return
            }
            appliedRevision = session.documentRevision
            session.pendingReplyApplied(reply)
            text.load(reply.base)
            let length = (text.string as NSString).length
            let range = reply.replacesAll ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
            guard text.replaceText(in: range, with: reply.insertion) else {
                text.load(session.document)
                return
            }
            text.setSelectedRange(NSRange(location: range.location + (reply.insertion as NSString).length, length: 0))
        }

        func reload(_ text: ComposerTextView) {
            text.load(session.document)
        }

        public func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? ComposerTextView else { return }
            session.updateBody(text.document)
            text.scheduleDateScan()
            publishFormat(text)
            if growsWithContent {
                DispatchQueue.main.async { [weak text] in text?.revealCaretInEnclosingScrollViews() }
            }
            if session.snippetTriggerRange != nil {
                session.updateSnippetTrigger(SnippetTrigger.pendingQuery(in: text.string, caret: text.selectedRange().location))
            }
            if session.mentionPicker != nil, !text.hasMarkedText() {
                session.updateMention(in: text.string, caret: text.selectedRange().location, mayOpen: false)
            }
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let text = notification.object as? ComposerTextView else { return }
            publishFormat(text)
            text.followCaretDate()
            if session.mentionPicker != nil, !text.hasMarkedText() {
                session.updateMention(in: text.string, caret: text.selectedRange().location, mayOpen: false)
            }
            guard session.snippetTriggerRange != nil else { return }
            session.updateSnippetTrigger(SnippetTrigger.pendingQuery(in: text.string, caret: text.selectedRange().location))
        }

        public func textDidEndEditing(_ notification: Notification) {
            hideFloatingBar()
            dateTip.hide()
        }

        let dateTip = DateCaretTip()

        func caretDateChanged(_ span: CalendarDateSpan?, caret: NSRect, in text: ComposerTextView) {
            guard span != nil, caret != .zero, let window = text.window, window.firstResponder === text,
                  !text.hasMarkedText(), session.snippetPicker == nil else {
                dateTip.hide()
                return
            }
            dateTip.show(under: caret, in: window, theme: InlineComposerView.resolvedTheme(for: theme),
                         scrolling: text.enclosingClipViews)
        }

        func publishFormat(_ text: ComposerTextView) {
            session.updateFormatState(text.formatState)
            updateFloatingBar(text)
        }

        func updateFloatingBar(_ text: ComposerTextView) {
            let range = text.selectedRange()
            guard range.length > 0, !manager.showsFormatBar, session.snippetPicker == nil, !text.hasMarkedText(),
                  text.selectedImageIndex == nil,
                  let window = text.window, window.firstResponder === text else {
                hideFloatingBar()
                return
            }
            let line = text.firstRect(forCharacterRange: range, actualRange: nil)
            guard line != .zero else {
                hideFloatingBar()
                return
            }
            floatingBar.show(over: line, in: window, state: text.formatState,
                             theme: InlineComposerView.resolvedTheme(for: theme), scrolling: text.enclosingClipViews) {
                [weak self] command in self?.applyFormat(command)
            }
        }

        func hideFloatingBar() {
            floatingBar.hide()
        }

        private func typed(_ string: String, caret: Int, in text: ComposerTextView) {
            session.updateMention(in: string, caret: caret, mayOpen: true)
            switch SnippetTrigger.detect(in: string, caret: caret, shortcuts: session.snippetShortcuts) {
            case .openPicker(let range, let query):
                if session.snippetPicker == nil { session.openSnippetPicker(replacing: range, query: query) }
            case .expand(let range, let shortcut):
                session.closeSnippetPicker()
                if let insertion = session.expansion(forShortcut: shortcut, replacing: range) {
                    let unresolved = text.insert(insertion)
                    session.updateBody(text.document)
                    session.didInsertSnippet(insertion, unresolved: unresolved)
                }
            case nil:
                break
            }
        }
    }
}

final class ComposerScrollView: NSScrollView {
    var growsUpTo: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let clip = ComposerClipView()
        clip.drawsBackground = false
        contentView = clip
        clip.pinsTop = { [weak self] in self?.pinsTop ?? false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private var pinsTop: Bool {
        guard let growsUpTo, let document = documentView else { return false }
        return document.frame.height <= growsUpTo + 0.5
    }

    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView else { return }
        let height = contentSize.height
        if text.minSize.height != height {
            text.minSize = NSSize(width: 0, height: height)
            text.sizeToFit()
        }
    }
}

final class ComposerClipView: NSClipView {
    var pinsTop: (() -> Bool)?

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if pinsTop?() == true { rect.origin.y = 0 }
        return rect
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: pinsTop?() == true ? NSPoint(x: newOrigin.x, y: 0) : newOrigin)
    }
}

extension ComposerEditor.Coordinator: ComposeTextEditing {
    public var editorText: String { textView?.string ?? "" }

    public var editorSelection: Range<Int> {
        guard let range = textView?.selectedRange(), range.location != NSNotFound else { return 0..<0 }
        return range.location..<(range.location + range.length)
    }

    public func replaceText(in range: Range<Int>, with text: String) -> Bool {
        guard let textView else { return false }
        return textView.replaceText(in: NSRange(location: range.lowerBound, length: range.count), with: text)
    }

    public func focusEditor() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    public var isOnScreen: Bool { textView?.window != nil }

    public var editorUndoManager: UndoManager? { textView?.undoManager }

    public func placeCaret(at offset: Int) {
        guard let textView else { return }
        let at = min(max(0, offset), (textView.string as NSString).length)
        textView.setSelectedRange(NSRange(location: at, length: 0))
    }
}

extension ComposerEditor.Coordinator: ComposeFormatting {
    public func applyFormatting(_ action: ActionID) -> Bool {
        textView?.applyFormatting(action) ?? false
    }
}

extension ComposerEditor.Coordinator: ComposeFormatEditing {
    public func applyFormat(_ command: ComposeFormatCommand) {
        guard let textView else { return }
        if let window = textView.window, window.firstResponder !== textView { window.makeFirstResponder(textView) }
        textView.apply(command)
        publishFormat(textView)
    }
}
