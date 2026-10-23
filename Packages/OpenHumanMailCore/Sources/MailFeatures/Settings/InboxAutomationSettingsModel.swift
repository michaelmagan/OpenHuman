import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class InboxAutomationSettingsModel {
    public let suggestCleanup: StoredSetting<Bool>
    public let cleanupThreshold: StoredSetting<Int>
    public let cleanupAgeDays: StoredSetting<Int>
    public let autoRemind: StoredSetting<Bool>
    public let autoRemindDays: StoredSetting<Int>
    public let autoRemindHour: StoredSetting<Int>
    public let autoRemindWeekdaysOnly: StoredSetting<Bool>
    public let autoRemindAIDetected: StoredSetting<Bool>
    public let cleanupRules: CleanupRulesModel
    public let availability: SettingsAvailability
    public private(set) var followUpModelReady: Bool?
    public private(set) var followUpUnavailableReason: String?
    public private(set) var isCatchingUp = false
    public private(set) var catchUpMessage: String?

    @ObservationIgnored private let followUps: FollowUpReminders?

    public init(settings: (any SettingsPort)?, availability: SettingsAvailability, followUps: FollowUpReminders? = nil,
                askDomainWide: @escaping DomainWideRuleAsking = { _ in .cancel }) {
        self.availability = availability
        self.followUps = followUps
        cleanupRules = CleanupRulesModel(settings: settings, askDomainWide: askDomainWide)
        suggestCleanup = StoredSetting(AppSettings.archiveSuggestionEnabled, port: settings)
        cleanupThreshold = StoredSetting(AppSettings.archiveSuggestionInboxThreshold, port: settings)
        cleanupAgeDays = StoredSetting(AppSettings.archiveSuggestionAgeDays, port: settings)
        autoRemind = StoredSetting(AppSettings.autoRemindExternal, port: settings)
        autoRemindDays = StoredSetting(AppSettings.autoRemindDays, port: settings)
        autoRemindHour = StoredSetting(AppSettings.autoRemindHour, port: settings)
        autoRemindWeekdaysOnly = StoredSetting(AppSettings.autoRemindWeekdaysOnly, port: settings)
        autoRemindAIDetected = StoredSetting(AppSettings.autoRemindAIDetected, port: settings)
    }

    public convenience init(environment: AppEnvironment) {
        self.init(settings: environment.settings, availability: SettingsAvailability(environment: environment),
                  followUps: environment.ai == nil ? nil : environment.followUps,
                  askDomainWide: environment.domainWideRuleAsking)
    }

    public func start() {
        for setting in [suggestCleanup.start, cleanupThreshold.start, cleanupAgeDays.start,
                        autoRemind.start, autoRemindDays.start, autoRemindHour.start, autoRemindWeekdaysOnly.start,
                        autoRemindAIDetected.start] {
            setting()
        }
        cleanupRules.start()
        Task { await refreshFollowUpModel() }
    }

    public func refreshFollowUpModel() async {
        guard let followUps else {
            followUpModelReady = false
            followUpUnavailableReason = Self.noAIReason
            return
        }
        let status = await followUps.availability()
        followUpModelReady = status.available
        followUpUnavailableReason = status.available ? nil : status.reason
    }

    public typealias Scope = SentMailReminderRule.Scope

    public var scope: Scope {
        SentMailReminderRule(enabled: autoRemind.value, aiDetected: autoRemindAIDetected.value).scope
    }

    public var scopeChoices: [Scope] {
        followUpModelReady == true || scope == .needsFollowUp ? Scope.allCases : [.off, .externalRecipients]
    }

    public func setScope(_ scope: Scope) async {
        switch scope {
        case .off:
            await autoRemind.set(false)
        case .externalRecipients:
            await autoRemindAIDetected.set(false)
            await autoRemind.set(true)
        case .needsFollowUp:
            guard followUpModelReady == true else { return }
            await autoRemindAIDetected.set(true)
            await autoRemind.set(true)
        }
    }

    public static func scopeTitle(_ scope: Scope) -> String {
        switch scope {
        case .off: String(localized: "Never")
        case .externalRecipients: String(localized: "Mail to people outside my domain")
        case .needsFollowUp: String(localized: "Only messages that need a follow-up")
        }
    }

    public var scopeNote: String {
        switch scope {
        case .off, .externalRecipients: Self.autoRemindNote
        case .needsFollowUp: Self.followUpNote
        }
    }

    public var scopeStatus: String? {
        guard followUpModelReady == false else { return nil }
        let reason = followUpUnavailableReason ?? Self.noAIReason
        return scope == .needsFollowUp
            ? String(localized: "Not running: \(reason). No reminders are set until the on-device model is ready.")
            : String(localized: "“Only messages that need a follow-up” needs the on-device model: \(reason).")
    }

    public func catchUp() async {
        guard let followUps, !isCatchingUp else { return }
        isCatchingUp = true
        catchUpMessage = String(localized: "Checking sent mail on this Mac…")
        defer { isCatchingUp = false }
        do {
            let result = try await followUps.catchUp()
            catchUpMessage = Self.catchUpSummary(result)
        } catch {
            switch error {
            case .scopeOff: catchUpMessage = String(localized: "Choose “Only messages that need a follow-up” first.")
            case .unavailable(let reason): catchUpMessage = reason.isEmpty ? Self.noAIReason : reason
            case .busy: catchUpMessage = String(localized: "Already checking.")
            }
        }
    }

    static func catchUpSummary(_ result: FollowUpReminders.CatchUpResult) -> String {
        switch (result.checked, result.remindersSet) {
        case (0, _): String(localized: "Nothing to check: no unanswered sent mail from the last 7 days.")
        case (let checked, 0): String(localized: "Checked \(checked) sent messages. None needs a follow-up.")
        case (let checked, 1): String(localized: "Checked \(checked) sent messages. Set 1 reminder.")
        case (let checked, let set): String(localized: "Checked \(checked) sent messages. Set \(set) reminders.")
        }
    }

    public static let cleanupNote = "When the inbox grows past this size, or holds old promotions, Mail asks once a day "
        + "whether to archive old conversations that need nothing from you. It never archives on its own."
    public static let autoRemindNote = "After you send mail to someone outside your own domain, Mail reminds you if nobody "
        + "has replied. Reminders stay on this Mac."
    public static let followUpNote = "Apple’s on-device model reads each message you send, on this Mac, and Mail reminds "
        + "you only when it asks a question, requests something or waits on a decision, and nobody has replied. Nothing "
        + "is sent anywhere. A date in your message can bring the reminder sooner."
    public static let catchUpNote = "Looks at what you sent in the last 7 days that nobody has answered. Runs only when "
        + "you press it."
    static let noAIReason = String(localized: "AI isn't set up in this version of Mail")

    public static let thresholdChoices = AppSettings.archiveSuggestionThresholdChoices
    public static let ageChoices = AppSettings.archiveSuggestionAgeChoices
    public static let dayChoices = AppSettings.autoRemindDayChoices
    public static let hourChoices = Array(6...20)

    public static func thresholdTitle(_ n: Int) -> String { "\(n.formatted()) conversations" }
    public static func ageTitle(_ days: Int) -> String { days == 1 ? "1 day" : "\(days) days" }
    public static func hourTitle(_ hour: Int) -> String { String(format: "%d:00", hour) }

    public var errorMessage: String? {
        [suggestCleanup.errorMessage, cleanupThreshold.errorMessage,
         cleanupAgeDays.errorMessage, autoRemind.errorMessage, autoRemindDays.errorMessage, autoRemindHour.errorMessage,
         autoRemindWeekdaysOnly.errorMessage, autoRemindAIDetected.errorMessage, cleanupRules.errorMessage].compactMap { $0 }.first
    }
}
