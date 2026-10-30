import MailFeatures
import MailTheme
import SwiftUI

public struct PromptsSettingsView: View {
    @Bindable var model: PromptsSettingsModel
    @Environment(\.theme) private var theme

    public init(model: PromptsSettingsModel) {
        self.model = model
    }

    public var body: some View {
        if model.selectedID != nil {
            PromptEditorView(model: model)
        } else {
            list
        }
    }

    @ViewBuilder private var list: some View {
        Section {
            if let missing = model.missingPrompt {
                SettingsFootnote(String(localized: "No prompt “\(missing)”."), tone: .warning)
            }
            SettingsFootnote(String(localized: "Every instruction Mail sends to a model. Your version is used from the next request; the default stays available."))
                .task { if model.rows.isEmpty { await model.load() } }
        }
        ForEach(model.sections) { section in
            SettingsSection(section.title) {
                ForEach(section.rows) { row in
                    SettingsRow(row.info.title, detail: row.info.usedBy, status: Self.status(row),
                                statusTone: row.activeRevision == nil ? .secondary : .success) {
                        Button(String(localized: "Edit")) { Task { await model.select(row.id) } }
                            .accessibilityLabel(String(localized: "Edit \(row.info.title)"))
                    }
                    .accessibilityIdentifier("settings.ai.prompt.\(row.id)")
                }
            }
        }
    }

    static func status(_ row: PromptsSettingsModel.Row) -> String {
        var parts = ["\(row.id) · v\(row.version)"]
        if let badge = row.badge { parts.append(badge) }
        if row.isBasedOnOlderDefault { parts.append(String(localized: "written for an older default")) }
        return parts.joined(separator: " · ")
    }
}

struct PromptEditorView: View {
    @Bindable var model: PromptsSettingsModel
    @Environment(\.theme) private var theme

    var body: some View {
        Section {
            header
                .task { if model.rows.isEmpty { await model.load() } }
            Picker(String(localized: "Show"), selection: $model.tab) {
                ForEach(PromptsSettingsModel.EditorTab.allCases, id: \.self) { tab in
                    Text(PromptsSettingsModel.title(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        Section {
            switch model.tab {
            case .mine: mine
            case .original: textBlock(model.originalText)
            case .changes: changes
            case .history: history
            }
        }
        if model.canTest { testSection }
        if let error = model.error {
            Section { SettingsFootnote(error, tone: .danger) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            Button(String(localized: "‹ All prompts")) { model.closeEditor() }
                .ohLinkButtonStyle()
                .accessibilityIdentifier("settings.ai.prompts.back")
            if let row = model.selected {
                Text(row.info.title).font(.title3).fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                Text(row.info.usedBy).font(.system(size: NativeMetrics.Text.secondary)).foregroundStyle(.secondary)
                Text(model.identity).font(.system(size: NativeMetrics.Text.secondary).monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if row.isBasedOnOlderDefault {
                    SettingsFootnote(String(localized: "Your version was written for v\(row.activeBaseVersion ?? 0); v\(row.version) is now the default. It stays in use: compare under Changes, or start again from the default."),
                                     tone: .warning)
                }
            }
        }
    }

    private var mine: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            TextEditor(text: $model.draft)
                .themeFont(theme.typeMono)
                .scrollContentBackground(.hidden)
                .padding(theme.space2)
                .frame(minHeight: 200, maxHeight: 320)
                .background(.background, in: RoundedRectangle(cornerRadius: theme.radiusMD))
                .overlay(RoundedRectangle(cornerRadius: theme.radiusMD).strokeBorder(.quaternary))
                .accessibilityLabel(String(localized: "Prompt text"))
                .accessibilityIdentifier("settings.ai.prompts.editor")
            if let slots = slotsLine { SettingsFootnote(slots) }
            ForEach(model.check.problems, id: \.self) { problem in
                SettingsFootnote(PromptsSettingsModel.message(problem), tone: .danger)
            }
            ForEach(model.check.warnings, id: \.self) { warning in
                SettingsFootnote(PromptsSettingsModel.message(warning), tone: .warning)
            }
            TextField(String(localized: "Note for this version (optional)"), text: $model.note)
                .textFieldStyle(.roundedBorder)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: theme.space3) { primaryButtons; Spacer(minLength: 0); secondaryButtons }
                VStack(alignment: .leading, spacing: theme.space3) {
                    HStack(spacing: theme.space3) { primaryButtons }
                    HStack(spacing: theme.space3) { secondaryButtons }
                }
            }
        }
    }

    @ViewBuilder private var primaryButtons: some View {
        Button(String(localized: "Save my version")) { Task { await model.save() } }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!model.canSave)
            .accessibilityIdentifier("settings.ai.prompts.save")
        Button(String(localized: "Discard changes")) { model.discardChanges() }
            .disabled(!model.hasChanges)
    }

    @ViewBuilder private var secondaryButtons: some View {
        Button(String(localized: "Start from default")) { model.startFromOriginal() }
            .disabled(model.draft == model.originalText)
        Button(String(localized: "Reset to default")) { Task { await model.resetToOriginal() } }
            .disabled(model.selected?.activeRevision == nil)
            .accessibilityIdentifier("settings.ai.prompts.reset")
    }

    private var slotsLine: String? {
        guard let slots = model.selected?.info.slots, !slots.isEmpty else { return nil }
        let names = slots.sorted().map { "{{\($0)}}" }.joined(separator: " ")
        return String(localized: "Filled in by Mail: \(names)")
    }

    private func textBlock(_ text: String) -> some View {
        Text(text)
            .themeFont(theme.typeMono)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(theme.space4)
            .background(.quinary, in: RoundedRectangle(cornerRadius: theme.radiusMD))
    }

    private var changes: some View {
        let lines = model.changes
        return VStack(alignment: .leading, spacing: 0) {
            if !lines.contains(where: { $0.kind != .same }) {
                SettingsFootnote(String(localized: "Same as the default."))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(Self.prefix(line.kind) + line.text)
                    .themeFont(theme.typeMono)
                    .foregroundStyle(color(line.kind).color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(theme.space4)
        .background(.quinary, in: RoundedRectangle(cornerRadius: theme.radiusMD))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Changes from the default"))
    }

    static func prefix(_ kind: PromptsSettingsModel.DiffLine.Kind) -> String {
        switch kind {
        case .same: "  "
        case .added: "+ "
        case .removed: "− "
        }
    }

    private func color(_ kind: PromptsSettingsModel.DiffLine.Kind) -> ThemeColor {
        switch kind {
        case .same: theme.textSecondary
        case .added: theme.textSuccess
        case .removed: theme.textDanger
        }
    }

    @ViewBuilder private var history: some View {
        if model.history.isEmpty {
            SettingsFootnote(String(localized: "No versions of yours yet. Saving makes r1."))
        }
        ForEach(model.history) { revision in
            SettingsRow(Self.title(revision), detail: revision.note, status: Self.status(revision)) {
                if revision.revision == model.selected?.activeRevision {
                    Text(String(localized: "In use")).font(.system(size: NativeMetrics.Text.secondary))
                        .foregroundStyle(theme.textSuccess.color)
                } else {
                    Button(String(localized: "Revert")) { Task { await model.revert(to: revision.revision) } }
                }
            }
        }
    }

    static func title(_ revision: PromptsSettingsModel.Revision) -> String {
        "r\(revision.revision) · " + revision.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    static func status(_ revision: PromptsSettingsModel.Revision) -> String {
        let made = switch revision.origin {
        case .edit: String(localized: "edited")
        case .revert: String(localized: "reverted")
        case .import: String(localized: "imported")
        case .reset: String(localized: "reset")
        }
        return "\(made) · for v\(revision.baseVersion) · \(revision.digest.prefix(8))"
    }

    private var testSection: some View {
        SettingsSection(String(localized: "Test on this thread"),
                        footnote: String(localized: "Runs on the conversation open in the mail window, with the text above (saved or not). The answer shows here only: nothing is stored or sent.")) {
            SettingsRow(String(localized: "Run with this text")) {
                Button(String(localized: "Test")) { Task { await model.runTest() } }
                    .disabled(model.test == .running)
                    .accessibilityIdentifier("settings.ai.prompts.test")
            }
            switch model.test {
            case .idle:
                EmptyView()
            case .running:
                SettingsFootnote(String(localized: "Running…"))
            case .done(let result):
                VStack(alignment: .leading, spacing: theme.space2) {
                    Text(result.subject).fontWeight(.semibold)
                    textBlock(result.output.isEmpty ? String(localized: "(no answer)") : result.output)
                    SettingsFootnote([result.promptIdentity, result.providerName].compactMap { $0 }.joined(separator: " · "))
                }
                .padding(.vertical, theme.space2)
            case .failed(let reason):
                SettingsFootnote(reason, tone: .danger)
            }
        }
    }
}
