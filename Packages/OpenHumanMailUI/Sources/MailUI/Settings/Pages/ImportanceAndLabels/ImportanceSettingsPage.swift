import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI

struct ImportanceSettingsPage: View {
    enum Tab: String, CaseIterable, Hashable {
        case rules, categories, tracking
        var title: String {
            switch self {
            case .rules: "Rules"
            case .categories: "Categories"
            case .tracking: "Tracking"
            }
        }
    }

    @State private var tab: Tab
    @State private var model: ImportanceSettingsModel
    private let learning: LearnedBehaviourCenter?
    @State private var vip: VIPSettingsModel?
    private let environment: AppEnvironment?
    @State private var ruleSet: ClassificationRuleSet
    @State private var tracking: ClassificationTrackingModel
    @Environment(\.theme) private var theme

    init(environment: AppEnvironment) {
        self.init(model: ImportanceSettingsModel(environment: environment), learning: environment.learning,
                  vip: VIPSettingsModel(environment: environment), environment: environment,
                  ruleSet: environment.classification, tracking: ClassificationTrackingModel(environment: environment))
    }

    init(model: ImportanceSettingsModel, learning: LearnedBehaviourCenter? = nil, vip: VIPSettingsModel? = nil,
         environment: AppEnvironment? = nil, ruleSet: ClassificationRuleSet? = nil,
         tracking: ClassificationTrackingModel? = nil, tab: Tab = .rules) {
        let rules = ruleSet ?? ClassificationRuleSet(environment: nil)
        _model = State(initialValue: model)
        self.learning = learning
        _vip = State(initialValue: vip)
        self.environment = environment
        _ruleSet = State(initialValue: rules)
        _tracking = State(initialValue: tracking ?? ClassificationTrackingModel(environment: nil, ruleSet: rules, center: nil))
        _tab = State(initialValue: tab)
    }

    var body: some View {
        SettingsPageScaffold(title: "Importance & labels") {
            Section {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("settings.importance.tabs")
            }
            switch tab {
            case .rules:
                RulesTab(ruleSet: ruleSet, environment: environment)
                importanceRules
            case .categories:
                CategoriesTab(environment: environment)
            case .tracking:
                TrackingTab(model: tracking, ruleSet: ruleSet)
            }
        }
        .onChange(of: ruleSet.pendingDraft) { _, draft in if draft != nil { tab = .rules } }
    }

    @ViewBuilder private var importanceRules: some View {
        SettingsSection("Importance", footnote: "Important: your importance rules, then Gmail's Important mark. Change "
                        + "the Important split's rule in Split inbox.") {
            SettingsRow("Importance rules", detail: ImportanceSettingsModel.precedenceNote)
                .task {
                    model.start()
                    vip?.start()
                }
                .onChange(of: model.account) { _, account in vip?.account = account }
            SettingsRow(ImportanceSettingsModel.sendsToGmailTitle, detail: ImportanceSettingsModel.sendsToGmailDetail,
                        isOn: Binding(get: { model.sendsToGmail.value },
                                      set: { on in Task { await model.sendsToGmail.set(on) } }))
                .accessibilityIdentifier("settings.importance.sendsToGmail")
        }
        importanceContent
    }

    private var importanceContent: some View {
        SettingsSectionStack {
            if model.accounts.count > 1 {
                SettingsSection {
                    SettingsRow("Account", detail: "Each account has its own rules. Rules for every account show under each.",
                                selection: $model.account) {
                        ForEach(model.accounts) { Text($0.alias ?? $0.email).tag(Optional($0.id)) }
                    }
                }
            }
            if let note = model.editNote { SettingsFootnote(note, tone: .warning) }
            ForEach(model.groups) { group in
                SettingsSection(group.title, footnote: group.footnote) {
                    ForEach(group.rows) { row in ruleRow(row) }
                }
            }
            if model.draft != nil { editor } else {
                let isEmpty = model.hasLoaded && model.groups.isEmpty
                SettingsSection(isEmpty ? "Rules" : nil) {
                    SettingsRow("Add a rule",
                                detail: isEmpty ? ImportanceSettingsModel.emptyText : nil) {
                        Button("Add rule…") { model.beginAdd() }
                            .disabled(!model.canEdit || model.isWorking)
                    }
                }
            }
            if let learning { LearnedBehaviourSection(center: learning) }
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
            if let vip { vipSection(vip) }
        }
    }

    @ViewBuilder private func vipSection(_ vip: VIPSettingsModel) -> some View {
        SettingsSection("VIPs") {
            SettingsRow(VIPSettingsModel.suggestTitle, detail: VIPSettingsModel.suggestDetail,
                        isOn: Binding(get: { vip.suggestEnabled }, set: { on in Task { await vip.setSuggestEnabled(on) } }))
            if vip.suggestEnabled {
                if vip.suggestions.isEmpty {
                    SettingsFootnote(VIPSettingsModel.emptyText)
                }
                ForEach(vip.suggestions) { suggestion in
                    SettingsRow(suggestion.question, detail: suggestion.reason) {
                        HStack(spacing: theme.space3) {
                            Button("Mark as VIP") { Task { await vip.accept(suggestion) } }
                                .disabled(!vip.canMarkVIPs)
                                .accessibilityLabel(suggestion.question)
                            Button("Not now") { Task { await vip.decline(suggestion) } }
                                .ohLinkButtonStyle()
                                .accessibilityLabel("Don't suggest \(suggestion.displayName) again")
                        }
                        .disabled(vip.isWorking)
                    }
                }
            }
            if !vip.vips.isEmpty {
                SettingsRow("VIPs", detail: vip.vips.joined(separator: ", "))
            }
            SettingsRow("Reset suggestions", detail: VIPSettingsModel.resetDetail) {
                Button("Reset") { Task { await vip.resetSuggestions() } }
                    .disabled(vip.isWorking)
            }
            if let notice = vip.notice {
                HStack(spacing: theme.space3) {
                    Text(notice).font(.system(size: NativeMetrics.Text.secondary)).foregroundStyle(.secondary)
                    if vip.canUndo {
                        Button("Undo") { Task { await vip.undoLastChange() } }
                            .ohLinkButtonStyle()
                    }
                }
            }
        }
        SettingsErrorLine(text: vip.errorMessage)
    }

    private func ruleRow(_ row: ImportanceSettingsModel.RuleRow) -> some View {
        SettingsRow(row.title, detail: row.detail) {
            HStack(spacing: theme.space3) {
                if row.isEditable {
                    Button("Edit") { model.beginEdit(row) }
                        .ohLinkButtonStyle()
                        .accessibilityLabel("Edit \(row.title)")
                }
                Button("Delete") { Task { await model.delete(row) } }
                    .ohLinkButtonStyle()
                    .accessibilityLabel("Delete \(row.title)")
            }
            .disabled(!model.canEdit || model.isWorking)
        }
    }

    private var editor: some View {
        SettingsSection(model.draft?.id == nil ? "New rule" : "Edit rule") {
            SettingsRow("Applies to", selection: Binding(get: { model.draft?.match ?? .sender },
                                                         set: { model.draft?.match = $0 })) {
                ForEach(ImportanceSettingsModel.editableMatches, id: \.self) {
                    Text(ImportanceSettingsModel.matchTitle($0)).tag($0)
                }
            }
            SettingsRow("Mail is", selection: Binding(get: { model.draft?.effect ?? .important },
                                                      set: { model.draft?.effect = $0 })) {
                Text("Always important").tag(ImportanceRuleEffect.important)
                Text("Never important").tag(ImportanceRuleEffect.neverImportant)
            }
            VStack(alignment: .leading, spacing: theme.space3) {
                TextField(ImportanceSettingsModel.matchTitle(model.draft?.match ?? .sender),
                          text: Binding(get: { model.draft?.value ?? "" }, set: { model.draft?.value = $0 }),
                          prompt: Text(verbatim: ImportanceSettingsModel.prompt(for: model.draft?.match ?? .sender))
                            .settingsPrompt(theme))
                    .settingsTextField()
                    .onSubmit { Task { await model.save() } }
                if let check = model.draftCheck {
                    SettingsFootnote(check.text, tone: check.isProblem ? .warning : .secondary)
                }
                HStack(spacing: theme.space3) {
                    Button("Cancel") { model.cancelEdit() }
                    Button("Save") { Task { await model.save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSave)
                }
            }
            .settingsRowPadding()
        }
    }
}
