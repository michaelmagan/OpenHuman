import Foundation
import Testing
@testable import OpenHumanGmail

@Suite struct CalendarOwnershipDecodingTests {
    private func decode(_ identity: String, calendarID: String? = nil,
                        selfAddress: String? = nil) throws -> GoogleCalendarEvent {
        let data = Data("""
        {"id":"planning","status":"confirmed","summary":"Planning",
         "start":{"dateTime":"2026-10-30T17:00:00Z"},"end":{"dateTime":"2026-10-30T18:00:00Z"},
         \(identity)}
        """.utf8)
        let wire = try JSONDecoder().decode(WireEvent.self, from: data)
        return try #require(wire.event(defaultZone: .gmt, calendarID: calendarID, selfAddress: selfAddress))
    }

    @Test func anOmittedSelfFlagUsesTheCalendarIdentityRatherThanCreatorIdentity() throws {
        let identity = #"""
            "organizer":{"email":"sam@example.com"},"creator":{"email":"robin@example.com","self":true}
            """#
        #expect(try decode(identity, calendarID: "robin@example.com").organizerIsSelf == false)
        #expect(try decode(identity, calendarID: "SAM@EXAMPLE.COM").organizerIsSelf == true)
        #expect(try decode(identity, calendarID: "team@example.com").organizerIsSelf == false)
        #expect(try decode(identity, calendarID: "primary").organizerIsSelf == nil)
        #expect(try decode(identity).organizerIsSelf == nil)
    }

    @Test func aSelfAttendeeIdentifiesTheCopyWhenTheCalendarIDIsOpaque() throws {
        let invited = #"""
            "organizer":{"email":"sam@example.com"},
            "attendees":[{"email":"robin@example.com","self":true,"responseStatus":"needsAction"}]
            """#
        let guest = try decode(invited, calendarID: "primary", selfAddress: "alias@example.com")
        #expect(guest.organizerIsSelf == false && guest.selfResponse == "needsAction")
        let organized = #"""
            "organizer":{"email":"robin@example.com"},
            "attendees":[{"email":"Robin@Example.com","self":true,"organizer":true,"responseStatus":"accepted"}]
            """#
        #expect(try decode(organized, calendarID: "primary").organizerIsSelf == true)
    }

    @Test func aSendAsAliasDoesNotChangeWhichCalendarOwnsTheCopy() throws {
        let identity = #"""
            "organizer":{"email":"alias@example.com"},
            "attendees":[{"email":"alias@example.com","organizer":true,"responseStatus":"accepted"}]
            """#
        #expect(try decode(identity, calendarID: "robin@example.com", selfAddress: "alias@example.com")
            .organizerIsSelf == false)
    }

    @Test func missingOrganizerIdentityStaysUnknownEvenWhenTheCreatorIsSelf() throws {
        for organizer in ["", #""organizer":{},"#] {
            let identity = """
                \(organizer)"creator":{"email":"robin@example.com","self":true},
                "attendees":[{"email":"robin@example.com","self":true,"responseStatus":"accepted"}]
                """
            #expect(try decode(identity, calendarID: "robin@example.com").organizerIsSelf == nil)
        }
    }

    @Test func anExplicitOrganizerSelfFlagKeepsDelegatedEventsOrganizerOwned() throws {
        let identity = #"""
            "organizer":{"email":"team@example.com","self":true},"creator":{"email":"robin@example.com"},
            "attendees":[{"email":"sam@example.com","responseStatus":"needsAction"}]
            """#
        #expect(try decode(identity, calendarID: "team@example.com").organizerIsSelf == true)
        #expect(try decode(identity).organizerIsSelf == true)
    }
}
