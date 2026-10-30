import Foundation
import MailModel

public struct InviteCard: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case request
        case cancelled
        case reply
        case counter
        case notice
    }

    public struct Guest: Sendable, Hashable, Identifiable {
        public var id: String { email }
        public let title: String
        public let email: String
        public let isOrganizer: Bool
        public let isMe: Bool
        public let response: CalendarResponse?
        public let isOptional: Bool
    }

    public struct Join: Sendable, Hashable {
        public let title: String
        public let url: URL
    }

    public let message: MessageKey
    public let invite: CalendarInvite
    public let kind: Kind
    public let title: String
    public let when: String
    public let whenNote: String?
    public let repeats: String?
    public let location: String?
    public let locationLink: URL?
    public let guests: [Guest]
    public let notes: String?
    public let join: Join?
    public let compactLine: String?
    public let isInvited: Bool
    public var response: CalendarResponse?
    public var conflict: String?
    public var isOutdated: Bool

    public var isUpdate: Bool { kind == .request && invite.sequence > 0 }
    public var offersRSVP: Bool { kind == .request && !isOutdated }
    public var canRespond: Bool { offersRSVP && isInvited }
}

public enum InviteCardBuilder {
    public static let visibleGuests = 8

    public static func card(_ invite: CalendarInvite, message: MessageKey, myAddresses: Set<String>, timeZone: TimeZone,
                            locale: Locale = .current, known: CalendarResponse? = nil, conflicts: [CalendarEvent] = [],
                            newestSequence: Int? = nil) -> InviteCard {
        let mine = Set(myAddresses.map { $0.lowercased() })
        let kind: InviteCard.Kind
        switch invite.method {
        case .cancel: kind = .cancelled
        case .reply: kind = .reply
        case .counter: kind = .counter
        case .request: kind = invite.isCancelled ? .cancelled : .request
        case .publish, .other: kind = invite.isCancelled ? .cancelled : .notice
        }
        let title = invite.title ?? String(localized: "(No title)")
        let me = invite.attendees.first { mine.contains($0.email) && $0.email != invite.organizer?.email }
        var response = me == nil ? nil : (known ?? me?.response)
        if response == .needsAction { response = nil }
        var compact: String?
        if kind == .reply || kind == .counter {
            let who = invite.attendees.first { !mine.contains($0.email) } ?? invite.attendees.first
            let name = who.map { $0.name ?? $0.email } ?? String(localized: "Someone")
            compact = kind == .counter ? String(localized: "\(name) proposed a new time")
                : Self.answerLine(name: name, response: who?.response)
        }
        return InviteCard(message: message, invite: invite, kind: kind, title: title,
                          when: when(invite, in: timeZone, locale: locale),
                          whenNote: organizerTime(invite, userZone: timeZone, locale: locale),
                          repeats: repeats(invite.repeatFrequency), location: invite.location,
                          locationLink: invite.location.flatMap(locationLink), guests: guests(invite, me: mine),
                          notes: invite.notes.flatMap(cleanNotes), join: join(invite), compactLine: compact,
                          isInvited: me != nil, response: response,
                          conflict: conflictLine(conflicts, excluding: invite, title: title),
                          isOutdated: newestSequence.map { $0 > invite.sequence } ?? false)
    }

    static func answerLine(name: String, response: CalendarResponse?) -> String {
        switch response {
        case .accepted?: String(localized: "\(name) accepted")
        case .declined?: String(localized: "\(name) declined")
        case .tentative?: String(localized: "\(name) said maybe")
        default: String(localized: "\(name) replied")
        }
    }


    public static func when(_ invite: CalendarInvite, in zone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = Date.FormatStyle(date: .complete, time: .omitted, locale: locale, calendar: calendar, timeZone: zone)
        let shortDay = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: zone)
        let clock = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: zone)
        if invite.isAllDay {
            let last = calendar.date(byAdding: .day, value: -1, to: invite.end).map { max($0, invite.start) } ?? invite.start
            if calendar.isDate(last, inSameDayAs: invite.start) {
                return String(localized: "\(invite.start.formatted(day)) (all day)")
            }
            return String(localized: "\(invite.start.formatted(shortDay)) – \(last.formatted(shortDay)) (all day)")
        }
        let abbreviation = zone.abbreviation(for: invite.start).map { " " + $0 } ?? ""
        if invite.end <= invite.start {
            return "\(invite.start.formatted(day)) · \(invite.start.formatted(clock))\(abbreviation)"
        }
        if calendar.isDate(invite.start, inSameDayAs: invite.end.addingTimeInterval(-1)) {
            return "\(invite.start.formatted(day)) · \(invite.start.formatted(clock)) – \(invite.end.formatted(clock))\(abbreviation)"
        }
        return "\(invite.start.formatted(shortDay)), \(invite.start.formatted(clock)) – "
            + "\(invite.end.formatted(shortDay)), \(invite.end.formatted(clock))\(abbreviation)"
    }

    static func organizerTime(_ invite: CalendarInvite, userZone: TimeZone, locale: Locale) -> String? {
        guard !invite.isAllDay, let id = invite.timeZoneID, let zone = TimeZone(identifier: id),
              zone.secondsFromGMT(for: invite.start) != userZone.secondsFromGMT(for: invite.start) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let clock = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: zone)
        let name = zone.abbreviation(for: invite.start) ?? zone.identifier
        let range = invite.end > invite.start
            ? "\(invite.start.formatted(clock)) – \(invite.end.formatted(clock))" : invite.start.formatted(clock)
        return String(localized: "\(range) \(name) in the organizer's time zone")
    }

    static func repeats(_ frequency: String?) -> String? {
        switch frequency {
        case nil: nil
        case "DAILY"?: String(localized: "Repeats daily")
        case "WEEKLY"?: String(localized: "Repeats weekly")
        case "MONTHLY"?: String(localized: "Repeats monthly")
        case "YEARLY"?: String(localized: "Repeats yearly")
        default: String(localized: "Repeats")
        }
    }


    static func locationLink(_ place: String) -> URL? {
        let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = ICSParser.safeURL(trimmed) { return url }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url
    }

    static func guests(_ invite: CalendarInvite, me: Set<String>) -> [InviteCard.Guest] {
        var seen = Set<String>()
        var out: [InviteCard.Guest] = []
        func add(_ person: CalendarInvite.Person, organizer: Bool) {
            guard !person.isResource, seen.insert(person.email).inserted else { return }
            let isMe = !organizer && person.email != invite.organizer?.email && me.contains(person.email)
            let response = organizer ? invite.attendees.first { $0.email == person.email }?.response ?? person.response
                                     : person.response
            out.append(InviteCard.Guest(title: isMe ? String(localized: "Me") : person.name ?? person.email,
                                        email: person.email, isOrganizer: organizer, isMe: isMe,
                                        response: response == .needsAction ? nil : response,
                                        isOptional: person.isOptional))
        }
        if let organizer = invite.organizer { add(organizer, organizer: true) }
        for attendee in invite.attendees { add(attendee, organizer: false) }
        return out
    }

    public static func cleanNotes(_ notes: String) -> String? {
        var kept: [Substring] = []
        for line in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 10, trimmed.allSatisfy({ "-:~".contains($0) }) { break }
            kept.append(line)
        }
        var text = kept.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 4_000 { text = String(text.prefix(4_000)) + "…" }
        return text.isEmpty ? nil : text
    }

    static func join(_ invite: CalendarInvite) -> InviteCard.Join? {
        guard let url = invite.conferenceURL, let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        let title: String
        if invite.conferenceIsGoogle || on("meet.google.com") {
            title = String(localized: "Join with Google Meet")
        } else if on("zoom.us") {
            title = String(localized: "Join Zoom meeting")
        } else if on("teams.microsoft.com") || on("teams.live.com") {
            title = String(localized: "Join Teams meeting")
        } else {
            title = String(localized: "Join meeting")
        }
        return InviteCard.Join(title: title, url: url)
    }


    static func conflictLine(_ events: [CalendarEvent], excluding invite: CalendarInvite, title: String) -> String? {
        guard !invite.isAllDay, invite.end > invite.start else { return nil }
        let others = events.filter { event in
            !event.isAllDay && event.myResponse != .declined && event.overlaps(from: invite.start, to: invite.end)
                && !(event.start == invite.start && event.end == invite.end && event.title == title)
        }
        guard let first = others.first else { return nil }
        return others.count == 1 ? String(localized: "Conflicts with \(first.title)")
            : String(localized: "Conflicts with \(first.title) and \(others.count - 1) more")
    }
}
