import Foundation
import OpenHumanCore

public enum CalendarResponse: String, Sendable, Hashable, Codable, CaseIterable {
    case accepted, declined, tentative, needsAction

    public var title: String {
        switch self {
        case .accepted: String(localized: "Yes")
        case .declined: String(localized: "No")
        case .tentative: String(localized: "Maybe")
        case .needsAction: String(localized: "Not answered")
        }
    }

    public static let choices: [CalendarResponse] = [.accepted, .declined, .tentative]
}

public struct CalendarEventChanges: Sendable, Hashable {
    public var title: String?
    public var location: String?
    public var notes: String?
    public var attendees: [EmailAddress]?

    public init(title: String? = nil, location: String? = nil, notes: String? = nil, attendees: [EmailAddress]? = nil) {
        self.title = title
        self.location = location
        self.notes = notes
        self.attendees = attendees
    }

    public var isEmpty: Bool { title == nil && location == nil && notes == nil && attendees == nil }
}

public struct CalendarAbilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let respond = CalendarAbilities(rawValue: 1 << 0)
    public static let editDetails = CalendarAbilities(rawValue: 1 << 1)
    public static let remove = CalendarAbilities(rawValue: 1 << 2)
    public static let editFull = CalendarAbilities(rawValue: 1 << 3)
    public static let moveCalendar = CalendarAbilities(rawValue: 1 << 4)
    public static let removeMeet = CalendarAbilities(rawValue: 1 << 5)
}

extension CalendarProviding {
    public var abilities: CalendarAbilities { [] }

    public func respond(to event: CalendarEvent, with response: CalendarResponse,
                        sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        throw CalendarError.refused("This calendar can't answer invitations from Mail. Answer it in your calendar.")
    }

    public func updateEvent(_ event: CalendarEvent, with changes: CalendarEventChanges,
                            sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        throw CalendarError.refused("This calendar can't change events from Mail yet. Change it in your calendar.")
    }

    public func removeEvent(_ event: CalendarEvent, sendUpdates: CalendarSendUpdates) async throws {
        throw CalendarError.refused("This calendar can't remove events from Mail yet. Remove it in your calendar.")
    }

    public func patchEvent(_ event: CalendarEvent, with patch: CalendarEventPatch, scope: CalendarRecurrenceScope,
                           sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        throw CalendarError.refused("This calendar can't change events from Mail yet. Change it in your calendar.")
    }
}

extension CalendarEvent {
    public var canRespond: Bool { !id.isEmpty && organizerIsMe != true && myResponse != nil }

    public var isRecurring: Bool { recurringEventID?.isEmpty == false }

    // Why: the calendar marks only its own address as `self`, so an invitation sent to one of the account's other
    // addresses (a send-as alias) carries the answer on that address's guest entry
    public func resolvingMyResponse(addresses: Set<String>) -> CalendarEvent {
        guard myResponse == nil, organizerIsMe != true, !id.isEmpty, !addresses.isEmpty else { return self }
        let mine = Set(addresses.map { $0.lowercased() })
        let entries = extras.guests.filter { mine.contains($0.email.lowercased()) }
        guard entries.count == 1, let entry = entries.first else { return self }
        var resolved = self
        resolved.myResponse = entry.response ?? .needsAction
        resolved.respondsAs = entry.email
        return resolved
    }

    // Someone else's event with guests where none of the account's addresses is on the guest list Mail can read:
    // an invitation to a group, or a guest list the calendar shortened
    public var hidesMyResponse: Bool { !id.isEmpty && organizerIsMe != true && myResponse == nil && !attendees.isEmpty }

    public static var responseNotShown: String { String(localized: "Your response is not shown for this event.") }
}

public enum CalendarViewKind: String, Sendable, Hashable, Codable, CaseIterable {
    case day, threeDays, week, month

    public var title: String {
        switch self {
        case .day: String(localized: "Day")
        case .threeDays: String(localized: "3 days")
        case .week: String(localized: "Week")
        case .month: String(localized: "Month")
        }
    }

    public var dayCount: Int {
        switch self {
        case .day: 1
        case .threeDays: 3
        case .week: 7
        case .month: 0
        }
    }
}

extension AppSettings {
    public static let calendarWindowView = AppSettingKey(name: "calendar.window_view", defaultValue: CalendarViewKind.week)
    public static let calendarHiddenCalendars = AppSettingKey<[String]>(name: "calendar.hidden_calendars", defaultValue: [])
    public static let calendarConfirmMoves = AppSettingKey<Bool>(name: "calendar.confirm_moves", defaultValue: true)
    public static let calendarTipsShown = AppSettingKey<[String]>(name: "calendar.tips_shown", defaultValue: [])
}
