import MailActions
import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct AISettingsSection: View {
    @State private var model: AISettingsPageModel
    @State private var summarizeEvery: StoredSetting<Bool>?
    @State private var refreshed = false
    private let offersQuickRepliesRow: Bool
    private weak var environment: AppEnvironment?
    @Environment(\.theme) private var theme

    public init(center: AICenter, environment: AppEnvironment?, listsUnavailableModels: Bool = true) {
        _model = State(initialValue: AISettingsPageModel(center: center, environment: environment,
                                                         listsUnavailableModels: listsUnavailableModels))
        offersQuickRepliesRow = environment?.actions.contains(.aiToggleInstantReply) ?? true
        self.environment = environment
    }

    public var body: some View {
        providers
        AIFeatureModelsSection(center: model.center, reloadKey: model.providers.hashValue,
                               onTriageChange: { [weak environment] in await environment?.autoLabels?.refreshAvailability() })
        choices
        personal
        accounts
        SettingsErrorLine(text: model.error)
    }

    // Why: the grouped form builds rows lazily, so the refresh rides on the footer, which shows before any model row
    private var providers: some View {
        Section {
            if model.providers.isEmpty {
                SettingsRow(String(localized: "Models"),
                            detail: refreshed ? String(localized: "No model is set up on this Mac yet.")
                                : String(localized: "Checking which models are on this Mac…"))
            }
            ForEach(model.providers) { row in
                SettingsRow(row.name, detail: row.status, status: row.warning, statusTone: .warning) {
                    HStack(spacing: theme.space3) {
                        if row.action == nil {
                            AIProviderBadgeView(badge: row.badge)
                        } else {
                            Image(systemName: row.badge.symbol)
                                .font(.system(size: 10))
                                .foregroundStyle((row.badge.leavesMac ? theme.textWarning : theme.textTertiary).color)
                                .help(row.badge.help)
                                .accessibilityLabel(row.badge.title)
                        }
                        switch row.action {
                        case .allow?:
                            Button(String(localized: "Allow…")) { Task { await model.allow(row.id) } }
                                .accessibilityIdentifier("settings.ai.allow.\(row.id)")
                        case .stopUsing?:
                            Button(String(localized: "Stop using")) { Task { await model.stopUsing(row.id) } }
                                .accessibilityIdentifier("settings.ai.stopUsing.\(row.id)")
                        case nil:
                            EmptyView()
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                if let consent = model.consent, consent.providerID.rawValue == row.id {
                    AIConsentView(request: consent, center: model.center,
                                  accept: { Task { await model.acceptConsent() } }, decline: { model.declineConsent() })
                }
            }
        } header: {
            Text(String(localized: "Models")).accessibilityAddTraits(.isHeader)
        } footer: {
            SettingsFootnote(String(localized: "The models Mail can use. Each feature's model is chosen below."))
                .task {
                    await model.refresh()
                    refreshed = true
                }
        }
    }

    private var choices: some View {
        SettingsSection(String(localized: "Features")) {
            SettingsRow(String(localized: "Use AI"), isOn: $model.useAI)
            // Why: a radio group beside a title in the grouped form lays its options out as form-wide rows, and the row
            // then widens the whole page past its pane; a menu keeps one definite width like the other choices
            SettingsRow(String(localized: "Draft replies"), selection: $model.draftReplies) {
                Text("Yes, when I open a conversation").tag(DraftRepliesChoice.onDeviceAuto)
                Text("Only when I ask (⌘J)").tag(DraftRepliesChoice.onDemand)
                Text("Not at all").tag(DraftRepliesChoice.off)
            }
            .disabled(!model.useAI)
            .accessibilityIdentifier("settings.ai.draftReplies")
            if offersQuickRepliesRow {
                SettingsRow(AISettingsPageModel.instantReplyStripTitle,
                            detail: AISettingsPageModel.instantReplyStripDetail,
                            status: model.instantReplyStripStatus,
                            isOn: $model.instantReplyStrip)
                    .disabled(!model.offersInstantReplyStrip)
                    .accessibilityIdentifier("settings.ai.quickRepliesRow")
            }
            SettingsRow(String(localized: "Summarize conversations when I open them"),
                        detail: String(localized: "On this Mac, for conversations of 3 messages or more."),
                        isOn: $model.summarizeOnOpen)
                .disabled(!model.useAI)
            SettingsRow(String(localized: "Summarize every conversation"),
                        detail: String(localized: "A one-line summary under each subject, made on this Mac only. With “Prepare replies and summaries in advance” on, your newest Inbox conversations get theirs in the background."),
                        isOn: Binding(get: { summarizeEvery?.value ?? true },
                                      set: { on in
                                          Task {
                                              await summarizeEvery?.set(on)
                                              if !on { model.center.threadLines.cancelBackground() }
                                          }
                                      }))
                .disabled(!model.useAI)
                .task {
                    guard summarizeEvery == nil else { return }
                    let setting = model.center.threadLines.makeEnabledSetting()
                    setting.start()
                    summarizeEvery = setting
                }
            HStack {
                Spacer(minLength: 0)
                Button(String(localized: "Summarize now")) {
                    Task { await model.center.threadLines.summarizeRecent(days: 7) }
                }
                .help(String(localized: "One-line summaries for the Inbox conversations of the last 7 days, on this Mac."))
                .disabled(!model.useAI || summarizeEvery?.value == false)
                .accessibilityIdentifier("settings.ai.summarizeNow")
            }
            SettingsRow(AISettingsPageModel.prepareTitle, detail: AISettingsPageModel.prepareDetail,
                        status: model.prepareStatus, isOn: $model.prepareInAdvance)
                .disabled(model.prepareStatus != nil)
                .accessibilityIdentifier("settings.ai.prepareInAdvance")
            SettingsRow(AISettingsPageModel.autoDraftTitle, detail: AISettingsPageModel.autoDraftDetail,
                        status: model.autoDraftStatus, isOn: $model.autoDraftReplies)
                .disabled(model.autoDraftStatus != nil)
                .accessibilityIdentifier("settings.ai.autoDraftReplies")
            HStack {
                Spacer(minLength: 0)
                Button(String(localized: "Clear prepared replies")) {
                    Task { await model.clearPrepared() }
                }
                .help(String(localized: "Drops the replies and summaries prepared in advance. New mail is prepared again as it comes."))
                .disabled(!model.useAI)
                .accessibilityIdentifier("settings.ai.clearPrepared")
            }
            SettingsRow(String(localized: "Allow Apple Writing Tools in the composer"),
                        detail: AISettingsPageModel.writingToolsNote,
                        isOn: $model.allowWritingTools)
                .disabled(!model.useAI)
        }
    }

    private var personal: some View {
        SettingsSection(String(localized: "Personal writing instructions"), footnote: AISettingsPageModel.personalNote) {
            personalRow(AISettingsPageModel.aboutMeTitle, prompt: AISettingsPageModel.aboutMePrompt, text: $model.aboutMe,
                        identifier: "settings.ai.aboutMe")
            personalRow(AISettingsPageModel.writingInstructionsTitle, prompt: AISettingsPageModel.writingInstructionsPrompt,
                        text: $model.writingInstructions, identifier: "settings.ai.howIWrite")
        }
        .disabled(!model.useAI)
    }

    private func personalRow(_ title: String, prompt: String, text: Binding<String>, identifier: String) -> some View {
        SettingsRow(title, alignment: .firstTextBaseline, labelsControl: true) {
            SettingsTextArea(title: title, prompt: prompt, text: text)
                .accessibilityIdentifier(identifier)
        }
    }

    @ViewBuilder private var accounts: some View {
        SettingsSection(String(localized: "On-device AI only"),
                        footnote: String(localized: "Mail never sends this account's mail to a provider off this Mac, even one you allowed.")) {
            ForEach(model.accounts) { account in
                SettingsRow(account.title, isOn: Binding(get: { account.onDeviceOnly },
                                                         set: { model.setOnDeviceOnly($0, account: account.id) }))
            }
        }
    }
}
