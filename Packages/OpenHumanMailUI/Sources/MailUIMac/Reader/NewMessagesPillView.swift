import AppKit
import MailFeatures
import MailTheme
import MailUI

/// A floating capsule over the bottom of the conversation that shows the messages that arrived while reading. It is
/// a solid accent capsule, the system's look for a prominent control, so it reads the same with Reduce Transparency.
@MainActor
final class NewMessagesPillView: NSView {
    var onClick: (() -> Void)?
    private(set) var count = 0
    let label: NSTextField
    private let arrow: NSImageView
    let fill: NSColor
    private let hoverFill: NSColor
    private let pillShadow: ThemeShadow
    private let labelStyle: TypeStyle
    private let labelColor: ThemeColor
    /// Room around the capsule for its shadow; the reader places the pill by it.
    let margin: CGFloat
    static let capsuleHeight: CGFloat = 28
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    private let enter: MotionSpec
    private let rise: CGFloat

    init(theme: ThemeTokens) {
        enter = theme.motion(theme.motionEnterBase)
        rise = CGFloat(theme.component.thread.pillEnterOffset)
        fill = theme.accentFill.nsColor
        hoverFill = theme.accentFillHover.nsColor
        pillShadow = theme.shadow2
        margin = ShadowRoom.margin(for: theme.shadow2)
        labelStyle = theme.typeLabel
        labelColor = theme.accentOnFill
        label = readerLabel("", theme.typeLabel, theme.accentOnFill)
        let image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NativeMetrics.Text.caption, weight: .semibold)) ?? NSImage()
        arrow = NSImageView(image: image)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        arrow.contentTintColor = theme.accentOnFill.nsColor
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.setAccessibilityElement(false)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(arrow)
        content.addSubview(label)
        addSubview(content)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.capsuleHeight + margin * 2),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            content.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin),
            arrow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: theme.space4),
            arrow.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: theme.space2),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -theme.space4),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Shows the messages that arrived while you were reading and highlights the newest")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(count: Int, key: String?) {
        let title = ReaderFormatting.newMessagesTitle(count)
        if count != self.count {
            let grew = count > self.count
            self.count = count
            label.attributedStringValue = readerText(title, labelStyle, labelColor)
            setAccessibilityLabel(title)
            if grew {
                NSAccessibility.post(element: self, notification: .announcementRequested,
                                     userInfo: [.announcement: title, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
        MotionAnimator.setVisible(self, count > 0, enter: enter, offset: rise)
        if isHidden { isHovered = false }
        let help = key.map { "Show new messages  \($0)" } ?? "Show new messages"
        if toolTip != help { toolTip = help }
    }

    var pillRect: NSRect { bounds.insetBy(dx: margin, dy: margin) }

    override func draw(_ dirtyRect: NSRect) {
        let pill = pillRect
        guard pill.width > 0, pill.height > 0 else { return }
        let r = pill.height / 2
        let path = NSBezierPath(roundedRect: pill, xRadius: r, yRadius: r)
        let color = isHovered ? hoverFill : fill
        for layer in pillShadow.layers {
            NSGraphicsContext.saveGraphicsState()
            let cast = NSShadow()
            cast.shadowOffset = NSSize(width: layer.x, height: -layer.y)
            cast.shadowBlurRadius = layer.blur
            cast.shadowColor = layer.color.nsColor
            cast.set()
            color.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        color.setFill()
        path.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        return pillRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: pillRect, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
