import MailFeatures
import OpenHumanAI
import SwiftUI

public enum AISettingsTab: String, CaseIterable, Sendable {
    case overview, prompts, activity

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .prompts: String(localized: "Prompts")
        case .activity: String(localized: "Activity")
        }
    }
}

/// The prompts people most often want to adjust, one click from the AI overview.
enum AISettingsInstructions {
    static let prompts: [String] = [PromptName.classify.rawValue, PromptName.autoLabel.rawValue]
    static let note = String(localized: "The instructions Mail gives the model for each job. Your version is used from the next request; every prompt is under Prompts.")
}

public struct AISettingsTabs<Overview: View>: View {
    public typealias Tab = AISettingsTab

    @State private var tab: Tab
    @State private var prompts: PromptsSettingsModel?
    @State private var activity: AIActivityModel?
    private let navigator: SettingsNavigator?
    private let overview: Overview

    public init(prompts: @autoclosure () -> PromptsSettingsModel?, activity: @autoclosure () -> AIActivityModel? = nil,
                navigator: SettingsNavigator? = nil, initialTab: Tab = .overview, @ViewBuilder overview: () -> Overview) {
        let model = prompts()
        let activityModel = activity()
        _prompts = State(initialValue: model)
        _activity = State(initialValue: activityModel)
        let offered = initialTab == .overview || (initialTab == .prompts && model != nil)
            || (initialTab == .activity && activityModel != nil)
        _tab = State(initialValue: offered ? initialTab : .overview)
        self.navigator = navigator
        self.overview = overview()
    }

    public var body: some View {
        if tabs.count > 1 {
            Section {
                Picker(String(localized: "AI settings"), selection: $tab) {
                    ForEach(tabs, id: \.self) { tab in Text(tab.title).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("settings.ai.tabs")
                .task(id: navigator?.requestedPrompt) { await takeRequest() }
            }
        }
        switch tab {
        case .overview:
            if prompts != nil { instructions }
            overview
        case .prompts:
            if let prompts { PromptsSettingsView(model: prompts) }
        case .activity:
            if let activity { AIActivityView(model: activity, editPrompt: prompts == nil ? nil : { editPrompt($0) }) }
        }
    }

    private var instructions: some View {
        SettingsSection(String(localized: "Instructions"), footnote: AISettingsInstructions.note) {
            ForEach(AISettingsInstructions.prompts, id: \.self) { id in
                if let info = PromptCatalog.entry(id) {
                    SettingsRow(info.title, detail: info.usedBy) {
                        Button(String(localized: "Edit Prompt…")) { editPrompt(id) }
                            .accessibilityLabel(String(localized: "Edit the \(info.title) prompt"))
                    }
                    .accessibilityIdentifier("settings.ai.instructions.\(id)")
                }
            }
            SettingsRow(String(localized: "All prompts"), detail: String(localized: "Replies, summaries, search and scheduling.")) {
                Button(String(localized: "Show Prompts")) { tab = .prompts }
                    .accessibilityIdentifier("settings.ai.instructions.all")
            }
        }
    }

    private var tabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .overview: true
            case .prompts: prompts != nil
            case .activity: activity != nil
            }
        }
    }

    private func editPrompt(_ id: String) {
        guard let prompts else { return }
        tab = .prompts
        Task { await prompts.open(promptID: id) }
    }

    private func takeRequest() async {
        guard let prompts, let id = navigator?.takeRequestedPrompt() else { return }
        tab = .prompts
        await prompts.open(promptID: id)
    }
}
