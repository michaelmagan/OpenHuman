import MailFeatures
import SwiftUI
import UniformTypeIdentifiers

public struct ClassifierSettingsSection: View {
    @State private var model: ClassifierSettingsModel
    @State private var choosingFolder = false
    @Environment(\.theme) private var theme

    public init(center: AICenter, port: (any LocalClassifierModelPort)?, environment: AppEnvironment?) {
        let model = ClassifierSettingsModel(center: center, port: port)
        model.onChange = { [weak environment] in await environment?.autoLabels?.refreshAvailability() }
        _model = State(initialValue: model)
    }

    public var body: some View {
        SettingsSection(ClassifierSettingsModel.title, footnote: ClassifierSettingsModel.footnote) {
            if let port = model.port {
                SettingsRow(port.modelName, detail: model.statusText, status: model.requirementsText,
                            statusTone: .warning) {
                    HStack(spacing: theme.space3) {
                        if let progress = model.progress {
                            ProgressView(value: progress).frame(width: 120)
                        }
                        if model.isDownloading {
                            Button("Stop") { Task { await model.cancel() } }
                        } else if model.isReady {
                            Button("Delete", role: .destructive) { Task { await model.delete() } }
                        } else {
                            Button(model.downloadTitle) { model.download() }
                                .disabled(!model.canDownload)
                                .accessibilityIdentifier("settings.ai.downloadClassifier")
                        }
                    }
                }
                .task { await model.refresh() }
                SettingsRow("Model folder", detail: model.directory) {
                    HStack(spacing: theme.space3) {
                        Button("Choose…") { choosingFolder = true }
                        Button("Default") { Task { await model.useDirectory(nil) } }
                    }
                    .disabled(model.isDownloading)
                }
                .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result { Task { await model.useDirectory(url.path) } }
                }
                SettingsRow(ClassifierSettingsModel.lowPowerTitle, detail: ClassifierSettingsModel.lowPowerDetail,
                            isOn: $model.allowLowPower)
                SettingsFootnote("Licence: \(port.licence). Downloaded only when you click, from a fixed version, and "
                                 + "checked before use.")
                ForEach(model.leftovers) { leftover in
                    SettingsRow(leftover.name, detail: ClassifierSettingsModel.leftoverText(leftover)) {
                        Button("Delete", role: .destructive) { Task { await model.deleteLeftover(leftover.id) } }
                            .accessibilityIdentifier("settings.ai.deleteLeftover.\(leftover.id)")
                    }
                }
            }
            if let error = model.error { SettingsFootnote(error, tone: .warning) }
        }
    }
}
