import MailFeatures
import MailModel
import SwiftUI

struct LearnedBehaviourSection: View {
    let center: LearnedBehaviourCenter
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsSection(LearnedBehaviourCenter.switchTitle) {
            SettingsRow(LearnedBehaviourCenter.switchTitle, detail: LearnedBehaviourCenter.switchDetail,
                        isOn: Binding(get: { center.isOn }, set: { on in Task { await center.setOn(on) } }))
                .accessibilityIdentifier("settings.importance.learnSwitch")
            if center.isOn {
                ForEach(center.suggestions) { suggestion in
                    SettingsRow(suggestion.text) {
                        HStack(spacing: theme.space3) {
                            Button(suggestion.actionTitle) { Task { await center.accept(suggestion) } }
                            Button("Not now") { Task { await center.notNow(suggestion) } }
                        }
                    }
                }
                if center.suggestions.isEmpty {
                    SettingsRow(center.observationCount == 0 ? "Nothing noticed yet."
                                : "Noticed \(center.observationCount) actions. No suggestions yet.")
                }
            }
            if center.isOn {
                SettingsRow(LearnedBehaviourCenter.seedTitle, detail: LearnedBehaviourCenter.seedDetail,
                            isOn: Binding(get: { center.seedOn }, set: { on in Task { await center.setSeedOn(on) } }))
                if center.seedOn {
                    SettingsRow("Learn from Superhuman's categories", status: center.seedMessage) {
                        Button("Learn Now") { Task { await center.learnNow() } }
                            .disabled(center.isSeeding)
                    }
                }
            }
            if !center.report.rows.isEmpty {
                ForEach(center.report.rows) { row in
                    SettingsRow("Auto label \(row.category)", detail: row.text)
                }
            }
            SettingsRow(LearnedBehaviourCenter.resetTitle,
                        detail: "Forgets what Mail learned on this Mac. Accepted rules stay.") {
                Button("Reset…") { Task { await center.reset() } }
                    .disabled(center.observationCount == 0)
            }
            if let error = center.errorMessage { SettingsFootnote(error, tone: .warning) }
        }
    }
}
