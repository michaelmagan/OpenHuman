import MailActions
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore

/// A row the sidebar can select. The router's state decides which one is selected; selecting one navigates.
public enum MailSidebarSelection: Hashable, Sendable {
    case allInboxes
    /// The account's inbox: its split tabs, or its plain Inbox without splits.
    case inbox(AccountID)
    case location(AccountID, MailLocation)
    case calendar
}

/// A user label in the sidebar's outline, with the labels nested under it.
struct MailSidebarLabel: Identifiable, Hashable {
    let item: SidebarItem
    /// The full Gmail name ("Projects/Atlas"); the row shows `item.title`.
    let name: String
    let hue: LabelChipHue
    var children: [MailSidebarLabel]?

    init(item: SidebarItem, name: String, hue: LabelChipHue, children: [MailSidebarLabel]? = nil) {
        self.item = item
        self.name = name
        self.hue = hue
        self.children = children
    }

    var id: MailLocation { item.location }
}

/// One account's rows: the split tabs fold into a single Inbox row, folders follow, and user labels form an outline.
struct MailSidebarSections: Equatable {
    var mailboxes: [SidebarItem]
    var labels: [MailSidebarLabel]

    @MainActor static func make(_ state: AccountState) -> MailSidebarSections {
        make(items: state.sidebarItems, tabs: Set(state.tabs.map(\.location)),
             isFolder: { state.sidebarFolder(for: $0) != nil }, labels: state.labels)
    }

    static func make(items: [SidebarItem], tabs: Set<MailLocation>, isFolder: (MailLocation) -> Bool,
                     labels: [LabelInfo]) -> MailSidebarSections {
        var mailboxes: [SidebarItem] = []
        var flat: [MailSidebarLabel] = []
        for item in items where !tabs.contains(item.location) && item.location != .system(.inbox) {
            if case .label(let id) = item.location, !isFolder(item.location) {
                let info = labels.first { $0.labelID == id }
                flat.append(MailSidebarLabel(item: item, name: info?.name ?? item.title,
                                             hue: hue(title: item.title, color: info?.colorBackground)))
            } else {
                mailboxes.append(item)
            }
        }
        return MailSidebarSections(mailboxes: mailboxes, labels: tree(flat))
    }

    /// The same colour the label's chip has in the thread list.
    static func hue(title: String, color: String?) -> LabelChipHue {
        ThreadRowChip(kind: .label, title: title, color: color).hue
    }

    /// Nests labels by their Gmail path ("Projects/Atlas" under "Projects"), keeping the input order among siblings.
    /// A label whose parent is not shown nests under its nearest shown ancestor, or stays at the top.
    static func tree(_ flat: [MailSidebarLabel]) -> [MailSidebarLabel] {
        var byName: [String: Int] = [:]
        for (index, node) in flat.enumerated() { byName[node.name] = index }
        var children = Array(repeating: [Int](), count: flat.count)
        var roots: [Int] = []
        for (index, node) in flat.enumerated() {
            var parent: Int?
            var path = node.name[...]
            while parent == nil, let slash = path.lastIndex(of: "/") {
                path = path[..<slash]
                if let found = byName[String(path)], found != index { parent = found }
            }
            if let parent { children[parent].append(index) } else { roots.append(index) }
        }
        func build(_ index: Int) -> MailSidebarLabel {
            var node = flat[index]
            let nested = children[index].map(build)
            node.children = nested.isEmpty ? nil : nested
            return node
        }
        return roots.map(build)
    }
}

@MainActor
enum MailSidebarModel {
    static func current(_ router: AppRouter) -> MailSidebarSelection? {
        selection(calendarOpen: router.environment.calendarWindowIfStarted?.isOpen == true,
                  allInboxes: router.unifiedInbox != nil, account: router.active?.id, location: router.active?.location,
                  tabs: Set(router.active?.tabs.map(\.location) ?? []))
    }

    nonisolated static func selection(calendarOpen: Bool, allInboxes: Bool, account: AccountID?, location: MailLocation?,
                                      tabs: Set<MailLocation>) -> MailSidebarSelection? {
        if calendarOpen { return .calendar }
        if allInboxes { return .allInboxes }
        guard let account, let location else { return nil }
        if location == .system(.inbox) || tabs.contains(location) { return .inbox(account) }
        return .location(account, location)
    }

    static func select(_ selection: MailSidebarSelection?, router: AppRouter) {
        guard let selection else { return }
        switch selection {
        case .allInboxes:
            router.goToAllInboxes()
        case .calendar:
            _ = router.perform(.calendarOpen, source: .toolbar)
        case .inbox(let account):
            router.switchAccount(to: account)
            router.environment.calendarWindowIfStarted?.stepAside()
            guard let state = router.active, state.id == account else { return }
            let tabs = Set(state.tabs.map(\.location))
            if Self.selection(calendarOpen: false, allInboxes: false, account: account, location: state.location, tabs: tabs)
                != .inbox(account) {
                router.goToInbox()
            }
        case .location(let account, let location):
            router.switchAccount(to: account)
            guard router.activeAccountID == account else { return }
            router.go(to: location)
        }
    }

    /// Hides a folder from every account's sidebar, with the router's notice and Undo.
    static func hide(_ folder: SidebarFolder, router: AppRouter) {
        switch folder.place {
        case .system(let system):
            router.hideFromSidebar(.system(system))
        case .muted:
            if let muted = router.active?.mutedLabel { router.hideFromSidebar(.label(muted.labelID)) }
        }
    }
}
