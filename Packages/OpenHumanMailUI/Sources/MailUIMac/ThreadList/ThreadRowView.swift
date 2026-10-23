import AppKit
import MailActions
import MailFeatures
import MailModel
import MailTheme
import MailUI

@MainActor
public final class ThreadRowView: NSTableCellView {
    public static let identifier = NSUserInterfaceItemIdentifier("ThreadRow")

    struct HoverAction: Equatable {
        let action: ActionID
        let symbol: String
        let title: String
    }

    private struct Content {
        var sender: NSAttributedString
        var line: NSAttributedString
        var date: NSAttributedString
        var dateWidth: CGFloat
        var indicators: [NSImage]
        var showsUnreadDot: Bool
        var fitted: (width: CGFloat, line: NSAttributedString)?
    }

    var style: ThreadRowStyle {
        didSet {
            guard style !== oldValue else { return }
            content?.fitted = nil
            restylePlate()
            needsDisplay = true
            needsLayout = true
            if style.metrics.buttonGlyph != oldValue.metrics.buttonGlyph, !shownHoverActions.isEmpty {
                shownHoverActions = []
                updateActions()
            }
        }
    }
    var onAction: ((ActionID) -> Void)?
    var hoverActions: (() -> [HoverAction])?
    var onActionHover: ((NSView, HoverAction, Bool) -> Void)?
    var accessibilityContent: (() -> (label: String, actions: [NSAccessibilityCustomAction]))?
    var importanceTip: (() -> String)?
    var onPointerEnter: (() -> Void)?

    private var content: Content?
    private var tipRect: NSRect?
    private var plate: NSView?
    private var plateButtons: [RowActionButton] = []
    private var shownHoverActions: [HoverAction] = []
    public private(set) var isPlaceholder = true
    private(set) var isChecked = false
    private(set) var isHovering = false
    private(set) var isCursor = false
    private(set) var isPointerInside = false
    static let checkboxSize = SelectCheckbox.side
    var showsEmptyCheckbox: Bool { !isChecked && !isPlaceholder && (isPointerInside || isCursor) }
    private(set) var showsActions = false
    static let showsActionsOnCursorRow = true
    var cursorRowShowsActions = true {
        didSet { if cursorRowShowsActions != oldValue { updateActions() } }
    }

    init(style: ThreadRowStyle) {
        self.style = style
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set {}
    }

    public override func accessibilityLabel() -> String? {
        accessibilityContent?().label ?? super.accessibilityLabel()
    }

    public override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        accessibilityContent?().actions ?? super.accessibilityCustomActions()
    }

    func configure(_ row: ThreadRow, texts: (sender: NSAttributedString, line: NSAttributedString),
                   date: NSAttributedString, indicators: [ThreadRowIndicator], isChecked: Bool, isMuted: Bool = false) {
        isPlaceholder = false
        drawsSkeleton = false
        stopShimmer()
        let images = indicators.compactMap { style.symbol($0.symbol, color: color(of: $0)) }
        content = Content(sender: texts.sender, line: texts.line, date: date, dateWidth: ceil(date.size().width),
                          indicators: images,
                          showsUnreadDot: row.isUnread && !isMuted)
        self.isChecked = isChecked
        isCursor = isCursorRow
        updateActions()
        updateTipRect()
        needsDisplay = true
    }

    func configurePlaceholder(showsSkeleton: Bool) {
        isPlaceholder = true
        content = nil
        isChecked = false
        importanceTip = nil
        onPointerEnter = nil
        updateTipRect()
        setHovering(false)
        accessibilityContent = { (String(localized: "Loading conversation"), []) }
        drawsSkeleton = showsSkeleton
        if showsSkeleton { startShimmer() } else { stopShimmer() }
        needsDisplay = true
    }

    private(set) var drawsSkeleton = false

    static let shimmerKey = "openhuman.rowShimmer"

    private func startShimmer() {
        guard let layer, layer.animation(forKey: Self.shimmerKey) == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.45
        animation.duration = 0.9
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: Self.shimmerKey)
    }

    private func stopShimmer() {
        layer?.removeAnimation(forKey: Self.shimmerKey)
    }

    var isShimmering: Bool { layer?.animation(forKey: Self.shimmerKey) != nil }

    private func drawSkeleton() {
        let c = style.columns(width: bounds.width)
        let rtl = userInterfaceLayoutDirection == .rightToLeft
        let height = bounds.height, barHeight: CGFloat = 10
        let color = style.tertiary.withAlphaComponent(0.22)
        color.setFill()
        let senderWidth = min(140, c.sender.upperBound - c.sender.lowerBound)
        let lineWidth = max(0, min(bounds.width * 0.42, c.subject.upperBound - c.subject.lowerBound))
        for (start, width) in [(c.sender.lowerBound, senderWidth), (c.subject.lowerBound, lineWidth)] where width > 0 {
            let x = rtl ? bounds.width - start - width : start
            NSBezierPath(roundedRect: NSRect(x: x, y: ((height - barHeight) / 2).rounded(), width: width, height: barHeight),
                         xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        }
    }

    func setChecked(_ checked: Bool) {
        guard checked != isChecked else { return }
        isChecked = checked
        needsDisplay = true
    }

    private func color(of indicator: ThreadRowIndicator) -> NSColor {
        switch indicator {
        case .starred, .snoozed: style.warning
        case .draft: style.success
        case .pending, .muted: style.tertiary
        case .reminder, .scheduled, .attachment: style.secondary
        }
    }

    private(set) var drawCount = 0

    public override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        guard let content else {
            if isPlaceholder, drawsSkeleton { drawSkeleton() }
            return
        }
        let width = bounds.width, height = bounds.height
        let c = style.columns(width: width)
        let rtl = userInterfaceLayoutDirection == .rightToLeft
        func x(_ start: CGFloat, _ w: CGFloat) -> CGFloat { rtl ? width - start - w : start }
        let frames = drawnFrames()

        let side = Self.checkboxSize
        let box = NSRect(x: x(c.dotCenterX - side / 2, side), y: ((height - side) / 2).rounded(), width: side, height: side)
        let radius = SelectCheckbox.cornerRadius(style.theme, side: side)
        if isChecked {
            style.accentFill.setFill()
            NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
            let mark = NSBezierPath(cgPath: SelectCheckbox.tick(in: box, yUp: !isFlipped))
            mark.lineWidth = SelectCheckbox.lineWidth
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            style.accentOnFill.setStroke()
            mark.stroke()
        } else if showsEmptyCheckbox {
            let outline = NSBezierPath(roundedRect: SelectCheckbox.outlineRect(box), xRadius: radius, yRadius: radius)
            outline.lineWidth = SelectCheckbox.lineWidth
            style.tertiary.setStroke()
            outline.stroke()
        } else if content.showsUnreadDot {
            let size = style.unreadDotSize
            style.unreadDot.setFill()
            NSBezierPath(ovalIn: NSRect(x: x(c.dotCenterX - size / 2, size), y: ((height - size) / 2).rounded(),
                                        width: size, height: size)).fill()
        }

        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        NSGraphicsContext.saveGraphicsState()
        if let band = frames.actions {
            NSBezierPath(rect: rtl ? NSRect(x: band.maxX, y: 0, width: max(0, width - band.maxX), height: height)
                                   : NSRect(x: 0, y: 0, width: max(0, band.minX), height: height)).addClip()
        }
        if let sender = frames.sender, let text = drawnSender() { text.draw(with: sender, options: options, context: nil) }
        if let line = frames.line, let text = drawnLine(frames) { text.draw(with: line, options: options, context: nil) }
        NSGraphicsContext.restoreGraphicsState()
        if let date = frames.date, let text = drawnDate() { text.draw(with: date, options: options, context: nil) }
        for (image, frame) in zip(content.indicators, frames.indicators) { image.draw(in: frame) }
    }

    private var onFill: Bool { isChecked || isCursorRow }

    func drawnLine(_ frames: DrawnFrames) -> NSAttributedString? {
        guard let line = frames.line else { return nil }
        let fitted = fittedLine(width: line.width)
        return onFill ? style.onFill(fitted) : fitted
    }

    func drawnSender() -> NSAttributedString? {
        guard let content else { return nil }
        return onFill ? style.onFill(content.sender) : content.sender
    }

    func drawnDate() -> NSAttributedString? {
        guard let content else { return nil }
        return onFill ? style.onFill(content.date) : content.date
    }

    func fittedLine(width: CGFloat) -> NSAttributedString {
        guard let content else { return NSAttributedString() }
        if let fitted = content.fitted, fitted.width == width { return fitted.line }
        let line = style.fitted(content.line, width: width)
        self.content?.fitted = (width, line)
        return line
    }

    struct DrawnFrames: Equatable {
        var sender: NSRect?
        var line: NSRect?
        var date: NSRect?
        var indicators: [NSRect] = []
        var actions: NSRect?
        var contents: [NSRect] { [sender, line, date].compactMap { $0 } + indicators }
    }

    func drawnFrames() -> DrawnFrames {
        guard let content else { return DrawnFrames() }
        let width = bounds.width, height = bounds.height
        let c = style.columns(width: width)
        let rtl = userInterfaceLayoutDirection == .rightToLeft
        let lineHeight = style.lineHeight
        let y = ((height - lineHeight) / 2).rounded()
        func place(_ start: CGFloat, _ end: CGFloat, y: CGFloat, height: CGFloat) -> NSRect? {
            let w = end - start
            guard w >= 1 else { return nil }
            return NSRect(x: rtl ? width - start - w : start, y: y, width: w, height: height)
        }
        var frames = DrawnFrames()
        let actionsStart = actionGroupStart(c)
        let textEnd = actionsStart.map { $0 - style.metrics.columnGap } ?? .greatestFiniteMagnitude
        frames.sender = place(c.sender.lowerBound, min(c.sender.upperBound, textEnd), y: y, height: lineHeight)
        frames.line = place(c.subject.lowerBound, min(c.subject.upperBound, textEnd), y: y, height: lineHeight)
        if let actionsStart {
            frames.actions = place(max(0, actionsStart), c.date.upperBound, y: 0, height: height)
            return frames
        }
        let overflow = dateOverflow(c)
        frames.date = place(c.date.lowerBound - overflow, c.date.upperBound, y: y, height: lineHeight)
        let icon = style.metrics.indicatorSize
        var right = c.indicators.upperBound - 4 - overflow
        for _ in content.indicators {
            right -= icon
            if let frame = place(right, right + icon, y: ((height - icon) / 2).rounded(), height: icon) {
                frames.indicators.append(frame)
            }
            right -= 4
        }
        return frames
    }

    func setHovering(_ hovering: Bool) {
        if hovering != isPointerInside {
            isPointerInside = hovering
            needsDisplay = true
            if hovering { onPointerEnter?() }
        }
        let wasShowing = showsActions
        updateActions(pointer: hovering)
        isHovering = hovering && showsActions
        if showsActions, !wasShowing, hovering { fadeIn(plate) }
    }

    func setCursor(_ cursor: Bool) {
        guard cursor != isCursor else { return }
        isCursor = cursor
        updateActions()
        needsDisplay = true
    }

    private func updateActions(pointer: Bool? = nil) {
        let hovering = pointer ?? isHovering
        let wanted = !isPlaceholder && (hovering || (isCursor && Self.showsActionsOnCursorRow && cursorRowShowsActions))
        let actions = wanted ? (hoverActions?() ?? []) : []
        let next = wanted && !actions.isEmpty
        if next { installPlate(actions) }
        plate?.isHidden = !next
        if !next { for button in plateButtons { button.resetPointerState() } }
        if pointer == nil { isHovering = isHovering && next }
        guard next != showsActions else { return }
        showsActions = next
        needsDisplay = true
        needsLayout = true
    }

    private func restylePlate() {
        for button in plateButtons { button.style = style }
    }

    private var isCursorRow: Bool { (superview as? NSTableRowView)?.isSelected == true }

    private func installPlate(_ actions: [HoverAction]) {
        if plate == nil {
            let view = NSView()
            view.wantsLayer = true
            view.isHidden = true
            addSubview(view)
            plate = view
        }
        guard actions != shownHoverActions, let plate else { return }
        shownHoverActions = actions
        for button in plateButtons { button.removeFromSuperview() }
        plateButtons = actions.enumerated().map { index, action in
            let config = NSImage.SymbolConfiguration(pointSize: style.metrics.buttonGlyph, weight: .regular)
            let image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)?
                .withSymbolConfiguration(config) ?? NSImage()
            let button = RowActionButton(image: image, style: style)
            button.target = self
            button.action = #selector(hoverButtonClicked(_:))
            button.tag = index
            button.setAccessibilityLabel(action.title)
            button.onHoverChange = { [weak self] button, inside in self?.onActionHover?(button, action, inside) }
            plate.addSubview(button)
            return button
        }
        needsLayout = true
        needsDisplay = true
    }

    private func fadeIn(_ view: NSView?) {
        guard let layer = view?.layer else { return }
        let duration = style.theme.motionReveal.seconds
        guard duration > 0 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = style.theme.motion(style.theme.motionReveal, transform: false).seconds
        layer.add(fade, forKey: "reveal")
    }

    @objc private func hoverButtonClicked(_ sender: NSButton) {
        guard shownHoverActions.indices.contains(sender.tag) else { return }
        onAction?(shownHoverActions[sender.tag].action)
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        isCursor = false
        setHovering(false)
        onAction = nil
        hoverActions = nil
        onActionHover = nil
        accessibilityContent = nil
        importanceTip = nil
        onPointerEnter = nil
        updateTipRect()
    }

    func importanceTipRect() -> NSRect? {
        guard importanceTip != nil, let frame = drawnFrames().line else { return nil }
        let line = fittedLine(width: frame.width)
        var span: ThreadRowStyle.ChipSpan?
        line.enumerateAttribute(ThreadRowStyle.tipSpan, in: NSRange(location: 0, length: line.length)) { value, _, stop in
            guard let value = value as? ThreadRowStyle.ChipSpan else { return }
            span = value
            stop.pointee = true
        }
        guard let span, span.start < frame.width else { return nil }
        let end = min(span.end, frame.width)
        let x = userInterfaceLayoutDirection == .rightToLeft ? frame.maxX - end : frame.minX + span.start
        return NSRect(x: x, y: 0, width: end - span.start, height: bounds.height)
    }

    private func updateTipRect() {
        let rect = importanceTipRect()
        guard rect != tipRect else { return }
        tipRect = rect
        removeAllToolTips()
        if let rect { addToolTip(rect, owner: self, userData: nil) }
    }

    public struct Columns: Equatable {
        public var dotCenterX: CGFloat
        public var sender: ClosedRange<CGFloat>
        public var subject: ClosedRange<CGFloat>
        public var indicators: ClosedRange<CGFloat>
        public var date: ClosedRange<CGFloat>
    }

    public static func columns(width: CGFloat) -> Columns {
        let c = ThreadRowStyle.columns(width: width, metrics: ThreadRowStyle.metrics(.light),
                                       minimumSubject: ThreadRowStyle.minimumSubject(for: .light))
        return Columns(dotCenterX: c.dotCenterX, sender: c.sender, subject: c.subject, indicators: c.indicators, date: c.date)
    }

    private func plateWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let n = CGFloat(count), gap = style.metrics.buttonGap
        return n * style.hoverTarget + (n - 1) * gap + 2 * gap
    }

    private func actionGroupStart(_ c: ThreadRowStyle.Columns) -> CGFloat? {
        guard showsActions, !plateButtons.isEmpty else { return nil }
        return c.date.upperBound - plateWidth(count: plateButtons.count)
    }

    private func dateOverflow(_ c: ThreadRowStyle.Columns) -> CGFloat {
        guard let content else { return 0 }
        return max(0, content.dateWidth - (c.date.upperBound - c.date.lowerBound))
    }

    var dateRange: ClosedRange<CGFloat> {
        let c = style.columns(width: bounds.width)
        return (c.date.lowerBound - dateOverflow(c))...c.date.upperBound
    }

    var showsUnreadDot: Bool { content?.showsUnreadDot ?? false }

    var subjectLineWidth: CGFloat { drawnFrames().line?.width ?? 0 }

    var actionGroupFrame: NSRect? {
        guard let plate, !plate.isHidden else { return nil }
        return plate.frame
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        guard newSize != old else { return }
        needsLayout = true
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        updateTipRect()
        guard let plate, !plateButtons.isEmpty else { return }
        let width = bounds.width, height = bounds.height
        let c = style.columns(width: width)
        let rtl = userInterfaceLayoutDirection == .rightToLeft
        let target = style.hoverTarget, gap = style.metrics.buttonGap
        let plateWidth = plateWidth(count: plateButtons.count)
        let plateHeight = min(height - 4, target + gap)
        let start = c.date.upperBound - plateWidth
        plate.frame = NSRect(x: rtl ? width - start - plateWidth : start, y: ((height - plateHeight) / 2).rounded(),
                             width: plateWidth, height: plateHeight)
        for (i, button) in plateButtons.enumerated() {
            let bx = gap + CGFloat(i) * (target + gap)
            button.frame = NSRect(x: rtl ? plateWidth - bx - target : bx, y: ((plateHeight - target) / 2).rounded(),
                                  width: target, height: target)
        }
    }
}

extension ThreadRowView: NSViewToolTipOwner {
    public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                     userData data: UnsafeMutableRawPointer?) -> String {
        importanceTip?() ?? ""
    }
}

@MainActor
final class RowActionButton: NSButton {
    var style: ThreadRowStyle {
        didSet { if style !== oldValue { update() } }
    }
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            update()
            onHoverChange?(self, isHovered)
        }
    }
    var onHoverChange: ((RowActionButton, Bool) -> Void)?
    private var isPressed = false { didSet { if isPressed != oldValue { update() } } }

    init(image: NSImage, style: ThreadRowStyle) {
        self.style = style
        super.init(frame: .zero)
        self.image = image
        imagePosition = .imageOnly
        isBordered = false
        wantsLayer = true
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func resetPointerState() {
        isHovered = false
        isPressed = false
    }

    private func update() {
        layer?.cornerRadius = CGFloat(style.theme.radiusMD)
        let fill: NSColor? = isPressed ? style.actionPressedFill : (isHovered ? style.actionPointerFill : nil)
        layer?.backgroundColor = fill?.cgColor
        contentTintColor = isHovered || isPressed ? style.actionTintUnderPointer : style.actionTint
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        onHoverChange?(self, false)
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }
}
