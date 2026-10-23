import MailFeatures
import MailModel
import SwiftUI

struct SuperhumanRemindersSection: View {
    @State private var model: SuperhumanRemindersSettingsModel

    init(environment: AppEnvironment) {
        _model = State(initialValue: SuperhumanRemindersSettingsModel(environment: environment))
    }

    var body: some View {
        Group {
            SettingsSection(SuperhumanRemindersSettingsModel.sectionTitle,
                            footnote: SuperhumanRemindersSettingsModel.pendingNote) {
                SettingsRow(SuperhumanRemindersSettingsModel.hideTitle, detail: SuperhumanRemindersSettingsModel.hideNote,
                            isOn: binding(model.hide))
                    .disabled(!model.availability.canEditSettings)
                    .task { model.start() }
                SettingsRow(SuperhumanRemindersSettingsModel.senderTitle, detail: SuperhumanRemindersSettingsModel.senderNote,
                            status: model.sendersError, statusTone: .danger) {
                    TextField(SuperhumanRemindersSettingsModel.senderTitle, text: $model.sendersText)
                        .labelsHidden()
                        .frame(minWidth: 220)
                        .onSubmit { Task { await model.commitSenders() } }
                }
                .disabled(!model.availability.canEditSettings || !model.hide.value)
                SettingsRow(SuperhumanRemindersSettingsModel.archiveTitle,
                            detail: SuperhumanRemindersSettingsModel.archiveNote, isOn: binding(model.archiveInGmail))
                    .disabled(!model.availability.canEditSettings || !model.hide.value)
                importRow
                ForEach(model.unmatched) { email in
                    SettingsRow(SuperhumanRemindersSettingsModel.couldNotMatchTitle,
                                detail: "\(email.subject.isEmpty ? "(no subject)" : email.subject) · "
                                    + email.date.formatted(date: .abbreviated, time: .shortened),
                                status: SuperhumanRemindersSettingsModel.couldNotMatchNote) {
                        Button("Dismiss") { Task { await model.dismiss(email) } }
                    }
                }
            }
        }
    }

    @ViewBuilder private var importRow: some View {
        switch model.phase {
        case .idle, .failed:
            SettingsRow(SuperhumanRemindersSettingsModel.importTitle,
                        detail: model.scanUnavailable ? SuperhumanRemindersSettingsModel.unavailableNote
                            : SuperhumanRemindersSettingsModel.importNote,
                        status: failure, statusTone: .danger) {
                Button("Find reminder emails…") { Task { await model.findReminders() } }
                    .disabled(!model.canImport)
            }
        case .counting:
            SettingsRow(SuperhumanRemindersSettingsModel.importTitle, status: "Counting…") { ProgressView().controlSize(.small) }
        case .preview(let preview):
            SettingsRow(SuperhumanRemindersSettingsModel.importTitle, detail: SuperhumanRemindersSettingsModel.summary(preview)) {
                HStack {
                    Button("Cancel") { model.cancelPreview() }
                    Button("Import") { Task { await model.applyImport() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(preview.changeCount == 0)
                }
            }
        case .applying:
            SettingsRow(SuperhumanRemindersSettingsModel.importTitle, status: "Importing…") { ProgressView().controlSize(.small) }
        case .applied(let text):
            SettingsRow(SuperhumanRemindersSettingsModel.importTitle, status: text, statusTone: .success) {
                if model.canUndoImport {
                    Button("Undo import") { Task { await model.undoImport() } }
                }
            }
        }
    }

    private var failure: String? {
        if case .failed(let text) = model.phase { text } else { nil }
    }

    private func binding<Value>(_ setting: StoredSetting<Value>) -> Binding<Value> {
        Binding(get: { setting.value }, set: { value in Task { await setting.set(value) } })
    }
}
