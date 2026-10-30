import MailFeatures
import MailModel
import MailTheme
import SwiftUI

struct MentionPickerView: View {
    let picker: MentionPickerModel
    @Environment(\.theme) private var theme

    static let rowHeight: CGFloat = 32
    static let width: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(picker.rows.enumerated()), id: \.element.id) { index, row in
                Button { picker.choose(row) } label: {
                    HStack(spacing: theme.space4) {
                        Text(row.displayName)
                            .font(theme.typeBody.swiftUIFont)
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.emailText(row, primary: theme.textPrimary.color, rest: theme.textSecondary.color))
                            .font(theme.typeBody.swiftUIFont)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, theme.space4)
                    .frame(height: Self.rowHeight)
                    .background(CursorRowBackground(isCursor: index == picker.cursor))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.displayName)
                .accessibilityValue(row.address.email)
                .accessibilityAddTraits(index == picker.cursor ? .isSelected : [])
                .accessibilityIdentifier("composer.mention.row.\(index)")
            }
        }
        .padding(.vertical, theme.space1)
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgElevated.color))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusLG).strokeBorder(theme.borderElevated.color, lineWidth: theme.borderWidthHairline))
        .themeShadow(theme.shadow2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mention a contact")
        .accessibilityIdentifier("composer.mention")
    }

    static func emailText(_ row: MentionRow, primary: Color, rest: Color) -> AttributedString {
        var matched = AttributedString(row.emailMatched)
        matched.foregroundColor = primary
        var tail = AttributedString(row.emailRest)
        tail.foregroundColor = rest
        return matched + tail
    }
}

// The @-mention list in the floating completion panel under the body: the editor keeps the caret and the keys, and
// opening or narrowing the list moves nothing in the card
struct FloatingMentionList: View {
    let picker: MentionPickerModel
    let floating: FloatingCompletion
    @Environment(\.theme) private var theme
    @State private var list = CompletionListModel()

    static func query(_ picker: MentionPickerModel) -> String {
        "@" + (picker.query ?? "")
    }

    var body: some View {
        floating.anchor(FloatingCompletion.Request(
            list: list, isPresented: !picker.isClosed && !picker.rows.isEmpty, theme: theme,
            label: String(localized: "Mention a contact"), identifier: "composer.mention",
            accept: { address in
                guard let row = picker.rows.first(where: { $0.address == address }) else { return }
                picker.choose(row)
            }))
            .frame(width: MentionPickerView.width, height: 1)
            .accessibilityHidden(true)
            .onAppear(perform: mirror)
            .onChange(of: picker.rows) { _, _ in mirror() }
            .onChange(of: picker.cursor) { _, _ in mirror() }
            .onChange(of: picker.query) { _, _ in mirror() }
    }

    private func mirror() {
        list.mirror(query: Self.query(picker), items: picker.rows.map(\.address), cursor: picker.cursor)
    }
}
