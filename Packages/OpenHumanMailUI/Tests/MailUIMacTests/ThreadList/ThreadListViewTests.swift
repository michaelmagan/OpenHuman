import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import Testing
@testable import MailUIMac

private let now = Date(timeIntervalSince1970: 1_791_000_000)

@MainActor
final class StubListHost: ThreadListHost {
    var enabled: Set<ActionID>
    var performed: [ActionID] = []
    var selection: SelectionModel?
    var connectivity: ConnectivityState?
    weak var model: ThreadListModel?

    init(enabled: Set<ActionID> = [.markDone, .trash]) {
        self.enabled = enabled
    }

    func threadListPerform(_ action: ActionID) -> Bool {
        performed.append(action)
        guard let model else { return true }
        let targets = model.actionTargets
        switch action {
        case .markDone: model.applyOptimistic(.markDone(targets))
        case .trash: model.applyOptimistic(.trash(targets))
        default: break
        }
        return true
    }
    func threadListCanPerform(_ action: ActionID) -> Bool { enabled.contains(action) }
    func threadListSelection(for model: ThreadListModel) -> SelectionModel? { selection }
    func threadListConnectivity(for account: AccountID) -> ConnectivityState? { connectivity }
    func threadListTitle(for location: MailLocation) -> String { "Inbox" }
}

@MainActor
@Suite(.serialized)
struct ThreadListViewTests {
    static func window(_ view: NSView, height: CGFloat = 700) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1000, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    static func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    static var hosts: [StubListHost] = []

    static func list(threads: Int, host: StubListHost = StubListHost(), height: CGFloat = 700)
        async throws -> (ThreadListViewController, ThreadListModel, FakeMailStore, NSWindow) {
        let store = FakeMailStore(corpus: .make(threadCount: threads, now: now))
        let model = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1))
        let controller = ThreadListViewController(theme: .light)
        hosts.append(host)
        host.model = model
        controller.host = host
        let window = Self.window(controller.view, height: height)
        controller.model = model
        model.start()
        try await until { model.rows.count == min(threads, ThreadListModel.initialLimit) }
        window.contentView?.layoutSubtreeIfNeeded()
        return (controller, model, store, window)
    }

    func cell(_ controller: ThreadListViewController, _ row: Int) -> ThreadRowView? {
        controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThreadRowView
    }

    @Test func aRowActionRemovesTheRowInTheSameTurnAndMovesTheCursor() async throws {
        let host = StubListHost()
        let (controller, model, _, window) = try await Self.list(threads: 20, host: host)
        defer { window.close() }
        let table = controller.tableView
        model.moveCursor(by: 2)
        #expect(table.selectedRow == 2)
        let target = model.rows[2].id, below = model.rows[3].id
        let before = table.numberOfRows

        #expect(controller.performRowAction(.markDone, key: target))
        #expect(host.performed == [.markDone])
        #expect(table.numberOfRows == before - 1)
        #expect(model.cursor == below)
        #expect(table.selectedRow == 2, "the row below took the cursor at the same index")
        #expect(cell(controller, 2)?.accessibilityLabel()?.contains(model.rows[2].subject) == true)
    }

    @Test func eThroughTheWindowRemovesTheRowInTheSameTurn() async throws {
        let environment = AppEnvironment.fake(corpus: .make(threadCount: 20, now: now), options: .init(remoteAck: .immediate))
        let content = MainContentViewController(router: AppRouter(environment: environment))
        let window = Self.window(content.view)
        defer { window.close() }
        content.keyRouter.isMailWindow = { $0 === window }
        try await until { content.router.list?.rows.count == 20 }
        let table = content.tableView
        try await until { table.numberOfRows == 20 }
        #expect(content.keyRouter.route(Self.key("j", 38, window: window)) == nil)
        let target = try #require(content.router.list?.cursor)
        #expect(content.keyRouter.route(Self.key("e", 14, window: window)) == nil)
        #expect(table.numberOfRows == 19)
        #expect(content.router.list?.index(of: target) == nil)
        try await until { content.router.list?.optimisticKeys.isEmpty == true }
        #expect(table.numberOfRows == 19)
        #expect(content.router.list?.index(of: target) == nil)
        #expect(table.selectedRow == 1)
    }

    static func routed(threads: Int) async throws
        -> (MainContentViewController, ThreadListViewController, ThreadListModel, AppEnvironment, NSWindow) {
        let environment = AppEnvironment.fake(corpus: .make(threadCount: threads, now: now), options: .init(remoteAck: .immediate))
        let content = MainContentViewController(router: AppRouter(environment: environment))
        let window = Self.window(content.view)
        await untilObserved { content.router.list?.rows.count == threads }
        let controller = try #require(content.children.lazy.compactMap { $0 as? ThreadListViewController }.first)
        let list = try #require(content.router.list)
        return (content, controller, list, environment, window)
    }

    @Test func aRowButtonChangesTheRowOnceAndAFailedWriteLeavesNothingBehind() async throws {
        let (content, controller, list, environment, window) = try await Self.routed(threads: 20)
        defer { withExtendedLifetime(content) { window.close() } }
        let store = try #require(environment.commands as? FakeMailStore)
        let unread = try #require(list.rows.first { $0.isUnread }).id
        store.failNextCommand()
        #expect(controller.performRowAction(ThreadListActionIDs.toggleRead, key: unread))
        #expect(list.row(for: unread)?.isUnread == false, "marked read in the same turn")
        await environment.actions.lastTask?.value
        #expect(list.optimisticKeys.isEmpty, "no second change outlives the failed write")
        await untilObserved { list.rows.first { $0.id == unread }?.isUnread == true }

        let done = try #require(list.rows.last).id
        #expect(controller.performRowAction(.markDone, key: done))
        #expect(list.index(of: done) == nil, "hidden in the same turn")
    }

    @Test func aRowToggleOnAMixedSelectionDoesWhatTheActionDoes() async throws {
        let (content, controller, list, environment, window) = try await Self.routed(threads: 20)
        defer { withExtendedLifetime(content) { window.close() } }
        let read = try #require(list.rows.first { !$0.isUnread }).id
        let unread = try #require(list.rows.first { $0.isUnread }).id
        let selection = try #require(content.router.active?.selection)
        selection.toggle(read)
        selection.toggle(unread)
        #expect(controller.performRowAction(ThreadListActionIDs.toggleRead, key: read))
        #expect(list.row(for: unread)?.isUnread == false, "the unread one is marked read")
        #expect(list.row(for: read)?.isUnread == false, "the read one is not flipped to unread")
        await environment.actions.lastTask?.value
        #expect(list.row(for: read)?.isUnread == false && list.row(for: unread)?.isUnread == false)
    }

    @Test func newMailAboveDoesNotMoveTheVisibleRows() async throws {
        let corpus = FakeCorpus.make(threadCount: 301, now: now)
        let store = FakeMailStore(corpus: FakeCorpus(account: corpus.account, threads: Array(corpus.threads.dropFirst())))
        let model = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1))
        let controller = ThreadListViewController(theme: .light)
        let host = StubListHost()
        controller.host = host
        let window = Self.window(controller.view)
        defer { window.close() }
        controller.model = model
        model.start()
        try await until { model.rows.count == 100 }
        window.contentView?.layoutSubtreeIfNeeded()
        let table = controller.tableView
        let clip = try #require(table.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: 40 * table.rowHeight))
        table.enclosingScrollView?.reflectScrolledClipView(clip)
        let firstVisible = model.rows[40].id
        store.insertAtTop(corpus.threads[0])
        try await until { model.rows.first?.id == corpus.threads[0].row.id }
        #expect(model.index(of: firstVisible) == 41)
        #expect(clip.bounds.origin.y == 41 * table.rowHeight, "the same thread is still the first visible row")

        clip.scroll(to: .zero)
        table.enclosingScrollView?.reflectScrolledClipView(clip)
        store.deliverMessage(account: AccountID(1), from: EmailAddress(name: "Sam", email: "sam@example.org"),
                             subject: "Fresh", at: now.addingTimeInterval(7_200))
        try await until { model.rows.first?.subject == "Fresh" }
        #expect(clip.bounds.origin.y == 0)
    }

    @Test func densityChangeRelaysOutWithoutReload() async throws {
        let (controller, model, _, window) = try await Self.list(threads: 150)
        defer { window.close() }
        let table = controller.tableView
        #expect(table.rowHeight == 40)
        model.moveCursor(by: 30)
        let clip = try #require(table.enclosingScrollView?.contentView)
        let top = clip.bounds.origin.y / table.rowHeight
        let visible = controller.visibleRowRange
        let cellsBefore = visible.map { cell(controller, $0) }
        var compact = ThemeTokens.light
        compact.density = .compact
        controller.apply(theme: compact)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(table.rowHeight == 32)
        let after = clip.bounds.origin.y / table.rowHeight
        #expect(abs(after - top) < 0.01 && Int(after + 0.001) == Int(top + 0.001), "the first visible row stays: \(top) → \(after)")
        let same = visible.filter { index in cellsBefore[index - visible.lowerBound].map { cell(controller, index) === $0 } ?? false }
        #expect(same.count == visible.count, "visible cells were re-laid out, not reloaded")
        #expect(table.selectedRow == 30)
        #expect(cell(controller, 30)?.frame.height == 32)
    }

    @Test func rowsExposeAVoiceOverLabelAndCustomActions() async throws {
        let host = StubListHost(enabled: [.markDone, .trash])
        let (controller, model, _, window) = try await Self.list(threads: 10, host: host)
        defer { window.close() }
        let row = model.rows[1]
        let view = try #require(cell(controller, 1))
        #expect(view.isAccessibilityElement())
        let label = try #require(view.accessibilityLabel())
        #expect(label.contains(row.subject))
        #expect(label.contains(ThreadRowFormatting().sender(row).name))
        let actions = try #require(view.accessibilityCustomActions())
        #expect(actions.map(\.name) == ["Mark done", "Trash"])
        #expect(actions[1].handler?() == true)
        #expect(host.performed == [.trash])
        #expect(model.index(of: row.id) == nil, "the custom action hid the row at once")
        #expect(ListAndWindowTests.containsHostingView(view) == false, "no NSHostingView inside cells")
    }

    @Test func voiceOverCanCheckARowWithoutMovingTheCursor() async throws {
        let host = StubListHost(enabled: [.markDone, .trash, .toggleCheck])
        let (controller, model, _, window) = try await Self.list(threads: 10, host: host)
        defer { window.close() }
        let cursor = model.cursor
        let key = model.rows[2].id
        let view = try #require(cell(controller, 2))
        let actions = try #require(view.accessibilityCustomActions())
        #expect(actions.map(\.name) == ["Mark done", "Trash", "Check"])
        #expect(actions[2].handler?() == true)
        #expect(model.selection.checked == [key] && model.cursor == cursor)
        #expect(try #require(view.accessibilityLabel()).hasPrefix("Checked"))
        #expect(try #require(view.accessibilityCustomActions()).last?.name == "Uncheck")
        #expect(host.performed.isEmpty)
    }

    @Test func swipeActionsComeFromTheCatalogAndFollowAvailability() async throws {
        let host = StubListHost(enabled: [.markDone, .trash])
        let (controller, _, _, window) = try await Self.list(threads: 5, host: host)
        defer { window.close() }
        let table = controller.tableView
        #expect(controller.tableView(table, rowActionsForRow: 0, edge: .leading).map(\.title) == ["Mark done"])
        #expect(controller.tableView(table, rowActionsForRow: 0, edge: .trailing).map(\.title) == ["Trash"],
                "Snooze is not in the catalog yet: Trash")
        host.enabled.insert(ThreadListActionIDs.snooze)
        #expect(controller.tableView(table, rowActionsForRow: 0, edge: .trailing).map(\.title) == ["Snooze"])
        host.enabled = []
        #expect(controller.tableView(table, rowActionsForRow: 0, edge: .leading).isEmpty)
        #expect(controller.tableView(table, rowActionsForRow: 0, edge: .trailing).isEmpty)
    }

    @Test func swipeFillsAreFixedSignalColorsAndUnmappedActionsHaveNoPlaceholder() {
        for theme in [ThemeTokens.light, .dark, .midnight] {
            #expect(ThreadListViewController.swipeFill(.markDone, theme: theme) == theme.component.swipe.done)
            #expect(ThreadListViewController.swipeFill(.trash, theme: theme) == theme.component.swipe.trash)
            #expect(ThreadListViewController.swipeFill(ThreadListActionIDs.snooze, theme: theme) == theme.component.swipe.snooze)
        }
        #expect(ThreadListViewController.symbol(.markDone) == "checkmark")
        #expect(ThreadListViewController.symbol(.spam) == nil)
    }

    @Test func aRightClickedRowGetsACatalogMenuThatActsOnIt() async throws {
        let host = StubListHost(enabled: [.markDone, .trash, .toggleStar])
        let (controller, model, _, window) = try await Self.list(threads: 5, host: host)
        defer { window.close() }
        let row = model.rows[2]
        let menu = try #require(controller.contextMenu(forRow: 2))
        #expect(model.cursor == row.id, "the right-clicked row becomes the cursor row")
        #expect(menu.items.filter { !$0.isSeparatorItem }.map { String($0.title.split(separator: "\t").first ?? "") }
                == ["Mark done", "Star or unstar", "Trash"])
        #expect(menu.items.first?.title == "Mark done\tE", "the menu bar's single-key hint")
        #expect(menu.items.filter(\.isSeparatorItem).count == 2, "one section each; destructive last")
        menu.performActionForItem(at: 0)
        #expect(host.performed == [.markDone])
        #expect(model.index(of: row.id) == nil, "Mark done hid the row at once")
        host.enabled = []
        #expect(controller.contextMenu(forRow: 0) == nil)
    }

    @Test func multiSelectKeysClicksAndCheckedRows() async throws {
        let (controller, model, _, window) = try await Self.list(threads: 12)
        defer { window.close() }
        let table = controller.tableView
        let keys = model.rows.map(\.id)
        table.keyDown(with: Self.key("x", 7, window: window))
        table.keyDown(with: Self.key("J", 38, .shift, window: window))
        table.keyDown(with: Self.key("\u{F701}", 125, [.shift, .numericPad, .function], window: window))
        #expect(model.selection.checked == Set(keys[0...2]))
        #expect(model.cursor == keys[2])
        try await until { (table.rowView(atRow: 1, makeIfNecessary: false) as? ThreadRowBackgroundView)?.isChecked == true }
        #expect(cell(controller, 1)?.isChecked == true)
        table.keyDown(with: Self.key("\u{1B}", 53, window: window))
        #expect(model.checkedCount == 0)
        try await until { (table.rowView(atRow: 1, makeIfNecessary: false) as? ThreadRowBackgroundView)?.isChecked == false }
        table.selectAll(nil)
        #expect(model.checkedCount == 12)
        table.cancelOperation(nil)
        let rect = table.rect(ofRow: 5)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: .shift, timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                       pressure: 1)!
        table.mouseDown(with: click)
        #expect(model.selection.checked == Set(keys[2...5]))
        #expect(table.selectedRow == 5)
        #expect(!table.allowsMultipleSelection)
    }

    @Test func commandAChecksFromTheCursorThenEverythingAndCommandShiftAChecksAll() async throws {
        let (controller, model, _, window) = try await Self.list(threads: 12)
        defer { window.close() }
        let table = controller.tableView
        let keys = model.rows.map(\.id)
        model.setCursor(keys[3])
        table.keyDown(with: Self.key("a", 0, .command, window: window))
        #expect(model.selection.checked == Set(keys[3...]))
        #expect(model.offersCheckBefore && model.headerCheck == .some)
        table.keyDown(with: Self.key("a", 0, .command, window: window))
        #expect(model.checkedCount == 12 && model.headerCheck == .all)
        table.keyDown(with: Self.key("\u{1B}", 53, window: window))
        #expect(model.headerCheck == .hidden)
        table.keyDown(with: Self.key("A", 0, [.command, .shift], window: window))
        #expect(model.checkedCount == 12)
    }

    @Test func theGutterBoxShowsOnHoverAndAClickOnItTogglesTheRow() async throws {
        let (controller, model, _, window) = try await Self.list(threads: 12)
        defer { window.close() }
        let table = controller.tableView
        let keys = model.rows.map(\.id)
        let hovered = try #require(cell(controller, 6))
        #expect(!hovered.showsEmptyCheckbox)
        hovered.setHovering(true)
        #expect(hovered.showsEmptyCheckbox)
        hovered.setHovering(false)
        #expect(!hovered.showsEmptyCheckbox)

        let rect = table.frameOfCell(atColumn: 0, row: 6)
        let columns = controller.style.columns(width: rect.width)
        let gutter = NSPoint(x: rect.minX + columns.dotCenterX, y: rect.midY)
        #expect(controller.isCheckboxHit(row: 6, at: gutter))
        #expect(!controller.isCheckboxHit(row: 6, at: NSPoint(x: rect.midX, y: rect.midY)))
        #expect(!controller.isCheckboxHit(row: 6, at: NSPoint(x: rect.minX + columns.sender.lowerBound + 1, y: rect.midY)),
                "the sender name opens the conversation")
        table.userInterfaceLayoutDirection = .rightToLeft
        #expect(controller.isCheckboxHit(row: 6, at: NSPoint(x: rect.maxX - columns.dotCenterX, y: rect.midY)))
        #expect(!controller.isCheckboxHit(row: 6, at: gutter))
        table.userInterfaceLayoutDirection = .leftToRight
        func click(_ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: table.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        table.mouseDown(with: click(gutter))
        #expect(model.selection.checked == [keys[6]])
        #expect(model.headerCheck == .some)
        table.mouseDown(with: click(gutter))
        #expect(model.checkedCount == 0)
    }

    @Test func placeholdersFillWhenTheListScrollsDeep() async throws {
        let (controller, model, _, window) = try await Self.list(threads: 2_600)
        defer { window.close() }
        let table = controller.tableView
        #expect(table.numberOfRows == 2_600)
        #expect(cell(controller, 0)?.isPlaceholder == false)
        let clip = try #require(table.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: 2_450 * table.rowHeight))
        table.enclosingScrollView?.reflectScrolledClipView(clip)
        window.contentView?.layoutSubtreeIfNeeded()
        try await until(timeout: .seconds(60)) { model.rows.count == 2_600 }
        window.contentView?.layoutSubtreeIfNeeded()
        let visible = controller.visibleRowRange
        #expect(!visible.isEmpty)
        for index in visible { #expect(cell(controller, index)?.isPlaceholder == false) }
        #expect(table.numberOfRows == 2_600)
    }

    @Test func aPlaceholderRowShowsAPulsingSkeletonNotAnEmptyBar() async throws {
        let (controller, _, _, window) = try await Self.list(threads: 50)
        defer { window.close() }
        let cell = try #require(cell(controller, 0))
        #expect(!cell.isShimmering, "a loaded row does not pulse")
        cell.configurePlaceholder(showsSkeleton: true)
        #expect(cell.isPlaceholder && cell.drawsSkeleton)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { #expect(cell.isShimmering) }
        cell.frame = NSRect(x: 0, y: 0, width: 900, height: 36)
        let rep = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: rep)
        var painted = false
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) where !painted {
            for y in 0..<rep.pixelsHigh where rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.01 { painted = true; break }
        }
        #expect(painted)
    }

    @Test func emptyInboxShowsTheDaysTitle() async throws {
        let corpus = FakeCorpus.make(threadCount: 1, now: now)
        let store = FakeMailStore(corpus: FakeCorpus(account: corpus.account, threads: []))
        let model = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1))
        let controller = ThreadListViewController(theme: .light)
        let host = StubListHost()
        controller.host = host
        let window = Self.window(controller.view)
        defer { window.close() }
        controller.model = model
        model.start()
        try await until { model.state == .loaded }
        let empty = try #require(controller.view.subviews.compactMap { $0 as? ThreadListEmptyView }.first)
        try await until { !empty.isHidden }
        #expect(empty.state?.style == .inboxClear)
        #expect(empty.state?.title == "Inbox zero.")
    }

    @Test func hoverShowsActionsWithoutMovingText() async throws {
        let (controller, _, _, window) = try await Self.list(threads: 5)
        defer { window.close() }
        let rowView = try #require(controller.tableView.rowView(atRow: 1, makeIfNecessary: false) as? ThreadRowBackgroundView)
        let view = try #require(cell(controller, 1))
        rowView.setHovering(true)
        view.layoutSubtreeIfNeeded()
        #expect(view.isHovering)
        let plate = try #require(view.subviews.first)
        let columns = ThreadRowView.columns(width: view.bounds.width)
        #expect(plate.frame.maxX == columns.date.upperBound)
        #expect(plate.frame.minX >= columns.subject.upperBound)
        #expect(plate.subviews.compactMap { $0 as? NSButton }.map { $0.accessibilityLabel() } == ["Mark done"])
        #expect(plate.subviews.compactMap { $0 as? NSButton }.allSatisfy { $0.toolTip == nil })
        rowView.setHovering(false)
        #expect(!view.isHovering)
    }

    @Test func aThemeChangeThroughTheWindowKeepsTheList() async throws {
        let environment = AppEnvironment.fake(corpus: .make(threadCount: 20, now: now))
        let content = MainContentViewController(router: AppRouter(environment: environment))
        let window = Self.window(content.view)
        defer { window.close() }
        try await until { content.tableView.numberOfRows == 20 }
        let table = content.tableView
        var compact = ThemeTokens.light
        compact.density = .compact
        content.apply(theme: compact)
        #expect(content.tableView === table)
        #expect(table.rowHeight == 32 && table.numberOfRows == 20)
    }
}
