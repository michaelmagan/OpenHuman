import AppKit
import MailModel
import MailRender

// Drawn over the text view, so showing it never moves the text. Only the size buttons and the corner handles take
// clicks; everything else goes through to the text.
@MainActor
final class InlineImageOverlay: NSView {
    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    static let handleSize: CGFloat = 8
    static let inset: CGFloat = 6

    let control = ImageSizeControl()
    private let pill = NSVisualEffectView()

    var onPreset: ((InlineImageSize) -> Void)?
    var onResize: ((CGSize) -> Void)?
    var onLeave: (() -> Void)?
    var resizedSize: ((CGFloat) -> CGSize)?

    private(set) var imageRect: NSRect = .zero
    private var drag: (corner: Corner, start: NSPoint, rect: NSRect)?
    private(set) var preview: NSRect?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("composer.imageSize")
        autoresizingMask = [.width, .height]
        isHidden = true
        pill.material = .popover
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 7
        pill.layer?.masksToBounds = true
        addSubview(pill)
        control.segmentCount = InlineImageSize.allCases.count
        for (index, size) in InlineImageSize.allCases.enumerated() {
            control.setLabel(size.title, forSegment: index)
            control.setToolTip(String(localized: "\(size.title) image"), forSegment: index)
        }
        control.trackingMode = .selectOne
        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        control.segmentStyle = .rounded
        control.target = self
        control.action = #selector(choose(_:))
        control.setAccessibilityLabel(String(localized: "Image size"))
        control.setAccessibilityHelp(String(localized: "Press Escape to go back to the message."))
        control.onLeave = { [weak self] in self?.onLeave?() }
        control.sizeToFit()
        pill.addSubview(control)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(over rect: NSRect, selected: InlineImageSize?) {
        imageRect = rect
        drag = nil
        preview = nil
        control.selectedSegment = selected.flatMap { InlineImageSize.allCases.firstIndex(of: $0) } ?? -1
        let size = control.fittingSize
        let pillSize = NSSize(width: size.width + 8, height: size.height + 8)
        var origin = NSPoint(x: rect.minX + Self.inset, y: rect.minY + Self.inset)
        if rect.width < pillSize.width + 2 * Self.inset || rect.height < pillSize.height + 2 * Self.inset {
            // Too small to hold the buttons: just below the picture, or above it near the end of the text
            origin = NSPoint(x: rect.minX, y: rect.maxY + Self.inset)
            if origin.y + pillSize.height > bounds.maxY { origin.y = max(0, rect.minY - Self.inset - pillSize.height) }
        }
        pill.frame = NSRect(origin: origin, size: pillSize)
        control.frame = NSRect(x: 4, y: 4, width: size.width, height: size.height)
        isHidden = false
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        drag = nil
        preview = nil
        imageRect = .zero
    }

    @objc private func choose(_ sender: NSSegmentedControl) {
        let all = InlineImageSize.allCases
        guard all.indices.contains(sender.selectedSegment) else { return }
        onPreset?(all[sender.selectedSegment])
        // After a click the typing goes on in the text; from the keyboard the focus stays to try another size
        let clicked: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp]
        if let event = NSApp.currentEvent, clicked.contains(event.type) { onLeave?() }
    }

    func handleRect(_ corner: Corner, of rect: NSRect? = nil) -> NSRect {
        let r = rect ?? imageRect
        let s = Self.handleSize
        let x = corner == .topLeft || corner == .bottomLeft ? r.minX : r.maxX
        let y = corner == .topLeft || corner == .topRight ? r.minY : r.maxY
        return NSRect(x: x - s / 2, y: y - s / 2, width: s, height: s)
    }

    func corner(at point: NSPoint) -> Corner? {
        Corner.allCases.first { handleRect($0).insetBy(dx: -3, dy: -3).contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        if pill.frame.contains(local) { return super.hitTest(point) }
        return corner(at: local) != nil ? self : nil
    }

    override func resetCursorRects() {
        guard !isHidden else { return }
        for corner in Corner.allCases {
            let position: NSCursor.FrameResizePosition = switch corner {
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            addCursorRect(handleRect(corner).insetBy(dx: -3, dy: -3),
                          cursor: .frameResize(position: position, directions: .all))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let corner = corner(at: point) else { return }
        drag = (corner, point, imageRect)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - drag.start.x
        let width = drag.corner == .topLeft || drag.corner == .bottomLeft ? drag.rect.width - dx : drag.rect.width + dx
        let size = resizedSize?(width) ?? drag.rect.size
        preview = NSRect(origin: drag.rect.origin, size: size)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            needsDisplay = true
        }
        guard drag != nil, let preview else { return }
        self.preview = nil
        if preview.size != imageRect.size { onResize?(preview.size) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, imageRect != .zero else { return }
        let accent = NSColor.controlAccentColor
        let rect = preview ?? imageRect
        let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        if preview != nil { border.setLineDash([4, 3], count: 2, phase: 0) }
        accent.setStroke()
        border.stroke()
        for corner in Corner.allCases {
            let handle = NSBezierPath(roundedRect: handleRect(corner, of: rect), xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            handle.fill()
            handle.lineWidth = 1.5
            accent.setStroke()
            handle.stroke()
        }
    }
}

// Takes focus with Tab from the text even without full keyboard access; Escape or Tab goes back
final class ImageSizeControl: NSSegmentedControl {
    var onLeave: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 48: onLeave?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onLeave?()
    }
}
