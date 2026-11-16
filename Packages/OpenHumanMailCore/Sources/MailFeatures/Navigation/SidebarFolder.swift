import Foundation
import MailActions
import MailModel
import OpenHumanCore

public struct SidebarFolder: Identifiable, Hashable, Sendable {
    public enum Place: Hashable, Sendable {
        case system(SystemFolder)
        case muted
    }

    public static let mutedToken = "muted"

    public let place: Place
    public let symbol: String
    public let goAction: ActionID?
    public let searchTerm: String?

    public var id: String { token }

    public var token: String {
        switch place {
        case .system(let folder): folder.rawValue
        case .muted: Self.mutedToken
        }
    }

    public var title: String {
        switch place {
        case .system(let folder): AccountState.title(of: folder)
        case .muted: "Muted"
        }
    }

    init(_ place: Place, symbol: String, goAction: ActionID? = nil, searchTerm: String? = nil) {
        self.place = place
        self.symbol = symbol
        self.goAction = goAction
        self.searchTerm = searchTerm
    }

    public static let all: [SidebarFolder] = [
        SidebarFolder(.system(.starred), symbol: "star", goAction: .goStarred),
        SidebarFolder(.system(.snoozed), symbol: "clock", goAction: .goSnoozed),
        SidebarFolder(.system(.reminders), symbol: "bell", goAction: .goReminders),
        SidebarFolder(.system(.waiting), symbol: "hourglass", goAction: .goWaiting),
        SidebarFolder(.system(.scheduled), symbol: "calendar.badge.clock", goAction: .goScheduled),
        SidebarFolder(.muted, symbol: "speaker.slash", goAction: .goMuted),
        SidebarFolder(.system(.drafts), symbol: "doc", goAction: .goDrafts),
        SidebarFolder(.system(.sent), symbol: "paperplane", goAction: .goSent),
        SidebarFolder(.system(.done), symbol: "checkmark.circle", goAction: .goDone),
        SidebarFolder(.system(.allMail), symbol: "archivebox", goAction: .goAllMail),
        SidebarFolder(.system(.spam), symbol: "xmark.octagon", goAction: .goSpam, searchTerm: "in:spam"),
        SidebarFolder(.system(.trash), symbol: "trash", goAction: .goTrash, searchTerm: "in:trash"),
    ]

    public static let tokens: Set<String> = Set(all.map(\.token))

    public static func named(_ token: String) -> SidebarFolder? { all.first { $0.token == token } }

    public static func folder(for location: MailLocation, mutedLabel: GmailLabelID?) -> SidebarFolder? {
        switch location {
        case .system(let folder): all.first { $0.place == .system(folder) }
        case .label(let id) where id == mutedLabel: all.first { $0.place == .muted }
        default: nil
        }
    }

    public static func hiddenTokens(_ stored: [String]) -> Set<String> {
        Set(stored).intersection(tokens)
    }

    // Unknown tokens are kept so a newer build's choices survive an edit here.
    public static func hiddenList(_ stored: [String], setting token: String, hidden: Bool) -> [String] {
        var next = Set(stored)
        if hidden { next.insert(token) } else { next.remove(token) }
        return next.sorted()
    }

    public static func visibleFolders(hidden: Set<String>, current: MailLocation?,
                                      mutedLabel: GmailLabelID? = nil) -> [SidebarFolder] {
        guard !hidden.isEmpty else { return all }
        let kept = current.flatMap { folder(for: $0, mutedLabel: mutedLabel)?.token }
        return all.filter { !hidden.contains($0.token) || $0.token == kept }
    }

    public static func route(of folder: SidebarFolder, descriptor: ActionDescriptor?) -> String? {
        if folder.goAction != nil, let binding = descriptor?.defaultBindings.first { return binding.description }
        return folder.searchTerm
    }

    public static func hiddenNotice(_ folder: SidebarFolder, route: String?) -> String {
        let reach: String
        if let route, route == folder.searchTerm {
            reach = "Searching \(route) still finds it."
        } else if let route {
            reach = "\(route) still opens it."
        } else {
            reach = "Settings › Sidebar shows it again."
        }
        return "\(folder.title) is hidden from the sidebar. \(reach)"
    }
}
