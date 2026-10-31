import AppKit
import MailActions
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore

@MainActor
public final class ThreadListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public let tableView = ThreadTableView()
    private let scrollView = NSScrollView()
    private var emptyView: ThreadListEmptyView?
    private var retryBar: NSStackView?
    private var retryLabel: NSTextField?
    var isRetryBarShown: Bool { retryBar?.isHidden == false }
    private(set) var style: ThreadRowStyle
    private var baseTheme: ThemeTokens
    public let zoom: ReaderPreferences
    private var appliedZoom: Double
    private var zoomObservation: ObservationLoop?
    private let format = ThreadRowFormatting()
    private var rowCount = 0
    private var shownRows: [ThreadRow] = []
    private var shownGroups = ThreadListGroups.none
    private var appliedRevision = -1
    private var mirroredCursor: ThreadKey?
    private var observation: ObservationLoop?
    private var mirroringSelection = false
    private var lastVisibleRange: Range<Int> = 0..<0
    private var appliedLabels: [Int64: LabelInfo] = [:]
    private var appliedImpliesImportance = false
    private var appliedChipRevision = 0
    private var appliedChecked: Set<ThreadKey> = []
    private var loadingShown = false
    private var loadingTimer: Task<Void, Never>?
    private var loadingVisibleSince: Date?
    private var placeholdersVisibleSince: ContinuousClock.Instant?
    private var skeletonTimer: Task<Void, Never>?
    private var appliedPagingFailed = false
    private var routerHost: RouterThreadListHost?
    private var notificationTokens: [NSObjectProtocol] = []
    private var hover = ThreadListHover()
    var hoveredRow: Int? { hover.row }
    let tipPresenter: KeycapTooltipPresenter

    public var model: ThreadListModel? {
        didSet { if model !== oldValue { bind(previous: oldValue) } }
    }
    public var threadDragWriter: (@MainActor () -> ThreadEMLDragWriter?)?
    public var dragFailed: @MainActor @Sendable () -> Void = {}
    public var onOpen: ((ThreadKey) -> Void)?
    public var placeholder: String? {
        didSet { if isViewLoaded { updateEmptyState() } }
    }
    public weak var host: ThreadListHost?
    public var swipeActions: (leading: [ActionID], trailing: [ActionID]) = ([.markDone], [ThreadListActionIDs.snooze, .trash])
    public var hoverActions: [ActionID] = [.markDone, ThreadListActionIDs.snooze, .remind]
    public var onTableUpdate: ((ThreadListChange, Duration) -> Void)?
    /// Draws the selection as in a key (`true`) or inactive (`false`) window regardless of the window, for renders.
    var selectionEmphasisOverride: Bool? {
        didSet {
            guard selectionEmphasisOverride != oldValue, isViewLoaded else { return }
            tableView.enumerateAvailableRowViews { rowView, _ in
                (rowView as? ThreadRowBackgroundView)?.emphasisOverride = self.selectionEmphasisOverride
            }
        }
    }
    public var showsDateGroups = false {
        didSet {
            if showsDateGroups != oldValue { model?.groupsByDate = showsDateGroups }
        }
    }

    public init(theme: ThemeTokens, zoom: ReaderPreferences = .shared) {
        baseTheme = theme
        self.zoom = zoom
        appliedZoom = zoom.textZoom
        style = ThreadRowStyle(theme: theme.listZoomed(zoom.textZoom))
        tipPresenter = KeycapTooltipPresenter(theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    isolated deinit {
        loadingTimer?.cancel()
        zoomObservation?.cancel()
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    public var theme: ThemeTokens { baseTheme }

    public override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("thread"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = style.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.backgroundColor = style.window
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.allowsTypeSelect = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.listController = self
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask([], forLocal: true)
        tableView.setAccessibilityLabel(String(localized: "Conversations"))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = style.window
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScrollBegan() }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScrollEnded() }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            let resigned = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let window = self.tableView.window, resigned == ObjectIdentifier(window) else { return }
                self.pointerExited()
                self.windowKeyChanged()
            }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let became = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let window = self.tableView.window, became == ObjectIdentifier(window) else { return }
                self.windowKeyChanged()
            }
        })
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            notificationTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.datesChanged() }
            })
        }

        let empty = ThreadListEmptyView(style: style)
        empty.isHidden = true
        emptyView = empty

        let container = NSView()
        for subview in [scrollView, empty] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                subview.topAnchor.constraint(equalTo: container.topAnchor),
                subview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        let retryLabel = NSTextField(labelWithString: String(localized: "Couldn't load more conversations."))
        let retryButton = NSButton(title: String(localized: "Retry"), target: self, action: #selector(retryPaging))
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.setAccessibilityIdentifier("threadList.retry")
        let bar = NSStackView(views: [retryLabel, retryButton])
        bar.orientation = .horizontal
        bar.wantsLayer = true
        bar.setAccessibilityElement(true)
        bar.setAccessibilityRole(.group)
        bar.setAccessibilityLabel(String(localized: "Couldn't load more conversations"))
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        retryBar = bar
        self.retryLabel = retryLabel
        styleRetryBar()
        container.addSubview(tipPresenter.view)
        view = container
        bind(previous: nil)
        zoomObservation = ObservationLoop.observe { [weak self] in self?.zoomChanged() }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(tableView)
    }

    private var resolvedHost: ThreadListHost? {
        if let host { return host }
        if let routerHost { return routerHost }
        var controller = parent
        while let current = controller {
            if let content = current as? MainContentViewController {
                let adapter = RouterThreadListHost(router: content.router)
                routerHost = adapter
                return adapter
            }
            controller = current.parent
        }
        return nil
    }

    private func bind(previous: ThreadListModel?) {
        previous?.removeListener(self)
        observation?.cancel()
        observation = nil
        loadingTimer?.cancel()
        loadingShown = false
        loadingVisibleSince = nil
        skeletonTimer?.cancel()
        skeletonTimer = nil
        placeholdersVisibleSince = nil
        appliedPagingFailed = model?.pagingFailed ?? false
        guard isViewLoaded else { return }
        if let model {
            if let selection = resolvedHost?.threadListSelection(for: model) { model.attach(selection: selection) }
            model.groupsByDate = showsDateGroups
            model.addListener(self) { [weak self] event in self?.handle(event) }
            appliedLabels = model.labels
            appliedImpliesImportance = model.impliesImportance
            appliedChipRevision = model.chipRevision
            appliedChecked = model.selection.checked
            if model.state == .loading { startLoadingTimer() }
        }
        reloadAll()
        observation = ObservationLoop.observe { [weak self] in self?.renderState() }
    }

    private func reloadAll() {
        rowCount = model?.displayCount ?? 0
        shownRows = model?.rows ?? []
        shownGroups = model?.groups ?? .none
        appliedRevision = model?.revision ?? -1
        mirroringSelection = true
        tableView.reloadData()
        mirroringSelection = false
        mirroredCursor = nil
        mirrorCursor()
        updateEmptyState()
        reportVisibleRange(force: true)
    }

    private func renderState() {
        guard let model else {
            retryBar?.isHidden = true
            updateEmptyState()
            return
        }
        let state = model.state
        _ = model.rows.isEmpty
        let labels = model.labels
        let implies = model.impliesImportance
        let chipRevision = model.chipRevision
        let checked = model.selection.checked
        if let host = resolvedHost { _ = host.threadListConnectivity(for: model.account) }
        if state != .loading { loadingTimer?.cancel() }
        if labels != appliedLabels || implies != appliedImpliesImportance || chipRevision != appliedChipRevision {
            appliedLabels = labels
            appliedImpliesImportance = implies
            appliedChipRevision = chipRevision
            reconfigure(visibleRows())
        }
        if checked != appliedChecked {
            let changed = checked.symmetricDifference(appliedChecked)
            appliedChecked = checked
            var indexes = IndexSet()
            for key in changed { if let index = model.displayIndex(of: key) { indexes.insert(index) } }
            let visible = visibleRows()
            reconfigure(indexes.filteredIndexSet { visible.contains($0) })
        }
        let failed = model.pagingFailed
        if retryBar?.isHidden == failed { retryBar?.isHidden = !failed }
        if failed != appliedPagingFailed {
            appliedPagingFailed = failed
            reconfigureVisiblePlaceholders()
        }
        updateEmptyState()
    }

    @objc private func retryPaging() {
        model?.retryPaging()
    }

    private func handle(_ event: ThreadListModel.Event) {
        switch event {
        case .rows(let change): applyRows(change)
        case .cursor: mirrorCursor()
        }
    }

    private func applyRows(_ change: ThreadListChange) {
        guard let model else { return }
        let clock = ContinuousClock()
        let start = clock.now
        let anchor = captureAnchor()
        let newCount = model.displayCount
        var edit: ThreadListEdit?
        if case .update(let e) = change, appliedRevision == model.revision - 1,
           rowCount - e.removed.count + e.inserted.count == newCount {
            edit = e
        }
        rowCount = newCount
        releaseOffMain(shownRows)
        shownRows = model.rows
        shownGroups = model.groups
        appliedRevision = model.revision
        mirroringSelection = true
        if let edit {
            if !edit.removed.isEmpty || !edit.inserted.isEmpty {
                tableView.beginUpdates()
                if !edit.removed.isEmpty { tableView.removeRows(at: edit.removed, withAnimation: []) }
                if !edit.inserted.isEmpty { tableView.insertRows(at: edit.inserted, withAnimation: []) }
                tableView.endUpdates()
            }
            mirroringSelection = false
            let visible = visibleRows()
            reconfigure(edit.reconfigured.filteredIndexSet { visible.contains($0) })
        } else {
            tableView.reloadData()
            mirroringSelection = false
        }
        restoreAnchor(anchor)
        mirrorCursor()
        updateEmptyState()
        reportVisibleRange(force: true)
        rehover()
        onTableUpdate?(change, clock.now - start)
    }

    private struct Anchor {
        var key: ThreadKey?
        var offset: CGFloat
        var atTop: Bool
    }

    private func captureAnchor() -> Anchor {
        let idle = model?.lastKeyAt.map { Date().timeIntervalSince($0) * 1000 >= theme.motionBannerIdle } ?? true
        let y = scrollView.contentView.bounds.origin.y
        let atTop = y <= 0.5 && idle
        let height = max(tableView.rowHeight, 1)
        let display = Int((y / height).rounded(.down))
        let row = shownGroups.rowIndex(atOrAfterDisplay: max(0, display))
        guard shownRows.indices.contains(row) else { return Anchor(key: nil, offset: 0, atTop: atTop) }
        let shownDisplay = shownGroups.displayIndex(ofRow: row)
        return Anchor(key: shownRows[row].id, offset: y - CGFloat(shownDisplay) * height, atTop: atTop)
    }

    private func restoreAnchor(_ anchor: Anchor) {
        guard !anchor.atTop, let key = anchor.key, let index = model?.displayIndex(of: key) else { return }
        let clip = scrollView.contentView
        let height = tableView.rowHeight
        let maxY = max(0, CGFloat(rowCount) * height - clip.bounds.height)
        let target = min(max(0, CGFloat(index) * height + anchor.offset), maxY)
        guard abs(target - clip.bounds.origin.y) > 0.25 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    private func visibleRows() -> Range<Int> {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return 0..<0 }
        return range.location..<min(range.location + range.length, rowCount)
    }

    private func reconfigure(_ indexes: IndexSet) {
        for index in indexes where index < rowCount {
            if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ThreadRowView {
                configure(cell, row: index)
            } else if let header = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ThreadGroupHeaderView,
                      let title = model?.header(atDisplay: index)?.title {
                header.configure(title: title)
            }
            if let rowView = tableView.rowView(atRow: index, makeIfNecessary: false) as? ThreadRowBackgroundView {
                rowView.isChecked = isChecked(row: index)
            }
        }
    }

    private func reconfigure(_ range: Range<Int>) {
        reconfigure(IndexSet(integersIn: range))
    }

    private func datesChanged() {
        day = Self.today()
        style.forget()
        model?.regroup()
        reconfigure(visibleRows())
    }

    private func mirrorCursor() {
        guard let model, let cursor = model.cursor, let index = model.displayIndex(of: cursor) else {
            if tableView.selectedRow >= 0 {
                mirroringSelection = true
                tableView.deselectAll(nil)
                mirroringSelection = false
            }
            mirroredCursor = nil
            return
        }
        if tableView.selectedRow != index {
            mirroringSelection = true
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            mirroringSelection = false
        }
        if cursor != mirroredCursor {
            mirroredCursor = cursor
            scrollToKeepMargin(index)
        }
    }

    private func scrollToKeepMargin(_ index: Int) {
        let rowHeight = tableView.rowHeight
        let visible = scrollView.contentView.bounds
        let rowTop = CGFloat(index) * rowHeight
        let margin = 2 * rowHeight
        var origin = visible.origin.y
        if rowTop - margin < visible.minY {
            origin = max(0, rowTop - margin)
        } else if rowTop + rowHeight + margin > visible.maxY {
            origin = min(rowTop + rowHeight + margin - visible.height, max(0, CGFloat(rowCount) * rowHeight - visible.height))
        }
        if origin != visible.origin.y {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let header = model?.header(atDisplay: row) {
            let view = (tableView.makeView(withIdentifier: ThreadGroupHeaderView.identifier, owner: nil) as? ThreadGroupHeaderView)
                ?? ThreadGroupHeaderView(style: style)
            view.style = style
            view.configure(title: header.title)
            return view
        }
        let cell = (tableView.makeView(withIdentifier: ThreadRowView.identifier, owner: nil) as? ThreadRowView)
            ?? ThreadRowView(style: style)
        cell.style = style
        configure(cell, row: row)
        return cell
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if model?.header(atDisplay: row) != nil {
            let view = (tableView.makeView(withIdentifier: ThreadGroupHeaderRowView.identifier, owner: nil)
                as? ThreadGroupHeaderRowView) ?? ThreadGroupHeaderRowView(background: style.window)
            view.background = style.window
            return view
        }
        let view = (tableView.makeView(withIdentifier: ThreadRowBackgroundView.identifier, owner: nil) as? ThreadRowBackgroundView)
            ?? ThreadRowBackgroundView(style: style)
        view.style = style
        view.isChecked = isChecked(row: row)
        view.emphasisOverride = selectionEmphasisOverride
        return view
    }

    // Only the selected row's plate changes with the window's key state
    private func windowKeyChanged() {
        guard tableView.selectedRow >= 0 else { return }
        (tableView.rowView(atRow: tableView.selectedRow, makeIfNecessary: false) as? ThreadRowBackgroundView)?.emphasisChanged()
    }

    public func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? ThreadRowBackgroundView)?.setHovering(hover.row == row)
    }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let writer = threadDragWriter?(), let thread = thread(atDisplay: row) else { return nil }
        let delegate = ThreadPromiseDelegate(thread: thread.id, subject: thread.subject, messageCount: thread.messageCount,
                                             writer: writer, failed: dragFailed)
        let provider = NSFilePromiseProvider(fileType: delegate.fileType.identifier, delegate: delegate)
        provider.userInfo = delegate
        return provider
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        thread(atDisplay: row) != nil
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !mirroringSelection, let model, tableView.selectedRow >= 0,
              let row = thread(atDisplay: tableView.selectedRow) else { return }
        model.setCursor(row.id)
    }

    private func isChecked(row: Int) -> Bool {
        guard let model, let thread = thread(atDisplay: row) else { return false }
        return model.isChecked(thread.id)
    }

    private func thread(atDisplay display: Int) -> ThreadRow? {
        guard let model, let row = model.rowIndex(atDisplay: display), row < model.rows.count else { return nil }
        return model.rows[row]
    }

    private var day = ThreadListViewController.today()
    private var importanceTips: [ThreadKey: String] = [:]

    private static func today() -> Int { Calendar.autoupdatingCurrent.ordinality(of: .day, in: .era, for: Date()) ?? 0 }

    private func configure(_ cell: ThreadRowView, row display: Int) {
        guard let model, let row = thread(atDisplay: display) else {
            cell.configurePlaceholder(showsSkeleton: showsSkeleton)
            return
        }
        let now = Date()
        let chips = model.chips(for: row)
        let muted = model.isMuted(row)
        let reason = model.location == .system(.reminders) ? resolvedHost?.threadListFollowUpReason(for: row) : nil
        let texts = style.texts(for: row, chips: chips, format: format, location: model.location, muted: muted,
                                followUpReason: reason)
        let date = style.dateText(for: row, location: model.location, format: format, now: now, day: day, muted: muted)
        let indicators = Array(ThreadRowFormatting.indicators(for: row, location: model.location, now: now, muted: muted)
            .prefix(ThreadRowFormatting.maximumIndicators))
        let checked = model.isChecked(row.id)
        let key = row.id
        cell.onAction = { [weak self] action in self?.performRowAction(action, key: key) }
        cell.hoverActions = { [weak self] in self?.availableHoverActions() ?? [] }
        cell.onActionHover = { [weak self] button, action, inside in self?.rowActionHover(button, action, inside: inside) }
        cell.cursorRowShowsActions = Self.cursorRowShowsActions(in: model.location)
        if chips.contains(where: { $0.kind == .gmailImportant }) {
            cell.importanceTip = { [weak self] in self?.importanceTips[key] ?? ThreadRowFormatting.gmailImportantTip }
            cell.onPointerEnter = { [weak self] in self?.loadImportanceTip(key) }
        } else {
            cell.importanceTip = nil
            cell.onPointerEnter = nil
        }
        cell.configure(row, texts: texts, date: date, indicators: indicators, isChecked: checked, isMuted: muted)
        cell.accessibilityContent = { [weak self, weak model] in
            guard let self, let model, let current = model.row(for: key) else { return ("", []) }
            var label = self.format.accessibilityLabel(current, chips: model.chips(for: current), location: model.location,
                                                       now: Date(), muted: model.isMuted(current))
            if model.isChecked(key) { label = String(localized: "Checked") + ", " + label }
            if model.location == .system(.reminders),
               let reason = self.resolvedHost?.threadListFollowUpReason(for: current) {
                label += ", " + String(localized: "Follow-up: \(reason)")
            }
            return (label, self.customActions(for: current))
        }
    }

    // Fetched on hover, not per row, so scrolling never reads the store
    private func loadImportanceTip(_ key: ThreadKey) {
        Task { [weak self] in
            guard let host = self?.resolvedHost, let line = await host.threadListImportanceReason(for: key),
                  let self else { return }
            if self.importanceTips.count >= 200 { self.importanceTips.removeAll() }
            self.importanceTips[key] = line
        }
    }

    static func cursorRowShowsActions(in location: MailLocation) -> Bool {
        switch location {
        case .system(.snoozed), .system(.reminders), .system(.scheduled): false
        default: true
        }
    }

    private static func title(_ action: ActionID, row: ThreadRow? = nil) -> String {
        switch action {
        case .markDone: String(localized: "Mark done")
        case .trash: String(localized: "Trash")
        case ThreadListActionIDs.snooze: String(localized: "Snooze")
        case .remind: String(localized: "Remind me")
        case ThreadListActionIDs.label: String(localized: "Label")
        case ThreadListActionIDs.reply: String(localized: "Reply")
        case ThreadListActionIDs.toggleRead:
            row?.isUnread == true ? String(localized: "Mark read") : String(localized: "Mark unread")
        default: ActionCatalog.descriptor(action)?.title ?? action.rawValue
        }
    }

    static func symbol(_ action: ActionID) -> String? {
        switch action {
        case .markDone: "checkmark"
        case .trash: "trash"
        case ThreadListActionIDs.snooze: "clock"
        case .remind: "bell"
        case ThreadListActionIDs.label: "tag"
        case ThreadListActionIDs.reply: "arrowshape.turn.up.left"
        case ThreadListActionIDs.toggleRead: "envelope.badge"
        default: nil
        }
    }

    func rowActionTip(_ action: ThreadRowView.HoverAction) -> KeycapTooltipContent? {
        let descriptors = resolvedHost?.threadListDescriptors() ?? ActionCatalog.all
        return ShortcutTip.action(action.action, in: descriptors, title: action.title).map { KeycapTooltipContent($0) }
    }

    private func rowActionHover(_ button: NSView, _ action: ThreadRowView.HoverAction, inside: Bool) {
        tipPresenter.hover(button, content: rowActionTip(action), inside: inside)
    }

    private func availableHoverActions() -> [ThreadRowView.HoverAction] {
        guard let host = resolvedHost else { return [] }
        return hoverActions.filter(host.threadListCanPerform).compactMap { action in
            Self.symbol(action).map { ThreadRowView.HoverAction(action: action, symbol: $0, title: Self.title(action)) }
        }
    }

    private func customActions(for row: ThreadRow) -> [NSAccessibilityCustomAction] {
        guard let host = resolvedHost else { return [] }
        let ids: [ActionID] = [.markDone, .trash, ThreadListActionIDs.snooze, .remind, ThreadListActionIDs.reply,
                               ThreadListActionIDs.toggleRead]
        let key = row.id
        var actions = ids.filter(host.threadListCanPerform).map { action in
            NSAccessibilityCustomAction(name: Self.title(action, row: row)) { [weak self] in
                self?.performRowAction(action, key: key) ?? false
            }
        }
        if host.threadListCanPerform(.toggleCheck) {
            let name = model?.isChecked(key) == true ? String(localized: "Uncheck") : String(localized: "Check")
            actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self, self.model?.toggleCheck(key) == true else { return false }
                self.announceChecks()
                return true
            })
        }
        return actions
    }

    public func tableView(_ tableView: NSTableView, rowActionsForRow row: Int,
                          edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard let thread = thread(atDisplay: row), let host = resolvedHost else { return [] }
        let key = thread.id
        let ids = (edge == .leading ? swipeActions.leading : swipeActions.trailing).filter(host.threadListCanPerform)
        let shown = edge == .leading ? ids : Array(ids.prefix(1))
        return shown.map { action in
            let item = NSTableViewRowAction(style: action == .trash ? .destructive : .regular, title: Self.title(action)) {
                [weak self] _, _ in
                self?.performRowAction(action, key: key)
                self?.tableView.rowActionsVisible = false
            }
            item.image = Self.symbol(action).flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: Self.title(action)) }
            item.backgroundColor = Self.swipeFill(action, theme: theme).nsColor
            return item
        }
    }

    static let rowMenuSections: [[ActionID]] = [
        [.openThread, .reply, .replyAll, .forward],
        [.sendDrafts],
        [.markDone, .moveToInbox, .snooze, .remind, .label, .move],
        [.toggleStar, .toggleRead, .toggleMute, .autoLabelWrong],
        [.blockSender, .blockDomain],
        [.spam, .notSpam, .trash],
    ]
    static let importanceMenu: [ActionID] = [.moveToImportant, .moveToOther, .alwaysImportantSender,
                                             .alwaysImportantDomain, .neverImportant, .notAPitch, .explainPlacement]

    func contextMenu(forRow row: Int) -> NSMenu? {
        guard let model, row >= 0, row < model.rows.count, let host = resolvedHost else { return nil }
        let key = model.rows[row].id
        if model.isChecked(key) { model.setCursor(key) } else { model.click(key) }
        func items(_ ids: [ActionID]) -> [NSMenuItem] {
            ids.compactMap { id in
                let entry = host.threadListMenuEntry(id)
                guard entry.availability != .hidden else { return nil }
                let item = NSMenuItem(title: entry.title, action: #selector(performMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = RowMenuAction(action: id, key: key)
                item.isEnabled = entry.availability.isEnabled
                item.toolTip = entry.reason
                return item
            }
        }
        var sections = Self.rowMenuSections.map(items)
        let importance = items(Self.importanceMenu)
        if !importance.isEmpty {
            let parent = NSMenuItem(title: String(localized: "Importance"), action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: parent.title)
            submenu.autoenablesItems = false
            importance.forEach(submenu.addItem)
            parent.submenu = submenu
            sections.insert([parent], at: sections.count - 1)
        }
        let menu = NSMenu(title: String(localized: "Conversation"))
        menu.autoenablesItems = false
        for section in sections where !section.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
        }
        guard !menu.items.isEmpty else { return nil }
        MenuShortcutHints(descriptors: host.threadListDescriptors()).apply(to: menu)
        return menu
    }

    @objc private func performMenuItem(_ sender: NSMenuItem) {
        guard let chosen = sender.representedObject as? RowMenuAction else { return }
        performRowAction(chosen.action, key: chosen.key)
    }

    static func swipeFill(_ action: ActionID, theme: ThemeTokens) -> ThemeColor {
        switch action {
        case .trash: theme.component.swipe.trash
        case ThreadListActionIDs.snooze: theme.component.swipe.snooze
        default: theme.component.swipe.done
        }
    }

    @discardableResult
    func performRowAction(_ action: ActionID, key: ThreadKey) -> Bool {
        guard let model, let host = resolvedHost, model.row(for: key) != nil, host.threadListCanPerform(action) else {
            return false
        }
        if model.isChecked(key) { model.setCursor(key) } else { model.click(key) }
        return host.threadListPerform(action)
    }

    @objc private func doubleClicked() {
        guard tableView.clickedRow >= 0, let thread = thread(atDisplay: tableView.clickedRow) else { return }
        onOpen?(thread.id)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let characters = event.charactersIgnoringModifiers ?? ""
        switch (event.keyCode, characters, modifiers) {
        case (_, "x", []):
            guard model.toggleCheck() else { return false }
            announceChecks()
            return true
        case (_, "J", .shift), (125, _, .shift):
            if model.extendCheck(by: 1) { announceChecks() }
            return true
        case (_, "K", .shift), (126, _, .shift):
            if model.extendCheck(by: -1) { announceChecks() }
            return true
        case (_, "a", .command):
            checkShortcut(SelectAllShortcuts.commandA)
            return true
        case (_, "A", [.command, .shift]):
            checkShortcut(SelectAllShortcuts.commandShiftA)
            return true
        case (53, _, []):
            return clearChecks()
        default:
            return false
        }
    }

    func checkAll() {
        model?.checkAll()
        announceChecks()
    }

    func checkFromHere() {
        model?.checkFromHere()
        announceChecks()
    }

    private func checkShortcut(_ action: ActionID) {
        if action == .checkFromHere { checkFromHere() } else { checkAll() }
    }

    func isCheckboxHit(row: Int, at point: NSPoint) -> Bool {
        guard thread(atDisplay: row) != nil else { return false }
        let cell = tableView.frameOfCell(atColumn: 0, row: row)
        guard cell.width > 0 else { return false }
        let local = point.x - cell.minX
        let x = tableView.userInterfaceLayoutDirection == .rightToLeft ? cell.width - local : local
        return x >= 0 && x < style.columns(width: cell.width).sender.lowerBound
    }

    @discardableResult
    func clearChecks() -> Bool {
        guard model?.clearChecks() == true else { return false }
        announce(String(localized: "No conversations checked"))
        return true
    }

    func handleClick(row: Int, extending: Bool, toggling: Bool) {
        guard let model, let thread = thread(atDisplay: row) else { return }
        let before = model.checkedCount
        model.click(thread.id, extending: extending, toggling: toggling)
        if model.checkedCount != before { announceChecks() }
    }

    private func announceChecks() {
        guard let count = model?.checkedCount else { return }
        announce(count == 0 ? String(localized: "No conversations checked")
                 : String(localized: "\(count) conversations checked"))
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: tableView, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    @objc private func scrolled() {
        tipPresenter.hide()
        reportVisibleRange(force: false)
        if !hover.isScrolling { refreshHover() }
    }

    func pointerMoved(to point: NSPoint) {
        if hover.pointer(over: hoverRow(at: point)) { showHover() }
    }

    func pointerExited() {
        if hover.pointerExited() { showHover() }
    }

    func liveScrollBegan() {
        if hover.scrollBegan() { showHover() }
    }

    func liveScrollEnded() {
        if hover.scrollEnded(pointerOver: rowUnderPointer()) { showHover() }
    }

    private func refreshHover() {
        if hover.pointer(over: rowUnderPointer()) { showHover() }
    }

    private func rehover() {
        if hover.pointer(over: rowUnderPointer()) || hover.row != nil { showHover() }
    }

    private func hoverRow(at point: NSPoint) -> Int? {
        guard tableView.visibleRect.contains(point) else { return nil }
        let row = tableView.row(at: point)
        return row >= 0 && row < rowCount ? row : nil
    }

    private func rowUnderPointer() -> Int? {
        guard let window = tableView.window, window.isVisible, window.isKeyWindow,
              NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
        else { return nil }
        return hoverRow(at: tableView.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func showHover() {
        let hovered = hover.row
        tableView.enumerateAvailableRowViews { rowView, row in
            (rowView as? ThreadRowBackgroundView)?.setHovering(row == hovered)
        }
    }

    private func reportVisibleRange(force: Bool) {
        let range = visibleRows()
        trackVisiblePlaceholders(range)
        guard force || range != lastVisibleRange, !range.isEmpty else { return }
        lastVisibleRange = range
        model?.visibleDisplayRangeDidChange(range)
    }


    private var showsSkeleton: Bool {
        ThreadListSkeleton.shows(pagingFailed: model?.pagingFailed ?? false,
                                 visibleFor: placeholdersVisibleSince.map { ContinuousClock.now - $0 },
                                 delay: .milliseconds(Int(theme.motionSpinnerDelay)))
    }

    private func isPlaceholder(display: Int) -> Bool {
        guard let model, display < rowCount else { return false }
        return thread(atDisplay: display) == nil && model.header(atDisplay: display) == nil
    }

    private func trackVisiblePlaceholders(_ range: Range<Int>) {
        let visible = range.contains { isPlaceholder(display: $0) }
        if visible, placeholdersVisibleSince == nil {
            placeholdersVisibleSince = .now
            let delay = Duration.milliseconds(Int(theme.motionSpinnerDelay))
            skeletonTimer?.cancel()
            skeletonTimer = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.reconfigureVisiblePlaceholders()
            }
        } else if !visible, placeholdersVisibleSince != nil {
            placeholdersVisibleSince = nil
            skeletonTimer?.cancel()
            skeletonTimer = nil
        }
    }

    private func reconfigureVisiblePlaceholders() {
        reconfigure(IndexSet(visibleRows().filter { isPlaceholder(display: $0) }))
    }

    private func styleRetryBar() {
        guard let bar = retryBar else { return }
        let t = style.theme, popover = t.component.popover
        retryLabel?.font = t.typeMeta.font
        retryLabel?.textColor = style.secondary
        bar.spacing = CGFloat(t.space3)
        bar.edgeInsets = NSEdgeInsets(top: CGFloat(t.space3), left: CGFloat(t.space4), bottom: CGFloat(t.space3),
                                      right: CGFloat(t.space4))
        bar.layer?.backgroundColor = popover.bg.nsColor.cgColor
        bar.layer?.borderColor = popover.border.nsColor.cgColor
        bar.layer?.borderWidth = 1
        bar.layer?.cornerRadius = CGFloat(t.radiusLG)
    }

    public var visibleRowRange: Range<Int> { visibleRows() }

    private func startLoadingTimer() {
        loadingTimer?.cancel()
        loadingTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(self?.theme.motionSpinnerDelay ?? 150)))
            guard !Task.isCancelled, let self else { return }
            self.loadingShown = true
            self.updateEmptyState()
        }
    }

    private func updateEmptyState() {
        guard let emptyView else { return }
        guard let model else {
            emptyView.show(placeholder.map { ThreadListEmptyState(style: .message, title: $0) }, now: Date())
            return
        }
        let host = resolvedHost
        var state = ThreadListEmptyState.make(
            location: model.location, locationTitle: host?.threadListTitle(for: model.location) ?? "",
            state: model.state, hasRows: !model.rows.isEmpty, loadingShown: loadingShown,
            connectivity: host?.threadListConnectivity(for: model.account), day: day,
            relatedResults: host?.threadListAddsRelatedResults() ?? false)
        if state?.style == .progress, loadingVisibleSince == nil { loadingVisibleSince = Date() }
        if state == nil || state?.style != .progress, let since = loadingVisibleSince, emptyView.state?.style == .progress {
            let remaining = theme.motionSpinnerMinVisible / 1000 - Date().timeIntervalSince(since)
            if remaining > 0 {
                state = emptyView.state
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(remaining))
                    self?.loadingVisibleSince = nil
                    self?.updateEmptyState()
                }
            } else {
                loadingVisibleSince = nil
            }
        }
        let wasHidden = emptyView.isHidden
        emptyView.show(state, now: Date())
        if wasHidden, !emptyView.isHidden, let title = state?.title, state?.style != .progress { announce(title) }
    }

    public func apply(theme newTheme: ThemeTokens) {
        guard newTheme != baseTheme else { return }
        baseTheme = newTheme
        restyle()
    }

    private func zoomChanged() {
        let value = zoom.textZoom
        guard value != appliedZoom else { return }
        appliedZoom = value
        restyle()
    }

    private func restyle() {
        let oldHeight = max(tableView.rowHeight, 1)
        style = ThreadRowStyle(theme: baseTheme.listZoomed(appliedZoom))
        tipPresenter.apply(theme: baseTheme)
        guard isViewLoaded else { return }
        let clip = scrollView.contentView
        let top = clip.bounds.origin.y / oldHeight
        tableView.backgroundColor = style.window
        scrollView.backgroundColor = style.window
        emptyView?.apply(style: style)
        styleRetryBar()
        if style.rowHeight != oldHeight {
            tableView.rowHeight = style.rowHeight
            let maxY = max(0, CGFloat(rowCount) * style.rowHeight - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: min(maxY, max(0, top * style.rowHeight))))
            scrollView.reflectScrolledClipView(clip)
        }
        for index in visibleRows() {
            if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ThreadRowView {
                cell.style = style
                configure(cell, row: index)
            } else if let header = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ThreadGroupHeaderView {
                header.style = style
            }
            if let rowView = tableView.rowView(atRow: index, makeIfNecessary: false) as? ThreadRowBackgroundView {
                rowView.style = style
            } else if let rowView = tableView.rowView(atRow: index, makeIfNecessary: false) as? ThreadGroupHeaderRowView {
                rowView.background = style.window
            }
        }
        updateEmptyState()
    }
}

final class RowMenuAction: NSObject {
    let action: ActionID
    let key: ThreadKey

    init(action: ActionID, key: ThreadKey) {
        self.action = action
        self.key = key
    }
}
