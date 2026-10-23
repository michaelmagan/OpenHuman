import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

@Suite struct CalendarInviteLookupTests {
    private static let me = "robin@example.com"
    private static let list = "/calendar/v3/calendars/robin@example.com/events"
    private static let start = ISO8601DateFormatter().date(from: "2026-10-21T17:00:00Z")!

    private func client(_ scopes: [String], _ http: FakeHTTPTransport) -> GoogleCalendarClient {
        GoogleCalendarClient(calendarID: Self.me, grantedScopes: scopes,
                             tokens: StaticTokenProvider(token: "synthetic-cal-access"), transport: http,
                             clock: InstantClock(), timeZone: TimeZone(identifier: "UTC")!)
    }

    private func items(_ request: HTTPRequest?) -> [URLQueryItem] {
        request.flatMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    }

    @Test func theListingIsAGetOfTheWindowWithEitherGrantWithEachEventsUIDAndOrganizer() async throws {
        for scopes in [CalendarScopes.request.read, CalendarScopes.request.write] {
            let http = FakeHTTPTransport()
            http.on("GET", Self.list) { _ in
                FakeHTTPTransport.json(200, ["items": [
                    ["id": "series1_20261021T170000Z", "recurringEventId": "series1", "iCalUID": "weekly+1@example.com",
                     "summary": "Weekly sync", "organizer": ["email": "Dana@Example.com"],
                     "start": ["dateTime": "2026-10-21T17:00:00Z"], "end": ["dateTime": "2026-10-21T17:30:00Z"],
                     "attendees": [["email": "robin@example.com", "self": true, "responseStatus": "needsAction"]]],
                    ["id": "other", "summary": "Lunch", "start": ["dateTime": "2026-10-21T16:30:00Z"],
                     "end": ["dateTime": "2026-10-21T17:30:00Z"]],
                ]])
            }
            let found = try await client(scopes, http).inviteCandidates(iCalUID: "weekly+1@example.com",
                                                                     from: Self.start.addingTimeInterval(-60),
                                                                     to: Self.start.addingTimeInterval(60))
            #expect(found.map(\.event.id) == ["other", "series1_20261021T170000Z"], "\(scopes): soonest first")
            let occurrence = try #require(found.last)
            #expect(occurrence.iCalUID == "weekly+1@example.com" && occurrence.organizerEmail == "dana@example.com")
            #expect(occurrence.event.recurringEventID == "series1" && occurrence.event.selfResponse == "needsAction")
            #expect(found.first?.iCalUID == nil && found.first?.organizerEmail == nil, "absent fields stay nil")
            let request = try #require(http.requests.first)
            #expect(request.method == "GET" && request.body == nil, "\(scopes)")
            let query = items(request)
            #expect(query.contains(URLQueryItem(name: "iCalUID", value: "weekly+1@example.com")))
            #expect(request.url.absoluteString.contains("weekly%2B1"), "a + in the UID is encoded (Google would read a space)")
            #expect(query.contains(URLQueryItem(name: "singleEvents", value: "true")))
            #expect(query.contains { $0.name == "timeMin" } && query.contains { $0.name == "timeMax" })
        }
    }

    @Test func theSeriesReadHasNoWindowAndTellsTheSeriesAndEachMovedOccurrence() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", Self.list) { _ in
            FakeHTTPTransport.json(200, ["items": [
                ["id": "series1", "iCalUID": "weekly-1@example.com", "summary": "Weekly sync",
                 "recurrence": ["RRULE:FREQ=WEEKLY"],
                 "start": ["dateTime": "2026-10-07T17:00:00Z"], "end": ["dateTime": "2026-10-07T17:30:00Z"]],
                ["id": "series1_20261021T170000Z", "iCalUID": "weekly-1@example.com", "recurringEventId": "series1",
                 "originalStartTime": ["dateTime": "2026-10-21T17:00:00Z"], "summary": "Weekly sync",
                 "start": ["dateTime": "2026-10-22T09:00:00Z"], "end": ["dateTime": "2026-10-22T09:30:00Z"]],
            ]])
        }
        let found = try await client(CalendarScopes.request.read, http).inviteCandidates(iCalUID: "weekly-1@example.com",
                                                                                         from: nil, to: nil,
                                                                                         singleEvents: false)
        #expect(found.map(\.event.id) == ["series1", "series1_20261021T170000Z"])
        #expect(found[0].isSeries && found[0].originalStart == nil)
        #expect(!found[1].isSeries && found[1].originalStart == Self.start, "the moved occurrence keeps its series start")
        let query = items(http.requests.first)
        #expect(query.contains(URLQueryItem(name: "singleEvents", value: "false")))
        #expect(!query.contains { $0.name == "timeMin" || $0.name == "timeMax" }, "wherever the event now starts")
    }

    @Test func withoutAUIDOnlyTheWindowIsAskedFor() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", Self.list) { _ in FakeHTTPTransport.json(200, ["items": [[String: Any]]()]) }
        let found = try await client(CalendarScopes.request.read, http).inviteCandidates(iCalUID: nil, from: Self.start,
                                                                       to: Self.start.addingTimeInterval(60))
        #expect(found.isEmpty)
        let query = items(http.requests.first)
        #expect(!query.contains { $0.name == "iCalUID" })
        #expect(query.contains { $0.name == "timeMin" && $0.value?.hasPrefix("2026-10-21T17:00:00") == true })
    }
}
