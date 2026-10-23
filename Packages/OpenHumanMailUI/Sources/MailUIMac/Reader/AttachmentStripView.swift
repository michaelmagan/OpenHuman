import AppKit
import MailFeatures
import MailModel
import MailTheme
@preconcurrency import Quartz
import Synchronization
import UniformTypeIdentifiers

@MainActor
protocol AttachmentStripDelegate: AnyObject {
    func attachmentStrip(_ strip: AttachmentStripView, quickLook attachment: AttachmentInfo)
    func attachmentStrip(_ strip: AttachmentStripView, open attachment: AttachmentInfo)
    func attachmentStrip(_ strip: AttachmentStripView, save attachments: [AttachmentInfo])
}

@MainActor
final class AttachmentStripView: NSView {
    let attachments: [AttachmentInfo]
    let message: MessageKey
    weak var delegate: AttachmentStripDelegate?
    private(set) var tiles: [AttachmentTileView] = []
    var dragWriter: AttachmentDragWriter? {
        didSet { for tile in tiles { tile.updateAccessibilityHelp(dragsOut: dragWriter != nil) } }
    }
    var dragFailed: @MainActor @Sendable (AttachmentInfo) -> Void = { _ in }
    private let theme: ThemeTokens
    private var heightConstraint: NSLayoutConstraint!
    private let header: NSStackView

    init(_ attachments: [AttachmentInfo], message: MessageKey, theme: ThemeTokens, formatting: ReaderFormatting) {
        self.attachments = attachments
        self.message = message
        self.theme = theme
        header = NSStackView()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let summary = readerLabel(formatting.attachmentsSummary(attachments), theme.typeMeta, theme.textSecondary)
        let saveAll = ReaderButton.link(attachments.count == 1 ? "Save" : "Save all", theme: theme, style: theme.typeMeta) {
            [weak self] in
            guard let self else { return }
            self.delegate?.attachmentStrip(self, save: self.attachments)
        }
        saveAll.identifier = NSUserInterfaceItemIdentifier("reader.attachments.saveAll")
        header.orientation = .horizontal
        header.spacing = theme.space3
        header.alignment = .firstBaseline
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addArrangedSubview(summary)
        header.addArrangedSubview(saveAll)
        addSubview(header)
        for attachment in attachments {
            let tile = AttachmentTileView(attachment, theme: theme)
            tile.strip = self
            addSubview(tile)
            tiles.append(tile)
        }
        heightConstraint = heightAnchor.constraint(equalToConstant: 72)
        heightConstraint.isActive = true
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(formatting.attachmentsSummary(attachments))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let tileSize = CGSize(width: 220, height: 52)
        let gap = theme.space3
        let top: CGFloat = 20 + theme.space3
        var x: CGFloat = 0
        var y: CGFloat = top
        for tile in tiles {
            if x > 0, x + tileSize.width > bounds.width {
                x = 0
                y += tileSize.height + gap
            }
            tile.frame = CGRect(origin: CGPoint(x: x, y: y), size: tileSize)
            x += tileSize.width + gap
        }
        let height = tiles.isEmpty ? 20 : y + tileSize.height
        if heightConstraint.constant != height {
            heightConstraint.constant = height
            superview?.needsLayout = true
        }
    }

    fileprivate func select(_ tile: AttachmentTileView) {
        for other in tiles { other.isSelected = other === tile }
        window?.makeFirstResponder(tile)
    }
}

@MainActor
final class AttachmentTileView: NSView {
    let attachment: AttachmentInfo
    weak var strip: AttachmentStripView?
    private let theme: ThemeTokens
    var isSelected = false { didSet { updateBorder() } }
    private(set) var isHovered = false { didSet { if isHovered != oldValue { updateBorder() } } }

    init(_ attachment: AttachmentInfo, theme: ThemeTokens) {
        self.attachment = attachment
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = theme.radiusMD
        layer?.borderWidth = theme.borderWidthHairline
        updateBorder()
        let type = UTType(mimeType: attachment.mimeType) ?? UTType(filenameExtension: (attachment.filename as NSString).pathExtension) ?? .data
        let icon = NSImageView(image: NSWorkspace.shared.icon(for: type))
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = readerLabel(ReaderFormatting.safeFilename(attachment.filename), theme.typeBody, theme.textPrimary)
        name.lineBreakMode = .byTruncatingMiddle
        let size = readerLabel(ReaderFormatting.size(attachment.size), theme.typeCaption, theme.textTertiary)
        for v in [icon, name, size] { addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: theme.space4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: theme.space3),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -theme.space4),
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            size.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            size.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
        let menu = NSMenu()
        menu.addItem(MenuAction("Quick Look") { [weak self] in self?.quickLook() })
        menu.addItem(MenuAction("Open") { [weak self] in self?.open() })
        menu.addItem(MenuAction("Save…") { [weak self] in self?.save() })
        self.menu = menu
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(ReaderFormatting.safeFilename(attachment.filename)), \(ReaderFormatting.size(attachment.size)), attachment")
        updateAccessibilityHelp(dragsOut: false)
        toolTip = ReaderFormatting.safeFilename(attachment.filename)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func updateBorder() {
        layer?.borderColor = (isSelected ? theme.accentRing : theme.borderHairline).nsColor.cgColor
        let fill: NSColor = isSelected ? theme.accentSubtle.nsColor : (isHovered ? theme.bgRowHover.nsColor : .clear)
        layer?.backgroundColor = fill.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    func updateAccessibilityHelp(dragsOut: Bool) {
        setAccessibilityHelp(dragsOut ? "Space previews it, double-click opens it, drag it to copy it."
                                      : "Space previews it, double-click opens it")
    }

    override var acceptsFirstResponder: Bool { true }

    private var mouseDownPoint: NSPoint?
    private var dragStarted = false

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        dragStarted = false
        strip?.select(self)
        if event.clickCount >= 2 { open() }
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        dragStarted = false
    }

    nonisolated static let dragThreshold: CGFloat = 4
    nonisolated static let dragOperations: NSDragOperation = .copy

    nonisolated static func passesDragThreshold(from start: NSPoint, to point: NSPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) >= dragThreshold
    }

    var beginDrag: @MainActor (AttachmentTileView, [NSDraggingItem], NSEvent) -> Void = { tile, items, event in
        _ = tile.beginDraggingSession(with: items, event: event, source: tile)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !dragStarted,
              Self.passesDragThreshold(from: start, to: event.locationInWindow),
              let strip, let writer = strip.dragWriter, let item = draggingItem() else { return }
        dragStarted = true
        writer.prepare(attachment, of: strip.message)
        beginDrag(self, [item], event)
    }

    func draggingItem() -> NSDraggingItem? {
        guard let strip, let writer = strip.dragWriter else { return nil }
        let type = UTType(mimeType: attachment.mimeType) ?? UTType(filenameExtension: (attachment.filename as NSString).pathExtension) ?? .data
        let delegate = AttachmentPromiseDelegate(attachment: attachment, message: strip.message, writer: writer,
                                                 failed: strip.dragFailed)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)
        provider.userInfo = delegate
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: dragImage())
        return item
    }

    private func dragImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { quickLook(); return }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool { quickLook(); return true }

    func quickLook() {
        guard let strip else { return }
        strip.select(self)
        strip.delegate?.attachmentStrip(strip, quickLook: attachment)
    }

    func open() {
        guard let strip else { return }
        strip.delegate?.attachmentStrip(strip, open: attachment)
    }

    func save() {
        guard let strip else { return }
        strip.delegate?.attachmentStrip(strip, save: [attachment])
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        QuickLookSession.shared.current != nil
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookSession.shared
            panel.delegate = QuickLookSession.shared
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

extension AttachmentTileView: NSDraggingSource {
    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        AttachmentTileView.dragOperations
    }
}

final class QuickLookSession: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate, Sendable {
    static let shared = QuickLookSession()
    private let item = Mutex<(url: URL, title: String)?>(nil)

    var current: (url: URL, title: String)? { item.withLock { $0 } }

    @MainActor
    func toggle(_ url: URL, title: String) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, current?.url == url {
            panel.orderOut(nil)
            return
        }
        item.withLock { $0 = (url, title) }
        if panel.dataSource == nil { panel.dataSource = self }
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { current == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        current.map { QuickLookItem(url: $0.url, title: $0.title) }
    }
}

final class QuickLookItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String?

    init(url: URL, title: String?) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL! { url }
    var previewItemTitle: String! { title }
}
