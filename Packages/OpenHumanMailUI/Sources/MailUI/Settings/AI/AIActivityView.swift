import MailFeatures
import MailTheme
import OpenHumanAI
import SwiftUI

public struct AIActivityView: View {
    @Bindable var model: AIActivityModel
    var editPrompt: ((String) -> Void)?
    @State private var confirmsClear = false
    @Environment(\.theme) private var theme

    public init(model: AIActivityModel, editPrompt: ((String) -> Void)? = nil) {
        self.model = model
        self.editPrompt = editPrompt
    }

    public var body: some View {
        if let detail = model.detail {
            Section {
                AITraceDetailView(detail: detail, backTitle: model.backTitle, back: { model.closeDetail() },
                                  delete: { Task { await model.delete(detail.id) } }, editPrompt: editPrompt)
                    .task(id: model.reloadKey) { await model.refresh() }
                    .accessibilityIdentifier("settings.ai.activity")
            }
        } else {
            list
            retention
            cache
            SettingsErrorLine(text: model.error)
        }
    }

    @ViewBuilder private var list: some View {
        Section {
            HStack(spacing: theme.space4) {
                Picker(String(localized: "Show"), selection: $model.page) {
                    ForEach(AIActivityModel.Page.allCases, id: \.self) { page in Text(page.title).tag(page) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings.ai.activity.page")
                Spacer(minLength: theme.space3)
                switch model.page {
                case .requests:
                    Picker(String(localized: "Show"), selection: $model.filter) {
                        ForEach(AIActivityModel.Filter.allCases, id: \.self) { filter in Text(filter.title).tag(filter) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityIdentifier("settings.ai.activity.filter")
                case .feedback:
                    Toggle(String(localized: "Thumbs down only"), isOn: $model.onlyThumbsDown)
                        .ohCheckboxToggleStyle()
                        .fixedSize()
                        .accessibilityIdentifier("settings.ai.activity.thumbsDown")
                }
            }
            .task(id: model.reloadKey) { await model.refresh() }
            .accessibilityIdentifier("settings.ai.activity")
            Text(verbatim: model.summary)
                .font(.system(size: NativeMetrics.Text.secondary))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.ai.activity.summary")
        }
        SettingsSection(footnote: AIActivityModel.note, compact: true) {
            let rows = model.rows
            if rows.isEmpty {
                Text(verbatim: model.emptyText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .settingsRowPadding()
                    .accessibilityIdentifier("settings.ai.activity.empty")
            } else {
                ForEach(rows) { row in
                    AIActivityRowView(row: row, showsSnippet: model.showsSnippets) { Task { await model.open(row.id) } }
                }
            }
        }
    }

    private var retention: some View {
        SettingsSection(String(localized: "Traces"), footnote: AIActivityModel.retentionNote) {
            SettingsRow(String(localized: "Keep a trace of each AI request"),
                        detail: String(localized: "Turn off to stop saving new traces. Ratings need a trace."),
                        isOn: $model.keepsTraces)
            Group {
                SettingsRow(String(localized: "Keep for"), selection: $model.keepDays) {
                    ForEach(Self.withCurrent(AIActivityModel.keepDaysChoices, model.keepDays), id: \.self) { days in
                        Text(AIActivityModel.days(days)).tag(days)
                    }
                }
                SettingsRow(String(localized: "Per feature, keep the newest"), selection: $model.perFeatureLimit) {
                    ForEach(Self.withCurrent(AIActivityModel.perFeatureChoices, model.perFeatureLimit), id: \.self) { count in
                        Text(verbatim: "\(count)").tag(count)
                    }
                }
                SettingsRow(String(localized: "Use at most"), selection: $model.maxBytes) {
                    ForEach(Self.withCurrent(AIActivityModel.sizeChoices, model.maxBytes), id: \.self) { bytes in
                        Text(AIActivityModel.size(bytes)).tag(bytes)
                    }
                }
                DisclosureGroup(String(localized: "Features to trace")) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(AIFeature.allCases, id: \.self) { feature in
                            SettingsRow(AITraceWording.feature(feature),
                                        isOn: Binding(get: { model.keeps(feature) }, set: { model.setKeeps(feature, $0) }))
                        }
                    }
                    .padding(.leading, theme.space4)
                }
                .settingsRowPadding()
                .accessibilityIdentifier("settings.ai.activity.features")
            }
            .disabled(!model.keepsTraces)
            SettingsRow(String(localized: "Clear all traces"),
                        detail: String(localized: "Deletes every trace and rating on this Mac.")) {
                Button(String(localized: "Clear…")) { confirmsClear = true }
                    .disabled(!model.keepsAny)
                    .accessibilityIdentifier("settings.ai.activity.clearAll")
            }
            .confirmationDialog(AIActivityModel.clearConfirmTitle, isPresented: $confirmsClear) {
                Button(String(localized: "Clear All Traces"), role: .destructive) { Task { await model.clearAll() } }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(AIActivityModel.clearConfirmDetail)
            }
        }
    }

    private var cache: some View {
        SettingsSection(AIActivityModel.cacheTitle) {
            SettingsRow(String(localized: "Clear AI cache"), detail: AIActivityModel.cacheDetail) {
                Button(String(localized: "Clear")) { Task { await model.clearCache() } }
                    .accessibilityIdentifier("settings.ai.activity.clearCache")
            }
        }
    }

    static func withCurrent(_ choices: [Int], _ current: Int) -> [Int] {
        choices.contains(current) ? choices : (choices + [current]).sorted()
    }
}

struct AIActivityRowView: View {
    let row: AIActivityModel.Row
    var showsSnippet = false
    let open: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: theme.space3) {
                Text(row.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: NativeMetrics.Text.secondary))
                    .foregroundStyle(.secondary)
                    .frame(width: 104, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.feature)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    subtitle
                        .font(.system(size: NativeMetrics.Text.secondary))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: theme.space3)
                marks
            }
            .padding(.vertical, theme.space2)
            .padding(.horizontal, theme.space1)
            .frame(minHeight: SettingsMetrics.rowMinHeight)
            .background(RoundedRectangle(cornerRadius: theme.radiusMD)
                .fill(hovered ? AnyShapeStyle(.quinary) : AnyShapeStyle(Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "Opens the full trace"))
        .accessibilityIdentifier("settings.ai.activity.row")
    }

    @ViewBuilder private var subtitle: some View {
        if showsSnippet, let snippet = row.snippet {
            Text(verbatim: "“\(snippet)”").lineLimit(1).truncationMode(.tail)
        } else if row.numbers.isEmpty {
            Text(verbatim: row.model).lineLimit(1).truncationMode(.tail)
        } else {
            ViewThatFits(in: .horizontal) {
                Text(verbatim: row.model + " · " + row.numbers).lineLimit(1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.model).lineLimit(1).truncationMode(.tail)
                    Text(verbatim: row.numbers).lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }

    private var marks: some View {
        HStack(spacing: theme.space3) {
            if row.failed {
                Text("Failed")
                    .font(.system(size: NativeMetrics.Text.caption))
                    .foregroundStyle(theme.textDanger.color)
                    .accessibilityIdentifier("settings.ai.activity.failed")
            }
            if row.cacheHit {
                Text("From cache")
                    .font(.system(size: NativeMetrics.Text.caption))
                    .foregroundStyle(.tertiary)
                    .help(String(localized: "A saved answer was reused; the model didn't run"))
            }
            if let rating = row.rating, rating != 0 {
                Image(systemName: rating > 0 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(AITraceWording.rating(rating) ?? "")
            }
            Image(systemName: row.badge.symbol)
                .font(.system(size: 10))
                .foregroundStyle((row.badge.leavesMac ? theme.textWarning : theme.textTertiary).color)
                .help(row.badge.title)
                .accessibilityLabel(row.badge.title)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .fixedSize()
    }
}
