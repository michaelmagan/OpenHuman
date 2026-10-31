import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail
import Testing
@testable import OpenHumanMailLive

@Suite struct GoogleCalendarMeetingIdentityTests {
    private static let start = ISO8601DateFormatter().date(from: "2026-10-21T18:00:00Z")!

    @Test func aSyncedEventKeepsTheMeetingsUIDOrganizerAndOccurrence() {
        var read = GoogleCalendarEvent(id: "weekly_20261021T170000Z", title: "Weekly sync", start: Self.start,
                                       end: Self.start.addingTimeInterval(3_600),
                                       attendees: [GoogleCalendarAttendee(email: "dana@example.com", isOrganizer: true)],
                                       recurringEventID: "weekly", selfResponse: "needsAction",
                                       originalStartTime: .timed(Self.start.addingTimeInterval(-3_600), timeZone: nil))
        read.iCalUID = "weekly-9@example.com"
        read.organizerEmail = "dana@example.com"
        read.organizerName = "Dana Ruiz"
        read.attendeesOmitted = true
        let record = GoogleCalendarProvider.record(GoogleSyncedEvent(event: read, etag: "\"e1\"", recurringEventID: "weekly"))
        #expect(record.event.uid == "weekly-9@example.com")
        #expect(record.event.organizer == EmailAddress(name: "Dana Ruiz", email: "dana@example.com"))
        #expect(record.event.guestsOmitted
                && record.event.originalStartTime == .timed(Self.start.addingTimeInterval(-3_600), timeZone: nil))
        #expect(record.event.copies.isEmpty)

        let applied = GoogleCalendarProvider.applying(CalendarEventPatch(), to: record.event)
        #expect(applied.uid == record.event.uid && applied.organizer == record.event.organizer
                && applied.guestsOmitted && applied.originalStartTime == record.event.originalStartTime,
                "a saved change keeps what identifies the meeting")
    }
}
