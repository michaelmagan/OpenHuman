import MailFeatures
import MailModel
import SwiftUI

struct InboxScreen: View {
    let phone: PhoneMail
    @Environment(\.touch) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if phone.isSearching {
                    SearchResultsHeader(phone: phone)
                } else if let title = phone.locationTitle {
                    LocationHeader(title: title) { phone.goToFirstTab() }
                }
                if let list = phone.list {
                    rows(list)
                }
            }
            .padding(.bottom, phone.chromeHeight + theme.tokens.space4)
        }
        .scrollIndicators(.hidden)
        .refreshable { await phone.refresh() }
        .safeAreaInset(edge: .top, spacing: 0) { InboxTopBar(phone: phone) }
        .background(theme.window)
        .accessibilityIdentifier("inbox.list")
    }

    @ViewBuilder
    private func rows(_ list: ThreadListModel) -> some View {
        if list.state == .loaded, list.rows.isEmpty {
            EmptyListView(isSplit: phone.showsSplitStrip, isSearch: phone.isSearching)
        } else if case .failed(let reason) = list.state {
            EmptyListView(isSplit: false, isSearch: false, failure: reason)
        }
        ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
            SwipeRow(phone: phone, row: row) {
                ThreadRowView(row: row, chips: list.chips(for: row), location: list.location,
                              formatting: phone.formatting)
            }
            .transition(reduceMotion ? AnyTransition.opacity
                        : .asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
            .onAppear { list.visibleRowsDidChange(lastVisibleIndex: index) }
        }
    }
}

struct InboxTopBar: View {
    let phone: PhoneMail
    @Environment(\.touch) private var theme

    var body: some View {
        HStack(spacing: theme.tokens.space3) {
            CircleIconButton(systemImage: "line.3.horizontal", label: "Mailboxes and labels") {
                phone.showsMailboxes = true
            }
            .accessibilityIdentifier("inbox.mailboxes")
            if phone.environment.isFake { SampleBadge() }
            Spacer(minLength: 0)
            PillGroup {
                PillIconButton(systemImage: "magnifyingglass", label: "Search") { phone.openSearch() }
                    .accessibilityIdentifier("inbox.search")
                PillIconButton(systemImage: "square.and.pencil", label: "New message") { phone.newMessage() }
                    .accessibilityIdentifier("inbox.compose")
            }
        }
        .padding(.horizontal, theme.tokens.space4)
        .padding(.top, theme.tokens.space1)
        .padding(.bottom, theme.tokens.space2)
        .topBarBackground(theme.window)
    }
}

struct LocationHeader: View {
    let title: String
    let back: () -> Void
    @Environment(\.touch) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(theme.title)
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Inbox", action: back)
                .font(theme.subject)
                .foregroundStyle(theme.textLink)
        }
        .padding(.horizontal, theme.gutter + theme.tokens.space2)
        .padding(.vertical, theme.tokens.space3)
    }
}

struct SearchResultsHeader: View {
    let phone: PhoneMail
    @Environment(\.touch) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.tokens.space3) {
            VStack(alignment: .leading, spacing: theme.tokens.space1) {
                Text(phone.locationTitle ?? "")
                    .font(theme.headline)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if let summary = phone.search.resultsSummary {
                    Text(summary)
                        .font(theme.date)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer()
            Button("Edit") { phone.showsSearch = true }
                .font(theme.subject)
                .foregroundStyle(theme.textLink)
            Button("Done") { phone.closeSearch() }
                .font(theme.subject.weight(.semibold))
                .foregroundStyle(theme.textLink)
                .accessibilityLabel("Close search")
        }
        .padding(.horizontal, theme.gutter + theme.tokens.space2)
        .padding(.vertical, theme.tokens.space3)
    }
}

struct EmptyListView: View {
    let isSplit: Bool
    let isSearch: Bool
    var failure: String?
    @Environment(\.touch) private var theme

    var body: some View {
        VStack(spacing: theme.tokens.space3) {
            Image(systemName: failure != nil ? "exclamationmark.triangle" : (isSearch ? "magnifyingglass" : "checkmark.circle"))
                .font(.system(.largeTitle, weight: .light))
                .foregroundStyle(failure != nil ? theme.textWarning : theme.textSuccess)
                .accessibilityHidden(true)
            Text(title)
                .font(theme.headline)
                .foregroundStyle(theme.textPrimary)
            Text(detail)
                .font(theme.snippet)
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, theme.tokens.space8)
        .padding(.top, 140)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if failure != nil { return "Couldn't load this list" }
        if isSearch { return "No matches" }
        return isSplit ? "You're done here" : "Nothing here"
    }

    private var detail: String {
        if failure != nil { return "The mail on this iPhone couldn't be read. Try again in a moment." }
        if isSearch { return "Nothing on this iPhone matches the search." }
        return isSplit ? "New mail in this split shows up here." : "No conversations in this view."
    }
}
