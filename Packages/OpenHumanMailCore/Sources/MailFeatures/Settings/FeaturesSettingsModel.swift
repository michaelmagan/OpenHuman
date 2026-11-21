import Foundation
import MailActions
import Observation

@MainActor @Observable
public final class FeaturesSettingsModel {
    public struct Row: Identifiable, Hashable {
        public let id: FeatureModuleID
        public let title: String
        public let detail: String
        public var isOn: Bool
        public let isRunning: Bool
        public var needsRestart: Bool { isOn != isRunning }
    }

    public private(set) var rows: [Row]
    @ObservationIgnored private let defaults: UserDefaults

    public init(modules: [any FeatureModule], registered: [FeatureModuleID], defaults: UserDefaults) {
        self.defaults = defaults
        rows = modules.map { module in
            let type = type(of: module)
            let stored = defaults.object(forKey: FeatureFlags.key(type.id)) as? Bool
            let info = Self.labelled(type.id)
            return Row(id: type.id, title: info.title, detail: info.detail, isOn: stored ?? type.defaultEnabled,
                       isRunning: registered.contains(type.id))
        }
    }

    public convenience init(environment: AppEnvironment, modules: [any FeatureModule]? = nil,
                            defaults: UserDefaults = .standard) {
        let target = environment.isFake ? AppEnvironment.fakeDefaults() : defaults
        self.init(modules: modules ?? ModuleList.all + ModuleList.configured(calendar: environment.calendar),
                  registered: environment.modules.modules, defaults: target)
    }

    public var needsRestart: Bool { rows.contains(where: \.needsRestart) }

    public func set(_ id: FeatureModuleID, enabled: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].isOn = enabled
        defaults.set(enabled, forKey: FeatureFlags.key(id))
    }

    public var pendingFlags: FeatureFlags { FeatureFlags(Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.isOn) })) }

    public static let userFacing: Set<FeatureModuleID> = [.ai, .unsubscribe]

    public static let everydayPage: [FeatureModuleID: String] = [
        .snooze: "General", .sendLater: "General", .reminders: "General", .dockBadge: "General",
        .launchAtLogin: "General", .notifications: "Notifications",
    ]

    public static func visibleRows(_ rows: [Row], developer: Bool) -> [Row] {
        developer ? rows : rows.filter { userFacing.contains($0.id) }
    }

    static func labelled(_ id: FeatureModuleID) -> (title: String, detail: String) {
        let info = info(id)
        guard let page = everydayPage[id] else { return info }
        return ("\(info.title) (whole feature)", "\(info.detail) The everyday switch is in \(page).")
    }

    static func info(_ id: FeatureModuleID) -> (title: String, detail: String) {
        switch id {
        case .snooze: ("Snooze", "Snooze a conversation until later.")
        case .sendLater: ("Send later", "Schedule a message to send later.")
        case .reminders: ("Reminders", "Remind yourself to follow up on a conversation.")
        case .importance: ("Importance rules", "Always or never important, per sender, domain, Gmail label or keyword.")
        case .notifications: ("Notifications", "New important mail, reminders and snoozes as system notifications.")
        case .dockBadge: ("Dock badge", "Unread count on the Dock icon.")
        case .unsubscribe: ("Unsubscribe", "An Unsubscribe line in the reader.")
        case .launchAtLogin: ("Open at login", "Start Mail when you log in.")
        case .diagnostics: ("Export diagnostics", "Help › Export Diagnostics, with no email content.")
        case .review: ("Review queue for prepared drafts", "A queue for drafts an agent prepared.")
        case .ai: ("AI features", "Summaries, reply options and rewrite.")
        case .mute: ("Mute", "Mute a conversation: new replies to it stay out of the Inbox.")
        case .block: ("Block sender and domain",
                      "Block a sender or a whole domain: new mail from them skips the Inbox. Settings › Blocked lists the rules.")
        case .instantReply: ("Quick replies row",
                             "Three AI drafts above an empty reply when Settings › AI turns it on. Nothing is sent.")
        case .hygiene: ("Get me to zero", "Archive the inbox's older conversations in one step; undo for 7 days.")
        case .menuBarExtra: ("Menu bar item", "The unread count in the menu bar, with Open Mail, New message and Quit.")
        case .globalHotkey: ("Global shortcut", "A key combination that opens a new message from any app.")
        case .services: ("Services menu", "New message or search from the Services menu of any app.")
        case .attachmentDragOut: ("Drag attachments out", "Drag attachments from a message to Finder or another app.")
        case .smartSearch: ("Smart search",
                            "Saved searches, recent mail beside people, and searches written as sentences, on this Mac.")
        case .calendar: ("Calendar sidebar",
                         "Events and free/busy for the dates a conversation mentions; create an event from an email.")
        case .appIntents: ("Shortcuts and Siri", "Actions for the Shortcuts app, Siri and Spotlight.")
        case .focusFilters: ("Focus filters", "Put an account first while a Focus is on.")
        default: (id.rawValue, "")
        }
    }
}
