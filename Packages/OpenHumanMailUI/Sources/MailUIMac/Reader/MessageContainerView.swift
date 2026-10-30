import AppKit
import MailActions
import MailFeatures
import MailModel
import MailRender
import MailTheme

@MainActor
final class MessageContainerView: NSView {
    let key: MessageKey
    private weak var controller: ReaderViewController?
    private let theme: ThemeTokens
    private let stack = NSStackView()
    let separator: HairlineView
    let focusPlate: ReaderPlateView
    private var plateEdges: [NSLayoutConstraint] = []
    private var stackTop: NSLayoutConstraint!
    private var slotBottom: NSLayoutConstraint!
    private let composerSlot = NSView()
    private var emptySlot: NSLayoutConstraint!
    private let composerDivider: HairlineView
    private(set) var attachedComposer: NSView?
    private(set) var trailingAccessory: NSView?
    private var shownExpanded: Bool?
    private(set) var header: MessageHeaderView?
    private(set) var collapsedRow: CollapsedMessageView?
    private let bannerHost = NSView()
    private(set) var banner: NSView?
    private var bannerState: BannerState?
    private let bodyHost = NSView()
    private(set) var htmlBody: HTMLBodyView?
    private(set) var plainBody: PlainTextMessageView?
    private var shownBody: ReaderModel.BodyState?
    private let note: NSTextField
    private(set) var attachmentsStrip: AttachmentStripView?
    private var shownTiles: [AttachmentInfo]?
    private(set) var inviteHost: InviteCardHostView?
    private var showsInviteCard: Bool { inviteHost?.showsCard == true }
    private var loadingTimer: Timer?
    private var hovering = false
    private var focused = false
    private var marksFocus = true
    private var message: ReaderModel.Message?
    private var baseLabel = ""

    private enum BannerState: Equatable {
        case none
        case hidden(blocked: Int, entry: String?, remembers: Bool)
        case shown(RemoteContentPolicy.Source, trackers: Int)
    }

    init(key: MessageKey, controller: ReaderViewController) {
        self.key = key
        self.controller = controller
        theme = controller.theme
        separator = HairlineView(theme: controller.theme)
        focusPlate = ReaderPlateView(theme: controller.theme)
        composerDivider = HairlineView(theme: controller.theme)
        note = readerLabel("This message is too large to show in full.", controller.theme.typeMeta, controller.theme.textTertiary)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        composerSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        addSubview(focusPlate)
        addSubview(stack)
        addSubview(composerSlot)
        let padding = Self.horizontalPadding(theme)
        stackTop = stack.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: theme.cardContentInsetY)
        slotBottom = composerSlot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -theme.cardContentInsetY)
        emptySlot = composerSlot.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            stackTop,
            composerSlot.topAnchor.constraint(equalTo: stack.bottomAnchor),
            composerSlot.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            composerSlot.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            slotBottom,
            emptySlot,
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            focusPlate.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusPlate.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        bannerHost.translatesAutoresizingMaskIntoConstraints = false
        bodyHost.translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var isExpanded: Bool { shownExpanded == true }
    var isFocused: Bool { focused }

    /// The content inset inside the column: room for the focus and hover plate around the text.
    static func horizontalPadding(_ theme: ThemeTokens) -> CGFloat { theme.space3 }

    var plateLook: ReaderPlateView.Look { focusPlate.look }

    func attachComposer(_ view: NSView?) {
        guard view !== attachedComposer else { return }
        if let attachedComposer, attachedComposer.superview === composerSlot { attachedComposer.removeFromSuperview() }
        composerDivider.removeFromSuperview()
        attachedComposer = view
        emptySlot.isActive = view == nil
        defer {
            updateVerticalPadding()
            updatePlate()
        }
        guard let view else { return }
        view.removeFromSuperview()
        addSubview(composerDivider)
        composerSlot.addSubview(view)
        NSLayoutConstraint.activate([
            composerDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            composerDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            composerDivider.topAnchor.constraint(equalTo: composerSlot.topAnchor, constant: theme.space5),
            view.leadingAnchor.constraint(equalTo: composerSlot.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: composerSlot.trailingAnchor),
            view.topAnchor.constraint(equalTo: composerDivider.bottomAnchor),
            view.bottomAnchor.constraint(equalTo: composerSlot.bottomAnchor),
        ])
    }

    private func placePlate() {
        NSLayoutConstraint.deactivate(plateEdges)
        if let header {
            plateEdges = [focusPlate.topAnchor.constraint(equalTo: header.topAnchor, constant: -theme.space3),
                          focusPlate.bottomAnchor.constraint(equalTo: header.bandBottomAnchor, constant: theme.space3)]
        } else if let collapsedRow {
            plateEdges = [focusPlate.topAnchor.constraint(equalTo: collapsedRow.topAnchor, constant: theme.space1),
                          focusPlate.bottomAnchor.constraint(equalTo: collapsedRow.bottomAnchor, constant: -theme.space1)]
        } else {
            plateEdges = []
        }
        NSLayoutConstraint.activate(plateEdges)
    }

    private func updatePlate() {
        if focused && marksFocus {
            focusPlate.look = .focus
        } else if hovering, collapsedRow != nil {
            focusPlate.look = .hover
        } else {
            focusPlate.look = .none
        }
    }

    private func updateVerticalPadding() {
        let expanded = shownExpanded == true
        stackTop.constant = expanded ? theme.cardContentInsetY : 0
        slotBottom.constant = expanded || attachedComposer != nil ? -theme.cardContentInsetY : 0
    }

    func setTrailingAccessory(_ view: NSView?) {
        guard view !== trailingAccessory else { return }
        if let old = trailingAccessory, old.superview === stack {
            stack.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        trailingAccessory = view
        keepAccessoryLast()
    }

    private func keepAccessoryLast() {
        guard let view = trailingAccessory else { return }
        guard shownExpanded == true else {
            if view.superview === stack {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            return
        }
        guard stack.arrangedSubviews.last !== view else { return }
        if view.superview === stack {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        append(view)
    }

    func update(_ message: ReaderModel.Message, focused: Bool, marksFocus: Bool = true, now: Date) {
        guard let controller else { return }
        defer { keepAccessoryLast() }
        self.message = message
        if shownExpanded != message.isExpanded {
            shownExpanded = message.isExpanded
            rebuild(message, controller: controller, now: now)
        }
        if self.marksFocus != marksFocus {
            self.marksFocus = marksFocus
            updatePlate()
        }
        if self.focused != focused {
            self.focused = focused
            updatePlate()
            setAccessibilityLabel(focused ? baseLabel + ", focused" : baseLabel)
            setAccessibilitySelected(focused)
            updateActionsVisibility()
        }
        guard message.isExpanded else { return }
        header?.setAccessory(message.accessory)
        updateBanner(message)
        if shownBody != message.body {
            shownBody = message.body
            setBody(message.body, quotesExpanded: message.quotesExpanded)
        }
        plainBody?.update(quotesExpanded: message.quotesExpanded, zoom: controller.zoom)
        if let htmlBody, htmlBody.quotesExpanded != message.quotesExpanded {
            htmlBody.setQuotesExpanded(message.quotesExpanded)
        }
        updateAttachments(message, controller: controller)
    }

    private func rebuild(_ message: ReaderModel.Message, controller: ReaderViewController, now: Date) {
        recycleBody()
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        header = nil
        collapsedRow = nil
        banner = nil
        bannerState = nil
        shownBody = nil
        attachmentsStrip = nil
        shownTiles = nil
        inviteHost = nil
        let summary = message.summary
        let sender = summary.from.map(ReaderFormatting.display) ?? "unknown sender"
        if message.isExpanded {
            let me = controller.meAddresses.isEmpty ? [controller.meAddress.lowercased()] : controller.meAddresses
            let isVIP = summary.from.flatMap { from in
                controller.model.flatMap { model in
                    controller.router?.environment.vips.isVIP(from.email, account: model.thread.account)
                }
            } ?? false
            let header = MessageHeaderView(summary, me: me, theme: theme, format: controller.format,
                                           reader: controller.formatting, now: now, actions: headerActions(controller),
                                           isVIP: isVIP)
            header.onBackgroundClick = { [weak self] in self?.headerClicked() }
            self.header = header
            append(header)
            stack.setCustomSpacing(header.bodyGap, after: header)
            placeInviteCard(summary, controller: controller)
            append(bannerHost)
            stack.setCustomSpacing(theme.space4, after: bannerHost)
            append(bodyHost)
            stack.setCustomSpacing(theme.space4, after: bodyHost)
            append(note)
            note.isHidden = true
            bannerHost.isHidden = true
            baseLabel = "Message from \(sender)"
        } else {
            let row = CollapsedMessageView(message, theme: theme, format: controller.format, now: now)
            row.onClick = { [weak controller, key] in controller?.model?.toggle(key) }
            collapsedRow = row
            append(row)
            baseLabel = "Collapsed message from \(sender)"
        }
        placePlate()
        updatePlate()
        updateVerticalPadding()
        setAccessibilityLabel(focused ? baseLabel + ", focused" : baseLabel)
        updateActionsVisibility()
    }

    private func append(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func headerClicked() {
        guard let model = controller?.model else { return }
        if model.focusedMessage == key { model.toggle(key) } else { model.focus(key) }
    }

    private func headerActions(_ controller: ReaderViewController) -> MessageHeaderActions {
        var actions = MessageHeaderActions()
        let key = key
        actions.toggleDetails = { [weak self] in self?.superview?.needsLayout = true }
        actions.collapse = { [weak controller] in controller?.model?.toggle(key) }
        actions.perform = { [weak controller] id in controller?.performMessageAction(id, on: key) }
        actions.availability = { [weak controller] descriptor in
            controller?.availability(descriptor) ?? .init(isEnabled: false, help: descriptor.title)
        }
        actions.isOffered = { [weak controller] descriptor in controller?.decided(descriptor) != .hidden }
        actions.activateAccessory = { [weak controller] in controller?.model?.activateAccessory(key) }
        actions.buildMenu = { [weak self] menu in self?.fillMenu(menu) }
        actions.bindings = { [weak controller] descriptor in controller?.keyBindings(descriptor) ?? descriptor.defaultBindings }
        actions.tooltipHover = { [weak controller] button, inside in controller?.tooltipHover(button, inside: inside) }
        return actions
    }

    func fillMenu(_ menu: NSMenu) {
        guard let controller, let model = controller.model, let message = model.message(key) else { return }
        menu.addItem(.separator())
        if case .rendered(.html(let rendered)) = message.body, rendered.hasRemoteContent {
            switch message.imagesShown {
            case nil: menu.addItem(MenuAction("Load Images") { [weak model, key] in model?.loadImagesOnce(key) })
            case .once?: menu.addItem(MenuAction("Hide Images") { [weak model, key] in model?.hideImages(key) })
            default: break
            }
        }
        if case .rendered(.html) = message.body {
            let spacing = model.keepsOriginalSpacing(key)
            menu.addItem(MenuAction("Show Original Spacing", state: spacing ? .on : .off) { [weak model, key] in
                model?.toggleOriginalSpacing(key)
            })
            let original = message.colorOverride == .originalColors
            menu.addItem(MenuAction("Show Original Colors", state: original ? .on : .off) { [weak model, key] in
                guard let model else { return }
                Task { await model.setColorOverride(original ? nil : .originalColors, for: key) }
            })
            if ReaderAppearance.appearance(of: theme) == .dark {
                let dark = message.colorOverride == .darkColors
                menu.addItem(MenuAction("Show in Dark Colors", state: dark ? .on : .off) { [weak model, key] in
                    guard let model else { return }
                    Task { await model.setColorOverride(dark ? nil : .darkColors, for: key) }
                })
            }
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction("Collapse Message") { [weak model, key] in model?.toggle(key) })
    }


    private func placeInviteCard(_ summary: MessageSummary, controller: ReaderViewController) {
        guard InviteCenter.mayHaveCard(summary), let environment = controller.router?.environment,
              let thread = controller.model?.thread else { return }
        let center = environment.invites
        let host = InviteCardHostView(center: center, message: summary.id, theme: theme) { [weak controller] url in
            controller?.followLink(url, from: nil, modifiers: [])
        }
        host.onShowsCardChange = { [weak self] _ in self?.applyInviteMode() }
        inviteHost = host
        append(host)
        stack.setCustomSpacing(theme.space4, after: host)
        center.load(summary, in: thread)
        applyInviteMode()
    }

    private func applyInviteMode() {
        let card = showsInviteCard
        bodyHost.isHidden = card
        if card {
            bannerHost.isHidden = true
            note.isHidden = true
        } else {
            bannerHost.isHidden = banner == nil
            if case .rendered(.html(let rendered))? = shownBody { note.isHidden = !rendered.isTruncated }
        }
        if let message, let controller, message.isExpanded {
            shownTiles = nil
            updateAttachments(message, controller: controller)
        }
        superview?.needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateActionsVisibility()
        updatePlate()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateActionsVisibility()
        updatePlate()
    }

    private func updateActionsVisibility() {
        header?.setActionsRaised(hovering || focused)
    }

    private func updateBanner(_ message: ReaderModel.Message) {
        guard let controller, let model = controller.model else { return }
        var state = BannerState.none
        if case .rendered(.html(let rendered)) = message.body, rendered.hasRemoteContent {
            if let source = message.imagesShown {
                state = .shown(source, trackers: rendered.trackerCount)
            } else {
                state = .hidden(blocked: rendered.blockedCount, entry: model.alwaysEntry(for: key), remembers: model.remembersChoices)
            }
        }
        guard state != bannerState else { return }
        bannerState = state
        banner?.removeFromSuperview()
        banner = nil
        let key = key
        switch state {
        case .none:
            bannerHost.isHidden = true
            return
        case .hidden(let blocked, let entry, let remembers):
            banner = RemoteImagesBannerView(
                blockedCount: blocked, alwaysEntry: entry, remembers: remembers, theme: theme,
                load: { [weak model] in model?.loadImagesOnce(key) },
                always: { [weak model] in
                    guard let model else { return }
                    Task { await model.alwaysLoadImages(key) }
                })
        case .shown(let source, let trackers):
            banner = ImagesShownView(source: source, trackerCount: trackers, theme: theme,
                                     hide: { [weak model] in model?.hideImages(key) },
                                     stop: { [weak model] in
                                         guard let model else { return }
                                         Task { await model.stopAlwaysLoadingImages(key) }
                                     })
        }
        guard let banner else { return }
        bannerHost.isHidden = showsInviteCard
        bannerHost.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: bannerHost.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: bannerHost.trailingAnchor),
            banner.topAnchor.constraint(equalTo: bannerHost.topAnchor),
            banner.bottomAnchor.constraint(equalTo: bannerHost.bottomAnchor),
        ])
    }

    private func setBody(_ body: ReaderModel.BodyState, quotesExpanded: Bool) {
        guard let controller else { return }
        loadingTimer?.invalidate()
        note.isHidden = true
        if case .rendered(.html(let rendered)) = body {
            plainBody?.removeFromSuperview()
            plainBody = nil
            clearPlaceholders()
            let webKit = controller.webKit
            if !webKit.isPrepared {
                Task { [weak self] in
                    await webKit.prepare()
                    guard let self, self.shownBody == body else { return }
                    self.shownBody = nil
                    if let message = self.message {
                        self.update(message, focused: self.focused, marksFocus: self.marksFocus, now: controller.now())
                    }
                }
                return
            }
            let html = htmlBody ?? HTMLBodyView(controller: controller)
            if htmlBody == nil {
                htmlBody = html
                let key = key
                html.onToggleQuotes = { [weak controller] in controller?.model?.toggleQuotedText(key) }
                place([html])
            }
            let shown = html.show(rendered, imagesAllowed: message?.imagesShown != nil, inline: inlineSource(controller),
                                  quotesExpanded: quotesExpanded, width: max(bodyHost.bounds.width, 300), zoom: controller.zoom)
            if !shown {
                // Fail closed: no HTML without the block-all-remote rule list
                recycleBody()
                place([readerLabel("This message can't be shown safely right now.", theme.typeBody, theme.textDanger)])
            }
            note.isHidden = !rendered.isTruncated || showsInviteCard
            return
        }
        recycleBody()
        var views: [NSView] = []
        switch body {
        case .notLoaded, .fetching:
            let label = readerLabel("Loading…", theme.typeBody, theme.textTertiary)
            label.isHidden = true
            loadingTimer = Timer.scheduledTimer(withTimeInterval: theme.motionSpinnerDelay / 1000, repeats: false) { _ in
                MainActor.assumeIsolated { label.isHidden = false }
            }
            views = [label]
        case .failed:
            views = [readerLabel("Couldn't load this message.", theme.typeBody, theme.textDanger)]
        case .rendered(.empty):
            views = [readerLabel("(No content)", theme.typeBody, theme.textTertiary)]
        case .rendered(.plain(let document)):
            let view = PlainTextMessageView(document, theme: theme, quotesExpanded: quotesExpanded, zoom: controller.zoom)
            let key = key
            view.onLink = { [weak controller, weak view] url in
                if let view, let index = PlainTextMessageView.dateIndex(url) {
                    controller?.openDate(index, in: view)
                    return
                }
                controller?.followLink(url, from: nil, modifiers: [])
            }
            view.onToggleQuotes = { [weak controller] in controller?.model?.toggleQuotedText(key) }
            controller.markDates(in: view)
            view.keyHandler = { [weak controller] event in controller?.handleKey(event) ?? false }
            view.onSelectionChange = { [weak controller] text in controller?.model?.setQuoteSelection(text, in: key) }
            plainBody = view
            views = [view]
        case .rendered(.html):
            return
        }
        place(views)
    }

    private func place(_ views: [NSView]) {
        var previous: NSView?
        for view in views {
            bodyHost.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: bodyHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? bodyHost.topAnchor, constant: previous == nil ? 0 : 12),
            ])
            previous = view
        }
        previous?.bottomAnchor.constraint(equalTo: bodyHost.bottomAnchor).isActive = true
    }

    private func clearPlaceholders() {
        for view in bodyHost.subviews where view !== htmlBody { view.removeFromSuperview() }
    }

    private func inlineSource(_ controller: ReaderViewController) -> InlinePartSource? {
        guard let message, let model = controller.model else { return nil }
        let key = key
        let inline = message.summary.attachments.filter { $0.contentID != nil }
        guard !inline.isEmpty else { return nil }
        return InlinePartSource(attachments: inline) { [weak model] attachment in
            guard let model else { throw CancellationError() }
            return try await model.attachmentFile(attachment, of: key)
        }
    }

    func recycle() {
        recycleBody()
        loadingTimer?.invalidate()
    }

    private func recycleBody() {
        htmlBody?.recycleAll()
        htmlBody = nil
        plainBody = nil
        for view in bodyHost.subviews { view.removeFromSuperview() }
    }

    func setZoom(_ zoom: CGFloat) {
        htmlBody?.setZoom(zoom)
        if let plainBody, let message { plainBody.update(quotesExpanded: message.quotesExpanded, zoom: zoom) }
    }

    private func updateAttachments(_ message: ReaderModel.Message, controller: ReaderViewController) {
        let inlineShown: [String]
        if case .rendered(.html(let rendered)) = message.body { inlineShown = rendered.inlineContentIDs } else { inlineShown = [] }
        var tiles = ReaderFormatting.tiles(message.summary.attachments, shownInline: inlineShown)
        if showsInviteCard {
            tiles.removeAll { InviteCenter.calendarPart(of: [$0]) != nil }
        }
        guard tiles != shownTiles else { return }
        shownTiles = tiles
        if let attachmentsStrip {
            stack.removeArrangedSubview(attachmentsStrip)
            attachmentsStrip.removeFromSuperview()
            self.attachmentsStrip = nil
        }
        guard !tiles.isEmpty else { return }
        let strip = AttachmentStripView(tiles, message: key, theme: theme, formatting: controller.formatting)
        strip.delegate = self
        strip.dragWriter = controller.router?.environment.attachmentDrag
        strip.dragFailed = { [weak controller] attachment in
            controller?.post("Couldn't copy \(ReaderFormatting.safeFilename(attachment.filename))")
        }
        attachmentsStrip = strip
        append(strip)
    }

    var isSearchable: Bool { htmlBody?.current != nil || plainBody != nil }

    func clearFindSelection() async {
        if let web = htmlBody?.current { await web.clearSelection() }
        plainBody?.textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    func findNext(_ text: String, backwards: Bool, after plainMatch: inout Int) async -> CGRect? {
        if let web = htmlBody?.current {
            guard await web.findNext(text, backwards: backwards) else { return nil }
            return await web.selectionRect() ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        if let plainBody {
            let ranges = plainBody.ranges(of: text)
            guard !ranges.isEmpty else { return nil }
            let next = plainMatch < 0 ? (backwards ? ranges.count - 1 : 0) : plainMatch + (backwards ? -1 : 1)
            guard ranges.indices.contains(next) else { return nil }
            plainMatch = next
            return plainBody.select(ranges[next])
        }
        return nil
    }

    func bodyRectInDocument(_ rect: CGRect, document: NSView) -> CGRect {
        if let web = htmlBody?.current {
            let r = web.isFlipped ? rect : CGRect(x: rect.minX, y: web.bounds.height - rect.maxY, width: rect.width, height: rect.height)
            return web.convert(r, to: document)
        }
        if let plainBody { return plainBody.convert(rect, to: document) }
        return convert(bounds, to: document)
    }
}

extension MessageContainerView: AttachmentStripDelegate {
    func attachmentStrip(_ strip: AttachmentStripView, quickLook attachment: AttachmentInfo) {
        controller?.quickLook(attachment, of: key)
    }

    func attachmentStrip(_ strip: AttachmentStripView, open attachment: AttachmentInfo) {
        controller?.open(attachment, of: key)
    }

    func attachmentStrip(_ strip: AttachmentStripView, save attachments: [AttachmentInfo]) {
        controller?.save(attachments, of: key)
    }
}

@MainActor
final class HTMLBodyView: NSView {
    private weak var controller: ReaderViewController?
    private(set) var current: ReaderWebView?
    private(set) var incoming: ReaderWebView?
    private var bottom: NSLayoutConstraint?
    private(set) var quotesExpanded = false
    var onToggleQuotes: (() -> Void)?

    init(controller: ReaderViewController) {
        self.controller = controller
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ rendered: RenderedMessage, imagesAllowed: Bool, inline: InlinePartSource?, quotesExpanded: Bool,
              width: CGFloat, zoom: CGFloat) -> Bool {
        guard let controller else { return false }
        let wantedMode = controller.webKit.mode(for: rendered, imagesAllowed: imagesAllowed)
        if let current, current.rendered?.contentHash == rendered.contentHash, current.mode == wantedMode {
            if let incoming {
                controller.webKit.pool.recycle(incoming)
                self.incoming = nil
            }
            return true
        }
        if let incoming, incoming.rendered?.contentHash == rendered.contentHash, incoming.mode == wantedMode { return true }
        guard let view = ReaderWebView.make(for: rendered, width: width, webKit: controller.webKit,
                                            imagesAllowed: imagesAllowed, zoom: zoom) else { return false }
        view.awaitsLayoutWidth = true
        view.owner = controller
        view.inlineParts = inline
        view.onToggleQuotes = { [weak self] in self?.onToggleQuotes?() }
        self.quotesExpanded = quotesExpanded
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
        ])
        if let incoming { controller.webKit.pool.recycle(incoming) }
        if current == nil {
            install(view)
            view.onShown = { [weak self, weak view] in
                guard let self, let view else { return }
                self.applyQuotes(to: view)
                self.controller?.markDates(in: view)
            }
        } else {
            incoming = view
            view.onShown = { [weak self, weak view] in
                guard let self, let view, self.incoming === view else { return }
                self.swapIn(view)
                self.controller?.markDates(in: view)
            }
        }
        view.onHeightChange = { [weak self] _ in self?.superview?.needsLayout = true }
        return true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        current?.layoutWidthSettled()
        incoming?.layoutWidthSettled()
    }

    private func install(_ view: ReaderWebView) {
        bottom?.isActive = false
        bottom = bottomAnchor.constraint(equalTo: view.bottomAnchor)
        bottom?.isActive = true
        current = view
    }

    private func swapIn(_ view: ReaderWebView) {
        if let current { controller?.webKit.pool.recycle(current) }
        incoming = nil
        install(view)
        applyQuotes(to: view)
        superview?.needsLayout = true
    }

    private func applyQuotes(to view: ReaderWebView) {
        guard quotesExpanded else { return }
        Task { await view.setQuotesExpanded(true) }
    }

    func setQuotesExpanded(_ open: Bool) {
        quotesExpanded = open
        for view in [current, incoming].compactMap({ $0 }) { Task { await view.setQuotesExpanded(open) } }
    }

    func setZoom(_ zoom: CGFloat) {
        current?.setZoom(zoom)
        incoming?.setZoom(zoom)
    }

    func recycleAll() {
        guard let pool = controller?.webKit.pool else { return }
        for view in [current, incoming].compactMap({ $0 }) { pool.recycle(view) }
        current = nil
        incoming = nil
        bottom = nil
    }
}
