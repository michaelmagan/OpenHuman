import Foundation
import MailActions
import MailModel

public struct ThreadListEmptyState: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        case blank
        case progress
        case inboxClear
        case message
        case failure
    }

    public var style: Style
    public var title: String
    public var subtitle: String?
    public var detail: String?
    public var symbol: String?

    public init(style: Style, title: String = "", subtitle: String? = nil, detail: String? = nil, symbol: String? = nil) {
        self.symbol = symbol
        self.style = style
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
    }

    public static let inboxZeroTitle = "Inbox zero."

    public static func make(location: MailLocation, locationTitle: String, state: ThreadListModel.LoadState,
                            hasRows: Bool, loadingShown: Bool, connectivity: ConnectivityState?,
                            day: Int, relatedResults: Bool = false) -> ThreadListEmptyState? {
        if hasRows { return nil }
        let offline: Bool = if case .offline = connectivity { true } else { false }
        let offlineDetail = offline ? String(localized: "You're offline. New mail shows up when you're back.") : nil
        switch state {
        case .failed:
            return ThreadListEmptyState(style: .failure, title: String(localized: "Couldn't load conversations."),
                                        subtitle: String(localized: "The mail on this Mac couldn't be read. Try again in a moment."),
                                        detail: offlineDetail)
        case .loading:
            return loadingShown ? ThreadListEmptyState(style: .progress, title: String(localized: "Loading…")) : ThreadListEmptyState(style: .blank)
        case .loaded:
            break
        }
        if case .online(true, nil) = connectivity, location.isInboxLike {
            return ThreadListEmptyState(style: .progress, title: String(localized: "Fetching your mail…"))
        }
        var result: ThreadListEmptyState
        switch location {
        case .system(.inbox):
            result = ThreadListEmptyState(style: .inboxClear, title: String(localized: "Inbox zero."), symbol: "tray")
        case .split, .splitOther:
            let title = location == .splitOther ? String(localized: "Nothing in Other.")
                : String(localized: "Nothing in \(locationTitle).")
            result = ThreadListEmptyState(style: .inboxClear, title: title, symbol: "tray")
        case .system(.reminders):
            let key = ActionCatalog.descriptor(.remind)?.shortcutHint ?? "H"
            result = ThreadListEmptyState(style: .message,
                                          title: String(localized: "No reminders. Press \(key) on a conversation to set one."),
                                          detail: String(localized: "Reminders stay on this Mac."))
        case .system(.waiting):
            result = ThreadListEmptyState(style: .message, title: String(localized: "Nothing waiting for a reply."),
                                          subtitle: String(localized: "Conversations where you wrote last show here until someone answers."))
        case .system(.scheduled):
            result = ThreadListEmptyState(style: .message, title: String(localized: "Nothing scheduled."),
                                          subtitle: String(localized: "Press ⇧⌘L in a draft to send it later."))
        case .system(.drafts):
            result = ThreadListEmptyState(style: .message, title: String(localized: "No drafts."))
        case .system(.snoozed):
            let key = ActionCatalog.descriptor(.snooze)?.shortcutHint ?? "⇧H"
            result = ThreadListEmptyState(style: .message, title: String(localized: "Nothing snoozed."),
                                          subtitle: String(localized: "Press \(key) on a conversation to bring it back later."))
        case .system(.starred):
            result = ThreadListEmptyState(style: .message, title: String(localized: "No starred conversations."))
        case .system(.trash):
            result = ThreadListEmptyState(style: .message, title: String(localized: "Trash is empty."))
        case .system(.spam):
            result = ThreadListEmptyState(style: .message, title: String(localized: "No spam."))
        case .label:
            result = ThreadListEmptyState(style: .message, title: String(localized: "No conversations with this label."))
        case .reviewQueue:
            result = ThreadListEmptyState(
                style: .message, title: String(localized: "No drafts waiting."),
                subtitle: String(localized: "Agent drafts show up here."))
        case .search(let query):
            let tips = String(localized: "Check the spelling, or try fewer words.")
            result = ThreadListEmptyState(style: .message, title: String(localized: "No mail matches “\(query)”."),
                                          subtitle: relatedResults ? SmartSearchStatusText.describeTip + " " + tips : tips)
        case .system(.done):
            result = ThreadListEmptyState(style: .message, title: String(localized: "Nothing is marked done yet."),
                                          subtitle: String(localized: "Mark a conversation done and it is kept here."))
        case .system(.important), .system(.unread), .system(.sent), .system(.allMail):
            result = ThreadListEmptyState(style: .message, title: String(localized: "Nothing in \(locationTitle)."))
        }
        if result.symbol == nil {
            if case .search = location { result.symbol = "magnifyingglass" } else { result.symbol = "tray" }
        }
        if let offlineDetail, result.detail == nil { result.detail = offlineDetail }
        return result
    }
}
