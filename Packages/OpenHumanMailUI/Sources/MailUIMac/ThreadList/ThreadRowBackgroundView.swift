import AppKit
import MailTheme

@MainActor
public final class ThreadRowBackgroundView: NSTableRowView {
    public static let identifier = NSUserInterfaceItemIdentifier("ThreadRowBackground")

    var style: ThreadRowStyle {
        didSet { if style !== oldValue { needsDisplay = true } }
    }
    var isChecked = false {
        didSet { if isChecked != oldValue { needsDisplay = true } }
    }
    private(set) var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            needsDisplay = true
            // The cell is a direct subview; `view(atColumn:)` throws on a row the table has not given columns
            for case let cell as ThreadRowView in subviews { cell.setHovering(isHovering) }
        }
    }

    init(style: ThreadRowStyle) {
        self.style = style
        super.init(frame: .zero)
        identifier = Self.identifier
        selectionHighlightStyle = .regular
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Set by renders and tests in place of the window's key state.
    var emphasisOverride: Bool? {
        didSet { if emphasisOverride != oldValue { emphasisChanged() } }
    }

    // The selection follows the window, not the first responder, so a focused search field keeps the accent
    public override var isEmphasized: Bool {
        get { emphasisOverride ?? (window?.isKeyWindow ?? false) }
        set { emphasisChanged() }
    }

    func emphasisChanged() {
        if isSelected { needsDisplay = true }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        emphasisChanged()
    }

    public override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            for case let cell as ThreadRowView in subviews { cell.setCursor(isSelected) }
        }
    }

    public override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard let cell = subview as? ThreadRowView else { return }
        cell.setCursor(isSelected)
        if isHovering { cell.setHovering(true) }
    }

    func setHovering(_ hovering: Bool) { isHovering = hovering }

    public override func drawBackground(in dirtyRect: NSRect) {
        style.window.setFill()
        dirtyRect.fill()
        guard !isSelected, let fill = idleFill else { return }
        fill.setFill()
        plate.fill()
    }

    var idleFill: NSColor? {
        if isChecked { return style.checked }
        return isHovering ? style.hover : nil
    }

    var selectionFill: NSColor { isEmphasized ? style.cursor : style.inactiveCursor }

    var drawsEdge: Bool { style.drawsPlateEdge }

    public override func drawSelection(in dirtyRect: NSRect) {
        selectionFill.setFill()
        plate.fill()
        guard drawsEdge else { return }
        let edge = style.plateRect(in: bounds).insetBy(dx: 0.5, dy: 0.5)
        let outline = NSBezierPath(roundedRect: edge, xRadius: max(0, style.plateRadius - 0.5),
                                   yRadius: max(0, style.plateRadius - 0.5))
        outline.lineWidth = 1
        style.plateEdge.setStroke()
        outline.stroke()
    }

    private var plate: NSBezierPath {
        NSBezierPath(roundedRect: style.plateRect(in: bounds), xRadius: style.plateRadius, yRadius: style.plateRadius)
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        isHovering = false
        isChecked = false
    }
}
