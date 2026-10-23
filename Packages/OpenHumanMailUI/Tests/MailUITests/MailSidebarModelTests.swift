import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import Testing
@testable import MailUI

private let account = AccountID(1)
private let muted = GmailLabelID("Label_muted")
private let important = MailLocation.split(SplitKey("important"))

private func userLabel(_ id: String, _ name: String, color: String? = nil, position: Int) -> LabelInfo {
    LabelInfo(id: Int64(position), account: account, labelID: GmailLabelID(id), kind: .user, name: name,
              displayName: String(name.split(separator: "/").last ?? Substring(name)), colorBackground: color,
              position: position)
}

private func labelItem(_ label: LabelInfo, count: Int? = nil) -> SidebarItem {
    SidebarItem(location: .label(label.labelID), title: label.displayName, count: count, symbol: "tag",
                depth: label.name.split(separator: "/").count - 1)
}

private func isFolder(_ location: MailLocation) -> Bool {
    if case .label(let id) = location { return id == muted }
    if case .system = location { return true }
    return false
}

@Test func theSplitTabsFoldIntoOneInboxRowAndFoldersKeepTheirOrder() {
    let items = [
        SidebarItem(location: important, title: "Important", count: 3, symbol: "line.3.horizontal"),
        SidebarItem(location: .splitOther, title: "Other", count: nil, symbol: "line.3.horizontal"),
        SidebarItem(location: .system(.snoozed), title: "Snoozed", count: 2, symbol: "clock"),
        SidebarItem(location: .label(muted), title: "Muted", count: nil, symbol: "speaker.slash"),
        SidebarItem(location: .system(.sent), title: "Sent", count: nil, symbol: "paperplane"),
        SidebarItem(location: .reviewQueue(nil), title: "Review queue", count: 1, symbol: "doc.badge.ellipsis"),
    ]
    let sections = MailSidebarSections.make(items: items, tabs: [important, .splitOther], isFolder: isFolder, labels: [])
    #expect(sections.mailboxes.map(\.location) == [.system(.snoozed), .label(muted), .system(.sent), .reviewQueue(nil)],
            "tabs leave the list; Muted is a folder, not a label")
    #expect(sections.labels.isEmpty)
}

@Test func aPlainInboxWithoutSplitsIsTheInboxRowToo() {
    let items = [
        SidebarItem(location: .system(.inbox), title: "Inbox", count: 5, symbol: "tray"),
        SidebarItem(location: .system(.drafts), title: "Drafts", count: 1, symbol: "doc"),
    ]
    let sections = MailSidebarSections.make(items: items, tabs: [.system(.inbox)], isFolder: isFolder, labels: [])
    #expect(sections.mailboxes.map(\.location) == [.system(.drafts)])
}

@Test func userLabelsNestByTheirGmailPathAndTakeTheirChipColour() throws {
    let projects = userLabel("L1", "Projects", position: 1)
    let older = userLabel("L2", "Projects Old", position: 2)
    let atlas = userLabel("L3", "Projects/Atlas", color: "#a479e2", position: 3)
    let acme = userLabel("L4", "Clients/Acme", color: "#16a766", position: 4)
    let travel = userLabel("L5", "Travel", position: 5)
    let items = [labelItem(acme, count: 2), labelItem(projects), labelItem(older), labelItem(atlas, count: 4),
                 labelItem(travel)]
    let sections = MailSidebarSections.make(items: items, tabs: [], isFolder: isFolder,
                                            labels: [projects, older, atlas, acme, travel])
    #expect(sections.mailboxes.isEmpty)
    #expect(sections.labels.map(\.item.title) == ["Acme", "Projects", "Projects Old", "Travel"],
            "a label whose parent is not shown stays at the top")
    let nested = try #require(sections.labels[1].children)
    #expect(nested.map(\.item.title) == ["Atlas"], "Atlas nests under Projects even with Projects Old between them")
    #expect(nested[0].item.count == 4)
    #expect(sections.labels[2].children == nil && sections.labels[3].children == nil)

    #expect(nested[0].hue == LabelChipHue.nearest(toHex: "#a479e2"), "a Gmail colour picks the nearest chip hue")
    #expect(sections.labels[0].hue == LabelChipHue.nearest(toHex: "#16a766"))
    #expect(sections.labels[3].hue == LabelChipHue.forName("Travel"), "without a colour the name picks the hue")
    #expect(sections.labels[3].hue == ThreadRowChip(kind: .label, title: "Travel").hue, "the same hue as its row chip")
}

@Test func theSelectionFollowsWhatTheWindowShows() {
    let tabs: Set<MailLocation> = [important, .splitOther]
    #expect(MailSidebarModel.selection(calendarOpen: true, allInboxes: true, account: account, location: important,
                                       tabs: tabs) == .calendar)
    #expect(MailSidebarModel.selection(calendarOpen: false, allInboxes: true, account: account, location: important,
                                       tabs: tabs) == .allInboxes)
    #expect(MailSidebarModel.selection(calendarOpen: false, allInboxes: false, account: account, location: .splitOther,
                                       tabs: tabs) == .inbox(account))
    #expect(MailSidebarModel.selection(calendarOpen: false, allInboxes: false, account: account,
                                       location: .system(.inbox), tabs: tabs) == .inbox(account))
    #expect(MailSidebarModel.selection(calendarOpen: false, allInboxes: false, account: account,
                                       location: .system(.done), tabs: tabs) == .location(account, .system(.done)))
    #expect(MailSidebarModel.selection(calendarOpen: false, allInboxes: false, account: account,
                                       location: .search("budget"), tabs: tabs) == .location(account, .search("budget")),
            "search results select no row")
    #expect(MailSidebarModel.selection(calendarOpen: false, allInboxes: false, account: account, location: nil,
                                       tabs: tabs) == nil)
    #expect(MailSidebarModel.selection(calendarOpen: false, allInboxes: false, account: nil, location: important,
                                       tabs: tabs) == nil)
}

@MainActor
@Test func choosingSidebarRowsNavigatesAcrossAccounts() async throws {
    let env = AppEnvironment.fake(corpus: .small, options: .init(remoteAck: .immediate))
    let router = env.router
    router.start()
    defer { router.stop() }
    await awaitObserved("both accounts and the first list load") {
        router.accounts.count == 2 && router.list?.state == .loaded
    }
    let first = router.accounts[0].id
    let second = router.accounts[1].id
    #expect(MailSidebarModel.current(router) == .inbox(first), "the split tabs select the Inbox row")

    MailSidebarModel.select(.location(second, .system(.sent)), router: router)
    #expect(router.activeAccountID == second)
    #expect(router.location == .system(.sent))
    #expect(MailSidebarModel.current(router) == .location(second, .system(.sent)))

    MailSidebarModel.select(.inbox(second), router: router)
    #expect(router.activeAccountID == second)
    #expect(MailSidebarModel.current(router) == .inbox(second), "Inbox leaves Sent for the account's tabs")

    MailSidebarModel.select(.allInboxes, router: router)
    #expect(router.unifiedInbox != nil)
    #expect(MailSidebarModel.current(router) == .allInboxes)

    MailSidebarModel.select(.inbox(first), router: router)
    #expect(router.unifiedInbox == nil, "an account row leaves All Inboxes")
    #expect(router.activeAccountID == first)
    #expect(MailSidebarModel.current(router) == .inbox(first))

    MailSidebarModel.select(nil, router: router)
    #expect(router.activeAccountID == first && MailSidebarModel.current(router) == .inbox(first),
            "clearing the selection does not navigate")
}
