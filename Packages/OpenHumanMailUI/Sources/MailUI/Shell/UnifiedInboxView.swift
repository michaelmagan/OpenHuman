import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct UnifiedInboxView: View {
    let model: AllInboxesModel
    let dismiss: () -> Void
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @FocusState private var searchFocused: Bool

    public init(model: AllInboxesModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().overlay(theme.borderHairline.color)
            // Keys belong to the list: letters in the search field above would reach the column first.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.escape) { dismiss(); return .handled }
                .onKeyPress(.return, phases: .down) { _ in model.openCursor(); return .handled }
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in model.moveCursor(by: 1); return .handled }
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in model.moveCursor(by: -1); return .handled }
                .onKeyPress(characters: .letters, phases: [.down, .repeat]) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    switch press.characters {
                    case "j": model.moveCursor(by: 1)
                    case "k": model.moveCursor(by: -1)
                    case "e": model.markDoneAtCursor()
                    case "l": model.labelAtCursor()
                    default: return .ignored
                    }
                    return .handled
                }
                .onKeyPress(KeyEquivalent("/")) { searchFocused = true; return .handled }
        }
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.bgWindow.color)
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("All Inboxes")
    }

    private var searchBar: some View {
        HStack(spacing: theme.space3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: OverlayMetrics.rowIconSize))
                .foregroundStyle(theme.textTertiary.color)
                .accessibilityHidden(true)
            TextField("Search", text: Binding(get: { model.query }, set: { model.setQuery($0) }),
                      prompt: Text(model.searchAllAccounts ? "Search all mail in every account" : "Filter these inboxes"))
                .textFieldStyle(.plain)
                .font(theme.typeBody.swiftUIFont)
                .focused($searchFocused)
                .onSubmit { leaveSearch() }
                .onKeyPress(.escape) {
                    if model.query.isEmpty { leaveSearch() } else { model.setQuery("") }
                    return .handled
                }
                .onKeyPress(.downArrow) { leaveSearch(); return .handled }
                .accessibilityLabel("Search All Inboxes")
            if model.isSearching || model.isLoading { ProgressView().controlSize(.small) }
            Toggle("All accounts", isOn: Binding(get: { model.searchAllAccounts },
                                                 set: { model.setSearchAllAccounts($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(theme.typeCaption.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize()
                .accessibilityHint("Searches all mail in every account instead of filtering the inboxes shown")
        }
        .padding(.horizontal, OverlayMetrics.rowIconX)
        .frame(height: OverlayMetrics.pickerInputHeight)
    }

    private func leaveSearch() {
        searchFocused = false
        focused = true
    }

    @ViewBuilder private var content: some View {
        if let empty = model.emptyText {
            Text(empty)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .padding(OverlayMetrics.rowIconX)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isStaticText)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { row in rowView(row).id(row.id) }
                    }
                }
                .onChange(of: model.cursor) { _, cursor in
                    if let cursor { proxy.scrollTo(cursor) }
                }
            }
        }
    }

    private func rowView(_ row: AllInboxesModel.Row) -> some View {
        let isCursor = model.cursor == row.id
        return Button {
            model.setCursor(row.id)
            model.openCursor()
        } label: {
            HStack(spacing: theme.space3) {
                accountTag(row.account)
                    .frame(width: 120, alignment: .leading)
                Text(row.thread.participantsDisplay)
                    .font(row.thread.isUnread ? theme.typeBodyStrong.swiftUIFont : theme.typeBody.swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                Text(row.thread.subject)
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                Spacer(minLength: theme.space3)
                Text(row.thread.lastMessageAt, format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: NativeMetrics.List.dateTextSize).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, OverlayMetrics.rowIconX)
            .frame(height: theme.component.picker.rowHeight)
            .background { if isCursor { UnifiedInboxSelectionPlate() } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.account): \(row.thread.participantsDisplay), \(row.thread.subject)")
        .accessibilityHint("Return opens it in its account")
        .accessibilityAddTraits(isCursor ? .isSelected : [])
    }

    private func accountTag(_ account: String) -> some View {
        let ink = theme.tokens.labelChip(LabelChipHue.forName(account)).text.color
        return NativeTagCapsule(account, tint: ink, text: ink)
    }
}

/// The cursor row's plate, drawn like the thread list's selection: accent while the window is active, grey otherwise.
private struct UnifiedInboxSelectionPlate: View {
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    #else
    private let appearsActive = true
    #endif

    var body: some View {
        RoundedRectangle(cornerRadius: NativeMetrics.List.plateCornerRadius, style: .continuous)
            .fill(appearsActive ? Color.accentColor.opacity(NativeMetrics.List.selectedAlpha)
                                : Color.primary.opacity(NativeMetrics.List.inactiveSelectedAlpha))
            .padding(.horizontal, NativeMetrics.List.plateInsetX)
            .padding(.vertical, NativeMetrics.List.plateInsetY)
    }
}
