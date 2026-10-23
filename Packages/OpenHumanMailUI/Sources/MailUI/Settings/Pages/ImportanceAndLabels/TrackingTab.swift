import MailFeatures
import MailModel
import MailTheme
import SwiftUI

struct TrackingTab: View {
    @State var model: ClassificationTrackingModel
    let ruleSet: ClassificationRuleSet
    @State private var confirmClearLog = false
    @State private var confirmClearCorrections = false
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsSectionStack {
            SettingsSection("Tracking", footnote: "Kept on this Mac only. Without the last switch nothing from your mail's "
                            + "text is stored: only what the rules saw (yes or no, counts) and the sender's domain.") {
                SettingsRow("Keep a log of how each conversation was sorted", isOn: binding(model.logEnabled))
                    .task { model.start() }
                    .onChange(of: ruleSet.revision) { _, _ in Task { await model.reload() } }
                SettingsRow("Learn from my corrections", detail: "Not important, Label as… and Wrong label are kept as examples.",
                            isOn: binding(model.teach))
                SettingsRow("Suggest rules when I correct", detail: "Offers \u{201C}Always do this for this sender, domain "
                            + "or list\u{201D}; nothing is saved until you tap.", isOn: binding(model.suggest))
                SettingsRow("Keep subject and preview text with corrections and the log", isOn: binding(model.keepText))
            }
            decisionLog
            corrections
            if let message = model.message { SettingsFootnote(message) }
        }
    }

    private var decisionLog: some View {
        SettingsSection("Decision log", footnote: model.hasLoaded && model.shownDecisions.isEmpty
                        ? "Nothing logged yet. Each newly sorted conversation adds a row." : nil) {
            SettingsRow("Show", selection: $model.filter) {
                ForEach(ClassificationTrackingModel.Filter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            ForEach(model.shownDecisions.prefix(50)) { row in
                SettingsRow(model.subject(row.account, row.thread) ?? "Conversation not on this Mac",
                            detail: model.line(row),
                            status: "\(row.decidedAt.formatted(date: .abbreviated, time: .shortened)) · "
                                + RuleWords.applied(row.appliedState))
            }
            SettingsRow("Clear decision log", detail: "Local notes only; your mail is not touched.") {
                Button("Clear decision log…") { confirmClearLog = true }
                    .disabled(model.decisions.isEmpty)
            }
            .confirmationDialog("Clear the decision log?", isPresented: $confirmClearLog) {
                Button("Clear decision log", role: .destructive) { Task { await model.clearLog() } }
            } message: {
                Text("This removes Mail's notes on how conversations were sorted on this Mac. It doesn't change any mail.")
            }
        }
        .accessibilityIdentifier("settings.tracking.log")
    }

    private var corrections: some View {
        SettingsSection("Corrections", footnote: model.hasLoaded && model.examples.isEmpty
                        ? "No corrections yet." : nil) {
            ForEach(model.examples.prefix(50)) { example in
                SettingsRow(model.subject(example.account, example.thread) ?? "Conversation not on this Mac",
                            detail: ClassificationTrackingModel.exampleLine(example),
                            status: example.createdAt.formatted(date: .abbreviated, time: .shortened)) {
                    Button("Delete") { Task { await model.delete(example) } }
                        .ohLinkButtonStyle()
                }
            }
            SettingsRow("Clear corrections", detail: "Local examples only; your rules and mail are not touched.") {
                Button("Clear corrections…") { confirmClearCorrections = true }
                    .disabled(model.examples.isEmpty)
            }
            .confirmationDialog("Clear your corrections?", isPresented: $confirmClearCorrections) {
                Button("Clear corrections", role: .destructive) { Task { await model.clearExamples() } }
            } message: {
                Text("This removes the examples Mail kept from your corrections. It doesn't change any mail or rule.")
            }
        }
    }

    private func binding(_ setting: StoredSetting<Bool>) -> Binding<Bool> {
        Binding(get: { setting.value }, set: { value in Task { await setting.set(value) } })
    }
}
