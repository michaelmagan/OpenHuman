import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

private let zone = TimeZone(identifier: "America/Los_Angeles")!

private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

@Suite struct CalendarFullEditClientTests {
    private static let me = "robin@example.com"
    private static let event = "https://www.googleapis.com/calendar/v3/calendars/robin@example.com/events/ev1"

    private func guardFor(_ scopes: [String] = CalendarScopes.request.write) -> CalendarGuardTransport {
        CalendarGuardTransport(wrapping: ScriptedTransport(), calendarID: Self.me, grantedScopes: scopes)
    }

    private func patch(_ query: String, _ body: [String: Any], marked: Bool = true) -> HTTPRequest {
        HTTPRequest(method: "PATCH", url: URL(string: Self.event + query)!,
                    headers: marked ? [CalendarGuardTransport.editRuleHeader: CalendarGuardTransport.editRuleValue] : [:],
                    body: try! JSONSerialization.data(withJSONObject: body))
    }


    @Test func theEditListPassesOnlyMarkedWithAWriteGrantAndSendUpdates() {
        let body: [String: Any] = ["summary": "Planning", "location": "Room 4", "transparency": "transparent"]
        #expect(guardFor().refusalReason(for: patch("?sendUpdates=none", body)) == nil)
        #expect(guardFor().refusalReason(for: patch("?sendUpdates=none", body, marked: false)) != nil,
                "without the edit header the earlier rule (times or own answer only) still refuses a title")
        #expect(guardFor().refusalReason(for: patch("", body)) != nil, "no sendUpdates")
        #expect(guardFor(CalendarScopes.request.read).refusalReason(for: patch("?sendUpdates=none", body)) != nil)
    }

    @Test func keysOffTheListAndUnsafeShapesAreRefusedEvenWhenMarked() {
        let calendar = guardFor()
        let refused: [[String: Any]] = [
            [:],
            ["organizer": ["email": "x@example.org"]],
            ["status": "cancelled"],
            ["summary": "x", "id": "other"],
            ["attachments": [["fileUrl": "https://example.org/a"]]],
            ["start": ["dateTime": "2026-10-13T15:00:00-07:00"]],
            ["attendees": [["displayName": "No address"]]],
            ["recurrence": ["FREQ=DAILY"]],
            ["conferenceData": ["entryPoints": [["uri": "https://example.org"]]]],
            ["conferenceData": ["createRequest": ["conferenceSolutionKey": ["type": "addOn"]]]],
            ["guestsCanModify": "yes"],
        ]
        for body in refused {
            #expect(calendar.refusalReason(for: patch("?sendUpdates=none", body)) != nil, "\(body)")
        }
        let other = "https://www.googleapis.com/calendar/v3/calendars/other@example.org/events/ev1?sendUpdates=none"
        #expect(calendar.refusalReason(for: HTTPRequest(method: "PATCH", url: URL(string: other)!,
                                                         headers: [CalendarGuardTransport.editRuleHeader: "form"],
                                                         body: try! JSONSerialization.data(withJSONObject: ["summary": "x"]))) != nil,
                "another calendar")
        let move = HTTPRequest(method: "POST", url: URL(string: Self.event + "/move?destination=x&sendUpdates=none")!,
                               headers: [CalendarGuardTransport.editRuleHeader: "form"], body: Data("{}".utf8))
        #expect(calendar.refusalReason(for: move) != nil, "moving between calendars stays refused")
    }

    @Test func aMeetCreateRequestARemovalAndRulesPass() {
        let calendar = guardFor()
        let meet: [String: Any] = ["conferenceData": ["createRequest": ["requestId": "r1",
                                                                         "conferenceSolutionKey": ["type": "hangoutsMeet"]]]]
        #expect(calendar.refusalReason(for: patch("?sendUpdates=none&conferenceDataVersion=1", meet)) == nil)
        #expect(calendar.refusalReason(for: patch("?sendUpdates=none&conferenceDataVersion=1", ["conferenceData": NSNull()])) == nil)
        #expect(calendar.refusalReason(for: patch("?sendUpdates=none", ["recurrence": ["RRULE:FREQ=WEEKLY"]])) == nil)
        #expect(calendar.refusalReason(for: patch("?sendUpdates=all", ["attendees": [["email": "sam@example.org", "optional": true]]])) == nil)
    }


    @Test func aPatchSendsOnlyWhatChangedAndSwitchesBetweenTimedAndAllDay() throws {
        var change = GoogleEventPatch()
        change.title = "Offsite"
        change.time = GoogleEventPatch.Time(start: at(13, 0), end: at(15, 0), isAllDay: true, timeZone: zone.identifier)
        change.details.transparency = "transparent"
        change.details.guestsCanModify = true
        change.details.colorID = ""
        let body = GoogleCalendarClient.patchBody(change, currentAttendees: [], zone: zone, requestID: "r1")
        #expect(Set(body.keys) == ["summary", "start", "end", "transparency", "guestsCanModify", "colorId"])
        let start = try #require(body["start"] as? [String: Any])
        #expect(start["date"] as? String == "2026-10-13" && start["dateTime"] is NSNull)
        #expect((body["end"] as? [String: Any])?["date"] as? String == "2026-10-15", "exclusive end")
        #expect(body["colorId"] is NSNull, "an empty colour goes back to the calendar's")
        var timed = GoogleEventPatch()
        timed.time = GoogleEventPatch.Time(start: at(13, 15), end: at(13, 16), isAllDay: false, timeZone: "Europe/Berlin")
        let wire = GoogleCalendarClient.patchBody(timed, currentAttendees: [], zone: zone, requestID: "r1")
        let first = try #require(wire["start"] as? [String: Any])
        #expect(first["dateTime"] as? String == "2026-10-14T00:00:00+02:00" && first["timeZone"] as? String == "Europe/Berlin")
        #expect(first["date"] is NSNull)
    }

    @Test func remindersMeetAndRulesAreSentInGooglesShape() throws {
        var change = GoogleEventPatch()
        change.details.useDefaultReminders = false
        change.details.reminderOverrides = [GoogleReminder(method: "popup", minutes: 10), GoogleReminder(method: "email", minutes: 1_440)]
        change.details.recurrence = ["RRULE:FREQ=WEEKLY"]
        change.meet = .add
        let body = GoogleCalendarClient.patchBody(change, currentAttendees: [], zone: zone, requestID: "req-7")
        let reminders = try #require(body["reminders"] as? [String: Any])
        #expect(reminders["useDefault"] as? Bool == false && (reminders["overrides"] as? [[String: Any]])?.count == 2)
        #expect(body["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY"])
        let request = try #require((body["conferenceData"] as? [String: Any])?["createRequest"] as? [String: Any])
        #expect(request["requestId"] as? String == "req-7" && (request["conferenceSolutionKey"] as? [String: Any])?["type"] as? String == "hangoutsMeet")
        change.meet = .remove
        #expect(GoogleCalendarClient.patchBody(change, currentAttendees: [], zone: zone, requestID: "x")["conferenceData"] is NSNull)
        var defaults = GoogleEventPatch()
        defaults.details.useDefaultReminders = true
        #expect((GoogleCalendarClient.patchBody(defaults, currentAttendees: [], zone: zone, requestID: "x")["reminders"] as? [String: Any])?["overrides"] == nil)
    }

    @Test func guestsWhoStayKeepTheirAnswersAndOwnEntriesAreNeverDropped() {
        let current: [[String: Any]] = [
            ["email": "robin@example.com", "self": true, "responseStatus": "accepted"],
            ["email": "sam@example.org", "responseStatus": "declined", "optional": true],
            ["email": "alex@example.org", "responseStatus": "accepted"],
        ]
        let wanted = [GoogleGuestEdit(email: "Sam@Example.org", isOptional: false),
                      GoogleGuestEdit(email: "lee@example.org", name: "Lee Park", isOptional: true)]
        let merged = GoogleCalendarClient.mergeAttendees(current: current, wanted: wanted)
        let emails = merged.compactMap { $0["email"] as? String }
        #expect(emails == ["sam@example.org", "lee@example.org", "robin@example.com"], "alex was removed; the owner's own entry stays")
        #expect(merged[0]["responseStatus"] as? String == "declined" && merged[0]["optional"] == nil, "answer kept, optional cleared")
        #expect(merged[1]["optional"] as? Bool == true && merged[1]["displayName"] as? String == "Lee Park")
    }

    @Test func anInsertCanBeAllDayWithOptionalGuestsAndTheSharedDetails() throws {
        var insert = GoogleEventInsert(title: "Offsite", start: at(13, 0), end: at(14, 0), timeZone: zone.identifier,
                                       attendees: ["sam@example.org", "lee@example.org"])
        insert.isAllDay = true
        insert.optionalAttendees = ["lee@example.org"]
        insert.details.recurrence = ["RRULE:FREQ=YEARLY"]
        insert.details.visibility = "private"
        let body = GoogleCalendarClient.insertBody(insert, zone: zone)
        #expect((body["start"] as? [String: Any])?["date"] as? String == "2026-10-13" && (body["start"] as? [String: Any])?["dateTime"] == nil)
        let people = try #require(body["attendees"] as? [[String: Any]])
        #expect(people.first { $0["email"] as? String == "lee@example.org" }?["optional"] as? Bool == true)
        #expect(people.first { $0["email"] as? String == "sam@example.org" }?["optional"] == nil)
        #expect(body["recurrence"] as? [String] == ["RRULE:FREQ=YEARLY"] && body["visibility"] as? String == "private")
        let plain = GoogleCalendarClient.insertBody(GoogleEventInsert(title: "Lunch", start: at(13, 12), end: at(13, 13), timeZone: zone.identifier), zone: zone)
        #expect(Set(plain.keys) == ["summary", "start", "end"])
        #expect((plain["start"] as? [String: Any])?["timeZone"] as? String == zone.identifier)
    }


    @Test func theClientReadsGuestsFlagsRulesRemindersAndColour() throws {
        let json = """
        {"id":"ev1","status":"confirmed","summary":"Planning","organizer":{"self":false},
         "start":{"dateTime":"2026-10-13T15:00:00-07:00"},"end":{"dateTime":"2026-10-13T15:30:00-07:00"},
         "attendees":[{"email":"sam@example.org","optional":true,"responseStatus":"tentative"},
                      {"email":"robin@example.com","self":true,"responseStatus":"needsAction"}],
         "guestsCanModify":true,"guestsCanSeeOtherGuests":false,"recurrence":["RRULE:FREQ=WEEKLY"],
         "reminders":{"useDefault":false,"overrides":[{"method":"popup","minutes":10}]},
         "transparency":"transparent","visibility":"private","colorId":"5"}
        """
        let wire = try JSONDecoder().decode(WireEvent.self, from: Data(json.utf8))
        let read = try #require(wire.event(defaultZone: zone, selfAddress: "robin@example.com"))
        #expect(read.attendees.first?.isOptional == true && read.attendees.first?.responseStatus == "tentative")
        #expect(read.extras.guestsCanModify == true && read.extras.guestsCanSeeOtherGuests == false && read.extras.guestsCanInviteOthers == nil)
        #expect(read.extras.recurrence == ["RRULE:FREQ=WEEKLY"] && read.extras.remindersUseDefault == false)
        #expect(read.extras.reminderOverrides == [GoogleReminder(method: "popup", minutes: 10)])
        #expect(read.extras.transparency == "transparent" && read.extras.visibility == "private" && read.extras.colorID == "5")
    }


    @Test func thePatchReadsTheEventFirstForGuestsAndSendsTheMarkedRequest() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", "/calendar/v3/calendars/robin@example.com/events/ev1") { _ in
            jsonResponse(200, ["id": "ev1", "attendeesOmitted": true,
                               "attendees": [["email": "sam@example.org", "responseStatus": "accepted"]]])
        }
        http.on("PATCH", "/calendar/v3/calendars/robin@example.com/events/ev1") { _ in
            jsonResponse(200, ["id": "ev1", "status": "confirmed", "summary": "Planning",
                               "start": ["dateTime": "2026-10-13T15:00:00-07:00"], "end": ["dateTime": "2026-10-13T15:30:00-07:00"]])
        }
        let client = GoogleCalendarClient(calendarID: Self.me, grantedScopes: CalendarScopes.request.write,
                                          tokens: StaticTokenProvider(token: "synthetic-cal-access"), transport: http,
                                          clock: InstantClock(), timeZone: zone)
        var change = GoogleEventPatch()
        change.guests = [GoogleGuestEdit(email: "sam@example.org", isOptional: true)]
        change.meet = .add
        _ = try await client.patchEvent(id: "ev1", patch: change, sendUpdates: .all)
        #expect(http.requests.map(\.method) == ["GET", "PATCH"])
        let sent = try #require(http.requests.last)
        let query = URLComponents(url: sent.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "sendUpdates" }?.value == "all" && query.first { $0.name == "conferenceDataVersion" }?.value == "1")
        #expect(sent.headers[CalendarGuardTransport.editRuleHeader] == nil, "the marker never leaves the process")
        let body = try #require(try JSONSerialization.jsonObject(with: sent.body ?? Data()) as? [String: Any])
        #expect(body["attendeesOmitted"] as? Bool == true)
        #expect(guardFor().refusalReason(for: patch("?sendUpdates=all", body)) == nil)
    }

    @Test func aReadGrantNeverSendsAnEdit() async {
        let http = FakeHTTPTransport()
        let client = GoogleCalendarClient(calendarID: Self.me, grantedScopes: CalendarScopes.request.read,
                                          tokens: StaticTokenProvider(token: "synthetic-cal-access"), transport: http,
                                          clock: InstantClock(), timeZone: zone)
        var change = GoogleEventPatch()
        change.title = "x"
        await #expect(throws: GoogleCalendarError.self) { _ = try await client.patchEvent(id: "ev1", patch: change, sendUpdates: .none) }
        #expect(!http.requests.contains { $0.method == "PATCH" })
    }
}
