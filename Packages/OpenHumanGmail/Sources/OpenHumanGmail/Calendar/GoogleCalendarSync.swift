import Foundation

public struct GoogleCalendarCancellation: Sendable, Hashable {
    public let id: String
    public let parentID: String?
    public let originalStartTime: GoogleOriginalStart?

    public init(id: String, parentID: String?, originalStartTime: GoogleOriginalStart?) {
        self.id = id
        self.parentID = parentID
        self.originalStartTime = originalStartTime
    }
}

public struct GoogleSyncedEvent: Sendable, Hashable {
    public let event: GoogleCalendarEvent
    public let etag: String?
    public let updated: Date?
    public let recurringEventID: String?
    public let isTransparent: Bool
    public let selfDeclined: Bool

    public init(event: GoogleCalendarEvent, etag: String? = nil, updated: Date? = nil, recurringEventID: String? = nil,
                isTransparent: Bool = false, selfDeclined: Bool = false) {
        self.event = event
        self.etag = etag
        self.updated = updated
        self.recurringEventID = recurringEventID
        self.isTransparent = isTransparent
        self.selfDeclined = selfDeclined
    }
}

public struct GoogleEventSyncPage: Sendable, Hashable {
    public let events: [GoogleSyncedEvent]
    public let removed: [String]
    public let nextSyncToken: String?
    public let isComplete: Bool
    public let cancellations: [GoogleCalendarCancellation]

    public init(events: [GoogleSyncedEvent], removed: [String] = [], nextSyncToken: String? = nil, isComplete: Bool = true,
                cancellations: [GoogleCalendarCancellation] = []) {
        self.cancellations = cancellations
        self.events = events
        self.removed = removed
        self.nextSyncToken = nextSyncToken
        self.isComplete = isComplete
    }
}

struct WireEventMetaList: Decodable {
    var items: [WireEventMeta]?
    var nextPageToken: String?
    var nextSyncToken: String?
}

struct WireEventMeta: Decodable {
    struct Attendee: Decodable {
        var email: String?
        var `self`: Bool?
        var responseStatus: String?
    }
    var id: String?
    var status: String?
    var etag: String?
    var updated: String?
    var recurringEventId: String?
    var transparency: String?
    var attendees: [Attendee]?

    func declined(by calendarID: String) -> Bool {
        let own = attendees?.first { $0.`self` == true }
            ?? attendees?.first { $0.email?.lowercased() == calendarID.lowercased() }
        return own?.responseStatus == "declined"
    }
}
