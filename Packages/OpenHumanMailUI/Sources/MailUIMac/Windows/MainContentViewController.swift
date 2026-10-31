import AppKit
import MailActions
import MailFeatures
import MailModel
import MailTheme
import MailUI

@MainActor
public final class MainContentViewController: NSViewController {
    public let windowModel: AppRouter
    public var router: AppRouter { windowModel }
    public let keyRouter = KeyRouter.catalog()
    public private(set) var theme: ThemeTokens
    private var listController: ThreadListViewController
    private var readerController: ReaderViewController
    private var observation: ObservationLoop?
    private var keymapObservation: ObservationLoop?
    private var loadedKeymapRevision: Int?
    private var shownMode: AppRouter.Mode?
    private var shownUnified = false
    private weak var boundAccount: AccountState?
    private var pendingScrollTop: ThreadKey?
    private var scrollRetries = 0
    private var scrollObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?
    private var seenFieldFocus = 0
    private var seenResultsFocus = 0
    /// Waiting for the results to load before they take the keys; true when the first result is to be selected.
    private var pendingResultsFocus: Bool?
    private var shownSearchOpen = false
    private var shownPillSelection = IndexSet()
    private lazy var printer = ConversationPrinter { [weak self] in self?.view.window }
    private(set) lazy var overlayFocus = OverlayFocusKeeper { [weak self] in self?.view.window }

    public convenience init(environment: AppEnvironment) {
        self.init(router: environment.router, theme: environment.theme)
    }

    public init(router: AppRouter, theme: ThemeTokens? = nil) {
        self.windowModel = router
        let theme = theme ?? router.environment.theme
        self.theme = theme
        listController = ThreadListViewController(theme: theme)
        readerController = ReaderViewController(theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public var tableView: ThreadTableView { listController.tableView }

    public var showsDateGroups: Bool {
        get { listController.showsDateGroups }
        set { listController.showsDateGroups = newValue }
    }

    var reader: ReaderViewController { readerController }

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = theme.bgWindow.nsColor.cgColor
        view = root
        install(listController, readerController)
        listController.threadDragWriter = { [weak self] in self?.router.environment.threadDrag }
        listController.dragFailed = { [weak self] in
            self?.router.environment.notices.post("Couldn't copy the conversation", style: .info, duration: NoticeCenter.infoDuration)
        }

        keyRouter.load(KeyTable.build(router.environment.actions.descriptors))
        loadedKeymapRevision = router.environment.actions.keymapRevision
        keymapObservation = ObservationLoop.observe { [weak self] in
            guard let self else { return }
            let actions = self.router.environment.actions
            let revision = actions.keymapRevision
            guard revision != self.loadedKeymapRevision else { return }
            self.loadedKeymapRevision = revision
            self.keyRouter.load(KeyTable.build(actions.descriptors))
        }
        keyRouter.activeScopes = { [weak self] in
            if self?.router.environment.overlays.isShowing == true { return [.global] }
            if self?.router.environment.calendarWindowIfStarted?.isOpen == true { return [.calendar, .global] }
            if self?.router.unifiedInbox != nil { return [.global] }
            if self?.router.mode == .list, case .reviewQueue? = self?.router.active?.location {
                return [.review, .global]
            }
            return self?.router.mode == .reader ? [.reader, .global] : [.list, .global]
        }
        keyRouter.perform = { [weak self] action, _ in self?.router.perform(action) ?? false }
        keyRouter.editingKeyHandler = { [weak self] event in self?.editSearchQuery(with: event) ?? false }
        keyRouter.fieldEditorKeyHandler = { [weak self] event, editor in
            self?.editSearchField(with: event, in: editor) ?? false
        }
        keyRouter.isMailWindow = { [weak self] window in window === self?.view.window }
        keyRouter.onPendingSequence = { [weak self] prefix in
            self?.router.sequenceHint = prefix.map { Self.hint(for: $0) }
        }

        Task { await ReaderWebKit.shared.prepare() }
        router.environment.actions.superhumanCore?.printer = printer
        router.environment.overlays.focusKeeper = overlayFocus
        router.willPersist = { [weak self] in self?.captureScroll(into: self?.boundAccount) }
        router.start()
        observation = ObservationLoop.observe { [weak self] in self?.render() }
        router.environment.ai?.preparation.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.router.environment.ai?.preparation.systemDidWake() }
        }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        keyRouter.install()
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        keyRouter.uninstall()
        captureScroll(into: boundAccount)
        router.persist()
    }

    isolated deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    public func apply(theme newTheme: ThemeTokens) {
        guard newTheme != theme else { return }
        theme = newTheme
        listController.apply(theme: newTheme)
        guard isViewLoaded else {
            readerController = ReaderViewController(theme: newTheme)
            return
        }
        let oldReader = readerController
        oldReader.view.removeFromSuperview()
        oldReader.removeFromParent()
        oldReader.model = nil
        readerController = ReaderViewController(theme: newTheme)
        view.layer?.backgroundColor = newTheme.bgWindow.nsColor.cgColor
        installReader(readerController)
        shownMode = nil
        render()
    }

    private func installReader(_ reader: ReaderViewController) {
        addChild(reader)
        reader.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(reader.view)
        NSLayoutConstraint.activate([
            reader.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            reader.view.topAnchor.constraint(equalTo: view.topAnchor),
            reader.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reader.view.isHidden = true
    }

    private func install(_ list: ThreadListViewController, _ reader: ReaderViewController) {
        addChild(list)
        addChild(reader)
        for content in [list.view, reader.view] {
            content.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                content.topAnchor.constraint(equalTo: view.topAnchor),
                content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        reader.view.isHidden = true
        list.onOpen = { [weak self] key in self?.router.openRow(key) }
        observeScroll(of: list)
    }

    private func observeScroll(of list: ThreadListViewController) {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        guard let clip = list.tableView.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pendingScrollTop == nil else { return }
                self.captureScroll(into: self.boundAccount)
            }
        }
    }

    private func render() {
        let active = router.active
        let mode = router.mode
        let list = active?.list
        let reader = active?.reader
        _ = list?.revision
        _ = list?.state
        if active !== boundAccount {
            captureScroll(into: boundAccount)
            boundAccount = active
            pendingScrollTop = active?.selection.scrollTop
            scrollRetries = 0
            shownMode = nil
        }
        if listController.model !== list { listController.model = list }
        if router.accountsError != nil {
            listController.placeholder = "Couldn't open the mail store."
        } else {
            listController.placeholder = router.accountsLoaded && active == nil ? "No account yet." : nil
        }
        readerController.meAddress = active?.account.email ?? ""
        readerController.meAddresses = active?.account.myAddresses ?? []
        if readerController.model !== reader { readerController.model = reader }
        applyPendingScroll()

        if !router.environment.overlays.isShowing { overlayFocus.overlayChanged(showing: false) }

        let search = router.environment.overlays.search
        let fieldTakesFocus = search.focusRequest != seenFieldFocus
        seenFieldFocus = search.focusRequest
        if fieldTakesFocus, mode == .list, search.isOpen { focusSearchField(request: search.focusRequest) }
        if search.resultsFocusRequest != seenResultsFocus {
            seenResultsFocus = search.resultsFocusRequest
            pendingResultsFocus = mode == .list ? search.resultsFocusStartsAtTop : nil
        }
        if pendingResultsFocus != nil { focusResultsOnceShown() }
        if search.isOpen != shownSearchOpen {
            let closed = shownSearchOpen
            shownSearchOpen = search.isOpen
            if closed, mode == .list, !router.environment.overlays.isShowing, router.unifiedInbox == nil {
                focusListAfterSearch()
            }
        }
        let selectedPills = search.selectedPills
        if selectedPills != shownPillSelection {
            shownPillSelection = selectedPills
            if !selectedPills.isEmpty, mode == .list, search.isOpen { placeCaretAtPills() }
        }

        let unified = router.unifiedInbox != nil
        if unified != shownUnified {
            shownUnified = unified
            shownMode = nil
        }
        if unified {
            listController.view.isHidden = true
            readerController.view.isHidden = true
            return
        }
        guard shownMode != mode else { return }
        shownMode = mode
        listController.view.isHidden = mode == .reader
        readerController.view.isHidden = mode == .list
        guard !(mode == .list && fieldTakesFocus) else { return }
        guard !(mode == .list && searchFieldHasTheKeys()) else { return }
        view.window?.makeFirstResponder(mode == .reader ? readerController.focusView : listController.tableView)
    }

    var topVisibleKey: ThreadKey? {
        guard let list = listController.model, !list.rows.isEmpty,
              let clip = listController.tableView.enclosingScrollView?.contentView else { return nil }
        let height = max(listController.tableView.rowHeight, 1)
        let index = list.rowIndex(atOrAfterDisplay: max(0, Int((clip.bounds.origin.y / height).rounded(.down))))
        return list.rows.indices.contains(index) ? list.rows[index].id : nil
    }

    private func captureScroll(into state: AccountState?) {
        guard let state, listController.model === state.list, pendingScrollTop == nil,
              let key = topVisibleKey, let index = listController.model?.displayIndex(of: key),
              let clip = listController.tableView.enclosingScrollView?.contentView else { return }
        let offset = Double(clip.bounds.origin.y - CGFloat(index) * listController.tableView.rowHeight)
        if state.selection.scrollTop != key { state.selection.scrollTop = key }
        if state.selection.scrollOffset != offset { state.selection.scrollOffset = offset }
    }

    private func applyPendingScroll() {
        guard let key = pendingScrollTop, let list = listController.model else { return }
        guard let index = list.displayIndex(of: key) else {
            if list.state != .loading { pendingScrollTop = nil }
            return
        }
        let table = listController.tableView
        guard table.numberOfRows > index, let scroll = table.enclosingScrollView else {
            if scrollRetries < 5 {
                scrollRetries += 1
                Task { @MainActor [weak self] in self?.applyPendingScroll() }
            }
            return
        }
        pendingScrollTop = nil
        let maxY = max(0, table.bounds.height - scroll.contentView.bounds.height)
        let y = min(max(0, CGFloat(index) * table.rowHeight + CGFloat(boundAccount?.selection.scrollOffset ?? 0)), maxY)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Return in the search field, or ↓ from it: the results take the keys once they have loaded, Return's with the
    /// first result selected. With no results the field keeps the keys.
    private func focusResultsOnceShown() {
        guard let startsAtTop = pendingResultsFocus else { return }
        let search = router.environment.overlays.search
        guard router.mode == .list, search.isOpen, let query = search.shownQuery, let list = router.active?.list,
              startsAtTop ? search.text.trimmingCharacters(in: .whitespacesAndNewlines) == query
                          : list.location == .search(query) else {
            pendingResultsFocus = nil
            return
        }
        // Typing on drops the request above; until then this waits for the query's list to load
        guard list.location == .search(query), list.state != .loading else { return }
        pendingResultsFocus = nil
        guard let first = list.rows.first?.id else { return }
        if startsAtTop { list.setCursor(first) }
        view.window?.makeFirstResponder(listController.tableView)
    }

    /// Search closed: the list takes the keys from the search field or from nowhere in particular. Another field and
    /// another list (the sidebar) keep theirs.
    private func focusListAfterSearch() {
        guard let window = view.window else { return }
        let responder = window.firstResponder
        let table = listController.tableView
        guard responder !== table else { return }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField,
           Self.isSearchField(field) {
            window.makeFirstResponder(table)
            return
        }
        if KeyRouter.isTextInput(responder) || responder is NSTableView || responder is NSCollectionView { return }
        window.makeFirstResponder(table)
    }

    /// Keys the toolbar's search field answers before its editor: Tab takes the completion (or the interpretation),
    /// and ⌫, ⌦, ← →, Esc and ⌘A edit the pills.
    func editSearchField(with event: NSEvent, in editor: NSTextView) -> Bool {
        if event.keyCode == KeyChord.NamedKey.tab.rawValue,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            return completeSearch(in: editor)
        }
        return editSearchPills(with: event, in: editor)
    }

    private func completeSearch(in editor: NSTextView) -> Bool {
        let search = router.environment.overlays.search
        guard router.mode == .list, search.isOpen, let window = view.window,
              let field = editor.delegate as? NSTextField, field === searchField(in: window),
              search.acceptCompletion() else { return false }
        let rest = SearchQueryTokens.rest(of: search.text)
        if editor.string != rest { editor.string = rest }
        editor.setSelectedRange(NSRange(location: (rest as NSString).length, length: 0))
        return true
    }

    func editSearchQuery(with event: NSEvent) -> Bool {
        let search = router.environment.overlays.search
        // The calendar covers the search field and answers ⌫ itself.
        guard router.environment.calendarWindowIfStarted?.isOpen != true,
              router.mode == .list, search.isOpen, search.shownQuery != nil, !router.environment.overlays.isShowing,
              let window = view.window, let field = searchField(in: window),
              (field.window ?? window).makeFirstResponder(field),
              let editor = field.currentEditor() as? NSTextView else { return false }
        let end = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: search.selectedPills.isEmpty ? end : 0, length: 0))
        if editSearchPills(with: event, in: editor) { return true }
        editor.keyDown(with: event)
        return true
    }

    /// The search field's pills answer ⌫, ⌦, ← →, Esc and ⌘A at their edge before the field editor sees them; the editor
    /// alone would beep at ⌫ with no text before the caret. See `SearchQueryTokens.edit`.
    func editSearchPills(with event: NSEvent, in editor: NSTextView) -> Bool {
        let search = router.environment.overlays.search
        guard router.mode == .list, search.isOpen, let window = view.window,
              let field = editor.delegate as? NSTextField, field === searchField(in: window),
              let edit = SearchQueryTokens.edit(SearchFieldKey(event: event), text: search.text,
                                                selected: search.selectedPills, caret: editor.selectedRange()) else {
            return false
        }
        if edit.text != search.text {
            SearchPills.setText(edit.text, of: search, undoManager: editor.undoManager)
            let rest = SearchQueryTokens.rest(of: edit.text)
            if editor.string != rest { editor.string = rest }
        }
        search.selectedPills = edit.selected
        if let caret = edit.caret { editor.setSelectedRange(caret) }
        return edit.consumesKey
    }

    /// A theme change or reload must leave the keys in the toolbar's search field.
    private func searchFieldHasTheKeys() -> Bool {
        guard let window = view.window, let field = searchField(in: window) else { return false }
        return OverlayFocusKeeper.control(of: (field.window ?? window).firstResponder) === field
    }

    /// A pill selected with a click: the field takes the keys with the caret at the pills, where ⌫ removes it.
    private func placeCaretAtPills() {
        let search = router.environment.overlays.search
        guard let window = view.window, let field = searchField(in: window) else { return }
        let target = field.window ?? window
        if OverlayFocusKeeper.control(of: target.firstResponder) !== field { target.makeFirstResponder(field) }
        guard let editor = field.currentEditor() as? NSTextView else { return }
        let start = NSRange(location: 0, length: 0)
        let whole = NSRange(location: 0, length: (editor.string as NSString).length)
        let allSelected = search.selectedPills.count == SearchQueryTokens.pillCount(search.text)
        let caret = editor.selectedRange()
        if caret != start, !(allSelected && caret == whole) { editor.setSelectedRange(start) }
    }

    static let searchFocusAttempts = 50

    /// Gives the toolbar's search field the keys. SwiftUI's focus request does not reach a field inside a toolbar
    /// item, and the item arrives a moment after search opens, so this waits for the field, a few frames at most.
    private func focusSearchField(request: Int, attempt: Int = 0) {
        let search = router.environment.overlays.search
        guard search.isOpen, search.focusRequest == request, router.mode == .list, let window = view.window else { return }
        if let field = searchField(in: window) {
            let target = field.window ?? window
            if OverlayFocusKeeper.control(of: target.firstResponder) !== field { target.makeFirstResponder(field) }
            // A toolbar that is still laying out its items can refuse the field; the next frame tries again
            if OverlayFocusKeeper.control(of: target.firstResponder) === field { return }
        }
        guard attempt < Self.searchFocusAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
            MainActor.assumeIsolated { self?.focusSearchField(request: request, attempt: attempt + 1) }
        }
    }

    /// The toolbar's search field. It lives in the window's toolbar, which in full screen AppKit moves into a
    /// window of its own, so the lookup starts from the toolbar's items rather than from the content view.
    func searchField(in window: NSWindow) -> NSTextField? {
        // A field in the toolbar's overflow has no window and cannot take the keys
        let fields = Self.toolbarFields(of: window).filter {
            $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && !$0.isDescendant(of: view)
        }
        return fields.first(where: Self.isSearchField) ?? fields.first
    }

    static func toolbarFields(of window: NSWindow) -> [NSTextField] {
        var roots: [NSView] = window.toolbar?.items.compactMap(\.view) ?? []
        if let frame = window.contentView?.superview { roots.append(frame) }
        var seen = Set<ObjectIdentifier>()
        var result: [NSTextField] = []
        func walk(_ view: NSView) {
            if view === window.contentView { return }
            if let field = view as? NSTextField, field.isEditable, seen.insert(ObjectIdentifier(field)).inserted {
                result.append(field)
            }
            for child in view.subviews { walk(child) }
        }
        for root in roots { walk(root) }
        return result
    }

    static func isSearchField(_ field: NSTextField) -> Bool {
        var view: NSView? = field
        while let current = view {
            if current.accessibilityIdentifier() == ShellToolbar.searchFieldIdentifier
                || current.identifier?.rawValue == ShellToolbar.searchFieldIdentifier { return true }
            view = current.superview
        }
        return false
    }

    static func hint(for chord: KeyChord) -> String {
        switch chord.key {
        case .character(let c): c.uppercased() + "…"
        case .named: "…"
        }
    }
}

extension SearchFieldKey {
    init(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let characters = event.characters ?? ""
        switch event.keyCode {
        case 51 where !modifiers.contains(.control): self = .deleteBackward
        case 117 where modifiers.isEmpty: self = .deleteForward
        case 123 where modifiers.isEmpty: self = .left
        case 124 where modifiers.isEmpty: self = .right
        case 53 where modifiers.isEmpty: self = .escape
        default:
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "a" {
                self = .selectAll
            } else if modifiers.intersection([.command, .control]).isEmpty, !characters.isEmpty,
                      characters.unicodeScalars.allSatisfy(Self.isTyped) {
                self = .typing(characters)
            } else {
                self = .other
            }
        }
    }

    private static func isTyped(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
    }
}
