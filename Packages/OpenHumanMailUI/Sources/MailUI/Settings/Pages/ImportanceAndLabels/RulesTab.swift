import MailFeatures
import MailModel
import MailTheme
import OpenHumanAI
import SwiftUI

struct RulesTab: View {
    let ruleSet: ClassificationRuleSet
    let environment: AppEnvironment?
    @State private var draft: RuleDraft?
    @State private var paramsDraft: DefaultParamsDraft?
    @State private var note: String?
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsSectionStack {
            SettingsSection("How mail is sorted", footnote: "The first step that decides wins. Rules only choose a label; "
                            + "labels reach Gmail when Mail applies them. “Tell Gmail when I move mail” controls Important moves.") {
                ForEach(Array(Self.steps(modelLine: modelLine).enumerated()), id: \.offset) { index, step in
                    SettingsRow("\(index + 1). \(step.0)", detail: step.1)
                }
            }
            userRules
            if let draft { editor(draft) }
            defaultRules
            if let paramsDraft { paramsEditor(paramsDraft) }
            if let note { SettingsFootnote(note) }
            SettingsErrorLine(text: ruleSet.errorMessage)
            SettingsFootnote("Rules as of version \(ruleSet.version).")
        }
    }

    private func takePendingDraft() {
        guard let pending = ruleSet.pendingDraft else { return }
        ruleSet.pendingDraft = nil
        draft = RuleDraft(rule: pending, isNew: true)
    }

    static func steps(modelLine: String) -> [(String, String)] {
        [("Your answer for a conversation", "Label as…, Wrong label, or a label you changed in Gmail; kept until a new message."),
         ("Your rules", "In the order below."),
         ("Default rules", "The nine rules Mail ships with; switch off or edit any of them."),
         ("Saved results", "A conversation already sorted with the same message, prompt and model."),
         ("A label already in Gmail", "An OpenHuman label on the conversation is read back."),
         ("The model", modelLine)]
    }

    private var modelLine: String {
        let center = environment?.autoLabels
        switch center?.availability {
        case .unavailable(let why): return why
        default: return "The on-device classifier with the autolabel.classify prompt, version \(AutoLabelPrompt.version)."
        }
    }


    private var userRules: some View {
        SettingsSection("Your rules", footnote: ruleSet.config.rules.isEmpty
                        ? "No rules yet. Add one, or use \u{201C}Always do this for…\u{201D} after a correction." : nil) {
            ForEach(Array(ruleSet.config.rules.enumerated()), id: \.element.id) { index, rule in
                userRuleRow(rule, index: index)
            }
            SettingsRow("Add a rule", detail: "Label mail by sender, domain, List-Id, words and more.") {
                Button("Add rule…") { draft = RuleDraft() }
                    .disabled(draft != nil)
                    .accessibilityIdentifier("settings.rules.add")
            }
            .task {
                await ruleSet.load()
                takePendingDraft()
            }
            .onChange(of: ruleSet.pendingDraft) { _, _ in takePendingDraft() }
        }
    }

    private func userRuleRow(_ rule: ClassificationRule, index: Int) -> some View {
        SettingsRow(rule.title, detail: RuleWords.sentence(rule),
                    status: rule.isKnown ? nil : "Uses something this version doesn't know; it never matches.",
                    statusTone: .warning) {
            HStack(spacing: theme.space3) {
                Button("Up") { Task { _ = await ruleSet.move(ruleID: rule.id, by: -1) } }
                    .ohLinkButtonStyle().disabled(index == 0)
                    .accessibilityLabel("Move \(rule.title) up")
                Button("Down") { Task { _ = await ruleSet.move(ruleID: rule.id, by: 1) } }
                    .ohLinkButtonStyle().disabled(index == ruleSet.config.rules.count - 1)
                    .accessibilityLabel("Move \(rule.title) down")
                if let editable = RuleDraft(rule: rule) {
                    Button("Edit") { draft = editable }
                        .ohLinkButtonStyle()
                        .accessibilityLabel("Edit \(rule.title)")
                }
                Button("Delete") { Task { _ = await ruleSet.delete(ruleID: rule.id) } }
                    .ohLinkButtonStyle()
                    .accessibilityLabel("Delete \(rule.title)")
                SettingsSwitch(title: rule.title, isOn: Binding(get: { rule.enabled }, set: { on in
                    Task { _ = await ruleSet.setEnabled(ruleID: rule.id, on) }
                }))
            }
        }
    }


    private func editor(_ current: RuleDraft) -> some View {
        SettingsSection(current.isNew ? "New rule" : "Edit rule") {
            VStack(alignment: .leading, spacing: theme.space3) {
                TextField("Name", text: binding(\.title), prompt: Text("Newsletters from the example list are News")
                            .settingsPrompt(theme))
                    .settingsTextField()
                Picker("Match", selection: binding(\.matchAll)) {
                    Text("All of these").tag(true)
                    Text("Any of these").tag(false)
                }
                .fixedSize()
                ForEach(Array(current.conditions.enumerated()), id: \.element.id) { index, condition in
                    conditionRow(condition, index: index)
                }
                HStack(spacing: theme.space3) {
                    Button("Add condition") { draft?.conditions.append(RuleDraft.Condition()) }
                    Picker("Then", selection: binding(\.action)) {
                        ForEach(AutoLabelCategory.allCases, id: \.self) { Text("Label \($0.title)").tag(RuleDraft.Action.label($0)) }
                        Text("No label").tag(RuleDraft.Action.noLabel)
                        ForEach(AutoLabelCategory.modelCategories, id: \.self) {
                            Text("Never \($0.title)").tag(RuleDraft.Action.never($0))
                        }
                    }
                    .fixedSize()
                }
                Picker("Account", selection: binding(\.account)) {
                    Text("Every account").tag("")
                    ForEach(accountEmails, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                if let problem = current.problem { SettingsFootnote(problem, tone: .warning) }
                HStack(spacing: theme.space3) {
                    Button("Cancel") { draft = nil }
                    Button("Save") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(current.problem != nil)
                }
            }
            .settingsRowPadding()
        }
    }

    private func conditionRow(_ condition: RuleDraft.Condition, index: Int) -> some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            conditionHead(condition, index: index)
            if condition.predicate.takesValue {
                TextField("Value", text: conditionBinding(index, \.value),
                          prompt: Text(Self.prompt(for: condition.predicate)).settingsPrompt(theme))
                    .settingsTextField()
            }
        }
    }

    private func conditionHead(_ condition: RuleDraft.Condition, index: Int) -> some View {
        HStack(spacing: theme.space2) {
            Toggle("Not", isOn: conditionBinding(index, \.negated)).ohCheckboxToggleStyle().fixedSize()
            Picker("If", selection: Binding(get: { condition.predicate }, set: { id in
                draft?.conditions[index] = RuleDraft.Condition(predicate: id, value: condition.value, negated: condition.negated)
            })) {
                ForEach(RuleWords.editorPredicates, id: \.self) { Text(RuleWords.title($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if !RuleWords.ops(condition.predicate).isEmpty {
                Picker("How", selection: conditionBinding(index, \.op)) {
                    ForEach(RuleWords.ops(condition.predicate), id: \.self) { Text(RuleWords.opTitle($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: 0)
            Button("Remove") { draft?.conditions.remove(at: index) }
                .ohLinkButtonStyle()
                .fixedSize()
                .disabled((draft?.conditions.count ?? 0) <= 1)
        }
    }

    static func prompt(for predicate: RulePredicateID) -> String {
        switch predicate {
        case .sender: "name@example.com"
        case .listID: "news.example.com"
        case .recipientCount, .messageCount: "10"
        case .gmailLabel: "Clients"
        case .currentLabel: "news"
        default: "words"
        }
    }

    private var accountEmails: [String] {
        guard let center = environment?.autoLabels else { return [] }
        return center.accountAddresses
    }

    private func binding<Value>(_ path: WritableKeyPath<RuleDraft, Value>) -> Binding<Value> {
        Binding(get: { draft.map { $0[keyPath: path] } ?? RuleDraft()[keyPath: path] },
                set: { draft?[keyPath: path] = $0 })
    }

    private func conditionBinding<Value>(_ index: Int, _ path: WritableKeyPath<RuleDraft.Condition, Value>) -> Binding<Value> {
        Binding(get: { draft?.conditions[ruleSafe: index]?[keyPath: path] ?? RuleDraft.Condition()[keyPath: path] },
                set: { value in
                    guard draft?.conditions.indices.contains(index) == true else { return }
                    draft?.conditions[index][keyPath: path] = value
                })
    }

    private func save() async {
        guard let current = draft, let rule = current.rule() else { return }
        let saved = current.isNew ? await ruleSet.add(rule) : await ruleSet.update(rule)
        if saved {
            draft = nil
            note = String(localized: "Saved. Mail sorts new and recent mail with it; ⌘Z undoes it.")
        }
    }


    private var defaultRules: some View {
        SettingsSection("Default rules", footnote: "Your rules come first. A default you switch off or edit stays that "
                        + "way when Mail updates; Reset brings back the shipped one.") {
            ForEach(ruleSet.config.defaultRules) { rule in defaultRow(rule) }
        }
    }

    private func defaultRow(_ rule: ClassificationRule) -> some View {
        let active = DefaultRules.isActiveInThisBuild(rule.id)
        let learnNote = rule.id == DefaultRules.senderRejections && environment?.learning.isOn != true
            ? "\u{201C}Learn from what I do\u{201D} is off, so this has nothing to do yet." : nil
        return SettingsRow(rule.title, detail: DefaultRules.summary(rule.id),
                           status: rule.edited ? "Edited" : learnNote, statusTone: rule.edited ? .warning : .secondary) {
            HStack(spacing: theme.space3) {
                if DefaultRules.hasParams(rule.id) {
                    Button("Edit") { paramsDraft = DefaultParamsDraft(rule: rule) }
                        .ohLinkButtonStyle()
                        .accessibilityLabel("Edit \(rule.title)")
                }
                if rule.edited {
                    Button("Reset") { Task { _ = await ruleSet.setDefault(rule.id, params: nil) } }
                        .ohLinkButtonStyle()
                        .accessibilityLabel("Reset \(rule.title)")
                }
                SettingsSwitch(title: rule.title, isOn: Binding(get: { rule.enabled }, set: { on in
                    Task { _ = await ruleSet.setDefault(rule.id, enabled: on) }
                }))
                .disabled(!active)
            }
        }
        .accessibilityIdentifier("settings.rules.default.\(rule.id)")
    }

    private func paramsEditor(_ current: DefaultParamsDraft) -> some View {
        SettingsSection("Edit \u{201C}\(ruleSet.config.defaultRule(current.ruleID)?.title ?? current.ruleID)\u{201D}",
                        footnote: "Lists are separated by commas. Mail compares them in lowercase.") {
            VStack(alignment: .leading, spacing: theme.space3) {
                ForEach(Array(current.fields.enumerated()), id: \.element.id) { index, field in
                    VStack(alignment: .leading, spacing: theme.space1) {
                        Text(field.title).font(.system(size: NativeMetrics.Text.secondary)).foregroundStyle(.secondary)
                        TextField(field.title, text: Binding(get: { paramsDraft?.fields[ruleSafe: index]?.text ?? "" },
                                                             set: { paramsDraft?.fields[index].text = $0 }), axis: .vertical)
                            .settingsTextField()
                            .lineLimit(1...4)
                    }
                }
                if current.params() == nil { SettingsFootnote("Use whole numbers in the number fields.", tone: .warning) }
                HStack(spacing: theme.space3) {
                    Button("Cancel") { paramsDraft = nil }
                    Button("Save") {
                        guard let params = current.params() else { return }
                        Task {
                            if await ruleSet.setDefault(current.ruleID, params: params) { paramsDraft = nil }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(current.params() == nil)
                }
            }
            .settingsRowPadding()
        }
    }
}

private extension Array {
    subscript(ruleSafe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
