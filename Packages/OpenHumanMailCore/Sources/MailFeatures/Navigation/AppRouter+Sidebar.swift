import MailModel
import OpenHumanCore

/// A row the sidebar can select. The router's state decides which one is selected; selecting one navigates.
public enum MailSidebarSelection: Hashable, Sendable {
    case allInboxes
    /// The account's inbox: its split tabs, or its plain Inbox without splits.
    case inbox(AccountID)
    case location(AccountID, MailLocation)
    case calendar
}

extension AppRouter {
    /// ← in the list: shows the sidebar when it is hidden and gives it the keys, starting at the current place.
    func focusSidebar() -> Bool {
        if !isLabelSidebarVisible { isLabelSidebarVisible = true }
        sidebarHighlight = nil
        sidebarFocusRequest += 1
        return true
    }

    /// Gives the keys back to the list or the conversation without opening the highlighted row.
    public func leaveSidebar() {
        sidebarHighlight = nil
        sidebarReturnRequest += 1
    }
}
