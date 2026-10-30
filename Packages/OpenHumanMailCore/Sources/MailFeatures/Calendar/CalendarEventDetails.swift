import Foundation
import MailModel
import MailRender
import OpenHumanCore

public struct CalendarEventDetails: Sendable, Hashable {
    public struct Guest: Sendable, Hashable, Identifiable {
        public let email: String
        public let name: String?
        public let isOptional: Bool
        public let isMe: Bool
        public let response: CalendarResponse?

        public var id: String { email.lowercased() }

        public var line: String {
            let shown = name.map { "\($0) <\(email)>" } ?? email
            return isMe ? String(localized: "\(shown) (you)") : shown
        }

        public var responseText: String? { response?.title }

        public var spokenText: String {
            var parts = [name ?? email]
            if name != nil { parts.append(email) }
            if isMe { parts.append(String(localized: "you")) }
            if isOptional { parts.append(String(localized: "optional")) }
            if let response { parts.append(Self.spoken(response)) }
            return parts.joined(separator: ", ")
        }

        static func spoken(_ response: CalendarResponse) -> String {
            switch response {
            case .accepted: String(localized: "accepted")
            case .declined: String(localized: "declined")
            case .tentative: String(localized: "maybe")
            case .needsAction: String(localized: "not answered yet")
            }
        }
    }

    public let event: CalendarEvent
    public let title: String
    public let dayText: String
    public let timeText: String?
    public let zoneText: String?
    public let eventZoneText: String?
    public let repeatText: String?
    public let location: String?
    public let joinLink: URL?
    public let guests: [Guest]
    public let guestSummary: String?
    public let notes: CalendarDescription.Parsed?
    public let calendarName: String
    public let calendarKey: String
    public let colorIndex: Int
    public let answerText: String?
    public let organizerText: String?
    public let organizedByMe: Bool
    public let canOpenEditor: Bool

    @MainActor
    public init(event: CalendarEvent, timeZone: TimeZone, calendarName: String, calendarKey: String,
                myAddresses: Set<String> = [], myResponse: CalendarResponse? = nil) {
        self.event = event
        let trimmedTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmedTitle.isEmpty ? String(localized: "(No title)") : trimmedTitle
        let when = Self.when(event, zone: timeZone)
        dayText = when.day
        timeText = when.time
        zoneText = event.isAllDay ? nil : String(localized: "Times in \(CalendarSidebarModel.city(timeZone))")
        eventZoneText = Self.eventZone(event, shownIn: timeZone)
        repeatText = Self.repeats(event)
        let place = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        location = place.isEmpty ? nil : place
        joinLink = event.meetLink.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        var mine = Set(myAddresses.map { $0.lowercased() })
        if let alias = event.respondsAs { mine.insert(alias.lowercased()) }
        let people = event.extras.guests.isEmpty ? event.attendees.map { CalendarGuest($0) } : event.extras.guests
        let shownGuests = people.map { person in
            let isMe = (person.isOrganizer == false || (event.organizerIsMe == true && person.isOrganizer == true))
                && mine.contains(person.email.lowercased())
            let answer = isMe ? (myResponse ?? person.response ?? event.myResponse) : person.response
            return Guest(email: person.email, name: person.name, isOptional: person.isOptional, isMe: isMe, response: answer)
        }
        guests = shownGuests
        guestSummary = Self.summary(shownGuests)
        let parsed = CalendarDescription.parse(event.notes)
        notes = parsed.isEmpty ? nil : parsed
        self.calendarName = calendarName
        self.calendarKey = calendarKey
        colorIndex = CalendarDayTimeline.colorIndex(for: event)
        let organizes = event.organizerIsMe == true || (event.organizerIsMe == nil && event.attendees.isEmpty)
        organizedByMe = organizes
        canOpenEditor = organizes && !event.id.isEmpty && !event.id.hasPrefix(CalendarSidebarModel.placeholderPrefix)
        answerText = organizes ? nil
            : event.myResponse.map { String(localized: "Your answer: \($0.title)") }
            ?? (event.hidesMyResponse ? CalendarEvent.responseNotShown : nil)
        if !organizes {
            organizerText = String(localized: "Someone else organizes this event: only they can change it.")
        } else if event.organizerIsMe == true, !event.attendees.isEmpty {
            organizerText = String(localized: "You organize this event.")
        } else {
            organizerText = nil
        }
    }

    public var spokenTime: String {
        [dayText, timeText, zoneText, eventZoneText].compactMap { $0 }.joined(separator: ", ")
    }

    @MainActor
    static func when(_ event: CalendarEvent, zone: TimeZone) -> (day: String, time: String?) {
        let calendar = CalendarDateMentions.calendar(zone)
        let dayStyle = Date.FormatStyle(timeZone: zone).weekday(.wide).month(.wide).day()
        if event.isAllDay {
            let days = max(Int((event.end.timeIntervalSince(event.start) / 86_400).rounded()), 1)
            let first = event.start.formatted(dayStyle)
            guard days > 1, let last = calendar.date(byAdding: .day, value: days - 1, to: event.start) else {
                return (first, String(localized: "All day"))
            }
            return ("\(first) – \(last.formatted(dayStyle))", String(localized: "All day"))
        }
        let lastInstant = max(event.end.addingTimeInterval(-1), event.start)
        if calendar.isDate(event.start, inSameDayAs: lastInstant) {
            return (event.start.formatted(dayStyle), CalendarSidebarModel.range(event.start, event.end, zone))
        }
        let span = (event.start..<max(event.start, event.end))
            .formatted(Date.IntervalFormatStyle(date: .abbreviated, time: .shortened, timeZone: zone))
        return (span, nil)
    }

    @MainActor
    static func eventZone(_ event: CalendarEvent, shownIn zone: TimeZone) -> String? {
        guard !event.isAllDay, let identifier = event.timeZone, let own = TimeZone(identifier: identifier),
              own.secondsFromGMT(for: event.start) != zone.secondsFromGMT(for: event.start) else { return nil }
        let range = CalendarSidebarModel.range(event.start, event.end, own)
        let city = CalendarSidebarModel.city(own)
        let shownDay = CalendarDateMentions.calendar(zone).dateComponents([.year, .month, .day], from: event.start)
        let ownDay = CalendarDateMentions.calendar(own).dateComponents([.year, .month, .day], from: event.start)
        guard shownDay != ownDay else { return String(localized: "\(range) in \(city)") }
        let weekday = event.start.formatted(Date.FormatStyle(timeZone: own).weekday(.abbreviated))
        return String(localized: "\(weekday) \(range) in \(city)")
    }

    static func repeats(_ event: CalendarEvent) -> String? {
        let preset = CalendarRepeat.preset(of: event.extras.recurrence)
        if preset != .none, preset != .custom { return preset.title }
        return preset == .custom || event.isRecurring ? String(localized: "Repeats") : nil
    }

    static func summary(_ guests: [Guest]) -> String? {
        guard !guests.isEmpty else { return nil }
        let head = guests.count == 1 ? String(localized: "1 guest") : String(localized: "\(guests.count) guests")
        func count(_ response: CalendarResponse) -> Int { guests.filter { $0.response == response }.count }
        var parts: [String] = []
        if count(.accepted) > 0 { parts.append(String(localized: "\(count(.accepted)) yes")) }
        if count(.tentative) > 0 { parts.append(String(localized: "\(count(.tentative)) maybe")) }
        if count(.declined) > 0 { parts.append(String(localized: "\(count(.declined)) no")) }
        if count(.needsAction) > 0 { parts.append(String(localized: "\(count(.needsAction)) not answered")) }
        return parts.isEmpty ? head : "\(head) · \(parts.joined(separator: ", "))"
    }
}
