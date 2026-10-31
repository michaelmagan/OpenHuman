import Foundation
import OpenHumanCore

public struct CalendarInviteQuery: Sendable, Hashable {
    public var uid: String
    public var title: String
    public var start: Date
    public var end: Date
    public var organizer: String?
    public var recurrenceID: Date?
    public var repeats: Bool
    public var matchesTitle: Bool

    public init(uid: String, title: String, start: Date, end: Date, organizer: String? = nil, recurrenceID: Date? = nil,
                repeats: Bool = false, matchesTitle: Bool = true) {
        self.uid = uid
        self.title = title
        self.start = start
        self.end = end
        self.organizer = organizer?.lowercased()
        self.recurrenceID = recurrenceID
        self.repeats = repeats
        self.matchesTitle = matchesTitle
    }

    public static let startSlack: TimeInterval = 60

    public var window: (from: Date, to: Date) {
        (start.addingTimeInterval(-Self.startSlack), start.addingTimeInterval(Self.startSlack))
    }

    public func startsTogether(_ start: Date) -> Bool { abs(start.timeIntervalSince(self.start)) <= Self.startSlack }

    public func looksLike(title: String?, organizer: String?) -> Bool {
        let mine = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == mine else { return false }
        guard let organizer, let expected = self.organizer else { return true }
        return organizer.lowercased() == expected
    }

    public enum Pick<Candidate> {
        case found(Candidate)
        case missing
        case ambiguous
    }

    public func pick<Candidate>(_ candidates: [Candidate], start: (Candidate) -> Date, uid: (Candidate) -> String?,
                                looksLike: (Candidate) -> Bool) -> Pick<Candidate> {
        let timed = candidates.filter { startsTogether(start($0)) }
        let byUID = timed.filter { uid($0) == self.uid }
        if byUID.count > 1 { return .ambiguous }
        if let only = byUID.first { return .found(only) }
        guard matchesTitle else { return .missing }
        let alike = timed.filter(looksLike)
        if alike.count > 1 { return .ambiguous }
        if let only = alike.first { return .found(only) }
        return .missing
    }

    public enum Role: Sendable, Hashable {
        case single
        case series
        case occurrence(originalStart: Date?)
    }

    // Why: an event moved after the invitation was sent no longer starts at its DTSTART, but its iCalUID still names
    // it: a single event, the series itself, or the moved occurrence by the start it had in the series
    public func pickMoved<Candidate>(_ candidates: [Candidate], wholeSeries: Bool, uid: (Candidate) -> String?,
                                     role: (Candidate) -> Role) -> Pick<Candidate> {
        let same = candidates.filter { uid($0) == self.uid }
        let matches: [Candidate]
        if wholeSeries {
            matches = same.filter { role($0) == .series }
        } else if let recurrenceID {
            matches = same.filter {
                guard case .occurrence(let original?) = role($0) else { return false }
                return abs(original.timeIntervalSince(recurrenceID)) <= Self.startSlack
            }
        } else if repeats {
            return .missing
        } else {
            matches = same.filter { role($0) == .single }
        }
        if matches.count > 1 { return .ambiguous }
        if let only = matches.first { return .found(only) }
        return .missing
    }

    public static var ambiguousRefusal: String {
        String(localized: "Mail found more than one event that could be this invitation. Answer it in your calendar.")
    }
}

extension CalendarProviding {
    public func invitedEvent(_ query: CalendarInviteQuery, wholeSeries: Bool) async throws -> CalendarEvent? {
        throw CalendarError.refused("This calendar can't find invitations from Mail. Answer it in your calendar.")
    }
}

extension CalendarEvent {
    public var seriesReference: CalendarEvent {
        guard let series = recurringEventID, !series.isEmpty else { return self }
        var reference = CalendarEvent(id: series, title: title, start: start, end: end, isAllDay: isAllDay,
                                      timeZone: timeZone, attendees: attendees, calendarName: calendarName,
                                      meetLink: meetLink, organizerIsMe: organizerIsMe, account: account,
                                      location: location, notes: notes, myResponse: myResponse, recurringEventID: nil,
                                      originalStartTime: nil, extras: extras)
        reference.respondsAs = respondsAs
        return reference
    }
}
