import Foundation
import MailModel

public enum SearchHeaderScope {
    public static func shows(searchOpen: Bool, location: MailLocation?, readerShown: Bool, unifiedInboxShown: Bool,
                             calendarShown: Bool) -> Bool {
        guard searchOpen, !readerShown, !unifiedInboxShown, !calendarShown, case .search? = location else { return false }
        return true
    }
}

extension AppRouter {
    public var showsSearchResultsHeader: Bool {
        SearchHeaderScope.shows(searchOpen: active?.searchOpen == true, location: active?.location,
                                readerShown: mode == .reader, unifiedInboxShown: unifiedInbox != nil,
                                calendarShown: environment.calendarWindowIfStarted?.isOpen == true)
    }
}
