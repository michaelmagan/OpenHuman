import Foundation
import MailModel

// Why: one meeting reaches each connected account as its own copy (the organizer's, and one per invited account). The
// copies share the iCalendar UID, so the window draws them as one meeting and keeps every copy for answers and edits.
@MainActor
public enum CalendarCopyGroups {
    // Events keep their order; the copies of one meeting become a single event at the place of its first copy
    public static func group(_ events: [CalendarEvent], accountOrder: [String]) -> [CalendarEvent] {
        let rank = Dictionary(accountOrder.enumerated().map { ($1.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var members: [String: [Int]] = [:]
        var meetingOf: [Int: String] = [:]
        for (index, event) in events.enumerated() {
            guard let key = meetingKey(event), let account = event.account?.lowercased() else { continue }
            // One copy per account: another event with the same key in the same account is drawn on its own
            guard !(members[key] ?? []).contains(where: { events[$0].account?.lowercased() == account }) else { continue }
            members[key, default: []].append(index)
            meetingOf[index] = key
        }
        var out: [CalendarEvent] = []
        var drawn: Set<String> = []
        for (index, event) in events.enumerated() {
            guard let key = meetingOf[index], let group = members[key], group.count > 1 else {
                out.append(event)
                continue
            }
            guard drawn.insert(key).inserted else { continue }
            let copies = group.map { events[$0] }.sorted { a, b in
                let left = rank[a.account?.lowercased() ?? ""] ?? Int.max
                let right = rank[b.account?.lowercased() ?? ""] ?? Int.max
                return left != right ? left < right : a.copyKey < b.copyKey
            }
            out.append(merged(copies))
        }
        return out
    }

    // Why: every occurrence of a repeating meeting has the series' UID, so an occurrence is also told apart by the start it
    // has in the series, which survives a move of that one occurrence
    public static func meetingKey(_ event: CalendarEvent) -> String? {
        guard let uid = event.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty, !event.id.isEmpty,
              !event.id.hasPrefix(CalendarSidebarModel.placeholderPrefix),
              let account = event.account, !account.isEmpty else { return nil }
        // An all-day occurrence keeps its series date, which every account's copy shares whatever its time zone
        switch event.originalStartTime {
        case .date(let day)?: return "\(uid)#\(day)"
        case .timed(let start, _)?: return "\(uid)#\(Int(start.timeIntervalSince1970.rounded()))"
        case nil:
            guard event.isRecurring else { return uid }
            return "\(uid)#\(Int(event.start.timeIntervalSince1970.rounded()))"
        }
    }

    // The copy the user organizes is shown and edited; otherwise the copy on the first calendar in the list
    static func merged(_ copies: [CalendarEvent]) -> CalendarEvent {
        let primary = copies.first { $0.organizerIsMe == true } ?? copies[0]
        var shown = primary.single
        shown.copies = [primary.single] + copies.filter { $0.copyKey != primary.copyKey }.map(\.single)
        return shown
    }

    // Says which copy's time the window shows when the calendars disagree
    public static func timeNote(for meeting: CalendarEvent) -> String? {
        guard meeting.copiesDisagreeOnTime, let shown = meeting.copies.first else { return nil }
        let account = shown.account ?? ""
        return shown.organizerIsMe == true
            ? String(localized: "Your calendars show different times. This is the time on \(account), where you organize it.")
            : String(localized: "Your calendars show different times. This is the time on \(account).")
    }
}
