import AppKit
import MailUI

/// An `NSButton` that calls a closure. It adds no drawing, hover tracking or layer of its own: the bezel style and
/// `showsBorderOnlyWhileMouseInside` give the hover look, and the system draws the press.
@MainActor
public final class NativeButton: NSButton {
    public var onPress: (() -> Void)?

    @objc func pressed() { onPress?() }

    fileprivate func finish(label: String, onPress: @escaping () -> Void) {
        self.onPress = onPress
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityLabel(label)
    }
}

@MainActor
extension NSButton {
    /// A symbol button with the accessory-bar bezel, shown only while the pointer is over it. `label` is the
    /// accessibility label; `help` is the tooltip and defaults to the label (give the shortcut there: "Next match  ⌘G").
    /// A fixed `size` keeps the button's frame the same whether or not its bezel shows.
    public static func nativeIcon(_ symbol: String, label: String, help: String? = nil,
                                  pointSize: CGFloat = NativeMetrics.Controls.iconPointSize,
                                  size: CGFloat? = NativeMetrics.Controls.iconButtonSize,
                                  onPress: @escaping () -> Void) -> NativeButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)) ?? NSImage()
        let button = NativeButton(image: image, target: nil, action: nil)
        button.isBordered = true
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = help ?? label
        button.finish(label: label, onPress: onPress)
        if let size {
            // The fixed square wins over the symbol's own size, whichever is larger
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            button.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
            button.widthAnchor.constraint(equalToConstant: size).isActive = true
            button.heightAnchor.constraint(equalToConstant: size).isActive = true
        }
        return button
    }

    /// A borderless text button in the system link colour ("Done", "Save all", "Show images").
    public static func nativeLink(_ title: String, font: NSFont = .systemFont(ofSize: NativeMetrics.Text.body),
                                  onPress: @escaping () -> Void) -> NativeButton {
        let button = NativeButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.font = font
        button.contentTintColor = .linkColor
        button.finish(label: title, onPress: onPress)
        return button
    }

    /// A borderless text button in secondary text that truncates at the tail when space runs out (a recipients line
    /// that opens the message details).
    public static func nativePlain(_ title: String, font: NSFont = .systemFont(ofSize: NativeMetrics.Text.secondary),
                                   onPress: @escaping () -> Void = {}) -> NativeButton {
        let button = NativeButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.font = font
        button.contentTintColor = .secondaryLabelColor
        button.lineBreakMode = .byTruncatingTail
        button.finish(label: title, onPress: onPress)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }
}

/// A system separator line (`NSBox` of type `.separator`); horizontal unless `vertical`. It never takes clicks.
@MainActor
public final class NativeSeparator: NSBox {
    private static let thickness: CGFloat = 1

    public let isVertical: Bool

    public init(vertical: Bool = false) {
        isVertical = vertical
        // NSBox picks the separator's direction from its frame
        let frame = vertical ? NSRect(x: 0, y: 0, width: Self.thickness, height: 8)
            : NSRect(x: 0, y: 0, width: 8, height: Self.thickness)
        super.init(frame: frame)
        boxType = .separator
        translatesAutoresizingMaskIntoConstraints = false
        let side = vertical ? widthAnchor : heightAnchor
        side.constraint(equalToConstant: Self.thickness).isActive = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // A separator box reports 2 pt alignment insets on each side of its line, so its frame would be 5 pt across while
    // constraints hold the line at 1 pt. Without them the frame is the line.
    public override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A floating capsule on Liquid Glass (new-messages pill, retry bar, link preview). Its content is a horizontal
/// stack; it covers what is behind it and never moves surrounding layout. Reduce Transparency is handled by the
/// system. With `backed`, a window-background fill under the glass keeps its text readable over rows wherever the
/// glass is thin or not drawn.
@MainActor
public final class NativeGlassPill: NSView {
    public let glass = NSGlassEffectView()
    public let stack = NSStackView()
    let backing: GlassBackingView?

    public init(views: [NSView] = [], height: CGFloat = NativeMetrics.Pill.height, backed: Bool = true) {
        backing = backed ? GlassBackingView(frame: .zero) : nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = height / 2
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = NativeMetrics.Pill.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        glass.contentView = content
        var constraints = [
            heightAnchor.constraint(equalToConstant: height),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            content.topAnchor.constraint(equalTo: glass.topAnchor),
            content.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: NativeMetrics.Pill.paddingX),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -NativeMetrics.Pill.paddingX),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ]
        if let backing {
            backing.translatesAutoresizingMaskIntoConstraints = false
            addSubview(backing)
            constraints += [
                backing.leadingAnchor.constraint(equalTo: leadingAnchor),
                backing.trailingAnchor.constraint(equalTo: trailingAnchor),
                backing.topAnchor.constraint(equalTo: topAnchor),
                backing.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        }
        addSubview(glass)
        NSLayoutConstraint.activate(constraints)
        setViews(views)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public var views: [NSView] { stack.arrangedSubviews }

    public func setViews(_ views: [NSView]) {
        stack.setViews(views, in: .leading)
    }
}

/// The window background in a capsule, under a glass pill. A layer keeps a resolved colour, so it is set again in
/// `updateLayer` whenever the appearance changes.
@MainActor
final class GlassBackingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    var fill: NSColor { NSColor.windowBackgroundColor.withAlphaComponent(NativeMetrics.Banner.backingOpacity) }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = fill.cgColor
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
