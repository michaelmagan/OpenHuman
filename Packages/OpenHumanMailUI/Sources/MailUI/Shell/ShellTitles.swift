import MailFeatures
import MailModel

/// The window's title and subtitle. The title names the place (a mailbox, a search, All Inboxes, Calendar); the
/// subtitle says whose it is and how much is in it ("Work · 1,204", "107 results", "Dana · 3 messages").
public enum ShellTitles {
    public static let appName = "OpenHuman Mail"
    public static let fakeDataNote = "Fake data"
    static let separator = " · "

    @MainActor
    public static func title(_ router: AppRouter) -> String {
        if router.environment.calendarWindowIfStarted?.isOpen == true { return "Calendar" }
        if let unified = router.unifiedInbox { return unified.title }
        guard let state = router.active else { return appName }
        guard let location = state.location else { return AccountState.title(of: .inbox) }
        return state.title(for: location)
    }

    @MainActor
    public static func subtitle(_ router: AppRouter) -> String {
        var parts = placeParts(router)
        if router.environment.isFake { parts.append(fakeDataNote) }
        return parts.joined(separator: separator)
    }

    @MainActor
    static func placeParts(_ router: AppRouter) -> [String] {
        if router.environment.calendarWindowIfStarted?.isOpen == true { return [] }
        if router.unifiedInbox != nil {
            guard let unread = router.allInboxesUnread, unread > 0 else { return [] }
            return [AccountSwitcherView.countPhrase(unread.formatted(), router.accountCountMode)]
        }
        guard let state = router.active else { return [] }
        if state.mode == .reader {
            let conversation = ShellToolbar.conversationTitle(state.reader)
            return conversation.isEmpty ? [] : [conversation]
        }
        guard let location = state.location else { return [accountName(state.account)] }
        if case .search = location {
            return state.list.map { [results($0.totalCount)] } ?? []
        }
        return listParts(account: accountName(state.account), location: location, total: state.list?.totalCount)
    }

    public static func listParts(account: String, location: MailLocation, total: Int?) -> [String] {
        guard AccountState.titleCount(for: location, total: total) != nil, let total else { return [account] }
        return [account, total.formatted()]
    }

    public static func results(_ total: Int) -> String {
        total == 1 ? "1 result" : "\(total.formatted()) results"
    }

    public static func accountName(_ account: Account) -> String {
        account.alias ?? account.displayName ?? account.email
    }
}
