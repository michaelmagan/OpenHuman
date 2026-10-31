import Foundation

public struct GoogleCalendarEvent: Sendable, Hashable {
    public let id: String
    public let title: String?
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let timeZone: String?
    public let attendees: [GoogleCalendarAttendee]
    public let meetLink: URL?
    public let conferenceStatus: String?
    public let organizerIsSelf: Bool?
    public let location: String?
    public let notes: String?
    public let recurringEventID: String?
    public let originalStartTime: GoogleOriginalStart?
    public let selfResponse: String?
    public var extras = GoogleEventExtras()

    public init(id: String, title: String?, start: Date, end: Date, isAllDay: Bool = false, timeZone: String? = nil,
                attendees: [GoogleCalendarAttendee] = [], meetLink: URL? = nil, conferenceStatus: String? = nil,
                organizerIsSelf: Bool? = nil, location: String? = nil, notes: String? = nil,
                recurringEventID: String? = nil, selfResponse: String? = nil,
                originalStartTime: GoogleOriginalStart? = nil) {
        self.originalStartTime = originalStartTime
        self.organizerIsSelf = organizerIsSelf
        self.location = location
        self.notes = notes
        self.recurringEventID = recurringEventID
        self.selfResponse = selfResponse
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZone = timeZone
        self.attendees = attendees
        self.meetLink = meetLink
        self.conferenceStatus = conferenceStatus
    }
}

public struct GoogleCalendarAttendee: Sendable, Hashable {
    public let email: String
    public let name: String?
    public var isOptional = false
    public var responseStatus: String?
    public var isOrganizer: Bool?

    public init(email: String, name: String? = nil, isOptional: Bool = false, responseStatus: String? = nil,
                isOrganizer: Bool? = nil) {
        self.email = email
        self.name = name
        self.isOptional = isOptional
        self.responseStatus = responseStatus
        self.isOrganizer = isOrganizer
    }
}

public struct GoogleEventExtras: Sendable, Hashable {
    public var guestsCanModify: Bool?
    public var guestsCanInviteOthers: Bool?
    public var guestsCanSeeOtherGuests: Bool?
    public var recurrence: [String] = []
    public var remindersUseDefault: Bool?
    public var reminderOverrides: [GoogleReminder] = []
    public var transparency: String?
    public var visibility: String?
    public var colorID: String?

    public init() {}
}

public struct GoogleReminder: Sendable, Hashable {
    public var method: String
    public var minutes: Int

    public init(method: String, minutes: Int) {
        self.method = method
        self.minutes = minutes
    }
}

public struct GoogleEventDetails: Sendable, Hashable {
    public var guestsCanModify: Bool?
    public var guestsCanInviteOthers: Bool?
    public var guestsCanSeeOtherGuests: Bool?
    public var recurrence: [String]?
    public var useDefaultReminders: Bool?
    public var reminderOverrides: [GoogleReminder] = []
    public var transparency: String?
    public var visibility: String?
    public var colorID: String?

    public init() {}

    func fields() -> [String: Any] {
        var body: [String: Any] = [:]
        if let value = guestsCanModify { body["guestsCanModify"] = value }
        if let value = guestsCanInviteOthers { body["guestsCanInviteOthers"] = value }
        if let value = guestsCanSeeOtherGuests { body["guestsCanSeeOtherGuests"] = value }
        if let recurrence { body["recurrence"] = recurrence }
        if let useDefault = useDefaultReminders {
            var reminders: [String: Any] = ["useDefault": useDefault]
            if !useDefault { reminders["overrides"] = reminderOverrides.map { ["method": $0.method, "minutes": $0.minutes] } }
            body["reminders"] = reminders
        }
        if let value = transparency { body["transparency"] = value }
        if let value = visibility { body["visibility"] = value }
        if let value = colorID { body["colorId"] = value.isEmpty ? NSNull() : value }
        return body
    }
}

public struct GoogleGuestEdit: Sendable, Hashable {
    public var email: String
    public var name: String?
    public var isOptional: Bool

    public init(email: String, name: String? = nil, isOptional: Bool = false) {
        self.email = email
        self.name = name
        self.isOptional = isOptional
    }
}

public struct GoogleEventPatch: Sendable, Hashable {
    public struct Time: Sendable, Hashable {
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        public var timeZone: String

        public init(start: Date, end: Date, isAllDay: Bool, timeZone: String) {
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
            self.timeZone = timeZone
        }
    }
    public enum Meet: Sendable, Hashable { case add, remove }

    public var title: String?
    public var location: String?
    public var description: String?
    public var time: Time?
    public var guests: [GoogleGuestEdit]?
    public var meet: Meet?
    public var details = GoogleEventDetails()

    public init() {}
}

public struct GoogleBusyInterval: Sendable, Hashable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public struct GoogleFreeBusy: Sendable, Hashable {
    public let busy: [GoogleBusyInterval]
    public let errors: [String]

    public init(busy: [GoogleBusyInterval], errors: [String] = []) {
        self.busy = busy
        self.errors = errors
    }
}

public struct GoogleEventInsert: Sendable, Hashable {
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZone: String
    public var attendees: [String]
    public var location: String?
    public var description: String?
    public var isAllDay = false
    public var optionalAttendees: Set<String> = []
    public var details = GoogleEventDetails()

    public init(title: String, start: Date, end: Date, timeZone: String, attendees: [String] = [],
                location: String? = nil, description: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.attendees = attendees
        self.location = location
        self.description = description
    }
}

public enum GoogleSendUpdates: String, Sendable, Hashable, CaseIterable {
    case all, externalOnly, none
}

struct WireEventList: Decodable {
    var items: [WireEvent]?
    var nextPageToken: String?
}

struct WireEvent: Decodable {
    struct Time: Decodable {
        var dateTime: String?
        var date: String?
        var timeZone: String?

        var original: GoogleOriginalStart? {
            if let timeZone, TimeZone(identifier: timeZone) == nil { return nil }
            if let date, dateTime == nil,
               GoogleRemovalPrefix.parse(date, pattern: "yyyy-MM-dd", zone: .gmt) != nil { return .date(date) }
            if let dateTime, date == nil, let value = RFC3339.date(dateTime) {
                return .timed(value, timeZone: timeZone)
            }
            return nil
        }
    }
    struct Attendee: Decodable {
        var email: String?
        var displayName: String?
        var responseStatus: String?
        var `self`: Bool?
        var optional: Bool?
        var organizer: Bool?
        var resource: Bool?
    }
    struct Reminders: Decodable {
        struct Override: Decodable {
            var method: String?
            var minutes: Int?
        }
        var useDefault: Bool?
        var overrides: [Override]?
    }
    struct Conference: Decodable {
        struct EntryPoint: Decodable {
            var entryPointType: String?
            var uri: String?
        }
        struct Solution: Decodable {
            struct Key: Decodable { var type: String? }
            var key: Key?
        }
        struct CreateRequest: Decodable {
            struct Status: Decodable { var statusCode: String? }
            var status: Status?
        }
        var entryPoints: [EntryPoint]?
        var conferenceSolution: Solution?
        var createRequest: CreateRequest?
    }
    struct Organizer: Decodable {
        var `self`: Bool?
        var email: String?
    }
    var id: String?
    var status: String?
    var summary: String?
    var organizer: Organizer?
    var creator: Organizer?
    var start: Time?
    var end: Time?
    var attendees: [Attendee]?
    var conferenceData: Conference?
    var location: String?
    var description: String?
    var recurringEventId: String?
    var originalStartTime: Time?
    var etag: String?
    var eventType: String?
    var guestsCanModify: Bool?
    var guestsCanInviteOthers: Bool?
    var guestsCanSeeOtherGuests: Bool?
    var recurrence: [String]?
    var reminders: Reminders?
    var transparency: String?
    var visibility: String?
    var colorId: String?

    func removalOwned(by calendarID: String, allowCreator: Bool) -> Bool {
        let owner = organizer ?? (allowCreator ? creator : nil)
        return owner?.`self` == true || owner?.email?.lowercased() == calendarID.lowercased()
    }

    /// Another calendar organizes this event, so deleting it here removes only this calendar's copy.
    func isGuestCopy(on calendarID: String) -> Bool {
        guard let organizer, organizer.`self` != true,
              let email = organizer.email?.trimmingCharacters(in: .whitespaces).lowercased(), !email.isEmpty else {
            return false
        }
        return email != calendarID.lowercased()
    }

    // Google's `self` flags describe the calendar holding this copy, not the signed-in user or a send-as alias.
    // An omitted organizer.self defaults to false, but absent organizer identity must remain unknown.
    private func organizerIsSelf(on calendarID: String?) -> Bool? {
        let own = (attendees ?? []).filter { $0.`self` == true }
        if organizer?.`self` == true || own.contains(where: { $0.organizer == true }) { return true }
        guard let email = Self.text(organizer?.email) else { return organizer?.`self` }
        if let calendarID = Self.text(calendarID), calendarID.contains("@") {
            return email.caseInsensitiveCompare(calendarID) == .orderedSame
        }
        if own.count == 1, let address = Self.text(own.first?.email) {
            return email.caseInsensitiveCompare(address) == .orderedSame
        }
        return organizer?.`self`
    }

    func event(defaultZone: TimeZone, calendarID: String? = nil, selfAddress: String? = nil) -> GoogleCalendarEvent? {
        guard let id, !id.isEmpty, status != "cancelled", let start, let end else { return nil }
        let zone = (start.timeZone ?? end.timeZone).flatMap(TimeZone.init(identifier:)) ?? defaultZone
        let begins: Date
        let ends: Date
        let allDay: Bool
        if let from = start.dateTime.flatMap(RFC3339.date), let to = end.dateTime.flatMap(RFC3339.date) {
            begins = from
            ends = to
            allDay = false
        } else if let from = start.date.flatMap({ RFC3339.day($0, in: zone) }),
                  let to = end.date.flatMap({ RFC3339.day($0, in: zone) }) {
            begins = from
            ends = to
            allDay = true
        } else {
            return nil
        }
        guard ends >= begins else { return nil }
        let hasMarkedOrganizer = (attendees ?? []).contains { $0.organizer == true }
        let people = (attendees ?? []).compactMap { person -> GoogleCalendarAttendee? in
            guard let email = person.email?.trimmingCharacters(in: .whitespaces), email.contains("@") else { return nil }
            let isOrganizer: Bool? = if let address = organizer?.email {
                person.organizer == true || email.caseInsensitiveCompare(address) == .orderedSame
            } else if let marked = person.organizer {
                marked
            } else if hasMarkedOrganizer || (person.`self` == true && organizer?.`self` != true) {
                false
            } else {
                nil
            }
            return GoogleCalendarAttendee(email: email, name: person.displayName, isOptional: person.optional == true,
                                          responseStatus: person.responseStatus, isOrganizer: isOrganizer)
        }
        let title = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = (attendees ?? []).first { $0.`self` == true }
            ?? (attendees ?? []).first { person in
                let differentFromOrganizer = organizer?.email.map {
                    person.email?.caseInsensitiveCompare($0) != .orderedSame
                } ?? false
                let isKnownGuest = person.organizer == false
                    || (hasMarkedOrganizer && person.organizer != true) || differentFromOrganizer
                return isKnownGuest && (selfAddress.map { person.email?.lowercased() == $0.lowercased() } ?? false)
            }
        var extras = GoogleEventExtras()
        extras.guestsCanModify = guestsCanModify
        extras.guestsCanInviteOthers = guestsCanInviteOthers
        extras.guestsCanSeeOtherGuests = guestsCanSeeOtherGuests
        extras.recurrence = recurrence ?? []
        extras.remindersUseDefault = reminders?.useDefault
        extras.reminderOverrides = (reminders?.overrides ?? []).compactMap { entry in
            guard let method = entry.method, let minutes = entry.minutes else { return nil }
            return GoogleReminder(method: method, minutes: minutes)
        }
        extras.transparency = transparency
        extras.visibility = visibility
        extras.colorID = colorId
        var made = GoogleCalendarEvent(id: id, title: title?.isEmpty == false ? title : nil, start: begins, end: ends,
                                   isAllDay: allDay, timeZone: start.timeZone ?? end.timeZone, attendees: people,
                                   meetLink: meetLink, conferenceStatus: conferenceData?.createRequest?.status?.statusCode,
                                   organizerIsSelf: organizerIsSelf(on: calendarID), location: Self.text(location),
                                   notes: Self.text(description), recurringEventID: Self.text(recurringEventId),
                                   selfResponse: own.map { $0.responseStatus ?? "needsAction" },
                                   originalStartTime: originalStartTime?.original)
        made.extras = extras
        return made
    }

    static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var meetLink: URL? {
        guard let conference = conferenceData,
              conference.conferenceSolution?.key?.type == GoogleCalendarClient.meetSolutionType,
              let uri = conference.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri,
              let url = URL(string: uri), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host(percentEncoded: true)?.lowercased(), GoogleCalendarClient.meetHosts.contains(host)
        else { return nil }
        return url
    }
}

struct WireFreeBusy: Decodable {
    struct Entry: Decodable {
        struct Busy: Decodable {
            var start: String?
            var end: String?
        }
        struct Failure: Decodable { var reason: String? }
        var busy: [Busy]?
        var errors: [Failure]?
    }
    var calendars: [String: Entry]?
}

enum RFC3339 {
    static func string(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return formatter.string(from: date)
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    static func day(_ text: String, in zone: TimeZone) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
