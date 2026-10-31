import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Synchronization
import Testing
@testable import OpenHumanGmail

private let newYork = TimeZone(identifier: "America/New_York")!

private func at(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ zone: TimeZone = newYork) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

@Suite struct GoogleCalendarClientTests {
    @Test func originalTimeIsImmutableEvenWhenTheDisplayedInstanceMovedAcrossDST() async throws {
        let http = FakeHTTPTransport()
        let response = FakeHTTPTransport.json(200, ["items": [["id": "moved", "recurringEventId": "weekly",
            "start": ["dateTime": "2026-10-28T16:00:00Z", "timeZone": "America/Los_Angeles"],
            "end": ["dateTime": "2026-10-28T17:00:00Z", "timeZone": "America/Los_Angeles"],
            "originalStartTime": ["dateTime": "2026-11-01T09:00:00-08:00", "timeZone": "America/Los_Angeles"]]]])
        http.on("GET", Self.eventsPath) { _ in response }
        let event = try #require(try await client(http).listEvents(from: at(10, 1), to: at(12, 1)).first)
        let original = ISO8601DateFormatter().date(from: "2026-11-01T17:00:00Z")!
        #expect(event.originalStartTime == .timed(original, timeZone: "America/Los_Angeles"))
        #expect(event.start != original && event.recurringEventID == "weekly")
    }

    private static let me = "robin@example.com"
    private static let eventsPath = "/calendar/v3/calendars/robin@example.com/events"

    private func client(_ http: FakeHTTPTransport, scopes: [String] = CalendarScopes.request.read,
                        tokens: StaticTokenProvider = StaticTokenProvider(token: "synthetic-cal-access"),
                        clock: InstantClock = InstantClock(),
                        budget: CalendarRequestBudget = CalendarRequestBudget()) -> GoogleCalendarClient {
        GoogleCalendarClient(calendarID: Self.me, grantedScopes: scopes,
                             tokens: tokens, transport: http, clock: clock, budget: budget, timeZone: newYork,
                             makeRequestID: { "synthetic-request-1" })
    }

    private func body(_ request: HTTPRequest?) -> [String: Any] {
        guard let data = request?.body, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private func query(_ request: HTTPRequest?, _ name: String) -> String? {
        request.flatMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
    }

    @Test func oneDayIsOneExpandedListWithOffsetsAndEventsComeBackSoonestFirst() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", Self.eventsPath) { _ in
            FakeHTTPTransport.json(200, ["items": [
                ["id": "ev1", "summary": "Standup", "attendees": [["email": "alice@example.com", "displayName": "Alice"]],
                 "start": ["dateTime": "2026-10-14T10:00:00-04:00", "timeZone": "America/New_York"],
                 "end": ["dateTime": "2026-10-14T10:30:00-04:00", "timeZone": "America/New_York"],
                 "conferenceData": ["conferenceSolution": ["key": ["type": "hangoutsMeet"]],
                                    "entryPoints": [["entryPointType": "phone", "uri": "tel:+1-555-0100"],
                                                    ["entryPointType": "video", "uri": "https://meet.google.com/abc-defg"]]]],
                ["id": "ev0", "summary": "Early", "start": ["dateTime": "2026-10-14T13:00:00Z"],
                 "end": ["dateTime": "2026-10-14T13:15:00.000Z"]],
                ["id": "allday", "summary": "Offsite", "start": ["date": "2026-10-14"], "end": ["date": "2026-10-15"]],
                ["id": "gone", "status": "cancelled", "start": ["dateTime": "2026-10-14T11:00:00Z"],
                 "end": ["dateTime": "2026-10-14T12:00:00Z"]],
                ["summary": "No id", "start": ["dateTime": "2026-10-14T11:00:00Z"], "end": ["dateTime": "2026-10-14T12:00:00Z"]],
                ["id": "notime", "summary": "No time", "start": [String: String](), "end": [String: String]()],
                ["id": "untitled", "start": ["dateTime": "2026-10-14T20:00:00Z"], "end": ["dateTime": "2026-10-14T21:00:00Z"]],
            ]])
        }
        let events = try await client(http).listEvents(from: at(10, 14), to: at(10, 15))
        #expect(events.map(\.id) == ["allday", "ev0", "ev1", "untitled"], "skipped: cancelled, no id, no time")
        let standup = try #require(events.first { $0.id == "ev1" })
        #expect(standup.title == "Standup" && standup.start == at(10, 14, 10) && standup.end == at(10, 14, 10, 30))
        #expect(standup.timeZone == "America/New_York" && !standup.isAllDay)
        #expect(standup.attendees == [GoogleCalendarAttendee(email: "alice@example.com", name: "Alice")])
        #expect(standup.meetLink == URL(string: "https://meet.google.com/abc-defg"), "the video entry point, not the phone")
        let offsite = try #require(events.first)
        #expect(offsite.isAllDay && offsite.start == at(10, 14) && offsite.end == at(10, 15))
        #expect(events.first { $0.id == "ev0" }?.end == at(10, 14, 9, 15), "fractional seconds read")
        #expect(events.last?.title == nil, "no summary: no title (the provider shows a placeholder)")

        let request = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(request.method == "GET" && request.url.host == "www.googleapis.com")
        #expect(request.url.path(percentEncoded: false) == Self.eventsPath)
        #expect(request.headers["Authorization"] == "Bearer synthetic-cal-access")
        #expect(query(request, "timeMin") == "2026-10-14T04:00:00+00:00")
        #expect(query(request, "timeMax") == "2026-10-15T04:00:00+00:00")
        #expect(query(request, "singleEvents") == "true" && query(request, "maxResults") == "2500")
        #expect(query(request, "syncToken") == nil && query(request, "pageToken") == nil)
        #expect(request.url.query(percentEncoded: true)?.contains("%2B00:00") == true, "a `+` is never sent as a space")
    }

    @Test func aMeetLinkIsOnlyAnHTTPSLinkOnTheMeetHostOfAMeetConference() async throws {
        @Sendable func item(_ id: String, type: String?, uri: String) -> [String: Any] {
            var conference: [String: Any] = ["entryPoints": [["entryPointType": "video", "uri": uri]]]
            if let type { conference["conferenceSolution"] = ["key": ["type": type]] }
            return ["id": id, "summary": id, "start": ["dateTime": "2026-10-14T13:00:00Z"],
                    "end": ["dateTime": "2026-10-14T14:00:00Z"], "conferenceData": conference]
        }
        let http = FakeHTTPTransport()
        http.on("GET", Self.eventsPath) { _ in
            FakeHTTPTransport.json(200, ["items": [
                item("meet", type: "hangoutsMeet", uri: "https://meet.google.com/abc-defg-hij"),
                item("unnamed", type: nil, uri: "https://meet.google.com/abc-defg-hij"),
                item("addon", type: "addOn", uri: "https://meet.google.com/abc-defg-hij"),
                item("otherhost", type: "hangoutsMeet", uri: "https://meet.example/abc-defg-hij"),
                item("lookalike", type: "hangoutsMeet", uri: "https://meet.google.com.example/abc"),
                item("http", type: "hangoutsMeet", uri: "http://meet.google.com/abc-defg-hij"),
                item("user", type: "hangoutsMeet", uri: "https://someone@meet.google.com/abc-defg-hij"),
                item("port", type: "hangoutsMeet", uri: "https://meet.google.com:8443/abc-defg-hij"),
            ]])
        }
        let events = try await client(http).listEvents(from: at(10, 14), to: at(10, 15))
        #expect(events.count == 8)
        let linked = Set(events.filter { $0.meetLink != nil }.map(\.id))
        #expect(linked == ["meet"])
        #expect(events.first { $0.id == "meet" }?.meetLink == URL(string: "https://meet.google.com/abc-defg-hij"))
    }

    @Test func pagesFollowTheTokenAndStop() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", Self.eventsPath) { request in
            let token = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "pageToken" }?.value
            let id = token == nil ? "first" : "second"
            var page: [String: Any] = ["items": [["id": id, "summary": id, "start": ["dateTime": "2026-10-14T13:00:00Z"],
                                                  "end": ["dateTime": "2026-10-14T14:00:00Z"]]]]
            if token == nil { page["nextPageToken"] = "synthetic-page-2" }
            return FakeHTTPTransport.json(200, page)
        }
        let events = try await client(http).listEvents(from: at(10, 14), to: at(10, 15))
        #expect(Set(events.map(\.id)) == ["first", "second"])
        #expect(http.requests.count == 2)
        #expect(query(http.requests.last, "pageToken") == "synthetic-page-2")
        #expect(query(http.requests.last, "timeMin") == query(http.requests.first, "timeMin"), "the same query on every page")
    }

    @Test func freeBusyAsksForTheAccountsCalendarAndReadsBusyAndErrors() async throws {
        let http = FakeHTTPTransport()
        http.on("POST", "/calendar/v3/freeBusy") { _ in
            FakeHTTPTransport.json(200, ["calendars": [Self.me: [
                "busy": [["start": "2026-10-14T14:00:00Z", "end": "2026-10-14T15:00:00Z"],
                         ["start": "2026-10-14T13:00:00Z", "end": "2026-10-14T13:30:00Z"],
                         ["start": "2026-10-14T16:00:00Z", "end": "2026-10-14T16:00:00Z"]],
                "errors": [["reason": "notFound"], [String: String]()]]]])
        }
        let answer = try await client(http).freeBusy(from: at(10, 14), to: at(10, 15))
        #expect(answer.busy == [GoogleBusyInterval(start: at(10, 14, 9), end: at(10, 14, 9, 30)),
                                GoogleBusyInterval(start: at(10, 14, 10), end: at(10, 14, 11))], "sorted; empty block dropped")
        #expect(answer.errors == ["notFound", "unknown"])
        let request = try #require(http.requests.first)
        #expect(request.method == "POST" && request.headers["Content-Type"] == "application/json")
        let sent = body(request)
        #expect(sent["timeMin"] as? String == "2026-10-14T04:00:00+00:00")
        #expect(sent["timeMax"] as? String == "2026-10-15T04:00:00+00:00")
        #expect(sent["timeZone"] as? String == "UTC")
        #expect((sent["items"] as? [[String: String]]) == [["id": Self.me]])
    }

    @Test func anInsertSendsTheEventAndAMeetRequestWithAWriteGrant() async throws {
        let http = FakeHTTPTransport()
        http.on("POST", Self.eventsPath) { _ in
            FakeHTTPTransport.json(200, [
                "id": "new1", "summary": "Lunch", "status": "confirmed",
                "start": ["dateTime": "2026-10-15T12:30:00-04:00", "timeZone": "America/New_York"],
                "end": ["dateTime": "2026-10-15T13:00:00-04:00", "timeZone": "America/New_York"],
                "attendees": [["email": "alice@example.com"]],
                "conferenceData": ["createRequest": ["requestId": "synthetic-request-1", "status": ["statusCode": "pending"]]],
            ])
        }
        let calendar = client(http, scopes: CalendarScopes.request.write)
        #expect(calendar.allowsWrites)
        let created = try await calendar.insertEvent(
            GoogleEventInsert(title: "Lunch", start: at(10, 15, 12, 30), end: at(10, 15, 13), timeZone: "America/New_York",
                              attendees: ["alice@example.com"]),
            sendUpdates: .all, addMeet: true)
        #expect(created.id == "new1" && created.start == at(10, 15, 12, 30) && created.conferenceStatus == "pending")
        #expect(created.meetLink == nil, "pending: the link comes later")
        let request = try #require(http.requests.first)
        #expect(query(request, "sendUpdates") == "all" && query(request, "conferenceDataVersion") == "1")
        let sent = body(request)
        #expect(sent["summary"] as? String == "Lunch")
        let start = try #require(sent["start"] as? [String: String])
        #expect(start == ["dateTime": "2026-10-15T12:30:00-04:00", "timeZone": "America/New_York"])
        #expect((sent["attendees"] as? [[String: String]]) == [["email": "alice@example.com"]])
        let conference = try #require((sent["conferenceData"] as? [String: Any])?["createRequest"] as? [String: Any])
        #expect(conference["requestId"] as? String == "synthetic-request-1")
        #expect((conference["conferenceSolutionKey"] as? [String: String]) == ["type": "hangoutsMeet"])
    }

    @Test func anInsertWithGuestsAsksGoogleToEmailTheirInvitations() async throws {
        let http = FakeHTTPTransport()
        http.on("POST", Self.eventsPath) { _ in
            FakeHTTPTransport.json(200, ["id": "new3", "start": ["dateTime": "2026-10-15T16:30:00Z"],
                                         "end": ["dateTime": "2026-10-15T17:00:00Z"]])
        }
        _ = try await client(http, scopes: CalendarScopes.request.write).insertEvent(
            GoogleEventInsert(title: "Lunch", start: at(10, 15, 12, 30), end: at(10, 15, 13), timeZone: "America/New_York",
                              attendees: ["alice@example.com"]),
            sendUpdates: .all, addMeet: false)
        let request = try #require(http.requests.first)
        #expect(request.url.query(percentEncoded: true)?.contains("sendUpdates=all") == true)
        #expect((body(request)["attendees"] as? [[String: String]]) == [["email": "alice@example.com"]])
    }

    @Test func withoutMeetThereIsNoConferenceRequest() async throws {
        let http = FakeHTTPTransport()
        http.on("POST", Self.eventsPath) { _ in
            FakeHTTPTransport.json(200, ["id": "new2", "start": ["dateTime": "2026-10-15T16:30:00Z"],
                                         "end": ["dateTime": "2026-10-15T17:00:00Z"]])
        }
        _ = try await client(http, scopes: CalendarScopes.request.write).insertEvent(
            GoogleEventInsert(title: "Focus", start: at(10, 15, 12, 30), end: at(10, 15, 13), timeZone: "America/New_York"),
            sendUpdates: .none, addMeet: false)
        let request = try #require(http.requests.first)
        #expect(query(request, "sendUpdates") == "none" && query(request, "conferenceDataVersion") == nil)
        #expect(body(request)["conferenceData"] == nil && body(request)["attendees"] == nil)
    }

    @Test func aCreatedEventWhoseAnswerIsUnreadableStillCountsAsCreated() async throws {
        let http = FakeHTTPTransport()
        http.on("POST", Self.eventsPath) { _ in HTTPResponse(status: 200, headers: [:], body: Data("not json".utf8)) }
        let created = try await client(http, scopes: CalendarScopes.request.write).insertEvent(
            GoogleEventInsert(title: "Focus", start: at(10, 15, 12), end: at(10, 15, 13), timeZone: "America/New_York"),
            sendUpdates: .none, addMeet: false)
        #expect(created.id.isEmpty && created.title == "Focus" && created.start == at(10, 15, 12))
    }

    @Test func anInsertWhoseAnswerIsLostIsUnclearAndSentOnce() async throws {
        let insert = GoogleEventInsert(title: "Lunch", start: at(10, 15, 12), end: at(10, 15, 13), timeZone: "UTC",
                                       attendees: ["alice@example.com"])
        for failure in [TransportError.connectionLost(requestMayHaveBeenSent: true), .timedOut, .other("synthetic")] {
            let http = FakeHTTPTransport()
            http.failNext(failure)
            await #expect(throws: GoogleCalendarError.unclear, "\(failure)") {
                _ = try await client(http, scopes: CalendarScopes.request.write).insertEvent(insert, sendUpdates: .all, addMeet: false)
            }
            #expect(http.requests.count == 1, "never repeated: \(failure)")
        }
        for status in [500, 503] {
            let http = FakeHTTPTransport()
            http.on("POST", Self.eventsPath) { _ in FakeHTTPTransport.json(status, ["error": ["code": status]]) }
            await #expect(throws: GoogleCalendarError.unclear) {
                _ = try await client(http, scopes: CalendarScopes.request.write).insertEvent(insert, sendUpdates: .all, addMeet: false)
            }
            #expect(http.requests.count == 1)
        }
        for failure in [TransportError.notConnected, .cannotConnect, .connectionLost(requestMayHaveBeenSent: false)] {
            let http = FakeHTTPTransport()
            http.failNext(failure)
            await #expect(throws: GoogleCalendarError.transport(failure)) {
                _ = try await client(http, scopes: CalendarScopes.request.write).insertEvent(insert, sendUpdates: .all, addMeet: false)
            }
        }
        let http = FakeHTTPTransport()
        http.on("GET", Self.eventsPath) { _ in FakeHTTPTransport.json(503, ["error": ["code": 503]]) }
        await #expect(throws: GoogleCalendarError.server(status: 503)) {
            _ = try await client(http, scopes: CalendarScopes.request.write).listEvents(from: at(10, 14), to: at(10, 15))
        }
        #expect(GoogleCalendarError.unclear.code == "unclear")
    }

    @Test func aGrantWithoutCalendarEventsNeverSendsAWrite() async throws {
        let http = FakeHTTPTransport()
        let insert = GoogleEventInsert(title: "x", start: at(10, 15, 12), end: at(10, 15, 13), timeZone: "UTC")
        for scopes in [CalendarScopes.request.read, [CalendarScope.events]] {
            let calendar = client(http, scopes: scopes)
            #expect(!calendar.allowsWrites)
            await #expect(throws: GoogleCalendarError.refusedByGuard("POST /calendar/v3/calendars/<redacted>/events")) {
                _ = try await calendar.insertEvent(insert, sendUpdates: .none, addMeet: true)
            }
        }
        #expect(http.requests.isEmpty)
    }

    @Test func theUndoDeletesOnlyAnEventItCreatedAndGoneCountsAsDeleted() async throws {
        let http = FakeHTTPTransport()
        let next = Mutex(0)
        http.on("POST", Self.eventsPath) { _ in
            let id = next.withLock { n -> String in
                n += 1
                return "made\(n)"
            }
            return FakeHTTPTransport.json(200, ["id": id, "start": ["dateTime": "2026-10-15T16:30:00Z"],
                                                "end": ["dateTime": "2026-10-15T17:00:00Z"]])
        }
        http.on("DELETE", Self.eventsPath + "/made1") { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
        http.on("DELETE", Self.eventsPath + "/made2") { _ in FakeHTTPTransport.json(410, ["error": ["code": 410]]) }
        let calendar = client(http, scopes: CalendarScopes.request.write)
        await #expect(throws: GoogleCalendarError.self) { try await calendar.deleteEvent(id: "someone-elses") }
        #expect(http.requests.isEmpty, "an event Mail did not create is never deleted")
        let insert = GoogleEventInsert(title: "x", start: at(10, 15, 12), end: at(10, 15, 13), timeZone: "UTC")
        _ = try await calendar.insertEvent(insert, sendUpdates: .none, addMeet: false)
        _ = try await calendar.insertEvent(insert, sendUpdates: .none, addMeet: false)
        try await calendar.deleteEvent(id: "made1")
        try await calendar.deleteEvent(id: "made2")
        let deletes = http.requests.filter { $0.method == "DELETE" }
        #expect(deletes.map { $0.url.lastPathComponent } == ["made1", "made2"])
        #expect(deletes.allSatisfy { query($0, "sendUpdates") == "none" })
        await #expect(throws: GoogleCalendarError.self) { try await calendar.deleteEvent(id: "made1") }
        #expect(http.requests.filter { $0.method == "DELETE" }.count == 2, "never twice")
    }

    @Test func a401RefreshesOnceThenTriesOnceMore() async throws {
        let http = FakeHTTPTransport()
        let answers = Mutex([401, 200])
        http.on("GET", Self.eventsPath) { _ in
            let status = answers.withLock { $0.isEmpty ? 401 : $0.removeFirst() }
            return FakeHTTPTransport.json(status, status == 200 ? ["items": []] : ["error": ["code": 401]])
        }
        let tokens = StaticTokenProvider()
        _ = try await client(http, tokens: tokens).listEvents(from: at(10, 14), to: at(10, 15))
        #expect(tokens.forcedRefreshes == 1 && http.requests.count == 2)
        await #expect(throws: GoogleCalendarError.unauthorized) {
            _ = try await client(http, tokens: tokens).listEvents(from: at(10, 14), to: at(10, 15))
        }
        #expect(tokens.forcedRefreshes == 2 && http.requests.count == 4, "one forced refresh per call, no more")
        let gone = StaticTokenProvider(failure: OAuthError.reauthRequired)
        await #expect(throws: GoogleCalendarError.reauthRequired) {
            _ = try await client(http, tokens: gone).listEvents(from: at(10, 14), to: at(10, 15))
        }
        #expect(http.requests.count == 4, "no token, no request")
    }

    @Test func whenGoogleLimitsNothingIsSentForAMinute() async throws {
        let http = FakeHTTPTransport()
        let limited = Mutex(true)
        http.on("GET", Self.eventsPath) { _ in
            limited.withLock { $0 } ? FakeHTTPTransport.json(429, ["error": ["code": 429, "status": "RESOURCE_EXHAUSTED"]])
                                    : FakeHTTPTransport.json(200, ["items": []])
        }
        let clock = InstantClock()
        let calendar = client(http, clock: clock)
        await #expect(throws: GoogleCalendarError.rateLimited) {
            _ = try await calendar.listEvents(from: at(10, 14), to: at(10, 15))
        }
        limited.withLock { $0 = false }
        await #expect(throws: GoogleCalendarError.rateLimited) {
            _ = try await calendar.listEvents(from: at(10, 14), to: at(10, 15))
        }
        #expect(http.requests.count == 1, "paused: the second call never left the process")
        clock.advance(by: .seconds(61))
        _ = try await calendar.listEvents(from: at(10, 14), to: at(10, 15))
        #expect(http.requests.count == 2)
    }

    @Test func mailKeepsToItsOwnPerMinuteBudget() async throws {
        #expect(CalendarRequestBudget.perMinute == 300, "half of the 600 per minute per user of [S5]")
        let http = FakeHTTPTransport()
        http.on("GET", Self.eventsPath) { _ in FakeHTTPTransport.json(200, ["items": []]) }
        let clock = InstantClock()
        let calendar = client(http, clock: clock, budget: CalendarRequestBudget(perMinute: 2))
        _ = try await calendar.listEvents(from: at(10, 14), to: at(10, 15))
        _ = try await calendar.listEvents(from: at(10, 14), to: at(10, 15))
        await #expect(throws: GoogleCalendarError.rateLimited) {
            _ = try await calendar.listEvents(from: at(10, 14), to: at(10, 15))
        }
        #expect(http.requests.count == 2)
        clock.advance(by: .seconds(60))
        _ = try await calendar.listEvents(from: at(10, 14), to: at(10, 15))
        #expect(http.requests.count == 3, "a sliding minute")
    }

    @Test func errorsCarryGoogleCodesNeverText() {
        func error(_ status: Int, reason: String?) -> GoogleCalendarError {
            var inner: [String: Any] = ["code": status, "message": "Some free text with robin@example.com in it"]
            if let reason { inner["errors"] = [["reason": reason, "message": "more text"]] }
            let response = FakeHTTPTransport.json(status, ["error": inner])
            return GoogleCalendarClient.error(response)
        }
        #expect(error(403, reason: "insufficientPermissions") == .forbidden(reason: "insufficientPermissions"))
        #expect(error(403, reason: "rateLimitExceeded") == .rateLimited)
        #expect(error(403, reason: "userRateLimitExceeded") == .rateLimited)
        #expect(error(403, reason: "a reason with spaces and robin@example.com") == .forbidden(reason: "forbidden"))
        #expect(error(400, reason: "invalid") == .badRequest(reason: "invalid"))
        #expect(error(404, reason: nil) == .notFound && error(410, reason: nil) == .gone)
        #expect(error(429, reason: nil) == .rateLimited && error(503, reason: nil) == .server(status: 503))
        #expect(GoogleCalendarError.forbidden(reason: "insufficientPermissions").code == "forbidden:insufficientPermissions")
    }
}
