import Foundation
import MailModel
import OpenHumanCore

public enum ActionSource: String, Hashable, Sendable, Codable {
    case keyboard, menu, palette, toolbar, deepLink, intent, toast, swipe
}

public struct TargetState: Hashable, Sendable {
    public var anyUnread = false
    public var allStarred = false
    public var anySnoozed = false
    public var anyReminder = false
    public var allMuted = false
    public var anyDraft = false
    public var anyScheduled = false
    public var autoLabel: String?

    public init(anyUnread: Bool = false, allStarred: Bool = false, anySnoozed: Bool = false, anyReminder: Bool = false,
                allMuted: Bool = false, anyDraft: Bool = false, anyScheduled: Bool = false, autoLabel: String? = nil) {
        self.anyUnread = anyUnread
        self.allStarred = allStarred
        self.anySnoozed = anySnoozed
        self.anyReminder = anyReminder
        self.allMuted = allMuted
        self.anyDraft = anyDraft
        self.anyScheduled = anyScheduled
        self.autoLabel = autoLabel
    }
}

public struct ActionContext: Hashable, Sendable {
    public var scope: ActionScope
    public var account: AccountID?
    public var accountCount: Int
    public var location: MailLocation?
    public var selection: [ThreadKey]
    public var checkedCount: Int
    public var focusedThread: ThreadKey?
    public var focusedMessage: MessageKey?
    public var sender: String?
    public var targets: TargetState
    public var hasRows: Bool
    public var composer: UUID?
    public var canWrite: Bool
    public var canUndo: Bool
    public var canRedo: Bool
    public var togglesOn: Set<ActionID>
    public var accountTitles: [String] = []
    /// The search field is open over the list, whether or not its results are shown yet.
    public var searchOpen = false

    public init(scope: ActionScope = .global, account: AccountID? = nil, accountCount: Int = 0,
                location: MailLocation? = nil, selection: [ThreadKey] = [], checkedCount: Int = 0,
                focusedThread: ThreadKey? = nil, focusedMessage: MessageKey? = nil, sender: String? = nil,
                targets: TargetState = TargetState(), hasRows: Bool = false, composer: UUID? = nil,
                canWrite: Bool = true, canUndo: Bool = false, canRedo: Bool = false,
                togglesOn: Set<ActionID> = []) {
        self.scope = scope
        self.account = account
        self.accountCount = accountCount
        self.location = location
        self.selection = selection
        self.checkedCount = checkedCount
        self.focusedThread = focusedThread
        self.focusedMessage = focusedMessage
        self.sender = sender
        self.targets = targets
        self.hasRows = hasRows
        self.composer = composer
        self.canWrite = canWrite
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.togglesOn = togglesOn
    }

    public func accountTitle(at position: Int) -> String? {
        accountTitles.indices.contains(position - 1) ? accountTitles[position - 1] : nil
    }

    public var senderDomain: String? {
        guard let sender, let at = sender.lastIndex(of: "@") else { return nil }
        let domain = sender[sender.index(after: at)...]
        return domain.isEmpty ? nil : String(domain)
    }

    public var isInInbox: Bool {
        switch location {
        case .split, .splitOther, .system(.inbox): true
        default: false
        }
    }
}

public enum ActionAvailability: Hashable, Sendable {
    case enabled
    case disabled(DisabledReason)
    case hidden

    public var isEnabled: Bool { self == .enabled }

    public var reason: DisabledReason? {
        if case .disabled(let reason) = self { return reason }
        return nil
    }
}

public enum DisabledReason: Hashable, Sendable, CustomStringConvertible {
    case unavailable(String)
    case noSelection
    case nothingToUndo
    case nothingToRedo
    case other(String)
    case needs(action: String, context: String)
    case notBuilt(String)

    public var description: String {
        switch self {
        case .unavailable(let what): "\(what) isn't available here"
        case .noSelection: "No conversation selected"
        case .nothingToUndo: "Nothing to undo"
        case .nothingToRedo: "Nothing to redo"
        case .other(let text): text
        case .needs(let action, let context): "\(action) only works when \(context)"
        case .notBuilt(let what): "\(what) isn't built in OpenHuman Mail yet"
        }
    }

    public var announces: Bool {
        switch self {
        case .unavailable, .noSelection, .needs, .notBuilt: true
        case .nothingToUndo, .nothingToRedo, .other: false
        }
    }
}
