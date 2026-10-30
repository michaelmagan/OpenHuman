import MailFeatures
import MailModel

/// The text a split shows in the split inbox picker: its count, tooltip and spoken value.
public enum SplitTabBar {
    static func tooltip(_ tab: MailTab) -> String {
        switch (tab.unread > 0, tab.total) {
        case (true, let total?): "\(tab.title): \(Self.conversations(total)), \(tab.unread.formatted()) unread"
        case (true, nil): "\(tab.title): \(tab.unread.formatted()) unread"
        case (false, let total?): "\(tab.title): \(Self.conversations(total))"
        case (false, nil): tab.title
        }
    }

    static func spokenCount(_ tab: MailTab) -> String {
        var parts: [String] = []
        if let total = tab.total, total > 0 { parts.append(conversations(total)) }
        if tab.unread > 0 { parts.append("\(tab.unread.formatted()) unread") }
        return parts.joined(separator: ", ")
    }

    private static func conversations(_ n: Int) -> String {
        n == 1 ? "1 conversation" : "\(n.formatted()) conversations"
    }

    public static func countText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 999 ? "999+" : "\(count)"
    }
}
