import Foundation

public struct GoogleInviteCandidate: Sendable, Hashable {
    public let event: GoogleCalendarEvent
    public let iCalUID: String?
    public let organizerEmail: String?
    public let originalStart: Date?
    public let isSeries: Bool

    public init(event: GoogleCalendarEvent, iCalUID: String?, organizerEmail: String?, originalStart: Date? = nil,
                isSeries: Bool = false) {
        self.event = event
        self.iCalUID = iCalUID
        self.organizerEmail = organizerEmail
        self.originalStart = originalStart
        self.isSeries = isSeries
    }
}

struct WireInviteIdentityList: Decodable {
    struct Item: Decodable {
        struct Organizer: Decodable { var email: String? }
        struct Time: Decodable {
            var dateTime: String?
            var date: String?
        }
        var id: String?
        var iCalUID: String?
        var organizer: Organizer?
        var originalStartTime: Time?
        var recurrence: [String]?
    }
    var items: [Item]?
}
