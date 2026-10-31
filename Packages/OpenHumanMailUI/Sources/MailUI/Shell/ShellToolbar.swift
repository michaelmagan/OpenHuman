import MailActions
import MailFeatures
import MailModel
import MailTheme
import SwiftUI

/// The main window's unified toolbar: Back and select-all at the leading edge, the split picker in the centre, the
/// conversation's actions, Calendar, Compose and Search at the trailing edge. With the calendar open, its view switch
/// takes the centre and New event and Refresh join the trailing edge. Every item is a `Label` with a menu
/// command or a key behind it. The items follow the window's place, and a customizable toolbar would make AppKit keep
/// every main window's items the same, so the toolbar is fixed.
public struct ShellToolbar: ToolbarContent {
    public static let searchFieldIdentifier = "search.field"

    public enum ItemID {
        public static let back = "mail.back"
        public static let selectAll = "mail.selectAll"
        public static let splits = "mail.splits"
        public static let sendDrafts = "mail.sendDrafts"
        public static let calendar = "mail.calendar"
        public static let compose = "mail.compose"
        public static let search = "mail.search"
        public static func reader(_ action: ActionID) -> String { "mail.reader.\(action.rawValue)" }
        public static let readerMore = "mail.reader.more"
    }

    let router: AppRouter

    public init(router: AppRouter) {
        self.router = router
    }

    public var body: some ToolbarContent {
        let surface = ShellSurface(router: router)
        if surface.isReader {
            ToolbarItem(id: ItemID.back, placement: .navigation) { backButton }
        }
        if let list = surface.selectableList {
            // The empty slot keeps the title in place; without a check it draws no glass behind it
            ToolbarItem(id: ItemID.selectAll, placement: .navigation) {
                SelectAllCheckbox(list: list, descriptors: router.environment.actions.descriptors)
            }
            .sharedBackgroundVisibility(list.headerCheck == .hidden ? .hidden : .automatic)
        }
        if let state = surface.splitState {
            ToolbarItem(id: ItemID.splits, placement: .principal) { SplitInboxPicker(router: router, state: state) }
        }
        if let count = surface.checkedDraftCount {
            ToolbarItem(id: ItemID.sendDrafts, placement: .primaryAction) { sendDraftsButton(count: count) }
        }
        if let reader = surface.reader {
            ReaderToolbarGroup(actions: ReaderToolbarActions(router: router, reader: reader), router: router)
        }
        if let calendar = router.environment.calendarWindowIfStarted, calendar.isOpen {
            CalendarToolbarItems(router: router, calendar: calendar)
        }
        if let calendar = router.environment.calendarWindow {
            ToolbarItem(id: ItemID.calendar, placement: .primaryAction) { calendarButton(isOpen: calendar.isOpen) }
        }
        ToolbarItem(id: ItemID.compose, placement: .primaryAction) { composeButton }
        ToolbarItem(id: ItemID.search, placement: .primaryAction) { searchItem(surface) }
    }

    private var backButton: some View {
        Button {
            router.closeReader()
        } label: {
            NativeToolbarLabel("Back", systemImage: "chevron.backward")
        }
        .help(Self.help(router, .backToList, title: "Back to the list"))
        .accessibilityLabel("Back")
        .accessibilityIdentifier("toolbar.back")
    }

    private func sendDraftsButton(count: Int) -> some View {
        let enabled = router.isEnabled(.sendDrafts)
        return Button {
            _ = router.perform(.sendDrafts, source: .toolbar)
        } label: {
            NativeToolbarLabel(Self.sendDraftsTitle(count), systemImage: "paperplane")
                .labelStyle(.titleAndIcon)
        }
        .disabled(!enabled)
        .help(enabled ? Self.help(router, .sendDrafts, title: "Send the checked drafts") : "Sending isn't available here")
        .accessibilityLabel(count == 1 ? "Send 1 checked draft" : "Send \(count) checked drafts")
        .accessibilityIdentifier("toolbar.sendDrafts")
    }

    static func sendDraftsTitle(_ count: Int) -> String {
        count == 1 ? "Send Draft" : "Send \(count) Drafts"
    }

    private func calendarButton(isOpen: Bool) -> some View {
        let action: ActionID = isOpen ? .calendarBackToMail : .calendarOpen
        let title = isOpen ? "Back to Mail" : "Calendar"
        return Button {
            _ = router.perform(action, source: .toolbar)
        } label: {
            NativeToolbarLabel(title, systemImage: isOpen ? "envelope" : "calendar")
        }
        .help(Self.help(router, action, title: title))
        .accessibilityLabel(title)
        .accessibilityIdentifier("toolbar.calendar")
    }

    private var composeButton: some View {
        let enabled = router.isEnabled(.compose)
        return Button {
            _ = router.perform(.compose, source: .toolbar)
        } label: {
            NativeToolbarLabel("Compose", systemImage: "square.and.pencil")
        }
        .disabled(!enabled)
        .help(enabled ? Self.help(router, .compose, title: "Compose") : "Compose is not available here")
        .accessibilityLabel("Compose")
        .accessibilityIdentifier("toolbar.compose")
    }

    @ViewBuilder
    private func searchItem(_ surface: ShellSurface) -> some View {
        if surface.showsSearchField {
            SearchFieldView(search: router.environment.overlays.search)
                .frame(minWidth: NativeMetrics.Search.fieldWidth, idealWidth: NativeMetrics.Search.focusedFieldWidth,
                       maxWidth: NativeMetrics.Search.focusedFieldWidth)
                .accessibilityIdentifier(Self.searchFieldIdentifier)
        } else {
            Button {
                _ = router.perform(.search, source: .toolbar)
            } label: {
                NativeToolbarLabel("Search", systemImage: "magnifyingglass")
            }
            .disabled(router.unifiedInbox != nil)
            .help(Self.help(router, .search, title: "Search"))
            .accessibilityLabel("Search")
            .accessibilityIdentifier("toolbar.search")
        }
    }

    @MainActor
    static func help(_ router: AppRouter, _ action: ActionID, title: String) -> String {
        guard let keys = router.environment.actions.descriptor(action)?.shortcutHint else { return title }
        return "\(title)  \(keys)"
    }

    public static func conversationTitle(_ reader: ReaderModel?) -> String {
        guard let reader, !reader.messages.isEmpty else { return "" }
        let sender = reader.messages.last?.summary.from.map { ($0.name?.isEmpty == false ? $0.name : nil) ?? $0.email } ?? ""
        let count = reader.messages.count == 1 ? "1 message" : "\(reader.messages.count) messages"
        if sender.isEmpty { return reader.messages.count == 1 ? "" : count }
        return "\(sender) · \(count)"
    }

    static func titleTooltip(_ total: Int?) -> String {
        guard let total, total > 0 else { return "" }
        return total == 1 ? "1 conversation" : "\(total.formatted()) conversations"
    }
}

/// What the toolbar shows for the window's current place.
@MainActor
struct ShellSurface {
    let state: AccountState?
    let isMail: Bool

    init(router: AppRouter) {
        state = router.active
        isMail = router.environment.calendarWindowIfStarted?.isOpen != true && router.unifiedInbox == nil
    }

    var isReader: Bool { isMail && state?.mode == .reader }

    var reader: ReaderModel? { isReader ? state?.reader : nil }

    var selectableList: ThreadListModel? {
        guard isMail, let state, state.mode == .list, !state.searchOpen else { return nil }
        return state.list
    }

    /// Drafts checked in the Drafts list, for the toolbar's Send button. Nil over a conversation, search, All
    /// Inboxes or the Calendar, which is drawn over the mail column while the list and its checks stay behind it.
    var checkedDraftCount: Int? {
        guard let list = selectableList, state?.location == .system(.drafts), list.checkedCount > 0 else { return nil }
        return list.checkedCount
    }

    var splitState: AccountState? {
        guard isMail, let state, SplitInboxPicker.shows(state) else { return nil }
        return state
    }

    var showsSearchField: Bool {
        guard isMail, let state else { return false }
        return state.searchOpen && state.mode == .list
    }
}

/// The open conversation's actions from `ReaderToolbarActions`: Done, Remind, Label and Trash, then Previous and
/// Next, then everything else under More. The same actions, keys and availability as the conversation's menu commands.
struct ReaderToolbarGroup: ToolbarContent {
    static let moreSymbol = "ellipsis"

    let actions: ReaderToolbarActions
    let router: AppRouter

    var body: some ToolbarContent {
        ForEach(actions.primary) { item in
            ToolbarItem(id: ShellToolbar.ItemID.reader(item.id), placement: .primaryAction) { button(item) }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ForEach(actions.navigation) { item in
            ToolbarItem(id: ShellToolbar.ItemID.reader(item.id), placement: .primaryAction) { button(item) }
        }
        ToolbarItem(id: ShellToolbar.ItemID.readerMore, placement: .primaryAction) { moreMenu }
        ToolbarSpacer(.fixed, placement: .primaryAction)
    }

    private func button(_ item: ReaderToolbarActions.Item) -> some View {
        Button {
            _ = ReaderToolbarActions.perform(item.id, router: router)
        } label: {
            NativeToolbarLabel(item.title, systemImage: item.symbol ?? Self.moreSymbol)
        }
        .disabled(!item.isEnabled)
        .help(item.help)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier("toolbar.\(item.id.rawValue)")
    }

    private var moreMenu: some View {
        let sections = actions.more
        return Menu {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(section) { item in
                        Button(item.title) { _ = ReaderToolbarActions.perform(item.id, router: router, source: .menu) }
                            .disabled(!item.isEnabled)
                    }
                }
            }
        } label: {
            NativeToolbarLabel("More", systemImage: Self.moreSymbol)
        }
        .menuIndicator(.hidden)
        .disabled(sections.isEmpty)
        .help("More actions for this conversation")
        .accessibilityLabel("More actions")
        .accessibilityIdentifier("toolbar.readerMore")
    }
}
