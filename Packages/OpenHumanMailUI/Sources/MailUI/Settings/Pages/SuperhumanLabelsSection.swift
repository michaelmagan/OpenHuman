import MailFeatures
import MailModel
import SwiftUI

struct SuperhumanLabelsSection: View {
    @State private var importer: SuperhumanLabelImportModel
    @State private var agreement: SuperhumanAgreementModel
    @State private var hide: StoredSetting<Bool>
    @State private var confirmingRemove = false
    private let canEditSettings: Bool
    @Environment(\.theme) private var theme

    init(environment: AppEnvironment) {
        _importer = State(initialValue: SuperhumanLabelImportModel(environment: environment))
        _agreement = State(initialValue: SuperhumanAgreementModel(environment: environment))
        _hide = State(initialValue: StoredSetting(AppSettings.hideSuperhumanLabels, port: environment.settings))
        canEditSettings = SettingsAvailability(environment: environment).canEditSettings
    }

    var body: some View {
        SettingsSection("Superhuman labels", footnote: SuperhumanLabelImportModel.note) {
            SettingsRow("Hide Superhuman labels", detail: SuperhumanLabelImportModel.hideNote,
                        isOn: Binding(get: { hide.value }, set: { value in Task { await hide.set(value) } }))
                .disabled(!canEditSettings)
                .accessibilityIdentifier("settings.superhumanLabels.hide")
                .task {
                    hide.start()
                    await agreement.load()
                }
            importRows
            agreementRows
            SettingsErrorLine(text: hide.errorMessage)
        }
    }

    @ViewBuilder private var importRows: some View {
        switch importer.phase {
        case .idle, .counting:
            SettingsRow("Import Superhuman labels",
                        detail: "Counts the conversations Superhuman sorted on the account you're viewing. Changes nothing.") {
                Button(importer.phase == .counting ? "Counting…" : "Count…") { Task { await importer.count() } }
                    .disabled(importer.phase == .counting)
                    .accessibilityIdentifier("settings.superhumanLabels.count")
            }
        case .failed(let text):
            SettingsFootnote(text, tone: .danger).settingsRowPadding()
            Button("Count again") { Task { await importer.count() } }.settingsRowPadding()
        case .counted, .importing, .removing, .done:
            countRows
            previewRows
            mappingRows
            SettingsRow("Import", detail: importer.writeBlockedReason
                            ?? "Adds Mail's own label to each conversation above, as one change you can undo.",
                        status: doneText, statusTone: .success) {
                HStack(spacing: theme.space3) {
                    Button("Count again") { Task { await importer.count(account: importer.account?.id) } }
                        .disabled(importer.isBusy)
                    Button(importer.phase == .importing ? "Importing…" : importer.importTitle) {
                        Task { await importer.importLabels() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!importer.canImport)
                    .accessibilityIdentifier("settings.superhumanLabels.import")
                }
            }
            SettingsRow("Remove Superhuman labels",
                        detail: "Optional. Takes Superhuman's category labels off conversations that already have Mail's. "
                            + "Superhuman loses them.") {
                Button(importer.removeTitle, role: .destructive) { confirmingRemove = true }
                    .disabled(!importer.canRemove)
                    .accessibilityIdentifier("settings.superhumanLabels.remove")
            }
            .alert("Remove Superhuman labels?", isPresented: $confirmingRemove) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) { Task { await importer.removeSuperhumanLabels() } }
            } message: {
                Text(SuperhumanLabelImportModel.removeWarning)
            }
        }
    }

    private var doneText: String? {
        if case .done(let text) = importer.phase { return text }
        return nil
    }

    @ViewBuilder private var countRows: some View {
        if importer.counts.isEmpty {
            SettingsFootnote("No conversations with a Superhuman category on this account.").settingsRowPadding()
        }
        ForEach(importer.counts) { count in
            SettingsRow(count.category, detail: countDetail(count)) {
                Text(count.toImport.formatted())
                    .monospacedDigit()
                    .accessibilityLabel(Text("\(count.toImport) to import"))
            }
        }
    }

    private func countDetail(_ count: SuperhumanLabelImportModel.CategoryCount) -> String {
        let names = count.sources.map { "[Superhuman]/AI/" + $0 }.joined(separator: ", ")
        let already = count.alreadyOurs == 0 ? "" : "; \(count.alreadyOurs.formatted()) already sorted by Mail"
        return "\(names): \(count.total.formatted()) conversations\(already)"
    }

    @ViewBuilder private var previewRows: some View {
        if !importer.preview.isEmpty {
            VStack(alignment: .leading, spacing: theme.space2) {
                Text("Examples").font(.system(size: NativeMetrics.Text.secondary)).foregroundStyle(.secondary)
                ForEach(importer.preview) { example in
                    HStack(spacing: theme.space3) {
                        Text(example.subject.isEmpty ? "(no subject)" : example.subject).lineLimit(1)
                        Spacer(minLength: theme.space3)
                        Text(example.superhumanName == example.category ? example.category
                             : "\(example.superhumanName) → \(example.category)")
                            .font(.system(size: NativeMetrics.Text.secondary)).foregroundStyle(.secondary)
                        Text(example.lastMessageAt, format: .dateTime.month(.abbreviated).day())
                            .font(.system(size: NativeMetrics.Text.secondary)).foregroundStyle(.tertiary)
                    }
                }
            }
            .settingsRowPadding()
        }
    }

    @ViewBuilder private var mappingRows: some View {
        if !importer.unconfirmed.isEmpty {
            SettingsFootnote(SuperhumanLabelImportModel.mappingNote).settingsRowPadding()
            ForEach(importer.unconfirmed) { label in
                SettingsRow("[Superhuman]/AI/" + label.name,
                            detail: "\(label.conversations.formatted()) conversations"
                                + (label.isKnown ? "" : "; not in Superhuman's documented labels"),
                            selection: mappingBinding(label)) {
                    Text("Skip").tag("")
                    ForEach(AutoLabelSettingsModel.categories, id: \.self) { Text($0).tag($0) }
                }
                .disabled(importer.isBusy || !canEditSettings)
            }
        }
    }

    private func mappingBinding(_ label: SuperhumanLabelImportModel.UnconfirmedLabel) -> Binding<String> {
        Binding(get: { label.mappedTo ?? "" },
                set: { value in Task { await importer.setMapping(value.isEmpty ? nil : value, for: label.name) } })
    }

    @ViewBuilder private var agreementRows: some View {
        SettingsRow("How close are we to Superhuman?", detail: SuperhumanAgreementModel.explanation,
                    status: agreement.note ?? agreement.summary) {
            Button(runTitle) { Task { await agreement.run() } }
                .disabled(agreement.isRunning)
                .accessibilityIdentifier("settings.superhumanLabels.compare")
        }
        if case .failed(let text) = agreement.phase {
            SettingsFootnote(text, tone: .danger).settingsRowPadding()
        }
        if agreement.report.compared > 0 {
            scoreTable.settingsRowPadding()
            confusionTable.settingsRowPadding()
        }
    }

    private var runTitle: String {
        if case .running(let done, let total) = agreement.phase {
            return total == 0 ? "Comparing…" : "Comparing \(done) of \(total)…"
        }
        return agreement.report.compared > 0 ? "Compare again" : "Compare"
    }

    private var scoreTable: some View {
        let report = agreement.report
        return VStack(alignment: .leading, spacing: theme.space2) {
            Text("\(report.fromCache.formatted()) answers Mail already had, \(report.ranOnDevice.formatted()) sorted now"
                 + (report.failed > 0 ? ", \(report.failed.formatted()) couldn't be sorted" : ""))
                .font(.system(size: NativeMetrics.Text.secondary)).foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: theme.space4, verticalSpacing: theme.space1) {
                GridRow {
                    header("Label", leading: true)
                    header("Superhuman")
                    header("Mail")
                    header("Same")
                    header("Precision")
                    header("Recall")
                }
                ForEach(report.perCategory) { score in
                    GridRow {
                        cell(score.category, leading: true)
                        cell(score.superhuman.formatted())
                        cell(score.ours.formatted())
                        cell(score.agreed.formatted())
                        cell(percent(score.precision))
                        cell(percent(score.recall))
                    }
                }
            }
        }
    }

    private var confusionTable: some View {
        let report = agreement.report
        let columns = report.columns
        return VStack(alignment: .leading, spacing: theme.space2) {
            Text("Superhuman's label (rows) against Mail's (columns)")
                .font(.system(size: NativeMetrics.Text.secondary)).foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: theme.space3, verticalSpacing: theme.space1) {
                GridRow {
                    header("", leading: true)
                    ForEach(columns, id: \.self) { header($0 == SuperhumanAgreement.noneColumn ? "None" : $0) }
                }
                ForEach(report.rows, id: \.self) { row in
                    GridRow {
                        cell(row, leading: true)
                        ForEach(columns, id: \.self) { column in
                            let n = report.confusion[row]?[column] ?? 0
                            Text(n == 0 ? "·" : n.formatted())
                                .font(.system(size: NativeMetrics.Text.secondary)).monospacedDigit()
                                .foregroundStyle(row == column ? HierarchicalShapeStyle.primary : .secondary)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func header(_ text: String, leading: Bool = false) -> some View {
        Text(text).font(.system(size: NativeMetrics.Text.secondary)).foregroundStyle(.secondary)
            .gridColumnAlignment(leading ? .leading : .trailing)
    }

    private func cell(_ text: String, leading: Bool = false) -> some View {
        Text(text).font(.system(size: NativeMetrics.Text.secondary)).monospacedDigit().foregroundStyle(.primary)
            .gridColumnAlignment(leading ? .leading : .trailing)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
