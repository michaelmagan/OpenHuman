import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

private let zone = TimeZone(identifier: "America/Los_Angeles")!

@Suite struct CalendarRSVPTests {
    private static let me = "robin@example.com"
    private static let event = "https://www.googleapis.com/calendar/v3/calendars/robin@example.com/events/ev1"
    private static let path = "/calendar/v3/calendars/robin@example.com/events/ev1"

    private static var organizer: [String: Any] {
        ["email": "sam@example.org", "displayName": "Sam Rivera", "organizer": true, "responseStatus": "accepted",
         "comment": "Looking forward"]
    }

    private func patch(_ url: String, _ body: [String: Any]) -> HTTPRequest {
        HTTPRequest(method: "PATCH", url: URL(string: url)!, headers: [:],
                    body: try! JSONSerialization.data(withJSONObject: body))
    }

    private func guardFor(_ scopes: [String] = CalendarScopes.request.write) -> CalendarGuardTransport {
        CalendarGuardTransport(wrapping: ScriptedTransport(), calendarID: Self.me, grantedScopes: scopes)
    }

    private func answer(_ status: String, own: [String: Any] = ["email": "robin@example.com"]) -> [String: Any] {
        var mine = own
        mine["responseStatus"] = status
        return ["attendees": [Self.organizer, mine]]
    }

    private func client(_ scopes: [String], _ http: FakeHTTPTransport) -> GoogleCalendarClient {
        GoogleCalendarClient(calendarID: Self.me, grantedScopes: scopes,
                             tokens: StaticTokenProvider(token: "synthetic-cal-access"), transport: http,
                             clock: InstantClock(), timeZone: zone)
    }

    @Test func anAnswerPatchPassesOnlyWithCalendarEvents() {
        for status in ["accepted", "declined", "tentative"] {
            let request = patch(Self.event + "?sendUpdates=all", answer(status))
            #expect(guardFor().refusalReason(for: request) == nil, "\(status)")
            #expect(guardFor(CalendarScopes.request.read).refusalReason(for: request) != nil, "a read grant never answers")
        }
        let bySelf = patch(Self.event + "?sendUpdates=none", answer("declined", own: ["email": "alias@example.com", "self": true]))
        #expect(guardFor().refusalReason(for: bySelf) == nil, "the entry Google marks as the account's own")
    }

    @Test func anyOtherAnswerShapeIsRefused() {
        let calendar = guardFor()
        var withTitle = answer("accepted")
        withTitle["summary"] = "x"
        var withTimes = answer("accepted")
        withTimes["start"] = ["dateTime": "2026-10-13T15:00:00-07:00"]
        withTimes["end"] = ["dateTime": "2026-10-13T15:30:00-07:00"]
        let refused = [
            patch(Self.event + "?sendUpdates=all", withTitle),
            patch(Self.event + "?sendUpdates=all", withTimes),
            patch(Self.event + "?sendUpdates=all", answer("needsAction")),
            patch(Self.event + "?sendUpdates=all", answer("maybe")),
            patch(Self.event + "?sendUpdates=all", ["attendees": [Self.organizer, ["email": "robin@example.com"]]]),
            patch(Self.event + "?sendUpdates=all", ["attendees": [Self.organizer]]),
            patch(Self.event + "?sendUpdates=all", ["attendees": [["email": "robin@example.com", "responseStatus": "accepted"],
                                                                  ["email": "alias@example.com", "self": true,
                                                                   "responseStatus": "accepted"]]]),
            patch(Self.event + "?sendUpdates=all", ["attendees": [["displayName": "No address"],
                                                                  ["email": "robin@example.com", "responseStatus": "accepted"]]]),
            patch(Self.event + "?sendUpdates=all", ["attendees": []]),
            patch(Self.event + "?sendUpdates=all", ["attendees": "robin@example.com"]),
            patch(Self.event, answer("accepted")),
            patch("https://www.googleapis.com/calendar/v3/calendars/other@example.org/events/ev1?sendUpdates=all",
                  answer("accepted")),
        ]
        for request in refused {
            #expect(calendar.refusalReason(for: request) != nil,
                    "\(String(decoding: request.body ?? Data(), as: UTF8.self)) \(request.url.absoluteString)")
        }
    }

    @Test func theClientReadsTheEventFirstAndChangesOnlyTheOwnAnswer() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", Self.path) { _ in
            let own: [String: Any] = ["email": "robin@example.com", "self": true, "responseStatus": "needsAction"]
            return FakeHTTPTransport.json(200, ["id": "ev1", "summary": "Review", "start": ["dateTime": "2026-10-13T15:00:00-07:00"],
                                         "end": ["dateTime": "2026-10-13T15:30:00-07:00"], "organizer": ["self": false],
                                         "attendees": [Self.organizer, own]])
        }
        http.on("PATCH", Self.path) { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]) ?? [:]
            return FakeHTTPTransport.json(200, ["id": "ev1", "summary": "Review",
                                                "start": ["dateTime": "2026-10-13T15:00:00-07:00"],
                                                "end": ["dateTime": "2026-10-13T15:30:00-07:00"],
                                                "organizer": ["self": false], "attendees": body["attendees"] ?? []])
        }
        let answered = try await client(CalendarScopes.request.write, http).respond(eventID: "ev1", response: "tentative", sendUpdates: .all)
        #expect(answered?.selfResponse == "tentative" && answered?.organizerIsSelf == false)
        #expect(http.requests.map(\.method) == ["GET", "PATCH"], "read first, then one patch")
        let sent = try #require(http.requests.last)
        #expect(URLComponents(url: sent.url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "sendUpdates" }?.value == "all")
        let body = try #require(try JSONSerialization.jsonObject(with: sent.body ?? Data()) as? [String: Any])
        #expect(Set(body.keys) == ["attendees"], "only the attendee list")
        let attendees = try #require(body["attendees"] as? [[String: Any]])
        #expect(attendees.count == 2)
        #expect(NSDictionary(dictionary: attendees[0]).isEqual(to: Self.organizer), "the organizer's entry exactly as read")
        #expect(attendees[1]["responseStatus"] as? String == "tentative" && attendees[1]["self"] as? Bool == true)
    }

    @Test func aReadGrantAndANonInvitationNeverSendAnAnswer() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", Self.path) { _ in
            FakeHTTPTransport.json(200, ["id": "ev1", "start": ["dateTime": "2026-10-13T15:00:00-07:00"],
                                         "end": ["dateTime": "2026-10-13T15:30:00-07:00"],
                                         "attendees": [Self.organizer, ["email": "robin@example.com", "self": true]]])
        }
        await #expect(throws: GoogleCalendarError.self) {
            _ = try await client(CalendarScopes.request.read, http).respond(eventID: "ev1", response: "accepted",
                                                                             sendUpdates: .all)
        }
        #expect(!http.requests.contains { $0.method == "PATCH" }, "a read grant: refused before the wire")

        let notInvited = FakeHTTPTransport()
        notInvited.on("GET", Self.path) { _ in
            FakeHTTPTransport.json(200, ["id": "ev1", "start": ["dateTime": "2026-10-13T15:00:00-07:00"],
                                         "end": ["dateTime": "2026-10-13T15:30:00-07:00"], "attendees": [Self.organizer]])
        }
        await #expect(throws: GoogleCalendarError.self) {
            _ = try await client(CalendarScopes.request.write, notInvited).respond(eventID: "ev1", response: "accepted", sendUpdates: .all)
        }
        #expect(notInvited.requests.map(\.method) == ["GET"], "not invited: nothing patched")
        await #expect(throws: GoogleCalendarError.self) {
            _ = try await client(CalendarScopes.request.write, notInvited).respond(eventID: "ev1", response: "needsAction", sendUpdates: .all)
        }
        #expect(notInvited.requests.count == 1, "an answer Mail does not give is refused before any request")
    }

    @Test func anAnswerAsAnAliasPassesOnlyWhenTheRequestNamesThatAddress() {
        let alias = "robin@team.example"
        var named = patch(Self.event + "?sendUpdates=all", answer("accepted", own: ["email": alias]))
        #expect(guardFor().refusalReason(for: named) != nil, "without the header an alias entry is someone else's")
        named.headers[CalendarGuardTransport.answerAsHeader] = alias
        #expect(guardFor().refusalReason(for: named) == nil)
        var other = patch(Self.event + "?sendUpdates=all", answer("accepted", own: ["email": "lee@example.org"]))
        other.headers[CalendarGuardTransport.answerAsHeader] = alias
        #expect(guardFor().refusalReason(for: other) != nil, "the header names one address, not any guest")
        var both = patch(Self.event + "?sendUpdates=all",
                         ["attendees": [["email": alias, "responseStatus": "accepted"],
                                        ["email": "robin@example.com", "responseStatus": "accepted"]]])
        both.headers[CalendarGuardTransport.answerAsHeader] = alias
        #expect(guardFor().refusalReason(for: both) != nil, "never two own entries")
        var shortened = answer("declined")
        shortened["attendeesOmitted"] = true
        #expect(guardFor().refusalReason(for: patch(Self.event + "?sendUpdates=all", shortened)) == nil)
        shortened["attendeesOmitted"] = false
        #expect(guardFor().refusalReason(for: patch(Self.event + "?sendUpdates=all", shortened)) != nil)
    }

    @Test func withoutAnOwnEntryTheClientAnswersAsTheAliasAndKeepsAShortenedListShort() async throws {
        let alias = "robin@team.example"
        let http = FakeHTTPTransport()
        http.on("GET", Self.path) { _ in
            FakeHTTPTransport.json(200, ["id": "ev1", "start": ["dateTime": "2026-10-13T15:00:00-07:00"],
                                         "end": ["dateTime": "2026-10-13T15:30:00-07:00"], "attendeesOmitted": true,
                                         "attendees": [Self.organizer, ["email": "Robin@Team.example",
                                                                        "responseStatus": "needsAction"]]])
        }
        http.on("PATCH", Self.path) { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]) ?? [:]
            return FakeHTTPTransport.json(200, ["id": "ev1", "start": ["dateTime": "2026-10-13T15:00:00-07:00"],
                                                "end": ["dateTime": "2026-10-13T15:30:00-07:00"],
                                                "attendees": body["attendees"] ?? []])
        }
        let calendar = client(CalendarScopes.request.write, http)
        await #expect(throws: GoogleCalendarError.badRequest(reason: "not_invited")) {
            _ = try await calendar.respond(eventID: "ev1", response: "accepted", sendUpdates: .all)
        }
        #expect(!http.requests.contains { $0.method == "PATCH" }, "no own entry and no alias: nothing is answered")
        let answered = try await calendar.respond(eventID: "ev1", response: "accepted", sendUpdates: .all, as: alias)
        #expect(answered?.selfResponse == "accepted", "the answer is read from the alias's entry")
        let sent = try #require(http.requests.last { $0.method == "PATCH" })
        let body = try #require(try JSONSerialization.jsonObject(with: sent.body ?? Data()) as? [String: Any])
        #expect(Set(body.keys) == ["attendees", "attendeesOmitted"] && body["attendeesOmitted"] as? Bool == true)
        let attendees = try #require(body["attendees"] as? [[String: Any]])
        #expect(NSDictionary(dictionary: attendees[0]).isEqual(to: Self.organizer))
        #expect(attendees[1]["responseStatus"] as? String == "accepted" && attendees.count == 2)
        #expect(sent.headers[CalendarGuardTransport.answerAsHeader] == nil, "the guard's header never reaches Google")
    }

    @Test func anOwnEntryWinsOverTheAlias() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", Self.path) { _ in
            FakeHTTPTransport.json(200, ["id": "ev1", "start": ["dateTime": "2026-10-13T15:00:00-07:00"],
                                         "end": ["dateTime": "2026-10-13T15:30:00-07:00"],
                                         "attendees": [["email": "robin@team.example", "responseStatus": "needsAction"],
                                                       ["email": "robin@example.com", "self": true,
                                                        "responseStatus": "needsAction"]]])
        }
        http.on("PATCH", Self.path) { _ in FakeHTTPTransport.json(200, ["id": "ev1"]) }
        _ = try await client(CalendarScopes.request.write, http).respond(eventID: "ev1", response: "declined",
                                                                          sendUpdates: .all, as: "robin@team.example")
        let sent = try #require(http.requests.last { $0.method == "PATCH" })
        let body = try #require(try JSONSerialization.jsonObject(with: sent.body ?? Data()) as? [String: Any])
        let attendees = try #require(body["attendees"] as? [[String: Any]])
        #expect(attendees[0]["responseStatus"] as? String == "needsAction", "the alias's entry is left alone")
        #expect(attendees[1]["responseStatus"] as? String == "declined")
    }

    @Test func anAliasThatNamesTheOrganizerCannotAnswerItsEntry() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", Self.path) { _ in
            FakeHTTPTransport.json(200, ["id": "ev1", "organizer": ["email": "work@example.test"],
                                         "start": ["dateTime": "2026-10-13T15:00:00-07:00"],
                                         "end": ["dateTime": "2026-10-13T15:30:00-07:00"],
                                         "attendees": [["email": "work@example.test", "responseStatus": "accepted"]]])
        }
        await #expect(throws: GoogleCalendarError.badRequest(reason: "not_invited")) {
            _ = try await client(CalendarScopes.request.write, http).respond(eventID: "ev1", response: "declined",
                                                                              sendUpdates: .all, as: "work@example.test")
        }
        #expect(http.requests.map(\.method) == ["GET"])
        let marked = answer("accepted", own: ["email": "work@example.test", "organizer": true])
        var request = patch(Self.event + "?sendUpdates=all", marked)
        request.headers[CalendarGuardTransport.answerAsHeader] = "work@example.test"
        #expect(guardFor().refusalReason(for: request) != nil)
    }

    @Test func anOrganizerOnlyListDoesNotBecomeAnAliasSelfResponse() throws {
        let body: [String: Any] = ["id": "copy", "organizer": ["email": "work@example.test"],
                                   "start": ["dateTime": "2026-10-13T15:00:00-07:00"],
                                   "end": ["dateTime": "2026-10-13T15:30:00-07:00"],
                                   "attendees": [["email": "work@example.test", "responseStatus": "accepted"]]]
        let wire = try JSONDecoder().decode(WireEvent.self, from: JSONSerialization.data(withJSONObject: body))
        let event = try #require(wire.event(defaultZone: zone, selfAddress: "work@example.test"))
        #expect(event.selfResponse == nil && event.attendees.first?.isOrganizer == true)
    }

    @Test func listingReadsTheOwnAnswerThePlaceTheNotesAndTheSeries() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", "/calendar/v3/calendars/robin@example.com/events") { _ in
            FakeHTTPTransport.json(200, ["items": [
                ["id": "a", "summary": "Weekly", "start": ["dateTime": "2026-10-13T09:00:00-07:00"],
                 "end": ["dateTime": "2026-10-13T09:30:00-07:00"], "location": " Room 4 ", "description": "Agenda",
                 "recurringEventId": "weekly", "attendees": [Self.organizer, ["email": "robin@example.com", "self": true,
                                                                               "responseStatus": "tentative"]]],
                ["id": "b", "summary": "By address", "start": ["dateTime": "2026-10-13T10:00:00-07:00"],
                 "end": ["dateTime": "2026-10-13T10:30:00-07:00"],
                 "organizer": ["email": "sam@example.org"],
                 "attendees": [["email": "Robin@Example.com", "responseStatus": "declined"]]],
                ["id": "c", "summary": "Own", "start": ["dateTime": "2026-10-13T11:00:00-07:00"],
                 "end": ["dateTime": "2026-10-13T11:30:00-07:00"], "location": "  "],
            ]])
        }
        let start = ISO8601DateFormatter().date(from: "2026-10-13T07:00:00Z")!
        let events = try await client(CalendarScopes.request.read, http).listEvents(from: start, to: start.addingTimeInterval(86_400))
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        #expect(byID["a"]?.selfResponse == "tentative" && byID["a"]?.location == "Room 4" && byID["a"]?.notes == "Agenda")
        #expect(byID["a"]?.recurringEventID == "weekly")
        #expect(byID["b"]?.selfResponse == "declined", "the calendar's own address counts without `self`")
        #expect(byID["c"]?.selfResponse == nil && byID["c"]?.location == nil && byID["c"]?.recurringEventID == nil)
    }
}
