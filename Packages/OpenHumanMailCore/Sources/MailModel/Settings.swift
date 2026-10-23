import Foundation
import OpenHumanCore

public enum AppSettingScope: Sendable, Hashable {
    case global
    case account(AccountID)
}

public struct AppSettingKey<Value: Codable & Sendable & Equatable>: Sendable, Hashable {
    public let name: String
    public let scope: AppSettingScope
    public let defaultValue: Value
    public let isSafetyKey: Bool

    public init(name: String, scope: AppSettingScope = .global, defaultValue: Value, isSafetyKey: Bool = false) {
        self.name = name
        self.scope = scope
        self.defaultValue = defaultValue
        self.isSafetyKey = isSafetyKey
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name && lhs.scope == rhs.scope }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(scope)
    }
}

public enum TabCountMode: String, Sendable, Hashable, Codable, CaseIterable {
    case all
    case unread
}

public struct BulkArchiveReceipt: Sendable, Hashable, Codable {
    public static let lifetime: TimeInterval = 7 * 86_400

    public let account: AccountID
    public let threads: [ThreadKey]
    public let archivedAt: Date

    public init(account: AccountID, threads: [ThreadKey], archivedAt: Date) {
        self.account = account
        self.threads = threads
        self.archivedAt = archivedAt
    }

    public func isReversible(at now: Date) -> Bool {
        now >= archivedAt && now.timeIntervalSince(archivedAt) < Self.lifetime
    }
}

public enum RemoteImagePolicy: String, Sendable, Hashable, Codable, CaseIterable { case block, ask, allow }

public enum InlineImageSize: String, Sendable, Hashable, Codable, CaseIterable {
    case small, medium, large, original

    public static let pastedDefault = InlineImageSize.medium

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .original: "Original"
        }
    }
}

public enum AppSettings {
    public static let undoSendSeconds = AppSettingKey(name: "undo_send_seconds", defaultValue: 10)
    public static let undoSendSecondsRange = 0...60
    public static func undoSendHold(_ stored: Int) -> Int {
        min(max(stored, undoSendSecondsRange.lowerBound), undoSendSecondsRange.upperBound)
    }
    public static let sendAndMarkDone = AppSettingKey(name: "send.mark_done", defaultValue: true)
    public static let defaultAccount = AppSettingKey<String?>(name: "default_account", defaultValue: nil)
    public static let snoozeMarkUnread = AppSettingKey(name: "snooze_mark_unread", defaultValue: true)
    public static let showShortcutHints = AppSettingKey(name: "ui.show_shortcut_hints", defaultValue: true)
    public static let showPendingSync = AppSettingKey(name: "ui.show_pending_sync", defaultValue: true)

    public static let moveToSuperset = AppSettingKey(name: "ui.move_to_superset", defaultValue: true)
    public static let schedulerSnooze = AppSettingKey(name: "scheduler.snooze.enabled", defaultValue: true)
    public static let schedulerSendLater = AppSettingKey(name: "scheduler.send_later.enabled", defaultValue: true)
    public static let schedulerReminders = AppSettingKey(name: "scheduler.reminders.enabled", defaultValue: true)
    public static let downloadBodies = AppSettingKey(name: "sync.download_bodies", defaultValue: true)
    public static let bodyMaxMessages = AppSettingKey<Int?>(name: "sync.body_max_messages", defaultValue: nil)
    public static let syncRequestAt = AppSettingKey<Int?>(name: "sync.request_at", defaultValue: nil)
    public static let spotlightIndexSubjects = AppSettingKey(name: "spotlight.index_subjects", defaultValue: false)
    public static let calendarSecondTimeZone = AppSettingKey<String?>(name: "calendar.second_time_zone", defaultValue: nil)
    public static let tabCounts = AppSettingKey(name: "ui.tab_counts", defaultValue: TabCountMode.all)
    public static let sidebarHidden = AppSettingKey<[String]>(name: "ui.sidebar.hidden", defaultValue: [])
    public static let lastBulkArchive = AppSettingKey<BulkArchiveReceipt?>(name: "hygiene.last_bulk_archive",
                                                                           defaultValue: nil)
    public static let calendarAddMeetLink = AppSettingKey(name: "calendar.add_meet_link", defaultValue: true)
    public static let calendarAvailabilityIgnoresConflicts = AppSettingKey(name: "calendar.availability_ignore_conflicts",
                                                                          defaultValue: false)
    public static let calendarShowAll = AppSettingKey(name: "calendar.show_all_calendars", defaultValue: false)
    public static let cliReadonlyDefault = AppSettingKey(name: "cli.readonly_default", defaultValue: false,
                                                         isSafetyKey: true)
    public static let cliAllowedCommands = AppSettingKey<[String]?>(name: "cli.allowed_commands", defaultValue: nil,
                                                                    isSafetyKey: true)

    public static func remoteImages(_ account: AccountID) -> AppSettingKey<RemoteImagePolicy> {
        AppSettingKey(name: "remote_images", scope: .account(account), defaultValue: .block)
    }

    public static func hideSplitWhenEmpty(_ account: AccountID) -> AppSettingKey<[String]> {
        AppSettingKey(name: "split.hide_when_empty", scope: .account(account), defaultValue: [])
    }

    public static let otherSplitToken = "oh:split:other"

    public static func alsoShowSplitInInbox(_ account: AccountID) -> AppSettingKey<[String]> {
        AppSettingKey(name: "split.also_show_in_inbox", scope: .account(account), defaultValue: [])
    }

    public static func eventsRescanAt(_ account: AccountID) -> AppSettingKey<Int?> {
        AppSettingKey(name: "split.events_rescan_at", scope: .account(account), defaultValue: nil)
    }

    public static func remoteImageSenders(_ account: AccountID) -> AppSettingKey<[String]> {
        AppSettingKey(name: "remote_images.allowed_senders", scope: .account(account), defaultValue: [])
    }

    public static func calendarSetupSkipped(_ account: AccountID) -> AppSettingKey<Bool> {
        AppSettingKey(name: "onboarding.calendar_skipped", scope: .account(account), defaultValue: false)
    }
}

public enum AccountCountMode: String, Sendable, Hashable, Codable, CaseIterable {
    case important
    case inbox
    case off

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .important
    }
}

extension AppSettings {
    public static let accountCounts = AppSettingKey(name: "ui.account_counts", defaultValue: AccountCountMode.important)
    public static let allInboxesShown = AppSettingKey(name: "ui.all_inboxes", defaultValue: true)
}

public struct ShortcutUseCount: Sendable, Hashable, Codable {
    public var keyboard: Int
    public var mouse: Int

    public init(keyboard: Int = 0, mouse: Int = 0) {
        self.keyboard = keyboard
        self.mouse = mouse
    }
}

extension AppSettings {
    public static let hintOnClick = AppSettingKey(name: "ui.hint_on_click", defaultValue: true)
    public static let shortcutLearning = AppSettingKey<[String: ShortcutUseCount]>(name: "ui.shortcut_learning",
                                                                                   defaultValue: [:])
}

public enum BodyDownloadEstimate {
    public static let bytesPerMessage = 40_000
    public static let capChoices: [Int?] = [nil, 5_000, 10_000, 20_000, 50_000]

    public static func bytes(messages: Int) -> Int { messages * bytesPerMessage }

    public static func note(cap: Int?) -> String {
        let count = cap ?? 10_000
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes(messages: count)), countStyle: .file)
        let number = count.formatted(.number)
        return cap == nil ? "No limit. About \(size) of disk for every 10,000 messages."
                          : "Up to about \(size) of disk for \(number) messages."
    }
}

public protocol SettingsPort: Sendable {
    func observe<V>(_ key: AppSettingKey<V>) -> AsyncStream<V>
    func get<V>(_ key: AppSettingKey<V>) async throws -> V
    func set<V>(_ key: AppSettingKey<V>, _ value: V) async throws
}
