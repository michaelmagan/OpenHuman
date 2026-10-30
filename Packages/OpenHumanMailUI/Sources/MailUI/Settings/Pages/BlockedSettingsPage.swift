import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI

struct BlockedSettingsPage: View {
    @State private var model: BlockedSettingsModel
    @Environment(\.theme) private var theme

    init(environment: AppEnvironment) {
        _model = State(initialValue: BlockedSettingsModel(environment: environment))
    }

    var body: some View {
        SettingsPageScaffold(title: "Blocked") {
            Section {
                SettingsFootnote("Mail from a blocked sender or domain skips the Inbox. \(BlockedSettingsModel.unblockNote)")
                if let note = model.editNote { SettingsFootnote(note, tone: .warning) }
            }
            if model.accounts.count > 1 {
                SettingsSection {
                    SettingsRow("Account", detail: "Each account has its own blocked list.", selection: $model.account) {
                        ForEach(model.accounts) { Text($0.alias ?? $0.email).tag(Optional($0.id)) }
                    }
                }
            }
            SettingsSection("New mail from a blocked sender") {
                SettingsRow("By default", detail: "A rule can choose differently below.",
                            selection: Binding(get: { model.defaultDisposition },
                                               set: { value in Task { await model.setDefault(value) } })) {
                    ForEach(BlockDisposition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!model.canEdit)
            }
            SettingsSection("Add") {
                VStack(alignment: .leading, spacing: theme.space3) {
                    TextField("Address or domain", text: $model.newValue,
                              prompt: Text(verbatim: "name@example.com or example.com").settingsPrompt(theme))
                        .settingsTextField()
                        .onSubmit { Task { await model.addTyped() } }
                    HStack(spacing: theme.space3) {
                        Button("Block") { Task { await model.addTyped() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canEdit || model.isWorking || model.newValue.isEmpty)
                    }
                    if let pending = model.pendingConfirmation {
                        SettingsFootnote("You've written to \(pending.value). Block it anyway?", tone: .warning)
                        HStack(spacing: theme.space3) {
                            Button("Block anyway") { Task { await model.confirmPending() } }
                            Button("Cancel") { model.cancelPending() }
                        }
                    }
                }
            }
            SettingsSection(model.rules.isEmpty ? "Blocked" : "Blocked (\(model.rules.count))") {
                if !model.rules.isEmpty {
                    TextField("Search", text: $model.query, prompt: Text(verbatim: "Search blocked").settingsPrompt(theme))
                        .settingsTextField()
                        .accessibilityIdentifier("settings.blocked.search")
                }
                if model.hasLoaded && model.rules.isEmpty {
                    SettingsFootnote(BlockedSettingsModel.emptyText)
                }
                ForEach(model.visibleRules) { rule in ruleRow(rule) }
                if !model.rules.isEmpty && model.visibleRules.isEmpty {
                    SettingsFootnote("Nothing matches that search.")
                }
            }
            if let change = model.lastChange, model.canUndoLastChange {
                Section {
                    HStack(spacing: theme.space3) {
                        Text(change.title).font(.system(size: NativeMetrics.Text.secondary)).foregroundStyle(.secondary)
                        Button("Undo") { Task { await model.undoLastChange() } }
                            .ohLinkButtonStyle()
                            .accessibilityLabel("Undo \(change.title)")
                    }
                }
            }
            SettingsErrorLine(text: model.errorMessage)
        }
        .task { model.start() }
    }

    private func ruleRow(_ rule: BlockRule) -> some View {
        let title = rule.kind == .domain ? "\(rule.value) (whole domain)" : rule.value
        return SettingsRow(title, detail: model.dispositionText(rule)) {
            HStack(spacing: theme.space3) {
                Menu("New mail") {
                    Button("Use the default") { Task { await model.setDisposition(nil, of: rule) } }
                    ForEach(BlockDisposition.allCases, id: \.self) { choice in
                        Button(choice.title) { Task { await model.setDisposition(choice, of: rule) } }
                    }
                }
                .disabled(!model.canEdit || model.isWorking)
                .accessibilityLabel("What happens to new mail from \(rule.value)")
                Button("Show mail") { model.showMail(rule) }
                    .ohLinkButtonStyle()
                    .accessibilityLabel("Show mail from \(rule.value)")
                Button("Unblock") { Task { await model.unblock(rule) } }
                    .ohLinkButtonStyle()
                    .disabled(!model.canEdit || model.isWorking)
                    .accessibilityLabel("Unblock \(rule.value)")
            }
        }
    }
}
