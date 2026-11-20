import Foundation
import MailModel
import Observation
import OpenHumanAI
import OpenHumanCore

@MainActor @Observable
public final class AISettingsPageModel {
    public struct ProviderRow: Identifiable, Hashable, Sendable {
        public enum Action: Hashable, Sendable { case allow, stopUsing }

        public let id: String
        public let name: String
        public let status: String
        public let isReady: Bool
        public let badge: AIProviderBadge
        public let warning: String?
        public var action: Action? = nil
    }

    public struct AccountRow: Identifiable, Hashable, Sendable {
        public let id: AccountID
        public let title: String
        public let onDeviceOnly: Bool
    }

    public let center: AICenter
    public private(set) var error: String?
    @ObservationIgnored private weak var environment: AppEnvironment?

    public var listsUnavailableModels: Bool

    public init(center: AICenter, environment: AppEnvironment?, listsUnavailableModels: Bool = true) {
        self.center = center
        self.environment = environment
        self.listsUnavailableModels = listsUnavailableModels
    }

    public var useAI: Bool {
        get { center.settings.enabled }
        set { change { $0.enabled = newValue } }
    }

    public var draftReplies: DraftRepliesChoice {
        get { AICenterOnboarding.choice(center.settings.draftReplies) }
        set {
            change { settings in
                settings.draftReplies = switch newValue {
                case .onDeviceAuto: .onDeviceAuto
                case .onDemand: .onDemand
                case .off: .off
                }
            }
        }
    }

    public var summarizeOnOpen: Bool {
        get { center.settings.autoSummarizeOnOpen }
        set { change { $0.autoSummarizeOnOpen = newValue } }
    }

    public var prepareInAdvance: Bool {
        get { center.settings.prepareInAdvance && onDeviceReady != false }
        set { change { $0.prepareInAdvance = newValue } }
    }

    public var autoDraftReplies: Bool {
        get { center.settings.autoDraftReplies && onDeviceReady != false }
        set { change { $0.autoDraftReplies = newValue } }
    }

    public static let autoDraftTitle = String(localized: "Auto-draft replies")
    public static let autoDraftDetail = String(localized: "Writes a reply ahead of time for conversations that need one, on this Mac only. They show as suggestions; nothing is sent or saved to Gmail until you use one. Paused in Low Power Mode.")

    public var autoDraftStatus: String? {
        guard center.settings.enabled else { return String(localized: "Needs Use AI on.") }
        if center.settings.draftReplies == .off { return String(localized: "Replies are set to Not at all above.") }
        return onDeviceReady == false ? Self.prepareNeedsModel : nil
    }

    public var onDeviceReady: Bool? {
        guard hasCheckedProviders else { return nil }
        return center.providers.contains { $0.isReady && !$0.badge.leavesMac }
    }

    private var hasCheckedProviders = false

    public static let prepareTitle = String(localized: "Prepare replies and summaries in advance")
    public static let prepareDetail = String(localized: "Runs on this Mac only. Uses a little battery.")
    public static let prepareNeedsModel = String(localized: "Needs a model on this Mac.")

    public var prepareStatus: String? {
        guard center.settings.enabled else { return String(localized: "Needs Use AI on.") }
        return onDeviceReady == false ? Self.prepareNeedsModel : nil
    }

    public func clearPrepared() async {
        await center.preparation.clearPrepared()
    }

    public var allowWritingTools: Bool {
        get { center.settings.allowWritingTools }
        set { change { $0.allowWritingTools = newValue } }
    }

    public var aboutMe: String {
        get { center.settings.aboutMe }
        set { change { $0.aboutMe = newValue } }
    }

    public var writingInstructions: String {
        get { center.settings.writingInstructions }
        set { change { $0.writingInstructions = newValue } }
    }

    public static let aboutMeTitle = String(localized: "About me")
    public static let aboutMePrompt = String(localized: "What you do, who you write to")
    public static let writingInstructionsTitle = String(localized: "How I write")
    public static let writingInstructionsPrompt = String(localized: "Tone, length, greetings and sign-offs")
    public static let personalNote = String(localized: "Used when AI writes for you. Stays on this Mac unless you allowed a provider off it.")

    public static let writingToolsNote = String(localized: "Writing Tools is part of macOS and may send the draft off this Mac. It stays off for accounts set to On-device AI only.")

    public var offersInstantReplyStrip: Bool {
        center.settings.enabled && center.settings.draftReplies == .onDeviceAuto
    }

    public var instantReplyStrip: Bool {
        get { center.settings.instantReplyStrip }
        set { change { $0.instantReplyStrip = newValue && self.offersInstantReplyStrip } }
    }

    public var instantReplyStripStatus: String? {
        if offersInstantReplyStrip { return nil }
        return center.settings.enabled ? Self.instantReplyStripNeedsDrafts : Self.instantReplyStripNeedsAI
    }

    public static let instantReplyStripNeedsDrafts = String(localized: "Needs Draft replies set to “Yes, when I open a conversation”.")
    public static let instantReplyStripNeedsAI = String(localized: "Needs Use AI on, and Draft replies set to “Yes, when I open a conversation”.")

    public static let instantReplyStripTitle = String(localized: "Show quick replies when I reply (⇥ to cycle)")
    public static let instantReplyStripDetail = String(localized: "Three short drafts above your reply, written by the Quick replies model. Nothing goes into the message until you press ↵, and nothing is sent until you press ⌘↵.")

    public private(set) var offered: [ProviderRow] = []
    public private(set) var consent: AIProviderConsentRequest?

    public var providers: [ProviderRow] {
        var rows = center.providers.map { row in
            ProviderRow(id: row.id.rawValue, name: Self.name(row), status: row.consented || !row.needsConsent ? row.status
                            : Self.notAllowed,
                        isReady: row.isReady, badge: row.badge,
                        warning: row.needsConsent && !row.consented ? Self.sendsText : nil,
                        action: row.needsConsent ? (row.consented ? .stopUsing : .allow) : nil)
        }
        rows += offered.filter { row in !rows.contains { $0.id == row.id } }
        if let reason = center.appleModel.unavailableReason,
           !rows.contains(where: { $0.id == AIProviderID.appleSystem.rawValue }) {
            rows.insert(ProviderRow(id: AIProviderID.appleSystem.rawValue, name: Self.appleModelName,
                                    status: AIWording.reason(reason), isReady: false,
                                    badge: AIProviderBadge(providerName: "Apple on-device model", location: .onDevice),
                                    warning: nil), at: 0)
        }
        guard listsUnavailableModels else { return rows }
        if !rows.contains(where: { $0.id.hasPrefix("local.") }) {
            rows.append(ProviderRow(id: "local", name: String(localized: "Local model"),
                                    status: String(localized: "Not available in this version of Mail"), isReady: false,
                                    badge: AIProviderBadge(providerName: "Local model", location: .onDevice), warning: nil))
        }
        if !rows.contains(where: { $0.id == AIProviderID.applePCC.rawValue }) {
            rows.append(ProviderRow(id: AIProviderID.applePCC.rawValue, name: "Apple Private Cloud Compute",
                                    status: AIWording.reason(.entitlementMissing), isReady: false,
                                    badge: AIProviderBadge(providerName: "Apple Private Cloud Compute", location: .appleCloud),
                                    warning: String(localized: "Runs on Apple's servers, not on this Mac. Off by default.")))
        }
        return rows
    }

    static let appleModelName = String(localized: "On this Mac (Apple Intelligence)")

    static func name(_ row: AIProviderRow) -> String {
        row.id == .appleSystem ? appleModelName : row.name
    }

    public var accounts: [AccountRow] {
        (environment?.router.accounts.map(\.account) ?? []).map { account in
            AccountRow(id: account.id, title: account.alias.map { "\($0) (\(account.email))" } ?? account.email,
                       onDeviceOnly: center.isOnDeviceOnly(account))
        }
    }

    public func setOnDeviceOnly(_ on: Bool, account: AccountID) {
        do { try center.setOnDeviceOnly(on, accountID: account) } catch { self.error = Self.saveFailure }
    }

    public static let notAllowed = String(localized: "Not allowed. Nothing is sent to it.")
    public static let sendsText = String(localized: "Sends the text of the email it works on off this Mac. Off until you allow it.")

    public func refresh() async {
        await center.refreshProviders()
        let registered = center.providers.map { ProviderCandidate(id: $0.id, displayName: $0.name, dataLocation: .onDevice,
                                                                  availability: .available, consented: true,
                                                                  autoSelectable: true) }
        offered = await center.offeredModels(besides: registered).map { model in
            ProviderRow(id: model.id.rawValue, name: model.displayName, status: Self.notAllowed, isReady: false,
                        badge: AIProviderBadge(providerName: model.displayName, location: model.dataLocation),
                        warning: Self.sendsText, action: .allow)
        }
        hasCheckedProviders = true
    }

    public func allow(_ id: String) async {
        consent = await center.consentRequest(for: AIProviderID(id))
    }

    public func acceptConsent() async {
        guard let consent else { return }
        self.consent = nil
        do {
            try await center.grantConsent(consent)
            error = nil
        } catch {
            self.error = Self.saveFailure
        }
        await refresh()
    }

    public func declineConsent() {
        consent = nil
    }

    public func stopUsing(_ id: String) async {
        do {
            try await center.revokeConsent(AIProviderID(id))
            error = nil
        } catch {
            self.error = Self.saveFailure
        }
        await refresh()
    }

    public func clearCache() async {
        await center.clearCache()
    }

    static let saveFailure = String(localized: "Couldn't save the AI setting")

    private func change(_ mutate: (inout AISettings) -> Void) {
        do {
            try center.update(mutate)
            error = nil
        } catch {
            self.error = Self.saveFailure
        }
    }
}
