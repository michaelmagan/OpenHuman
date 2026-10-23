import Foundation
import OpenHumanCore

public struct CalendarEvent: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let timeZone: String?
    public let attendees: [EmailAddress]
    public let calendarName: String?
    public let meetLink: URL?
    public let organizerIsMe: Bool?
    public var account: String?
    public var location: String?
    public var notes: String?
    public var myResponse: CalendarResponse?
    public var recurringEventID: String?
    public var extras: CalendarEventExtras
    // The guest address Mail answers as when the calendar marks no entry as its own (an invitation sent to an alias)
    public var respondsAs: String?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, timeZone: String? = nil,
                attendees: [EmailAddress] = [], calendarName: String? = nil, meetLink: URL? = nil,
                organizerIsMe: Bool? = nil, account: String? = nil, location: String? = nil, notes: String? = nil,
                myResponse: CalendarResponse? = nil, recurringEventID: String? = nil,
                extras: CalendarEventExtras = CalendarEventExtras()) {
        self.extras = extras
        self.location = location
        self.notes = notes
        self.myResponse = myResponse
        self.recurringEventID = recurringEventID
        self.organizerIsMe = organizerIsMe
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZone = timeZone
        self.attendees = attendees
        self.calendarName = calendarName
        self.meetLink = meetLink
        self.account = account
    }

    public func overlaps(from: Date, to: Date) -> Bool { end > from && start < to }

    public var isMovableByMe: Bool {
        guard !id.isEmpty, !isAllDay else { return false }
        return organizerIsMe == true || (organizerIsMe == nil && attendees.isEmpty)
    }
}

public struct CalendarBusyInterval: Sendable, Hashable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct CalendarFreeBusy: Sendable, Hashable {
    public let busy: [CalendarBusyInterval]
    // Provider error reasons are shown generically, never parsed: clients must tolerate unknown reasons
    public let errors: [String]

    public init(busy: [CalendarBusyInterval], errors: [String] = []) {
        self.busy = busy
        self.errors = errors
    }
}

public enum CalendarSendUpdates: String, Sendable, Hashable, Codable, CaseIterable {
    case all, externalOnly, none
}

public struct CalendarEventDraft: Sendable, Hashable {
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZone: String
    public var attendees: [EmailAddress]
    public var sendUpdates: CalendarSendUpdates
    public var addMeetLink: Bool
    public var location: String
    public var notes: String
    public var provenance: String
    public var isAllDay: Bool = false
    public var extras: CalendarEventExtras = CalendarEventExtras()

    public init(title: String, start: Date, end: Date, timeZone: String, attendees: [EmailAddress] = [],
                sendUpdates: CalendarSendUpdates = .none, addMeetLink: Bool = false, location: String = "",
                notes: String = "", provenance: String = "") {
        self.provenance = provenance
        self.title = title
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.attendees = attendees
        self.sendUpdates = sendUpdates
        self.addMeetLink = addMeetLink
        self.location = location
        self.notes = notes
    }

    // A new event with guests emails them its invitation unless the user turns that off
    public static func defaultSendUpdates(attendees: [EmailAddress]) -> CalendarSendUpdates {
        attendees.isEmpty ? .none : .all
    }

    // The first guest turns invitations on; later changes keep what the user chose
    public mutating func setAttendees(_ people: [EmailAddress]) {
        if attendees.isEmpty, !people.isEmpty { sendUpdates = Self.defaultSendUpdates(attendees: people) }
        attendees = people
    }

    public var emailsAttendees: Bool { sendUpdates != .none && !attendees.isEmpty }

    public var mayEmailAttendees: Bool { !attendees.isEmpty }

    public var problem: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Add a title." }
        if end <= start { return "The event must end after it starts." }
        if TimeZone(identifier: timeZone) == nil { return "Unknown time zone." }
        return nil
    }
}

public struct CalendarProviderInfo: Sendable, Hashable {
    public let name: String
    public let account: String?
    public let isSample: Bool
    public let createRefusal: String?

    public init(name: String, account: String? = nil, isSample: Bool = false, createRefusal: String? = nil) {
        self.name = name
        self.account = account
        self.isSample = isSample
        self.createRefusal = createRefusal
    }
}

public protocol CalendarProviding: Sendable {
    var info: CalendarProviderInfo { get }
    func events(from: Date, to: Date) async throws -> [CalendarEvent]
    func freeBusy(from: Date, to: Date) async throws -> CalendarFreeBusy
    func eventWindow(from: Date, to: Date) async throws -> CalendarEventWindow
    func eventDelta(since token: String) async throws -> CalendarEventDelta
    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEvent
    func deleteEvent(_ event: CalendarEvent) async throws
    func moveEvent(_ event: CalendarEvent, to start: Date, end: Date, sendUpdates: CalendarSendUpdates) async throws
        -> CalendarEvent
    var abilities: CalendarAbilities { get }
    func respond(to event: CalendarEvent, with response: CalendarResponse, sendUpdates: CalendarSendUpdates) async throws
        -> CalendarEvent
    func invitedEvent(_ query: CalendarInviteQuery, wholeSeries: Bool) async throws -> CalendarEvent?
    func updateEvent(_ event: CalendarEvent, with changes: CalendarEventChanges, sendUpdates: CalendarSendUpdates)
        async throws -> CalendarEvent
    func removeEvent(_ event: CalendarEvent, sendUpdates: CalendarSendUpdates) async throws
    func patchEvent(_ event: CalendarEvent, with patch: CalendarEventPatch, scope: CalendarRecurrenceScope,
                    sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent
}

extension CalendarProviding {
    public func moveEvent(_ event: CalendarEvent, to start: Date, end: Date,
                          sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        throw CalendarError.refused("This calendar can't move events from Mail. Move it in your calendar.")
    }

    public func deleteEvent(_ event: CalendarEvent) async throws {
        throw CalendarError.refused("This calendar can't remove events from Mail. Remove it in your calendar.")
    }
}

public protocol CalendarConnecting: Sendable {
    func connectionStates() -> AsyncStream<CalendarConnectionState>
    func connect() async throws
    func connect(client: OAuthClientSummary.ID?) async throws
    func disconnect() async throws
}

extension CalendarConnecting {
    public func connect(client: OAuthClientSummary.ID?) async throws {
        guard client == nil else {
            throw CalendarError.refused("This calendar connects with its inbox's own Google client only.")
        }
        try await connect()
    }
}

public protocol CalendarConnectionsProviding: Sendable {
    func calendarConnection(for account: Account) -> (any CalendarConnecting)?
    func calendarProvider(for account: Account) -> (any CalendarProviding)?
    var routesByAccount: Bool { get }
    func windowCalendarProvider() -> (any CalendarProviding)?
}

extension CalendarConnectionsProviding {
    public func calendarProvider(for account: Account) -> (any CalendarProviding)? { nil }
    public var routesByAccount: Bool { false }
    public func windowCalendarProvider() -> (any CalendarProviding)? { nil }
}

public struct CalendarConnectionState: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case disconnected
        case connected
        case needsReconnect
    }

    public var status: Status
    public var account: String
    public var canCreateEvents: Bool
    public var needsRestart: Bool
    public var clientShortID: String?
    public var lastRefreshed: Date?
    public var problem: String?
    public var scopes: [String]
    public var lastFetch: Date?
    public var lastFetchError: String?

    public init(status: Status, account: String, canCreateEvents: Bool = false, needsRestart: Bool = false,
                clientShortID: String? = nil, lastRefreshed: Date? = nil, problem: String? = nil,
                scopes: [String] = [], lastFetch: Date? = nil, lastFetchError: String? = nil) {
        self.status = status
        self.account = account
        self.canCreateEvents = canCreateEvents
        self.needsRestart = needsRestart
        self.clientShortID = clientShortID
        self.lastRefreshed = lastRefreshed
        self.problem = problem
        self.scopes = scopes
        self.lastFetch = lastFetch
        self.lastFetchError = lastFetchError
    }

    public static func scopeName(_ scope: String) -> String {
        scope.split(separator: "/").last.map(String.init) ?? scope
    }
}

public enum CalendarError: Error, Sendable, Hashable, CustomStringConvertible {
    case notConfigured
    case refused(String)
    case failed(String)
    case unclear(String)

    public var description: String {
        switch self {
        case .notConfigured: "No calendar is connected."
        case .refused(let why): why
        case .failed(let why): why
        case .unclear(let why): why
        }
    }
}
