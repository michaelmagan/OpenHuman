import MailFeatures
import MailModel
import MailTheme
import OpenHumanAI
import OpenHumanCore
import SwiftUI

struct CategoriesTab: View {
    let environment: AppEnvironment?
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsSectionStack {
            SettingsSection("Categories", footnote: "Each conversation gets one label. In Gmail, Mail changes only its own "
                            + "OpenHuman labels, and it never renames or deletes them.") {
                ForEach(AutoLabelCategory.allCases, id: \.self) { category in
                    SettingsRow(category.title, detail: Self.meaning(category),
                                status: OHGmailLabels.autoLabel(category.title).map { "In Gmail: \($0)" })
                }
            }
            SettingsSection("Auto labels") {
                SettingsRow("Auto label settings",
                            detail: "Turn auto labels on or off, add them in Gmail and choose how each one affects Important. "
                                + "They're on the General page, with Superhuman labels.") {
                    Button("Open General") { environment?.settingsNavigator.open(SettingsPageID.general.rawValue) }
                        .disabled(environment == nil)
                }
                if let environment, environment.ai != nil {
                    SettingsRow("Instructions to the model", detail: Self.promptsNote) {
                        HStack(spacing: theme.space3) {
                            ForEach(Self.prompts, id: \.self) { id in
                                Button(PromptCatalog.entry(id)?.title ?? id) { environment.settingsNavigator.openPrompt(id) }
                                    .accessibilityLabel("Edit the \(PromptCatalog.entry(id)?.title ?? id) prompt")
                                    .accessibilityIdentifier("settings.categories.prompt.\(id)")
                            }
                        }
                    }
                }
            }
        }
    }

    static let prompts = [PromptName.autoLabel.rawValue, PromptName.classify.rawValue]
    static let promptsNote = "Auto labels picks the label; Triage sorts conversations by what they need from you. "
        + "Each opens its prompt in AI › Prompts."

    static func meaning(_ category: AutoLabelCategory) -> String {
        switch category {
        case .respond: "A real person writes to you and asks for an answer."
        case .waiting: "You wrote last; the other side owes the reply. Never the model's choice."
        case .meeting: "An invitation or a message about a meeting."
        case .invoice: "A bill, a receipt or a payment."
        case .travel: "Flights, hotels, trains and bookings."
        case .pitch: "Unsolicited sales, hiring, partnership or sponsorship outreach."
        case .social: "Notifications from social networks."
        case .news: "A newsletter or news digest."
        case .marketing: "Promotions and marketing from companies."
        }
    }
}
