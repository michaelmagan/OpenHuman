import MailActions
import MailFeatures
import MailModel
import OpenHumanCore
import SwiftUI

struct SearchSettingsPage: View {
    let model: SearchRankingModel
    private let environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.model = environment.searchRanking
        self.environment = environment
    }

    init(model: SearchRankingModel) {
        self.model = model
        environment = nil
    }

    static let learningNote = "Search learning remembers which conversations you open from search results: only which "
        + "conversation and when, never what it says, on this Mac only. Opens fade over time. People you write to are "
        + "counted from the mail on this Mac and never leave it."

    var body: some View {
        SettingsPageScaffold(title: "Search") {
            SettingsSection("Order") {
                SettingsRow("Sort results by",
                            detail: "How a new search starts. The switch above the results changes one search.",
                            selection: Binding(get: { model.settings.sort }, set: { model.setDefaultSort($0) })) {
                    ForEach(SearchSortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            if let environment { SearchMailSections(environment: environment) }
            SettingsSection("Most relevant", detail: model.settings.preset.detail, footnote: dominanceNote) {
                SettingsRow("Ranking", selection: Binding(get: { model.settings.preset }, set: { model.setPreset($0) })) {
                    ForEach(SearchRankingPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.settings.preset != .classic {
                    ForEach(SearchRankingWeights.Field.allCases, id: \.self) { field in
                        SearchWeightRow(field: field, model: model)
                    }
                }
            }
            SettingsSection("Search learning", footnote: Self.learningNote) {
                SettingsRow("Opened from search", detail: rememberedText) {
                    Button("Reset search learning") { Task { await model.resetLearning() } }
                        .ohLinkButtonStyle()
                }
            }
            SettingsSection {
                SettingsRow("Order and ranking", detail: "Most relevant, Balanced and every weight as they came.") {
                    Button("Reset all") { model.resetAll() }
                        .ohLinkButtonStyle()
                        .accessibilityLabel("Reset order and ranking")
                }
            }
        }
        .task { await model.refresh() }
    }

    private var rememberedText: String {
        switch model.rememberedConversations {
        case 0: "No conversations remembered."
        case 1: "1 conversation remembered on this Mac."
        case let n: "\(n) conversations remembered on this Mac."
        }
    }

    private var dominanceNote: String? {
        guard let weights = model.settings.weights else { return nil }
        return weights.headerLevelsDominate
            ? "Sender and subject matches always rank above matches found only in the text."
            : "With these weights, very recent or often-opened mail can rank above a sender or subject match."
    }
}

// What search can find: message text kept on this Mac, sentences and saved searches.
struct SearchMailSections: View {
    @State private var model: GeneralSettingsModel
    @State private var savedSearches: SavedSearchesModel
    let modules: [FeatureModuleID]
    let ai: AICenter?
    let savedSearchAccount: AccountID?

    static let sentencesNote = "When you type a search as a sentence, Mail offers the matching filters to use with ⇥. "
        + "It runs only on this Mac and sends nothing anywhere."

    init(environment: AppEnvironment) {
        _model = State(initialValue: GeneralSettingsModel(environment: environment))
        _savedSearches = State(initialValue: SavedSearchesModel(settings: environment.settings))
        modules = environment.modules.modules
        ai = environment.ai
        savedSearchAccount = environment.router.active?.id
    }

    var body: some View {
        SettingsSection("Message text") {
            SettingsRow("Download message bodies for search", detail: GeneralSettingsModel.downloadBodiesNote,
                        isOn: binding(model.downloadBodies))
                .disabled(!model.availability.canEditSettings)
                .task {
                    model.downloadBodies.start()
                    model.bodyMax.start()
                    savedSearches.follow(savedSearchAccount)
                }
            SettingsRow("Keep at most", detail: model.bodyDiskNote, selection: binding(model.bodyMax)) {
                ForEach(GeneralSettingsModel.bodyCapChoices, id: \.self) { Text(GeneralSettingsModel.bodyCapTitle($0)).tag($0) }
            }
            .disabled(!model.availability.canEditSettings || !model.downloadBodies.value)
            SettingsErrorLine(text: model.downloadBodies.errorMessage ?? model.bodyMax.errorMessage)
        }
        if modules.contains(.smartSearch) {
            SettingsSection("Smart search") {
                if let ai {
                    SettingsRow("Understand searches written as sentences", detail: Self.sentencesNote,
                                isOn: Binding(get: { ai.understandsSearchSentences },
                                              set: { ai.setUnderstandsSearchSentences($0) }))
                }
                if savedSearches.canSave {
                    SavedSearchSettingsRows(model: savedSearches)
                }
            }
        }
    }

    private func binding<Value>(_ setting: StoredSetting<Value>) -> Binding<Value> {
        Binding(get: { setting.value }, set: { value in Task { await setting.set(value) } })
    }
}

struct SearchWeightRow: View {
    let field: SearchRankingWeights.Field
    let model: SearchRankingModel
    @Environment(\.theme) private var theme

    var body: some View {
        let value = model.shownWeights[field]
        let text = Self.text(value, field: field)
        SettingsRow(field.title, detail: field.help) {
            HStack(spacing: theme.space3) {
                Slider(value: Binding(get: { model.shownWeights[field] }, set: { model.setWeight(field, $0) }),
                       in: field.range, step: field.step)
                    .frame(width: 150)
                    .accessibilityLabel(field.title)
                    .accessibilityValue(text)
                Text(text)
                    .font(.system(size: NativeMetrics.Text.secondary))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56, alignment: .trailing)
                    .accessibilityHidden(true)
                Button("Reset") { model.resetWeight(field) }
                    .ohLinkButtonStyle()
                    .opacity(model.isChanged(field) ? 1 : 0)
                    .disabled(!model.isChanged(field))
                    .accessibilityLabel("Reset \(field.title)")
            }
        }
    }

    static func text(_ value: Double, field: SearchRankingWeights.Field) -> String {
        field.isDays ? "\(Int(value.rounded())) days" : String(format: "%.2f", value)
    }
}
