import MailActions
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

public struct ContextSidebarView: View {
    let model: ContextSidebarModel
    let router: AppRouter
    @Environment(\.theme) private var theme

    public init(model: ContextSidebarModel, router: AppRouter) {
        self.model = model
        self.router = router
    }

    public var body: some View {
        let panel = model.person == nil && model.thread == nil ? ListSidePanelView.panel(for: router) : nil
        let title = panel?.title ?? "Contact"
        VStack(alignment: .leading, spacing: 0) {
            RightPaneTabs(selected: .contact, contactTitle: title, contact: nil,
                          calendar: model.hasCalendar ? { model.showCalendar() } : nil, close: { model.setVisible(false) })
            Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: theme.space5) {
                    if let person = model.person {
                        card(person)
                        vipInset
                        recent
                    } else if let panel {
                        ListSidePanelView(router: router, panel: panel)
                    } else if !model.isLoading {
                        Text("Only your own addresses are in this conversation.")
                            .themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
                    }
                }
                .padding(theme.space5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: theme.component.sidebar.width)
        .frame(maxHeight: .infinity)
        .background(theme.component.sidebar.bg.color)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.borderHairline.color).frame(width: theme.borderWidthHairline)
        }
        .task(id: router.reader?.thread) { await model.show(thread: router.reader?.thread) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("contact.sidebar")
    }

    private func card(_ person: ContextSidebarModel.Person) -> some View {
        HStack(alignment: .center, spacing: theme.space3) {
            Text(person.initials)
                .themeFont(theme.typeBodyStrong)
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.bgSunken.color))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.space1) {
                Button { model.searchPerson() } label: {
                    Text(person.displayName).themeFont(theme.typeBodyStrong).foregroundStyle(theme.textPrimary.color)
                        .lineLimit(2)
                }
                .buttonStyle(.plain)
                .help("Search mail with \(person.displayName)")
                .accessibilityIdentifier("contact.name")
                Button { model.compose() } label: {
                    Text(person.email).themeFont(theme.typeMeta).foregroundStyle(theme.accentText.color)
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("New message to \(person.email)")
                .accessibilityIdentifier("contact.address")
                if model.personIsVIP {
                    Text("★ VIP").themeFont(theme.typeMeta).foregroundStyle(theme.textWarning.color)
                        .help("You marked this person as a VIP: their mail is always important.")
                        .accessibilityIdentifier("contact.vip")
                }
            }
        }
    }

    @ViewBuilder
    private var vipInset: some View {
        if let suggestion = model.vipSuggestion {
            VStack(alignment: .leading, spacing: theme.space2) {
                Text(suggestion.question).themeFont(theme.typeBodyStrong).foregroundStyle(theme.textPrimary.color)
                Text(suggestion.reason).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                HStack(spacing: theme.space3) {
                    Button("Mark as VIP") { Task { await model.acceptVIP() } }
                        .accessibilityIdentifier("contact.vip.accept")
                    Button("Not now") { Task { await model.declineVIP() } }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("contact.vip.decline")
                }
            }
            .padding(theme.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgSunken.color))
        }
        if let message = model.vipMessage {
            Text(message).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
        }
    }

    @ViewBuilder
    private var recent: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            Text("Recent conversations").themeFont(theme.typeLabel).foregroundStyle(theme.textTertiary.color)
                .accessibilityAddTraits(.isHeader)
            if model.isLoading && model.recent.isEmpty {
                ProgressView().controlSize(.small)
            } else if model.recent.isEmpty {
                Text("No other conversations with them on this Mac.")
                    .themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
            }
            ForEach(model.recent) { item in
                Button { model.open(item.id) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.subject.isEmpty ? "(no subject)" : item.subject)
                            .themeFont(item.isUnread ? theme.typeBodyStrong : theme.typeBody)
                            .foregroundStyle(theme.textPrimary.color).lineLimit(2)
                        Text(item.date.formatted(date: .abbreviated, time: .omitted))
                            .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct RightPaneTabs: View {
    enum Tab { case contact, calendar }

    let selected: Tab
    var contactTitle = "Contact"
    let contact: (() -> Void)?
    let calendar: (() -> Void)?
    let close: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let hide = selected == .contact ? "Hide \(contactTitle.lowercased())" : "Hide calendar"
        HStack(spacing: theme.space3) {
            tab(contactTitle, .contact, contact)
            if calendar != nil || selected == .calendar { tab("Calendar", .calendar, calendar) }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").foregroundStyle(Self.closeTint(theme.tokens).color).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shortcutTip(selected == .contact ? .toggleContextSidebar : .calendarToggleSidebar, title: hide)
            .accessibilityLabel(hide)
        }
        .padding(.horizontal, theme.space5)
        .padding(.vertical, theme.space4)
    }

    static func closeTint(_ theme: ThemeTokens) -> ThemeColor { theme.textSecondary }

    @ViewBuilder
    private func tab(_ title: String, _ tab: Tab, _ action: (() -> Void)?) -> some View {
        if tab == selected {
            Text(title).themeFont(theme.typeHeadline).foregroundStyle(theme.textPrimary.color)
                .accessibilityAddTraits([.isHeader, .isSelected])
        } else if let action {
            Button(title, action: action).buttonStyle(.borderless)
                .themeFont(theme.typeHeadline).foregroundStyle(theme.textSecondary.color)
                .shortcutTip(tab == .calendar ? .calendarToggleSidebar : .toggleContextSidebar,
                             title: "Show \(title.lowercased())")
        }
    }
}
