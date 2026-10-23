import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI

/// The column shown in the window's sidebar: All Inboxes, one section per account with its mailboxes, the active
/// account's labels, and Calendar. Selection is the system's; choosing a row navigates.
public struct MailSidebar: View {
    let router: AppRouter
    @Environment(\.theme) private var theme
    @State private var collapsedAccounts: Set<AccountID> = []
    @State private var labelsExpanded = true

    public init(router: AppRouter) {
        self.router = router
    }

    public var body: some View {
        List(selection: selection) {
            if router.showsAllInboxes { allInboxesRow }
            ForEach(Array(router.accounts.enumerated()), id: \.element.id) { position, state in
                accountSection(state, position: position + 1)
            }
            if let state = router.active { labelsSection(state) }
            if router.environment.calendarWindow != nil { calendarSection }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: NativeMetrics.Sidebar.minWidth, ideal: NativeMetrics.Sidebar.idealWidth,
                                        max: NativeMetrics.Sidebar.maxWidth)
        .accessibilityIdentifier("sidebar")
        .accessibilityLabel("Sidebar")
    }

    private var selection: Binding<MailSidebarSelection?> {
        Binding(get: { MailSidebarModel.current(router) }, set: { MailSidebarModel.select($0, router: router) })
    }

    private var allInboxesRow: some View {
        let count = router.allInboxesUnread
        let mode = router.accountCountMode
        return Label("All Inboxes", systemImage: "tray.2")
            .badge(count ?? 0)
            .tag(MailSidebarSelection.allInboxes)
            .help(AccountSwitcherView.allInboxesTooltip(count, mode))
            .contextMenu {
                if router.environment.settings != nil {
                    Button(mode == .off ? "Show count" : "Hide count") { AccountSwitcherView.toggleCounts(router) }
                    Button("Hide All Inboxes") { router.hideAllInboxes() }
                }
            }
            .accessibilityValue(count.map { AccountSwitcherView.countPhrase(String($0), mode) } ?? "")
            .accessibilityHint("Control-0 shows every account's inbox together")
            .accessibilityIdentifier("sidebar.allInboxes")
    }

    private func accountSection(_ state: AccountState, position: Int) -> some View {
        let sections = MailSidebarSections.make(state)
        return Section(isExpanded: expansion(of: state.id)) {
            inboxRow(state)
            ForEach(sections.mailboxes) { item in mailboxRow(item, in: state) }
        } header: {
            AccountSectionHeader(router: router, state: state, position: position)
        }
    }

    private func inboxRow(_ state: AccountState) -> some View {
        let mode = router.accountCountMode
        let count = state.badgeCount(mode) ?? 0
        return Label("Inbox", systemImage: "tray")
            .badge(count)
            .tag(MailSidebarSelection.inbox(state.id))
            .accessibilityValue(count > 0 ? AccountSwitcherView.unreadValue(count, mode) : "")
            .accessibilityIdentifier("sidebar.\(state.id.rawValue).inbox")
    }

    private func mailboxRow(_ item: SidebarItem, in state: AccountState) -> some View {
        let folder = state.sidebarFolder(for: item.location)
        return Label(item.title, systemImage: item.symbol)
            .badge(item.count ?? 0)
            .tag(MailSidebarSelection.location(state.id, item.location))
            .contextMenu {
                if let folder {
                    Button("Hide from sidebar") { MailSidebarModel.hide(folder, router: router) }
                }
            }
            .accessibilityValue(item.count.map { "\($0)" } ?? "")
    }

    @ViewBuilder private func labelsSection(_ state: AccountState) -> some View {
        let labels = MailSidebarSections.make(state).labels
        if !labels.isEmpty {
            Section(isExpanded: $labelsExpanded) {
                OutlineGroup(labels, children: \.children) { label in labelRow(label, in: state) }
            } header: {
                Text("Labels")
                    .help(router.showsAccountSwitcher ? AccountSwitcherView.name(state.account) : "")
            }
        }
    }

    private func labelRow(_ label: MailSidebarLabel, in state: AccountState) -> some View {
        Label {
            Text(label.item.title)
        } icon: {
            Image(systemName: "tag.fill").foregroundStyle(tagColor(label.hue))
        }
        .badge(label.item.count ?? 0)
        .tag(MailSidebarSelection.location(state.id, label.item.location))
        .accessibilityLabel(label.item.title)
        .accessibilityValue(label.item.count.map { "\($0)" } ?? "")
    }

    private func tagColor(_ hue: LabelChipHue) -> Color {
        hue == .neutral ? Color.secondary : theme.tokens.labelChip(hue).text.color
    }

    private var calendarSection: some View {
        Section {
            Label("Calendar", systemImage: "calendar")
                .tag(MailSidebarSelection.calendar)
                .accessibilityIdentifier("sidebar.calendar")
        }
    }

    private func expansion(of account: AccountID) -> Binding<Bool> {
        Binding(get: { !collapsedAccounts.contains(account) }, set: { expanded in
            if expanded { collapsedAccounts.remove(account) } else { collapsedAccounts.insert(account) }
        })
    }
}

/// An account's section title: its picture and name, a mark when it needs signing in again, and the account
/// commands in its context menu.
private struct AccountSectionHeader: View {
    let router: AppRouter
    let state: AccountState
    let position: Int

    var body: some View {
        let account = state.account
        let isActive = state.id == router.activeAccountID && router.unifiedInbox == nil
        let needsSignIn = account.health == .needsSignIn
        HStack {
            AccountAvatar(account: account, size: NativeMetrics.Sidebar.avatarSize,
                          textSize: NativeMetrics.Sidebar.avatarTextSize)
            Text(AccountSwitcherView.name(account))
                .lineLimit(1)
                .truncationMode(.middle)
            if needsSignIn {
                Spacer(minLength: 0)
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .help(AccountSwitcherView.tooltip(account, position: position))
        .contextMenu {
            if !isActive {
                Button("Switch to \(AccountSwitcherView.name(account))") { router.switchAccount(to: account.id) }
            }
            if needsSignIn, router.environment.accounts != nil {
                Button("Sign in again…") { AccountSwitcherView.signInAgain(account, router: router) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AccountSwitcherView.name(account))
        .accessibilityValue(isActive ? "Active" : (needsSignIn ? "Needs sign-in" : ""))
        .accessibilityHint(position <= 9 ? "Control-\(position) switches to this account" : "")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("sidebar.account.\(state.id.rawValue)")
    }
}
