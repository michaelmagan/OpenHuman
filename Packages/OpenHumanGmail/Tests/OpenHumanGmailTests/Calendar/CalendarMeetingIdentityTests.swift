import Foundation
import Testing
@testable import OpenHumanGmail

@Suite struct CalendarMeetingIdentityTests {
    private static let utc = TimeZone(identifier: "UTC")!

    private func read(_ json: String) throws -> GoogleCalendarEvent {
        let wire = try JSONDecoder().decode(WireEvent.self, from: Data(json.utf8))
        return try #require(wire.event(defaultZone: Self.utc, calendarID: "robin@example.com",
                                       selfAddress: "robin@example.com"))
    }

    @Test func theUIDOrganizerShortenedGuestListAndOccurrenceAreRead() throws {
        let event = try read("""
            {"id": "weekly_20261021T170000Z", "iCalUID": "weekly-9@example.com", "status": "confirmed",
             "summary": "Weekly sync", "recurringEventId": "weekly",
             "organizer": {"email": "dana@example.com", "displayName": "Dana Ruiz"},
             "attendeesOmitted": true,
             "originalStartTime": {"dateTime": "2026-10-21T17:00:00Z"},
             "start": {"dateTime": "2026-10-21T18:00:00Z"}, "end": {"dateTime": "2026-10-21T19:00:00Z"},
             "attendees": [{"email": "dana@example.com", "organizer": true, "responseStatus": "accepted"},
                           {"email": "robin@example.com", "self": true, "responseStatus": "needsAction"}]}
            """)
        #expect(event.iCalUID == "weekly-9@example.com")
        #expect(event.organizerEmail == "dana@example.com" && event.organizerName == "Dana Ruiz")
        #expect(event.attendeesOmitted)
        #expect(event.originalStartTime == .timed(try #require(ISO8601DateFormatter().date(from: "2026-10-21T17:00:00Z")),
                                                   timeZone: nil))
        #expect(event.start == ISO8601DateFormatter().date(from: "2026-10-21T18:00:00Z"), "this occurrence was moved")
        #expect(event.attendees.map(\.isOrganizer) == [true, false])
        #expect(event.organizerIsSelf == false, "the organizer's address is not this calendar's")
    }

    @Test func anAllDayOccurrenceKeepsItsDayAndMissingFieldsStayEmpty() throws {
        let allDay = try read("""
            {"id": "offsite_20261021", "iCalUID": "offsite@example.com", "recurringEventId": "offsite",
             "originalStartTime": {"date": "2026-10-21"},
             "start": {"date": "2026-10-22"}, "end": {"date": "2026-10-23"}}
            """)
        #expect(allDay.isAllDay && allDay.originalStartTime == .date("2026-10-21"))
        let plain = try read("""
            {"id": "focus", "iCalUID": "  ", "organizer": {"self": true},
             "start": {"dateTime": "2026-10-21T18:00:00Z"}, "end": {"dateTime": "2026-10-21T19:00:00Z"}}
            """)
        #expect(plain.iCalUID == nil && plain.organizerEmail == nil && plain.organizerName == nil)
        #expect(!plain.attendeesOmitted && plain.originalStartTime == nil && plain.organizerIsSelf == true)
    }
}
