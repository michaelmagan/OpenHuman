import AppKit
import MailActions
import MailFeatures
import MailModel
import MailRender
import MailTheme
import MailUI
import OpenHumanCore

@MainActor
public final class ReaderViewController: NSViewController {
    let theme: ThemeTokens
    let format = ThreadRowFormatting()
    let formatting = ReaderFormatting()
    public let webKit: ReaderWebKit
    public let preferences: ReaderPreferences
    private let root = ReaderRootView()
    private let scrollView = NSScrollView()
    private let document = ReaderDocumentView()
    private let column = NSStackView()
    private let subjectRow = NSStackView()
    private let subjectLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private var renderedExpansion: [MessageKey: Bool] = [:]
    private var renderedShowsAll = false
    private(set) var messageViews: [MessageKey: MessageContainerView] = [:]
    private var pillViews: [[MessageKey]: OlderMessagesPillView] = [:]
    private(set) var aiAccessory: NSView?
    private var aiAccessoryResolved = false
    private var renderedItems: [ReaderModel.Item] = []
    private(set) var outgoingViews: [UUID: OutgoingMessageView] = [:]
    private var renderedOutgoing: [UUID] = []
    private(set) var inlineComposer: InlineComposerView?
    private(set) var schedulingSlot: (key: MessageKey, view: NSView)?
    private var followedDraft: RichTextDocument?
    private var documentObserver: (any NSObjectProtocol)?
    private var handledFocusScroll = 0
    private var handledFind = 0
    private var mouseMonitor: Any?
    private var scrollMonitor: Any?
    private var liveScrollObserver: (any NSObjectProtocol)?
    let newMessagesPill: NewMessagesPillView
    private var renderedPending = 0
    private var renderedCanAct = false
    private var keepFocusedVisibleUntil: Date?
    private var observation: ObservationLoop?
    private var zoomObservation: ObservationLoop?
    private var widthConstraint: NSLayoutConstraint?
    private var columnTop: NSLayoutConstraint?
    private var scrollRoom: NSLayoutConstraint?
    private(set) var summarySlack: CGFloat = 0
    let findBar: ReaderFindBar
    let linkPreview: LinkPreviewView
    let tooltipView: KeycapTooltipView
    private let tooltipTiming: KeycapTooltipTiming
    private var tooltipTask: Task<Void, Never>?
    private weak var tooltipButton: ReaderButton?
    private var tooltipHiddenAt: ContinuousClock.Instant?
    private var resignKeyObserver: (any NSObjectProtocol)?
    private var popover: NSPopover?
    private var find = FindState()
    private var prefetched = false
    public var meAddress = ""
    public var meAddresses: Set<String> = []
    public weak var host: ReaderHost?

    var openInBrowser: (URL, Bool) -> Void = { url, background in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !background
        NSWorkspace.shared.open(url, configuration: configuration)
    }
    var openFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var quickLook: (URL, String) -> Void = { QuickLookSession.shared.toggle($0, title: $1) }
    var chooseSaveDestination: ([AttachmentInfo], NSWindow?) async -> URL? = ReaderViewController.runSavePanel
    var confirmRiskyAttachment: (ReaderFormatting.AttachmentWarning, NSWindow?) async -> Bool =
        ReaderViewController.runAttachmentAlert
    var confirmLink: ((SuspiciousLink, ReaderWebView?, @escaping () -> Void) -> Void)?
    var now: () -> Date = { Date() }

    public var model: ReaderModel? {
        didSet { if model !== oldValue { bind() } }
    }

    public init(theme: ThemeTokens, webKit: ReaderWebKit = .shared, preferences: ReaderPreferences = .shared) {
        self.theme = theme
        self.webKit = webKit
        self.preferences = preferences
        findBar = ReaderFindBar(theme: theme)
        linkPreview = LinkPreviewView(theme: theme)
        newMessagesPill = NewMessagesPillView(theme: theme)
        tooltipView = KeycapTooltipView(theme: theme)
        tooltipTiming = KeycapTooltipTiming(theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var router: AppRouter? { (host ?? parent as? ReaderHost)?.readerRouter }

    static func headerTop(_ theme: ThemeTokens) -> CGFloat { theme.space7 }

    static func subjectStyle(_ theme: ThemeTokens) -> TypeStyle {
        var style = theme.typeSubject
        style.size = Double(NativeMetrics.Reader.subjectSize)
        style.weight = 600
        return style
    }

    static func metaStyle(_ theme: ThemeTokens) -> TypeStyle {
        var style = theme.typeMeta
        style.size = Double(NativeMetrics.Reader.metaSize)
        return style
    }

    /// The column's text inset: the title block, the summary and every message's content start here, and the focus
    /// plate fills the inset around a message's header.
    static func contentInset(_ theme: ThemeTokens) -> CGFloat { MessageContainerView.horizontalPadding(theme) }

    public override func loadView() {
        root.controller = self
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.bgCanvas.nsColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.scrollView = scrollView
        document.controller = self

        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)

        subjectLabel.font = Self.subjectStyle(theme).font
        subjectLabel.textColor = theme.textPrimary.nsColor
        subjectLabel.maximumNumberOfLines = 3
        subjectLabel.lineBreakMode = .byWordWrapping
        subjectLabel.isSelectable = true
        subjectLabel.translatesAutoresizingMaskIntoConstraints = false
        subjectLabel.setAccessibilityRole(.staticText)
        subjectLabel.setAccessibilityIdentifier("reader.subject")
        subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subjectLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metaLabel.font = Self.metaStyle(theme).font
        metaLabel.textColor = theme.textSecondary.nsColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subjectRow.orientation = .vertical
        subjectRow.alignment = .leading
        subjectRow.spacing = theme.space3
        subjectRow.translatesAutoresizingMaskIntoConstraints = false
        subjectRow.addArrangedSubview(subjectLabel)
        subjectRow.addArrangedSubview(metaLabel)
        subjectRow.setCustomSpacing(theme.space2, after: subjectLabel)
        subjectLabel.widthAnchor.constraint(equalTo: subjectRow.widthAnchor).isActive = true
        metaLabel.widthAnchor.constraint(lessThanOrEqualTo: subjectRow.widthAnchor).isActive = true

        root.addSubview(scrollView)
        root.addSubview(newMessagesPill)
        root.addSubview(findBar)
        root.addSubview(linkPreview)
        root.addSubview(tooltipView)
        findBar.isHidden = true
        findBar.onFind = { [weak self] text, backwards in self?.findNext(text, backwards: backwards) }
        findBar.onClose = { [weak self] in self?.closeFind() }
        newMessagesPill.onClick = { [weak self] in self?.model?.showNewMessages() }

        let clip = scrollView.contentView
        let maxWidth = NativeMetrics.Reader.maxColumnWidth
        let preferred = column.widthAnchor.constraint(equalToConstant: maxWidth)
        preferred.priority = NSLayoutConstraint.Priority(490)
        let inset = column.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 40)
        widthConstraint = inset
        let top = column.topAnchor.constraint(equalTo: document.topAnchor, constant: Self.headerTop(theme))
        columnTop = top
        let room = document.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor)
        scrollRoom = room
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            room,
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            preferred,
            inset,
            top,
            column.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -max(CGFloat(theme.space7), toastBand)),
            findBar.topAnchor.constraint(equalTo: root.topAnchor, constant: theme.space3),
            findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -theme.space5),
            linkPreview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: theme.space3),
            linkPreview.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -theme.space3),
            linkPreview.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -theme.space3),
            newMessagesPill.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            newMessagesPill.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: newMessagesPill.margin - toastBand),
            newMessagesPill.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor),
        ])
        view = root
        document.postsFrameChangedNotifications = true
        documentObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.documentGrew() }
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.focusMessage(clickedBy: event) }
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.userScrolled(by: event) }
            return event
        }
        liveScrollObserver = NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                                                                    object: scrollView, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.userScrolled() }
        }
        resignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                                                   queue: .main) { [weak self] note in
            let resigned = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let resigned, self.view.window.map(ObjectIdentifier.init) == resigned else { return }
                self.hideTooltip()
            }
        }
        router?.environment.renderQueue.setRenderer(ReaderAppearance.renderer(for: theme))
        zoomObservation = ObservationLoop.observe { [weak self] in self?.applyZoom() }
        bind()
    }

    isolated deinit {
        tooltipTask?.cancel()
        for observer in [documentObserver, liveScrollObserver, resignKeyObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        for monitor in [mouseMonitor, scrollMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        let side: CGFloat = (view.window?.frame.width ?? 1360) < 1100 ? 24 : 40
        if widthConstraint?.constant != side { widthConstraint?.constant = side }
    }

    public var focusView: NSView { document }

    private func bind() {
        observation?.cancel()
        clear()
        guard isViewLoaded, let model else { return }
        prefetched = false
        handledFocusScroll = model.focusScrollRequest
        handledFind = model.findRequest
        renderedPending = model.pendingMessages.count
        renderedCanAct = router?.active != nil
        // The headers' Reply, Reply All and Forward open through the compose manager and are not offered until it runs
        _ = router?.environment.compose
        Task { await webKit.prepare() }
        model.useRenderer(ReaderAppearance.renderer(for: theme))
        observation = ObservationLoop.observe { [weak self] in self?.render() }
    }

    private func clear() {
        hideTooltip()
        inlineComposer = nil
        schedulingSlot = nil
        for view in column.arrangedSubviews { column.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in messageViews.values { view.recycle() }
        messageViews = [:]
        pillViews = [:]
        outgoingViews = [:]
        renderedOutgoing = []
        aiAccessory = nil
        aiAccessoryResolved = false
        summarySlack = 0
        columnTop?.constant = Self.headerTop(theme)
        scrollRoom?.constant = 0
        renderedItems = []
        renderedExpansion = [:]
        renderedShowsAll = false
        keepFocusedVisibleUntil = nil
        newMessagesPill.update(count: 0, key: nil)
        renderedCanAct = false
        closeFind()
        linkPreview.show(nil, suspicious: nil)
        popover?.close()
        if isViewLoaded { scrollView.contentView.scroll(to: .zero) }
    }

    private func render() {
        guard let model else { return }
        _ = model.revision
        if let notice = model.notice {
            post(notice)
            model.clearNotice()
        }
        let messages = model.messages
        if column.arrangedSubviews.isEmpty {
            column.addArrangedSubview(subjectRow)
            subjectRow.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * Self.contentInset(theme)).isActive = true
            column.setCustomSpacing(theme.space8, after: subjectRow)
        }
        if !aiAccessoryResolved { addAIAccessory(model) }
        let subject = model.state == .missing ? "This conversation is no longer here." : model.subject
        if subjectLabel.stringValue != subject { subjectLabel.stringValue = subject }
        renderMeta(model)

        let expansionAnchor = captureExpansionAnchor(model)
        let docked = dockedSession(model)
        if docked != nil { model.noteInteraction() }
        let anchor = docked.flatMap { composerAnchor($0, in: model) }
        if let anchor, !hasPlaced(docked) { model.reveal(anchor) }
        let items = model.items
        let outgoing = outgoingMessages(model)
        let sentHere = outgoing.first { !renderedOutgoing.contains($0.id) && $0.id == inlineComposer?.session.id }?.id
        if items != renderedItems || outgoing.map(\.id) != renderedOutgoing {
            var rows: [NSView] = []
            var kept: [MessageKey: MessageContainerView] = [:]
            var keptPills: [[MessageKey]: OlderMessagesPillView] = [:]
            var keptOutgoing: [UUID: OutgoingMessageView] = [:]
            for item in items {
                switch item {
                case .message(let key):
                    let view = messageViews[key] ?? MessageContainerView(key: key, controller: self)
                    rows.append(view)
                    kept[key] = view
                case .olderMessages(let keys):
                    let pill = pillViews[keys] ?? OlderMessagesPillView(count: keys.count, theme: theme)
                    pill.onClick = { [weak model] in model?.showAllMessages() }
                    rows.append(pill)
                    keptPills[keys] = pill
                }
            }
            for entry in outgoing {
                let view = outgoingViews[entry.id] ?? OutgoingMessageView(entry, theme: theme, format: format)
                rows.append(view)
                keptOutgoing[entry.id] = view
            }
            arrange(rows)
            for (key, view) in messageViews where kept[key] == nil { view.recycle() }
            messageViews = kept
            pillViews = keptPills
            outgoingViews = keptOutgoing
            renderedItems = items
            renderedOutgoing = outgoing.map(\.id)
        }
        let date = now()
        let marksFocus = messages.count > 1
        for message in messages {
            messageViews[message.id]?.update(message, focused: message.id == model.focusedMessage, marksFocus: marksFocus,
                                             now: date)
        }
        for entry in outgoing { outgoingViews[entry.id]?.update(entry) }
        let canAct = router?.active != nil
        if canAct != renderedCanAct {
            renderedCanAct = canAct
            for view in messageViews.values { view.header?.refreshMessageActions() }
        }
        placeInlineComposer(docked, anchor: anchor, model: model)
        placeSchedulingSlot(model)
        restoreExpansionAnchor(expansionAnchor)
        if let sentHere, let card = outgoingViews[sentHere] { scrollClearOfToast(card) }
        let pending = model.pendingMessages.count
        let revealed = renderedPending > 0 && pending == 0
        renderedPending = pending
        newMessagesPill.update(count: pending, key: router?.environment.actions.descriptor(.showNewMessages)?.shortcutHint)
        if model.focusScrollRequest != handledFocusScroll {
            handledFocusScroll = model.focusScrollRequest
            scrollFocusedIntoView()
            if revealed { keepFocusedVisibleUntil = Date().addingTimeInterval(2) }
        }
        if model.findRequest != handledFind {
            handledFind = model.findRequest
            showFind()
        }
        if model.state == .loaded, !prefetched {
            prefetched = true
            prefetchNeighbors(model)
        }
    }

    private func arrange(_ rows: [NSView]) {
        let hadFocus = inlineComposer?.hasKeyboardFocus == true
        let fixed = column.arrangedSubviews.filter { $0 === subjectRow || $0 === aiAccessory }
        let wanted = Set(rows.map(ObjectIdentifier.init))
        for view in column.arrangedSubviews where !fixed.contains(view) && !wanted.contains(ObjectIdentifier(view)) {
            column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (offset, view) in rows.enumerated() {
            let index = fixed.count + offset
            let current = column.arrangedSubviews
            if index < current.count, current[index] === view { continue }
            if view.superview === column {
                column.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            column.insertArrangedSubview(view, at: index)
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        if hadFocus, let composer = inlineComposer, !composer.hasKeyboardFocus { composer.session.requestFocus() }
    }

    private func outgoingMessages(_ model: ReaderModel) -> [OutgoingMessage] {
        router?.environment.composeIfStarted?.outgoingMessages(in: model.thread, shown: model.messages.map(\.id)) ?? []
    }

    private func dockedSession(_ model: ReaderModel) -> ComposeSession? {
        guard let manager = router?.environment.composeIfStarted, let session = manager.dockedSession(for: model.thread),
              session.isOpen else { return nil }
        _ = session.focusRequest
        manager.dockedComposerHasFocus = { [weak self] session in
            guard let composer = self?.inlineComposer, composer.session === session else { return false }
            return composer.hasKeyboardFocus
        }
        return session
    }

    private func composerAnchor(_ session: ComposeSession, in model: ReaderModel) -> MessageKey? {
        if let id = session.replyToGmailMessageID, let message = model.messages.first(where: { $0.id.gmailMessageID == id }) {
            return message.id
        }
        return model.messages.last?.id
    }

    private func hasPlaced(_ session: ComposeSession?) -> Bool {
        guard let session, let inlineComposer else { return false }
        return inlineComposer.session === session && inlineComposer.hostMessage.map { messageViews[$0.key] === $0 } == true
    }

    private func placeInlineComposer(_ session: ComposeSession?, anchor: MessageKey?, model: ReaderModel) {
        guard let session, model.state == .loaded, let manager = router?.environment.composeIfStarted else {
            removeInlineComposer()
            return
        }
        if let current = inlineComposer, current.session !== session { removeInlineComposer() }
        let composer = inlineComposer ?? InlineComposerView(session: session, manager: manager, theme: theme)
        inlineComposer = composer
        let host = anchor.flatMap { messageViews[$0] } ?? model.messages.last.flatMap { messageViews[$0.id] }
        if let host, composer.hostMessage !== host {
            let hadFocus = composer.hasKeyboardFocus
            composer.hostMessage?.attachComposer(nil)
            host.attachComposer(composer)
            if hadFocus { session.requestFocus() }
        }
        if session.focusRequest != session.focusHandled {
            view.layoutSubtreeIfNeeded()
            composer.focusIfRequested { [weak self, weak composer] in
                self?.followedDraft = composer?.session.document
                self?.scrollComposerIntoView()
            }
        }
    }

    private func placeSchedulingSlot(_ model: ReaderModel) {
        let environment = router?.environment
        let scheduling = environment?.scheduling
        let center = environment?.modules.modules.contains(.ai) == true ? environment?.ai : nil
        guard model.state == .loaded, scheduling != nil || center != nil, let environment, let newest = model.messages.last,
              let host = messageViews[newest.id] else {
            if let slot = schedulingSlot { messageViews[slot.key]?.setTrailingAccessory(nil) }
            schedulingSlot = nil
            return
        }
        if let slot = schedulingSlot, slot.key == newest.id {
            host.setTrailingAccessory(slot.view)
            return
        }
        if let slot = schedulingSlot { messageViews[slot.key]?.setTrailingAccessory(nil) }
        let quick = center.map { QuickReplySlot(center: $0, environment: environment, message: newest.id) }
        let view = SchedulingSlotHostView(assistant: scheduling, quickReplies: quick, thread: model.thread, theme: theme)
        schedulingSlot = (newest.id, view)
        host.setTrailingAccessory(view)
    }

    private func documentGrew() {
        if let until = keepFocusedVisibleUntil {
            if Date() < until {
                DispatchQueue.main.async { [weak self] in
                    self?.view.window?.layoutIfNeeded()
                    self?.scrollFocusedIntoView()
                }
            } else {
                keepFocusedVisibleUntil = nil
            }
        }
        guard let draft = followedDraft else { return }
        guard let composer = inlineComposer, composer.hasKeyboardFocus, composer.session.document == draft else {
            followedDraft = nil
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.layoutIfNeeded()
            self?.scrollComposerIntoView()
        }
    }

    private func removeInlineComposer() {
        guard let composer = inlineComposer else { return }
        let hadFocus = composer.hasKeyboardFocus
        composer.hostMessage?.attachComposer(nil)
        composer.removeFromSuperview()
        inlineComposer = nil
        if hadFocus { view.window?.makeFirstResponder(document) }
    }

    func scrollComposerIntoView() {
        guard let composer = inlineComposer else { return }
        view.layoutSubtreeIfNeeded()
        let frame = composer.convert(composer.bounds, to: document)
        let visible = scrollView.contentView.documentVisibleRect
        let target = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(frame.height, visible.height))
        guard !visible.contains(target) else { return }
        document.scrollToVisible(target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func performMessageAction(_ action: ActionID, on key: MessageKey) {
        model?.focus(key)
        perform(action)
    }

    private func addAIAccessory(_ model: ReaderModel) {
        guard let router else { return }
        aiAccessoryResolved = true
        guard let line = AIReaderAccessory.view(reader: model, environment: router.environment, theme: theme) else { return }
        column.insertArrangedSubview(line, at: 1)
        line.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * Self.contentInset(theme)).isActive = true
        aiAccessory = line
        guard let summary = line as? ThreadSummaryLineView else {
            applySummaryGaps(.settled, after: line)
            return
        }
        summary.onStageChange = { [weak self, weak summary] stage in
            guard let self, let summary else { return }
            self.applySummaryGaps(stage, after: summary)
        }
        summary.applyChange = { [weak self, weak summary] change in
            guard let self, let summary else { return change() }
            self.keepCardsInPlace(around: summary, change)
        }
        applySummaryGaps(summary.stage, after: summary)
    }

    private func applySummaryGaps(_ stage: SummaryBlockLayout.Stage, after line: NSView) {
        let gaps = SummaryBlockLayout.gaps(stage: stage, theme: theme)
        column.setCustomSpacing(gaps.afterSubject, after: subjectRow)
        column.setCustomSpacing(gaps.afterBlock, after: line)
    }

    private func keepCardsInPlace(around line: ThreadSummaryLineView, _ change: () -> Void) {
        let rows = column.arrangedSubviews
        guard isViewLoaded, let index = rows.firstIndex(where: { $0 === line }), index + 1 < rows.count else {
            change()
            return
        }
        let card = rows[index + 1]
        view.layoutSubtreeIfNeeded()
        let before = card.convert(card.bounds, to: document).minY
        let old = line.stage
        change()
        view.layoutSubtreeIfNeeded()
        let delta = card.convert(card.bounds, to: document).minY - before
        guard abs(delta) > 0.5 else { return }
        let clip = scrollView.contentView
        let absorbed = SummaryBlockLayout.absorb(delta: delta, slack: summarySlack, scrollOffset: clip.bounds.origin.y,
                                                 anchored: SummaryBlockLayout.anchors(from: old, to: line.stage))
        guard absorbed.slack != summarySlack || absorbed.scroll != 0 else { return }
        summarySlack = absorbed.slack
        columnTop?.constant = Self.headerTop(theme) + absorbed.slack
        if absorbed.scroll > 0 {
            scrollRoom?.constant = max(scrollRoom?.constant ?? 0, clip.bounds.origin.y + absorbed.scroll)
        }
        view.layoutSubtreeIfNeeded()
        guard absorbed.scroll != 0 else { return }
        let maxY = max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, clip.bounds.origin.y + absorbed.scroll), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    func keyBindings(_ descriptor: ActionDescriptor) -> [KeyBinding] {
        (router?.environment.actions.descriptor(descriptor.id) ?? descriptor).defaultBindings
    }

    func tooltipHover(_ button: ReaderButton, inside: Bool) {
        guard inside else {
            if button === tooltipButton || tooltipTask != nil { hideTooltip() }
            return
        }
        guard button.tip != nil else { return }
        tooltipTask?.cancel()
        tooltipTask = nil
        let showing = !tooltipView.isHidden
        let since: Duration? = showing ? .zero : tooltipHiddenAt.map { ContinuousClock.now - $0 }
        let wait = tooltipTiming.wait(sinceLastHidden: since)
        tooltipButton = button
        guard wait > .zero else {
            showTooltipNow(for: button)
            return
        }
        tooltipTask = Task { @MainActor [weak self, weak button] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, let button, self.tooltipButton === button else { return }
            self.tooltipTask = nil
            self.showTooltipNow(for: button)
        }
    }

    func showTooltipNow(for button: ReaderButton) {
        guard let tip = button.tip, isViewLoaded, button.window === view.window, !button.isHiddenOrHasHiddenAncestor else { return }
        tooltipTask?.cancel()
        tooltipTask = nil
        tooltipButton = button
        view.layoutSubtreeIfNeeded()
        let pill = KeycapTooltipLayout.frame(anchor: button.convert(button.bounds, to: root),
                                             size: tooltipView.pillSize(for: tip), bounds: root.bounds,
                                             gap: KeycapTooltipView.gap, margin: KeycapTooltipView.margin,
                                             flipped: root.isFlipped)
        tooltipView.show(tip, at: pill)
    }

    func hideTooltip() {
        tooltipTask?.cancel()
        tooltipTask = nil
        tooltipButton = nil
        guard !tooltipView.isHidden else { return }
        tooltipView.hide()
        tooltipHiddenAt = .now
    }

    private func renderMeta(_ model: ReaderModel) {
        let me = meAddresses.isEmpty ? [meAddress.lowercased()] : meAddresses
        let text = ReaderFormatting.titleMeta(model.messages.map(\.summary), me: Set(me))
        let line = NSMutableAttributedString(string: text, attributes: [
            .font: Self.metaStyle(theme).font, .foregroundColor: theme.textSecondary.nsColor,
        ])
        var listChips: [ThreadRowChip]?
        if let list = router?.active?.list, let row = list.row(for: model.thread) { listChips = list.chips(for: row) }
        Self.appendMetaChips(Self.metaChips(listChips: listChips, returnedByReminder: model.returnedByReminder),
                             to: line, theme: theme)
        if metaLabel.attributedStringValue != line { metaLabel.attributedStringValue = line }
        metaLabel.menu = autoLabelChipMenu()
        metaLabel.isHidden = line.length == 0
        metaLabel.setAccessibilityLabel(Self.metaAccessibilityLabel(line))
    }

    static func metaChips(listChips: [ThreadRowChip]?, returnedByReminder: Bool) -> [ThreadRowChip] {
        listChips ?? (returnedByReminder ? [.reminderReturned] : [])
    }

    static func appendMetaChips(_ chips: [ThreadRowChip], to line: NSMutableAttributedString, theme: ThemeTokens) {
        for chip in chips where chip.kind != .overflow {
            let dotColor: NSColor = switch chip.kind {
            case .important, .vip, .returned: theme.textWarning.nsColor
            case .label: chip.color.flatMap { ThemeColor(hex: $0)?.nsColor } ?? theme.textTertiary.nsColor
            default: theme.textTertiary.nsColor
            }
            let dotFont = NSFont.systemFont(ofSize: max(6, theme.typeMeta.size * 0.6))
            line.append(NSAttributedString(string: "  ●", attributes: [
                .font: dotFont, .foregroundColor: dotColor,
                .baselineOffset: (theme.typeMeta.font.xHeight - dotFont.xHeight) / 2,
            ]))
            line.append(NSAttributedString(string: " " + chip.title, attributes: [
                .font: theme.typeMeta.font,
                .foregroundColor: (chip.isQuiet ? theme.textTertiary : theme.textSecondary).nsColor,
            ]))
        }
    }

    static func metaAccessibilityLabel(_ line: NSAttributedString) -> String {
        line.string.replacingOccurrences(of: "●", with: "")
    }

    func autoLabelChipMenu() -> NSMenu? {
        guard let descriptor = ActionCatalog.descriptor(.autoLabelWrong), let (_, context) = actionContext(),
              decided(descriptor) == .enabled else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = MenuAction(ActionRules.title(for: descriptor, in: context)) { [weak self] in
            self?.perform(.autoLabelWrong, source: .menu)
        }
        item.identifier = NSUserInterfaceItemIdentifier(descriptor.id.rawValue)
        menu.addItem(item)
        return menu
    }

    private func captureExpansionAnchor(_ model: ReaderModel) -> (key: MessageKey, y: CGFloat)? {
        var expansion: [MessageKey: Bool] = [:]
        for message in model.messages { expansion[message.id] = message.isExpanded }
        defer {
            renderedExpansion = expansion
            renderedShowsAll = model.showsAllMessages
        }
        guard !renderedExpansion.isEmpty, expansion != renderedExpansion || model.showsAllMessages != renderedShowsAll,
              let key = model.focusedMessage, let view = messageViews[key], view.superview === column else { return nil }
        return (key, view.convert(view.bounds, to: document).minY - scrollView.contentView.bounds.origin.y)
    }

    private func restoreExpansionAnchor(_ anchor: (key: MessageKey, y: CGFloat)?) {
        guard let anchor, let view = messageViews[anchor.key], view.superview === column else { return }
        self.view.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let delta = view.convert(view.bounds, to: document).minY - clip.bounds.origin.y - anchor.y
        guard abs(delta) > 0.5 else { return }
        let maxY = max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, clip.bounds.origin.y + delta), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    private func actionContext() -> (AppRouter, ActionContext)? {
        guard let model, let router, router.active != nil else { return nil }
        return (router, ReaderActions.context(host: router, thread: model.thread, lastMessage: model.messages.last?.id,
                                              isStarred: model.isStarred))
    }

    /// The conversation's toolbar actions, as the window toolbar shows them for this reader.
    var toolbarActions: ReaderToolbarActions {
        guard let model, let router else { return .empty }
        return ReaderToolbarActions(router: router, reader: model)
    }

    func decided(_ descriptor: ActionDescriptor) -> ActionAvailability {
        guard let (router, context) = actionContext() else { return .hidden }
        return ReaderActions.decide(descriptor, registry: router.environment.actions, host: router, context: context)
    }

    func availability(_ descriptor: ActionDescriptor) -> ReaderActions.Availability {
        guard let (_, context) = actionContext() else { return ReaderActions.availability(descriptor, decided: decided(descriptor)) }
        return ReaderActions.availability(descriptor, decided: decided(descriptor),
                                          title: ActionRules.title(for: descriptor, in: context))
    }

    var subjectView: NSView { subjectLabel }
    var subjectContainer: NSView { subjectRow }
    var metaLabelView: NSTextField { metaLabel }
    var metaText: String { metaLabel.attributedStringValue.string }

    func perform(_ action: ActionID, source: ActionSource = .toolbar) {
        guard let router else { return }
        router.performClick(action, source: source)
    }

    func post(_ message: String) {
        router?.environment.notices.post(message, style: .info, duration: NoticeCenter.infoDuration)
    }

    private func prefetchNeighbors(_ model: ReaderModel) {
        guard let rows = router?.active?.list?.rows, let index = rows.firstIndex(where: { $0.id == model.thread }) else { return }
        let next = rows[(index + 1)...].prefix(2).map(\.id)
        model.prefetch(Array(next))
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard let model, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option), let chars = event.charactersIgnoringModifiers else { return false }
        switch event.keyCode {
        case 125 where !event.modifierFlags.contains(.shift): return model.focusNext()
        case 126 where !event.modifierFlags.contains(.shift): return model.focusPrevious()
        default: break
        }
        switch chars {
        case "n":
            model.focusNext()
        case "p":
            model.focusPrevious()
        case "o":
            model.toggleFocused()
        case "O":
            model.expandAll()
        case ".":
            model.toggleQuotedText()
        case "I":
            model.showImages()
        default:
            return false
        }
        return true
    }

    private static func isInside(_ composer: NSView?, _ responder: NSResponder?) -> Bool {
        guard let composer, var view = responder as? NSView else { return false }
        while true {
            if view === composer { return true }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard model != nil, isViewLoaded, !view.isHiddenOrHasHiddenAncestor else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if chars == "f" || chars == "g", view.window?.firstResponder is ComposerTextView { return false }
        if chars == "f" || (chars == "g" && !flags.contains(.shift)) || chars == "s" || chars == "=" || chars == "+"
            || chars == "-" || chars == "0", Self.isInside(inlineComposer, view.window?.firstResponder) { return false }
        if chars == "f", flags.contains(.shift) { return false }
        switch chars {
        case "f": showFind()
        case "g": findAgain(backwards: flags.contains(.shift))
        case "=", "+": preferences.zoomIn()
        case "-": preferences.zoomOut()
        case "0": preferences.resetZoom()
        case "s":
            guard let key = model?.focusedMessage, let view = messageViews[key], let strip = view.attachmentsStrip else { return false }
            save(strip.attachments, of: key)
        default: return false
        }
        return true
    }

    func scrollFocusedIntoView() {
        guard let key = model?.focusedMessage, let container = messageViews[key] else { return }
        scrollIntoView(container)
    }

    private func scrollIntoView(_ target: NSView) {
        view.layoutSubtreeIfNeeded()
        let frame = target.convert(target.bounds, to: document)
        let visible = scrollView.contentView.documentVisibleRect
        guard !visible.contains(NSRect(x: frame.minX, y: frame.minY, width: 1, height: min(frame.height, visible.height))) else { return }
        let y = min(max(0, frame.minY - theme.space5), max(0, document.frame.height - visible.height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var toastBand: CGFloat { theme.component.toast.bottom + theme.component.toast.height + theme.space3 }

    private func scrollClearOfToast(_ target: NSView) {
        view.layoutSubtreeIfNeeded()
        let frame = target.convert(target.bounds, to: document)
        let visible = scrollView.contentView.documentVisibleRect
        let room = max(0, visible.height - toastBand)
        guard frame.minY < visible.minY || frame.maxY > visible.minY + room else { return }
        let y = min(frame.maxY - room, frame.minY - theme.space5)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), max(0, document.frame.height - visible.height))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var visibleDocumentRect: NSRect { scrollView.contentView.documentVisibleRect }

    func userScrolled() {
        hideTooltip()
        keepFocusedVisibleUntil = nil
        followedDraft = nil
        model?.noteInteraction()
    }

    private func userScrolled(by event: NSEvent) {
        guard event.type == .scrollWheel, isViewLoaded, let window = view.window, event.window === window,
              !view.isHiddenOrHasHiddenAncestor,
              scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil)) else { return }
        userScrolled()
    }

    func focusMessage(clickedBy event: NSEvent) {
        guard let key = message(clickedBy: event) else { return }
        model?.focus(key)
    }

    func message(clickedBy event: NSEvent) -> MessageKey? {
        guard event.type == .leftMouseDown, isViewLoaded, let window = view.window, event.window === window,
              !view.isHiddenOrHasHiddenAncestor, let frameView = window.contentView?.superview,
              var hit = frameView.hitTest(event.locationInWindow), hit.isDescendant(of: document) else { return nil }
        var pressedControl = false
        while hit !== document {
            if hit is NSButton || (hit as? NSTextField)?.isSelectable == true { pressedControl = true }
            if hit is CollapsedMessageView { return nil }
            if hit is MessageHeaderView, !pressedControl { return nil }
            if let container = hit as? MessageContainerView { return container.key }
            guard let parent = hit.superview else { return nil }
            hit = parent
        }
        return nil
    }

    private func applyZoom() {
        let zoom = CGFloat(preferences.textZoom)
        for view in messageViews.values { view.setZoom(zoom) }
    }

    var zoom: CGFloat { CGFloat(preferences.textZoom) }

    private struct FindState {
        var text = ""
        var body = -1
        var plainMatch = -1
    }

    func showFind() {
        MotionAnimator.setVisible(findBar, true, enter: theme.motion(theme.motionEnterFast),
                                  offset: -CGFloat(theme.component.popover.enterOffset))
        view.window?.makeFirstResponder(findBar.field)
        findBar.field.selectText(nil)
    }

    func closeFind() {
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        findBar.status.stringValue = ""
        find = FindState()
        if let window = view.window, window.firstResponder === findBar.field.currentEditor() || window.firstResponder === findBar.field {
            window.makeFirstResponder(document)
        }
    }

    private func findAgain(backwards: Bool) {
        if findBar.isHidden || findBar.field.stringValue.isEmpty { showFind(); return }
        findNext(findBar.field.stringValue, backwards: backwards)
    }

    var searchableBodies: [MessageContainerView] {
        guard let model else { return [] }
        return model.messages.compactMap { message in
            guard message.isExpanded, let view = messageViews[message.id], view.isSearchable else { return nil }
            return view
        }
    }

    func findNext(_ text: String, backwards: Bool) {
        Task { await findNextAsync(text, backwards: backwards) }
    }

    @discardableResult
    func findNextAsync(_ text: String, backwards: Bool) async -> Bool {
        let bodies = searchableBodies
        guard !text.isEmpty, !bodies.isEmpty else {
            findBar.status.stringValue = text.isEmpty ? "" : "Not found"
            return false
        }
        if text != find.text || find.body >= bodies.count {
            find = FindState(text: text, body: -1, plainMatch: -1)
            for body in bodies { await body.clearFindSelection() }
        }
        var index = find.body < 0 ? (backwards ? bodies.count - 1 : 0) : find.body
        var entering = find.body < 0
        for _ in 0...(bodies.count) {
            let body = bodies[index]
            if entering {
                await body.clearFindSelection()
                find.plainMatch = -1
            }
            var plainMatch = find.plainMatch
            let rect = await body.findNext(text, backwards: backwards, after: &plainMatch)
            find.plainMatch = plainMatch
            if let rect {
                find.body = index
                findBar.status.stringValue = ""
                scrollToMatch(rect, in: body)
                return true
            }
            index = backwards ? (index - 1 + bodies.count) % bodies.count : (index + 1) % bodies.count
            entering = true
        }
        find = FindState(text: text, body: -1, plainMatch: -1)
        findBar.status.stringValue = "Not found"
        return false
    }

    private func scrollToMatch(_ rect: CGRect, in body: MessageContainerView) {
        userScrolled()
        let inDocument = body.bodyRectInDocument(rect, document: document)
        document.scrollToVisible(inDocument.insetBy(dx: 0, dy: -80))
    }

    func followLink(_ url: URL, from web: ReaderWebView?, modifiers: NSEvent.ModifierFlags) {
        let action = ReaderLinkAction.resolve(url)
        let go: () -> Void = { [weak self] in self?.perform(action, background: modifiers.contains(.command)) }
        if let suspicious = web?.rendered?.suspiciousLink(for: url) {
            presentConfirmation(suspicious, from: web, open: go)
        } else {
            go()
        }
    }

    private func perform(_ action: ReaderLinkAction, background: Bool) {
        switch action {
        case .openInBrowser(let url):
            openInBrowser(url, background)
        default:
            if let router, let message = action.follow(with: router) {
                post(message)
            } else if router == nil, action == .unsupported {
                NSSound.beep()
            }
        }
    }

    private func presentConfirmation(_ link: SuspiciousLink, from web: ReaderWebView?, open: @escaping () -> Void) {
        if let confirmLink {
            confirmLink(link, web, open)
            return
        }
        popover?.close()
        view.layoutSubtreeIfNeeded()
        let content = LinkConfirmationViewController(warning: ReaderFormatting.warning(for: link), theme: theme)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        content.onCancel = { [weak popover] in popover?.close() }
        content.onOpen = { [weak popover] in
            popover?.close()
            open()
        }
        self.popover = popover
        let anchor: NSView = web ?? document
        var rect = anchor.bounds.insetBy(dx: 0, dy: 0)
        if let web, let hovered = web.hoveredLink, link.matches(hovered.url), let r = hovered.rect {
            let z = web.pageZoom
            rect = CGRect(x: r.minX * z, y: r.minY * z, width: max(r.width * z, 1), height: max(r.height * z, 1))
            if !web.isFlipped { rect.origin.y = web.bounds.height - rect.maxY }
        } else {
            rect = CGRect(x: anchor.bounds.minX, y: anchor.isFlipped ? anchor.bounds.minY : anchor.bounds.maxY - 1, width: 40, height: 1)
        }
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
    }

    var presentedLinkPopover: NSPopover? { popover?.isShown == true ? popover : nil }

    func hover(_ link: ReaderWebView.HoveredLink?, in web: ReaderWebView) {
        let suspicious = link.flatMap { web.rendered?.suspiciousLink(for: $0.url) }
        linkPreview.show(link?.url, suspicious: suspicious)
    }

    func quickLook(_ attachment: AttachmentInfo, of key: MessageKey) {
        guard let model else { return }
        Task {
            do {
                let url = try await model.attachmentFile(attachment, of: key)
                quickLook(url, ReaderFormatting.safeFilename(attachment.filename))
            } catch {
                post(Self.attachmentError(error, attachment))
            }
        }
    }

    func open(_ attachment: AttachmentInfo, of key: MessageKey) {
        guard let model else { return }
        let window = view.window
        Task {
            do {
                let url = try await model.attachmentFile(attachment, of: key)
                if let warning = ReaderFormatting.openWarning(filename: attachment.filename, file: url) {
                    guard await confirmRiskyAttachment(warning, window) else { return }
                }
                openFile(url)
            } catch {
                post(Self.attachmentError(error, attachment))
            }
        }
    }

    func save(_ attachments: [AttachmentInfo], of key: MessageKey) {
        guard let model, !attachments.isEmpty else { return }
        let window = view.window
        Task {
            guard let destination = await chooseSaveDestination(attachments, window) else { return }
            var saved = 0
            for attachment in attachments {
                do {
                    try await model.saveAttachment(attachment, of: key, to: destination)
                    saved += 1
                } catch {
                    post(Self.attachmentError(error, attachment))
                    return
                }
            }
            post(saved == 1 ? "Saved 1 attachment" : "Saved \(saved) attachments")
        }
    }

    static func attachmentError(_ error: Error, _ attachment: AttachmentInfo) -> String {
        if case MailPortError.unsupported = error { return "Attachments can't be opened right now." }
        return "Couldn't open \(ReaderFormatting.safeFilename(attachment.filename))"
    }

    static func runAttachmentAlert(_ warning: ReaderFormatting.AttachmentWarning, _ window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = warning.title
        alert.informativeText = warning.message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open")
        let response = if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        return response == .alertSecondButtonReturn
    }

    static func runSavePanel(_ attachments: [AttachmentInfo], _ window: NSWindow?) async -> URL? {
        if attachments.count == 1 {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = ReaderFormatting.safeFilename(attachments[0].filename)
            panel.canCreateDirectories = true
            let response = if let window { await panel.beginSheetModal(for: window) } else { panel.runModal() }
            return response == .OK ? panel.url : nil
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        panel.message = "Choose a folder for \(attachments.count) attachments"
        let response = if let window { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        return response == .OK ? panel.url : nil
    }
}

@MainActor
final class ReaderRootView: NSView {
    weak var controller: ReaderViewController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if controller?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ReaderDocumentView: NSView {
    weak var scrollView: NSScrollView?
    weak var controller: ReaderViewController?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) == true { return }
        guard let scrollView else { return super.keyDown(with: event) }
        let clip = scrollView.contentView
        let page = clip.bounds.height - 40
        var y = clip.bounds.origin.y
        switch event.keyCode {
        case 125: y += 40
        case 126: y -= 40
        case 121: y += page
        case 116: y -= page
        case 49: y += event.modifierFlags.contains(.shift) ? -page : page
        default: return super.keyDown(with: event)
        }
        controller?.userScrolled()
        y = min(max(0, y), max(0, frame.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    override func performTextFinderAction(_ sender: Any?) { controller?.showFind() }
}

@MainActor
final class HairlineView: NSView {
    let thickness: CGFloat = 1
    let color: NSColor

    init(theme: ThemeTokens) {
        color = theme.borderHairline.nsColor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        heightAnchor.constraint(equalToConstant: thickness).isActive = true
        setAccessibilityElement(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

extension ReaderViewController: ReaderWebViewOwner {
    func readerWebView(_ view: ReaderWebView, hovered link: ReaderWebView.HoveredLink?) { hover(link, in: view) }

    func readerWebView(_ view: ReaderWebView, activated url: URL, modifiers: NSEvent.ModifierFlags) {
        followLink(url, from: view, modifiers: modifiers)
    }

    func readerWebView(_ view: ReaderWebView, keyDown event: NSEvent) -> Bool { handleKey(event) }

    func readerWebViewFind(_ view: ReaderWebView) { showFind() }

    func readerWebView(_ view: ReaderWebView, selected text: String) {
        guard let key = message(holding: view) else { return }
        model?.setQuoteSelection(text, in: key)
    }

    func message(holding view: NSView) -> MessageKey? {
        var current = view.superview
        while let candidate = current {
            if let container = candidate as? MessageContainerView { return container.key }
            current = candidate.superview
        }
        return nil
    }
}
