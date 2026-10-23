import AppKit
import MailFeatures
import MailTheme

@MainActor
final class ThreadListEmptyView: NSView {
    private let symbolView = NSImageView()
    private let titleField = NSTextField(wrappingLabelWithString: "")
    private let subtitleField = NSTextField(wrappingLabelWithString: "")
    private let detailField = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private(set) var state: ThreadListEmptyState?
    private var style: ThreadRowStyle

    init(style: ThreadRowStyle) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        // A long title (a search query) wraps, and past its last line ends in an ellipsis rather than mid-word
        titleField.isSelectable = false
        for field in [titleField, subtitleField, detailField] {
            field.alignment = .center
            field.maximumNumberOfLines = 3
            field.cell?.truncatesLastVisibleLine = true
            addSubview(field)
        }
        symbolView.imageScaling = .scaleNone
        symbolView.setAccessibilityElement(false)
        addSubview(symbolView)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = true
        spinner.isIndeterminate = true
        spinner.isHidden = true
        spinner.setAccessibilityElement(false)
        addSubview(spinner)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        apply(style: style)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func apply(style: ThreadRowStyle) {
        self.style = style
        let theme = style.theme
        styleTitle()
        subtitleField.font = theme.typeBody.font
        subtitleField.textColor = theme.textSecondary.nsColor
        detailField.font = theme.typeMeta.font
        detailField.textColor = theme.textTertiary.nsColor
        symbolView.contentTintColor = theme.textSecondary.nsColor
        needsLayout = true
    }

    private func styleTitle() {
        let theme = style.theme
        let quiet = state?.style == .progress
        titleField.font = quiet ? theme.typeBody.font : theme.typeTitle.font
        titleField.textColor = quiet ? theme.textTertiary.nsColor : theme.textPrimary.nsColor
    }

    var titleAppearance: (font: NSFont?, color: NSColor?) { (titleField.font, titleField.textColor) }

    var symbolAppearance: (shown: Bool, frame: NSRect, tint: NSColor?) { (!symbolView.isHidden, symbolView.frame, symbolView.contentTintColor) }

    var textFrames: [NSRect] { [titleField, subtitleField, detailField].filter { !$0.isHidden && !$0.stringValue.isEmpty }.map(\.frame) }

    func show(_ state: ThreadListEmptyState?, now: Date) {
        let changed = state != self.state
        self.state = state
        isHidden = state == nil || state?.style == .blank
        if isHidden { spinner.stopAnimation(nil) }
        guard let state, changed else { return }
        styleTitle()
        titleField.stringValue = state.title
        subtitleField.stringValue = state.subtitle ?? ""
        detailField.stringValue = state.detail ?? ""
        subtitleField.isHidden = state.subtitle == nil
        detailField.isHidden = state.detail == nil
        if let name = state.symbol, state.style == .inboxClear || state.style == .message {
            let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            symbolView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            symbolView.isHidden = symbolView.image == nil
        } else {
            symbolView.isHidden = true
        }
        let showsProgress = state.style == .progress
        spinner.isHidden = !showsProgress
        setAccessibilityLabel([state.title, state.subtitle, state.detail].compactMap { $0 }.joined(separator: ". "))
        if !symbolView.isHidden { fade(symbolView, duration: style.theme.motionSlow.seconds) }
        if showsProgress, !reduceMotion { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
    }

    var showsSpinner: Bool { !spinner.isHidden }

    private var reduceMotion: Bool { style.theme.reduceMotion }

    private func fade(_ view: NSView, duration: Double) {
        view.wantsLayer = true
        guard let layer = view.layer, duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = reduceMotion ? min(duration, style.theme.motionReducedFade / 1000) : duration
        layer.add(animation, forKey: "fade")
    }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        let textWidth = min(width - 48, 480)
        var y = (height * 0.3).rounded()
        if !symbolView.isHidden {
            symbolView.frame = NSRect(x: ((width - 40) / 2).rounded(), y: y, width: 40, height: 40)
            y = symbolView.frame.maxY + 12
        }
        if !spinner.isHidden {
            let size = spinner.fittingSize
            spinner.frame = NSRect(x: ((width - size.width) / 2).rounded(), y: y, width: size.width, height: size.height)
            y = spinner.frame.maxY + 12
        }
        func place(_ field: NSTextField, gap: CGFloat) {
            guard !field.isHidden, !field.stringValue.isEmpty else { return }
            let size = field.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude))
            field.frame = NSRect(x: ((width - textWidth) / 2).rounded(), y: y + gap, width: textWidth, height: ceil(size.height))
            y = field.frame.maxY
        }
        place(titleField, gap: 0)
        place(subtitleField, gap: 8)
        place(detailField, gap: 8)
    }
}
