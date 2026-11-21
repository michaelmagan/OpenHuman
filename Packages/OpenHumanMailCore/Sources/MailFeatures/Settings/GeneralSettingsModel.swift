import Foundation
import MailModel
import Observation

@MainActor @Observable
public final class GeneralSettingsModel {
    public static let undoSendChoices = [0, 5, 10, 20, 30]

    public let undoSend: StoredSetting<Int>
    public let snooze: StoredSetting<Bool>
    public let sendLater: StoredSetting<Bool>
    public let sendAndMarkDone: StoredSetting<Bool>
    public let reminders: StoredSetting<Bool>
    public let snoozeMarkUnread: StoredSetting<Bool>
    public let showShortcutHints: StoredSetting<Bool>
    public let showPendingSync: StoredSetting<Bool>
    public let moveToSuperset: StoredSetting<Bool>
    public let tabCounts: StoredSetting<TabCountMode>
    public let accountCounts: StoredSetting<AccountCountMode>
    public let downloadBodies: StoredSetting<Bool>
    public let bodyMax: StoredSetting<Int?>
    public let confirmEverySend: StoredSetting<Bool>
    public let showsConfirmBeforeSending: Bool
    public let availability: SettingsAvailability
    public let signatureOnReplies: StoredSetting<Bool>
    public let defaultReminderTime: StoredSetting<Int>
    public let reminderWeekdaysOnly: StoredSetting<Bool>

    public let hintOnClick: StoredSetting<Bool>
    public let shortcutLearning: ShortcutLearning?

    public init(settings: (any SettingsPort)?, availability: SettingsAvailability, isLiveAccount: Bool = false,
                shortcutLearning: ShortcutLearning? = nil) {
        hintOnClick = StoredSetting(AppSettings.hintOnClick, port: settings)
        self.shortcutLearning = shortcutLearning
        self.availability = availability
        showsConfirmBeforeSending = isLiveAccount && availability.hasCommands
        defaultReminderTime = StoredSetting(AppSettings.defaultReminderTime, port: settings)
        reminderWeekdaysOnly = StoredSetting(AppSettings.reminderWeekdaysOnly, port: settings)
        signatureOnReplies = StoredSetting(AppSettings.signatureOnReplies, port: settings)
        confirmEverySend = StoredSetting(SendSettings.confirmEverySend, port: settings)
        undoSend = StoredSetting(AppSettings.undoSendSeconds, port: settings)
        snooze = StoredSetting(AppSettings.schedulerSnooze, port: settings)
        sendLater = StoredSetting(AppSettings.schedulerSendLater, port: settings)
        sendAndMarkDone = StoredSetting(AppSettings.sendAndMarkDone, port: settings)
        reminders = StoredSetting(AppSettings.schedulerReminders, port: settings)
        snoozeMarkUnread = StoredSetting(AppSettings.snoozeMarkUnread, port: settings)
        showShortcutHints = StoredSetting(AppSettings.showShortcutHints, port: settings)
        showPendingSync = StoredSetting(AppSettings.showPendingSync, port: settings)
        moveToSuperset = StoredSetting(AppSettings.moveToSuperset, port: settings)
        tabCounts = StoredSetting(AppSettings.tabCounts, port: settings)
        accountCounts = StoredSetting(AppSettings.accountCounts, port: settings)
        downloadBodies = StoredSetting(AppSettings.downloadBodies, port: settings)
        bodyMax = StoredSetting(AppSettings.bodyMaxMessages, port: settings)
    }

    public convenience init(environment: AppEnvironment) {
        self.init(settings: environment.settings, availability: SettingsAvailability(environment: environment),
                  isLiveAccount: environment.isLiveAccount, shortcutLearning: environment.actions.shortcutHints)
    }

    public func start() {
        for setting in [undoSend.start, snooze.start, sendLater.start, reminders.start, snoozeMarkUnread.start,
                        downloadBodies.start, bodyMax.start, confirmEverySend.start, sendAndMarkDone.start, showShortcutHints.start,
                        showPendingSync.start,
                        moveToSuperset.start,
                        tabCounts.start, accountCounts.start, signatureOnReplies.start, defaultReminderTime.start,
                        reminderWeekdaysOnly.start] { setting() }
        hintOnClick.start()
    }

    public static let hintOnClickTitle = "Hint when I click"
    public static let hintOnClickNote = "After you click a button or menu item that has a key, a short note names the "
        + "key, until you have pressed it a few times. Separate from the strip along the bottom."
    public static let resetHintsTitle = "Reset hints"
    public static let resetHintsNote = "Forgets which keys you have learned, so the notes show again."

    public var canResetShortcutHints: Bool { shortcutLearning?.canReset ?? false }

    public func resetShortcutHints() async {
        await shortcutLearning?.reset()
    }

    public var defaultReminderTimeChoices: [Int] {
        let choices = AppSettings.defaultReminderTimeChoices
        let current = defaultReminderTime.value
        return choices.contains(current) ? choices : (choices + [current]).sorted()
    }

    public static func defaultReminderTimeTitle(_ minutes: Int, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let clamped = min(max(minutes, 0), 23 * 60 + 59)
        let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: clamped / 60,
                                                      minute: clamped % 60)) ?? Date(timeIntervalSince1970: 0)
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        style.locale = locale
        return date.formatted(style)
    }

    public static let defaultReminderTimeNote = "When “Tomorrow morning”, “Next week” and other remind and snooze "
        + "choices come back. A day typed without a time uses it too."
    public static let reminderWeekdaysOnlyNote = "A reminder or snooze that would come back on a Saturday or Sunday "
        + "comes back on Monday instead. “This weekend” still means the weekend."

    public static let signatureOnRepliesNote = "Replies and forwards start with your signature. New messages always do."

    public static let confirmBeforeSendingTitle = "Confirm before sending"
    public static let confirmEverySendNote = "Off: Send goes straight out, with Undo send above to take it back. On: Mail "
        + "asks before each message goes out."

    public static let bodyCapChoices = BodyDownloadEstimate.capChoices
    public static func bodyCapTitle(_ cap: Int?) -> String { cap.map { "\($0.formatted(.number)) messages" } ?? "No limit" }
    public static let downloadBodiesNote = "Keeps a copy of message text on this Mac so search finds words inside "
        + "messages, not only subjects and senders. It downloads slowly, newest first, and pauses while you work."
    public var bodyDiskNote: String { BodyDownloadEstimate.note(cap: bodyMax.value) }

    public static func undoSendTitle(_ seconds: Int) -> String { seconds == 0 ? "Off" : "\(seconds) seconds" }

    public static func tabCountTitle(_ mode: TabCountMode) -> String {
        switch mode {
        case .all: "All conversations"
        case .unread: "Unread only"
        }
    }
    public static let moveToSupersetNote = "V also lists Inbox, Important, Other and your split tabs above the labels. "
        + "Off: V lists labels only."
    public static let tabCountsNote = "The number next to each split tab. Like a task list, it counts every "
        + "conversation still in the tab, read or not."

    public static func accountCountTitle(_ mode: AccountCountMode) -> String {
        switch mode {
        case .important: "Important unread"
        case .inbox: "All unread in Inbox"
        case .off: "Off"
        }
    }
    public static let accountCountsNote = "The number on each account picture and on All Inboxes. Important unread "
        + "follows your splits."
    public static let zoomNote = "The size of the conversation list and of conversations on this Mac. In a conversation, "
        + "⌘+ and ⌘- change it too."

    public static let snoozeNote = "Snoozed threads wake on your other Mac too, because a snooze is a label in Gmail. "
        + "Turning this off pauses waking on this Mac only."
    public static let sendLaterNote = "Scheduled messages wait as drafts in Gmail and go out from the first Mac running "
        + "Mail after their time, or when you next open Mail (a day or more late, Mail asks first). Turning this off "
        + "stops this Mac sending them."
    public static let remindersNote = "Reminders stay on this Mac only."

    public var errorMessage: String? {
        [undoSend.errorMessage, snooze.errorMessage, sendLater.errorMessage, reminders.errorMessage,
         snoozeMarkUnread.errorMessage, downloadBodies.errorMessage, bodyMax.errorMessage,
         confirmEverySend.errorMessage, showShortcutHints.errorMessage, showPendingSync.errorMessage, sendAndMarkDone.errorMessage,
         moveToSuperset.errorMessage,
         tabCounts.errorMessage, accountCounts.errorMessage, signatureOnReplies.errorMessage, defaultReminderTime.errorMessage,
         reminderWeekdaysOnly.errorMessage].compactMap { $0 }.first
            ?? hintOnClick.errorMessage
    }
}
