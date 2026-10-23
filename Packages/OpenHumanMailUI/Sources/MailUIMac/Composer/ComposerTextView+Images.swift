import AppKit
import MailModel
import MailRender

extension ComposerTextView {
    func configureImageOverlay() {
        imageOverlay.frame = bounds
        addSubview(imageOverlay)
        imageOverlay.onPreset = { [weak self] size in self?.applyImageSize(size) }
        imageOverlay.onResize = { [weak self] size in
            guard let self, let index = self.selectedImageIndex else { return }
            self.resizeImage(at: index, to: size)
        }
        imageOverlay.resizedSize = { [weak self] width in
            guard let self, let index = self.selectedImageIndex, let attachment = self.imageAttachment(at: index) else {
                return .zero
            }
            return InlineImageSizing.resized(attachment.size, toWidth: width, column: self.imageColumn)
        }
        imageOverlay.onLeave = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    // The width presets are measured against, after the reader's own cap
    var imageColumn: CGFloat {
        let padding = textContainer?.lineFragmentPadding ?? 0
        let container = textContainer?.size.width ?? 0
        let shown = bounds.width - textContainerInset.width * 2
        return InlineImageSizing.column((min(container, shown) - padding * 2) * bridge.maxImageFraction)
    }

    func sizingNewImages(_ document: RichTextDocument) -> RichTextDocument {
        let column = imageColumn
        return document.mappingImages { ref in
            guard ref.size == nil, let image = inlineImageProvider?(ref)?.image,
                  let natural = AttributedBridge.naturalSize(image) else { return ref }
            return ref.sized(pastedImageSize.size(natural: natural, column: column))
        }
    }

    func imageAttachment(at index: Int) -> InlineImageAttachment? {
        guard let storage = textStorage, index >= 0, index < storage.length,
              storage.attribute(AttributedBridge.inlineImageKey, at: index, effectiveRange: nil) != nil else { return nil }
        return storage.attribute(.attachment, at: index, effectiveRange: nil) as? InlineImageAttachment
    }

    var selectedImageIndex: Int? {
        let range = selectedRange()
        guard range.location != NSNotFound, range.length == 1, imageAttachment(at: range.location) != nil else { return nil }
        return range.location
    }

    func imageFrame(at index: Int) -> NSRect? {
        guard imageAttachment(at: index) != nil, let layout = textLayoutManager, let content = layout.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: index),
              let end = content.location(location, offsetBy: 1),
              let range = NSTextRange(location: location, end: end) else { return nil }
        layout.ensureLayout(for: range)
        guard let fragment = layout.textLayoutFragment(for: location) else { return nil }
        let local = fragment.frameForTextAttachment(at: location)
        guard local.width > 0, local.height > 0 else { return nil }
        let origin = fragment.layoutFragmentFrame.origin
        let inset = textContainerOrigin
        return local.offsetBy(dx: origin.x + inset.x, dy: origin.y + inset.y)
    }

    func imageIndex(at point: NSPoint) -> Int? {
        let index = characterIndexForInsertion(at: point)
        guard index != NSNotFound else { return nil }
        return [index, index - 1].first { imageFrame(at: $0)?.contains(point) == true }
    }

    func currentImageSize(_ attachment: InlineImageAttachment) -> InlineImageSize? {
        InlineImageSize.matching(attachment.size, natural: attachment.natural, column: imageColumn)
    }

    func applyImageSize(_ preset: InlineImageSize) {
        guard let index = selectedImageIndex, let attachment = imageAttachment(at: index) else { return }
        resizeImage(at: index, to: preset.size(natural: attachment.natural, column: imageColumn))
    }

    // A new attachment in place of the old one, so Undo brings back the old size
    @discardableResult
    func resizeImage(at index: Int, to proposed: CGSize) -> Bool {
        guard let storage = textStorage, let attachment = imageAttachment(at: index), proposed.width > 0,
              proposed.height > 0 else { return false }
        let size = InlineImageSizing.fit(proposed, maxWidth: InlineImageSizing.maximumSide)
        guard size != attachment.size else { return false }
        let range = NSRange(location: index, length: 1)
        let piece = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        piece.addAttribute(.attachment, value: attachment.resized(to: size), range: NSRange(location: 0, length: 1))
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: piece.string) else { return false }
        storage.replaceCharacters(in: range, with: piece)
        didChangeText()
        undoManager?.setActionName(String(localized: "Change Image Size"))
        breakUndoCoalescing()
        setSelectedRange(range)
        return true
    }

    func scheduleImageOverlay() {
        guard !imageOverlayScheduled else { return }
        imageOverlayScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.imageOverlayScheduled = false
            self.updateImageOverlay()
        }
    }

    var imageSizesFocused: Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder === self || responder === imageOverlay.control
    }

    func updateImageOverlay() {
        guard isEditable, imageSizesFocused, let index = selectedImageIndex, let attachment = imageAttachment(at: index),
              let frame = imageFrame(at: index) else {
            imageOverlay.hide()
            announcedImage = nil
            return
        }
        // TextKit may add its own views after ours; the overlay stays on top
        if subviews.last !== imageOverlay { addSubview(imageOverlay, positioned: .above, relativeTo: nil) }
        if imageOverlay.frame != bounds { imageOverlay.frame = bounds }
        imageOverlay.show(over: frame, selected: currentImageSize(attachment))
        guard announcedImage !== attachment, window?.firstResponder === self else { return }
        announcedImage = attachment
        let width = Int(attachment.size.width), height = Int(attachment.size.height)
        let words = String(localized: "Image, \(width) by \(height) points. Press Tab to change its size.")
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func focusImageSizes() -> Bool {
        guard selectedImageIndex != nil, let window else { return false }
        updateImageOverlay()
        guard !imageOverlay.isHidden else { return false }
        return window.makeFirstResponder(imageOverlay.control)
    }

    func imageSizeMenuItem(at index: Int) -> NSMenuItem {
        let current = imageAttachment(at: index).flatMap { currentImageSize($0) }
        let title = String(localized: "Image Size")
        let sizes = NSMenu(title: title)
        for size in InlineImageSize.allCases {
            let item = NSMenuItem(title: size.title, action: #selector(chooseImageSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            item.state = size == current ? .on : .off
            sizes.addItem(item)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sizes
        return item
    }

    @objc func chooseImageSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = InlineImageSize(rawValue: raw) else { return }
        applyImageSize(size)
    }
}
