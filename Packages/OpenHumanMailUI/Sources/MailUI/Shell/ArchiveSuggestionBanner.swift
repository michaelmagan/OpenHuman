import MailFeatures
import MailModel
import SwiftUI

struct ArchiveSuggestionBanner: View {
    let model: ArchiveSuggestionModel
    let suggestion: ArchiveSuggestionModel.Suggestion
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.space1) {
                Text(suggestion.text)
                    .font(theme.typeLabel.swiftUIFont)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ArchiveSuggestionModel.footnote)
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: theme.space3)
            Button("\(suggestion.confirmTitle)  ⌥⌘E") { Task { await model.confirm() } }
                .ohLinkButtonStyle()
                .font(theme.typeLabel.swiftUIFont)
                .accessibilityLabel(suggestion.confirmTitle)
                .accessibilityHint("Archives them. Undo with Command Z.")
            if model.canEditRules {
                Button("Always / Never…") { model.openRules() }
                    .ohLinkButtonStyle()
                    .font(theme.typeLabel.swiftUIFont)
                    .accessibilityHint("Opens Settings, where you choose senders and domains to always or never include.")
            }
            Button("Not now") { Task { await model.notNow() } }
                .ohLinkButtonStyle()
                .font(theme.typeLabel.swiftUIFont)
            Button { model.dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close the cleanup suggestion")
        }
        .padding(.horizontal, NativeMetrics.Banner.paddingX)
        .padding(.vertical, theme.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nativeGlassCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inbox cleanup suggestion")
    }
}
