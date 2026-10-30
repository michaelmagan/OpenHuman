import MailActions

public struct IntentInfo: Hashable, Sendable {
    public enum Tier: String, Hashable, Sendable {
        case read
        case write
    }

    public let name: String
    public let title: String
    public let tier: Tier
    public let foreground: Bool
    public let actions: [ActionID]
    public let module: FeatureModuleID?

    public init(_ name: String, _ title: String, tier: Tier, foreground: Bool, actions: [ActionID] = [],
                module: FeatureModuleID? = nil) {
        self.name = name
        self.title = title
        self.tier = tier
        self.foreground = foreground
        self.actions = actions
        self.module = module
    }
}

public enum IntentCatalog {
    public static let all: [IntentInfo] = [
        IntentInfo("CountUnreadIntent", "Count unread mail", tier: .read, foreground: false),
        IntentInfo("FindConversationsIntent", "Find conversations", tier: .read, foreground: false),
        IntentInfo("OpenMailboxIntent", "Open mailbox", tier: .read, foreground: true,
                   actions: IntentMailbox.allCases.compactMap(\.action)),
        IntentInfo("OpenThreadIntent", "Open conversation", tier: .read, foreground: true, actions: [.openThread]),
        IntentInfo("SearchMailIntent", "Search mail", tier: .read, foreground: true, actions: [.search]),
        IntentInfo("NewMessageIntent", "New message", tier: .read, foreground: true, actions: [.compose]),
        IntentInfo("OpenReviewQueueIntent", "Open review queue", tier: .read, foreground: true, actions: [.goReview],
                   module: .review),
        IntentInfo("MarkDoneIntent", "Mark done", tier: .write, foreground: false, actions: [.markDone]),
        IntentInfo("SnoozeIntent", "Snooze", tier: .write, foreground: false, actions: [.snooze], module: .snooze),
        IntentInfo("RemindMeIntent", "Remind me", tier: .write, foreground: false, actions: [.remind],
                   module: .reminders),
    ]

    public static let neverExposed: [ActionID] = [
        .send, .sendLater, .reviewSend, .unsubscribe, .trash, .spam, .discardDraft, .reviewDiscard,
        .alwaysImportantSender, .alwaysImportantDomain, .neverImportant, .removeFromSplit, .notAPitch,
        .neverImportantDomain, .blockSender, .blockDomain,
    ]

    public static var writeTitles: [String] { all.filter { $0.tier == .write }.map(\.title) }
}

public enum IntentMailbox: String, CaseIterable, Hashable, Sendable {
    case inbox, important, starred, drafts, sent, allMail, snoozed, reminders, scheduled, reviewQueue, muted

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .important: "Important"
        case .starred: "Starred"
        case .drafts: "Drafts"
        case .sent: "Sent"
        case .allMail: "All mail"
        case .snoozed: "Snoozed"
        case .reminders: "Reminders"
        case .scheduled: "Scheduled"
        case .reviewQueue: "Review queue"
        case .muted: "Muted"
        }
    }

    public var action: ActionID? {
        switch self {
        case .inbox: .goInbox
        case .important: nil
        case .starred: .goStarred
        case .drafts: .goDrafts
        case .sent: .goSent
        case .allMail: .goAllMail
        case .snoozed: .goSnoozed
        case .reminders: .goReminders
        case .scheduled: .goScheduled
        case .reviewQueue: .goReview
        case .muted: .goMuted
        }
    }

    public var module: FeatureModuleID? {
        switch self {
        case .snoozed: .snooze
        case .reminders: .reminders
        case .scheduled: .sendLater
        case .reviewQueue: .review
        case .muted: .mute
        default: nil
        }
    }
}

public enum IntentUnreadKind: String, CaseIterable, Hashable, Sendable {
    case important
    case inbox
}
