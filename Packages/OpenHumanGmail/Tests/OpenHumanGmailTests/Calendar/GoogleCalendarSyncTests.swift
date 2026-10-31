import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

private let newYork = TimeZone(identifier: "America/New_York")!

private func at(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = newYork
    return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

@Suite struct GoogleCalendarSyncTests {
    @Test func syncKeepsDateIdentityAndCancellationPositionsWithoutInventingDisplayTimes() async throws {
        let http = FakeHTTPTransport()
        let response = FakeHTTPTransport.json(200, ["items": [
            ["id": "offsite", "recurringEventId": "days", "start": ["date": "2026-11-03"], "end": ["date": "2026-11-04"],
             "originalStartTime": ["date": "2026-11-01"]],
            ["id": "cancelled", "status": "cancelled", "recurringEventId": "days", "originalStartTime": ["date": "2026-11-02"]]],
            "nextSyncToken": "next"])
        http.on("GET", Self.eventsPath) { _ in response }
        let page = try await client(http).listEventChanges(syncToken: "before")
        #expect(page.events.first?.event.originalStartTime == .date("2026-11-01"))
        #expect(page.removed == ["cancelled"])
        #expect(page.cancellations == [GoogleCalendarCancellation(id: "cancelled", parentID: "days", originalStartTime: .date("2026-11-02"))])
    }

    private static let me = "robin@example.com"
    private static let eventsPath = "/calendar/v3/calendars/robin@example.com/events"

    private func client(_ http: FakeHTTPTransport) -> GoogleCalendarClient {
        GoogleCalendarClient(calendarID: Self.me, grantedScopes: CalendarScopes.request.read,
                             tokens: StaticTokenProvider(token: "synthetic-cal-access"), transport: http,
                             clock: InstantClock(), timeZone: newYork)
    }

    private func query(_ request: HTTPRequest, _ name: String) -> String? {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private func names(_ request: HTTPRequest) -> Set<String> {
        Set((URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name))
    }

    private static func timed(_ id: String, _ start: String, _ end: String, extra: [String: Any] = [:]) -> [String: Any] {
        var item: [String: Any] = ["id": id, "summary": id, "start": ["dateTime": start], "end": ["dateTime": end]]
        for (key, value) in extra { item[key] = value }
        return item
    }

    @Test func aWindowIsOneLogicalReadOf250PerPageWithTheLastPagesToken() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", Self.eventsPath) { request in
            let page = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "pageToken" }?.value
            if page == nil {
                return FakeHTTPTransport.json(200, [
                    "items": [Self.timed("a", "2026-10-14T14:00:00Z", "2026-10-14T15:00:00Z",
                                         extra: ["etag": "\"e1\"", "updated": "2026-10-10T08:00:00Z"])],
                    "nextPageToken": "page-2",
                ])
            }
            return FakeHTTPTransport.json(200, [
                "items": [
                    Self.timed("b_20261015T140000Z", "2026-10-15T14:00:00Z", "2026-10-15T15:00:00Z",
                               extra: ["etag": "\"e2\"", "recurringEventId": "b", "transparency": "transparent"]),
                    ["id": "allday", "summary": "Offsite", "start": ["date": "2026-10-16"], "end": ["date": "2026-10-17"]],
                ],
                "nextSyncToken": "synthetic-sync-1",
            ])
        }
        let page = try await client(http).listEventWindow(from: at(9, 30), to: at(11, 28))
        #expect(http.requests.count == 2, "one logical read: two pages")
        #expect(page.isComplete && page.nextSyncToken == "synthetic-sync-1")
        #expect(page.events.map(\.event.id) == ["a", "b_20261015T140000Z", "allday"] && page.removed.isEmpty)
        let first = try #require(page.events.first)
        #expect(first.etag == "\"e1\"" && first.updated != nil && first.recurringEventID == nil && !first.isTransparent)
        let instance = page.events[1]
        #expect(instance.recurringEventID == "b" && instance.isTransparent, "an instance names its series")
        #expect(page.events[2].event.isAllDay && page.events[2].event.start == at(10, 16))
        for request in http.requests {
            #expect(request.method == "GET" && request.body == nil)
            #expect(query(request, "maxResults") == "250" && query(request, "singleEvents") == "true")
            #expect(query(request, "timeMin") == "2026-09-30T04:00:00+00:00")
            #expect(query(request, "timeMax") == "2026-11-28T05:00:00+00:00")
            #expect(query(request, "syncToken") == nil)
        }
        #expect(query(http.requests[1], "pageToken") == "page-2")
    }

    @Test func aChangeReadSendsOnlyTheTokenAndReturnsChangesAndRemovals() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", Self.eventsPath) { request in
            let page = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "pageToken" }?.value
            if page == nil {
                return FakeHTTPTransport.json(200, [
                    "items": [
                        Self.timed("moved", "2026-10-14T16:00:00Z", "2026-10-14T17:00:00Z", extra: ["etag": "\"e9\""]),
                        ["id": "gone", "status": "cancelled"],
                    ],
                    "nextPageToken": "more",
                ])
            }
            return FakeHTTPTransport.json(200, [
                "items": [
                    Self.timed("declined", "2026-10-15T16:00:00Z", "2026-10-15T17:00:00Z",
                               extra: ["attendees": [["email": "alex@example.com", "responseStatus": "accepted"],
                                                     ["email": "robin@example.com", "self": true,
                                                      "responseStatus": "declined"]]]),
                    ["id": "series_20261016T140000Z", "status": "cancelled", "recurringEventId": "series"],
                ],
                "nextSyncToken": "synthetic-sync-2",
            ])
        }
        let page = try await client(http).listEventChanges(syncToken: "synthetic-sync-1")
        #expect(page.events.map(\.event.id) == ["moved", "declined"])
        #expect(page.removed == ["gone", "series_20261016T140000Z"], "cancelled entries and instances are removals")
        #expect(page.events.first?.etag == "\"e9\"" && page.events.last?.selfDeclined == true)
        #expect(page.events.first?.selfDeclined == false)
        #expect(page.nextSyncToken == "synthetic-sync-2" && page.isComplete)
        #expect(http.requests.count == 2)
        for request in http.requests {
            #expect(request.method == "GET")
            #expect(query(request, "syncToken") == "synthetic-sync-1", "the same token on every page ([S1])")
            #expect(query(request, "singleEvents") == "true" && query(request, "maxResults") == "250")
            #expect(names(request).isDisjoint(with: ["timeMin", "timeMax", "showDeleted", "orderBy", "q", "updatedMin",
                                                     "iCalUID"]), "parameters [S1] does not allow with a token")
        }
        #expect(query(http.requests[1], "pageToken") == "more")
    }

    @Test func anExpiredTokenIsGone() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", Self.eventsPath) { _ in
            FakeHTTPTransport.json(410, ["error": ["code": 410, "errors": [["reason": "fullSyncRequired"]]]])
        }
        await #expect(throws: GoogleCalendarError.gone) {
            _ = try await client(http).listEventChanges(syncToken: "synthetic-old")
        }
        #expect(http.requests.count == 1, "never retried: the cache reads its window again")
    }

    @Test func aReadWithoutATokenOrWhosePagesRunOutHasNoToken() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", Self.eventsPath) { _ in
            FakeHTTPTransport.json(200, ["items": [Self.timed("a", "2026-10-14T14:00:00Z", "2026-10-14T15:00:00Z")],
                                         "nextPageToken": "again-\(UUID().uuidString)"])
        }
        let page = try await client(http).listEventWindow(from: at(10, 1), to: at(11, 1))
        #expect(http.requests.count == GoogleCalendarClient.maxSyncPages, "paging stops at the cap")
        #expect(!page.isComplete && page.nextSyncToken == nil, "no token from a read that did not finish")

        let plain = FakeHTTPTransport()
        plain.on("GET", Self.eventsPath) { _ in FakeHTTPTransport.json(200, ["items": [[String: Any]]()]) }
        let empty = try await client(plain).listEventWindow(from: at(10, 1), to: at(11, 1))
        #expect(empty.isComplete && empty.nextSyncToken == nil && empty.events.isEmpty)
    }

    @Test func bothReadsPassTheGuardOnAReadGrantAndNothingIsWidened() throws {
        let guardian = CalendarGuardTransport(wrapping: FakeHTTPTransport(), calendarID: Self.me,
                                              grantedScopes: CalendarScopes.request.read)
        let client = client(FakeHTTPTransport())
        let window = client.url(["calendars", Self.me, "events"],
                                query: [URLQueryItem(name: "syncToken", value: "synthetic"),
                                        URLQueryItem(name: "singleEvents", value: "true")])
        #expect(guardian.refusalReason(for: HTTPRequest(method: "GET", url: window, headers: [:], body: nil)) == nil)
        let other = URL(string: "https://example.com/calendar/v3/calendars/robin@example.com/events?syncToken=x")!
        #expect(guardian.refusalReason(for: HTTPRequest(method: "GET", url: other, headers: [:], body: nil)) != nil)
        #expect(guardian.refusalReason(for: HTTPRequest(method: "POST", url: window, headers: [:], body: Data("{}".utf8))) != nil)
    }
}
