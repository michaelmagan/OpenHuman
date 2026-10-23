import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanMailLive

private let calendarPath = "/calendar/v3/calendars/robin@example.com/events"
private let start = ISO8601DateFormatter().date(from: "2026-10-21T17:00:00Z")!
private let query = CalendarInviteQuery(uid: "weekly-1@example.com", title: "Weekly sync", start: start,
                                        end: start.addingTimeInterval(1_800), organizer: "dana@example.com")

private func provider(_ grant: [String], _ http: FakeHTTPTransport) -> GoogleCalendarProvider {
    let client = GoogleCalendarClient(calendarID: "robin@example.com", grantedScopes: grant,
                                      tokens: StaticTokenProvider(token: "synthetic-cal-access"), transport: http,
                                      clock: InstantClock(), timeZone: TimeZone(identifier: "UTC")!)
    return GoogleCalendarProvider(client: client, account: "robin@example.com", createRefusal: nil)
}

@Sendable private func item(_ id: String, uid: String?, title: String = "Weekly sync", at time: String = "2026-10-21T17:00:00Z",
                            organizer: String? = "dana@example.com", series: String? = nil) -> [String: Any] {
    var event: [String: Any] = ["id": id, "summary": title, "start": ["dateTime": time],
                                "end": ["dateTime": time.replacingOccurrences(of: ":00:00Z", with: ":30:00Z")],
                                "attendees": [["email": "robin@example.com", "self": true, "responseStatus": "needsAction"]]]
    if let uid { event["iCalUID"] = uid }
    if let organizer { event["organizer"] = ["email": organizer] }
    if let series { event["recurringEventId"] = series }
    return event
}

@Sendable private func asksForUID(_ request: HTTPRequest) -> Bool {
    URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "iCalUID" } == true
}

@Sendable private func value(_ name: String, in request: HTTPRequest) -> String? {
    URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

// Lists the way Google does: by iCalUID, by window, and with a series either expanded into its occurrences or listed
// as the series itself; a moved occurrence is listed both ways
private func honoring(_ build: @escaping @Sendable () -> [[String: Any]]) -> FakeHTTPTransport.Handler {
    { request in
        let reader = ISO8601DateFormatter()
        let uid = value("iCalUID", in: request)
        let expands = value("singleEvents", in: request) == "true"
        let from = value("timeMin", in: request).flatMap(reader.date(from:))
        let to = value("timeMax", in: request).flatMap(reader.date(from:))
        let items = build().filter { item in
            if let uid, item["iCalUID"] as? String != uid { return false }
            let shape = item["shape"] as? String ?? "single"
            if expands, shape == "series" { return false }
            if !expands, shape == "occurrence" { return false }
            guard let from, let to else { return true }
            let start = ((item["start"] as? [String: Any])?["dateTime"] as? String).flatMap(reader.date(from:))
            let end = ((item["end"] as? [String: Any])?["dateTime"] as? String).flatMap(reader.date(from:))
            guard let start, let end else { return false }
            return end > from && start < to
        }
        return FakeHTTPTransport.json(200, ["items": items])
    }
}

@Sendable private func shaped(_ shape: String, _ event: [String: Any], original: String? = nil,
                              repeats: Bool = false) -> [String: Any] {
    var out = event
    out["shape"] = shape
    if let original { out["originalStartTime"] = ["dateTime": original] }
    if repeats { out["recurrence"] = ["RRULE:FREQ=WEEKLY"] }
    return out
}

@MainActor
@Suite struct GoogleCalendarInviteLookupTests {
    @Test func aListingThatIgnoresTheFilterStillPicksTheEventByItsUIDWithEitherGrant() async throws {
        for grant in [CalendarScopes.request.read, CalendarScopes.request.write] {
            let http = FakeHTTPTransport()
            http.on("GET", calendarPath) { _ in
                FakeHTTPTransport.json(200, ["items": [
                    item("lunch", uid: "lunch@example.com", title: "Weekly sync"),
                    item("series1_20261021T170000Z", uid: "weekly-1@example.com", series: "series1"),
                ]])
            }
            let found = try await provider(grant, http).invitedEvent(query, wholeSeries: false)
            #expect(found?.id == "series1_20261021T170000Z" && found?.recurringEventID == "series1", "\(grant)")
            #expect(http.requests.count == 1 && http.requests.allSatisfy { $0.method == "GET" }, "\(grant): one read")
        }
    }

    @Test func withoutTheUIDTheWindowIsReadAgainAndTitleStartAndOrganizerDecide() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", calendarPath) { request in
            asksForUID(request) ? FakeHTTPTransport.json(200, ["items": [[String: Any]]()])
                : FakeHTTPTransport.json(200, ["items": [
                    item("not-dana", uid: nil, organizer: "lee@example.org"),
                    item("later", uid: nil, at: "2026-10-21T18:00:00Z"),
                    item("copy", uid: nil),
                ]])
        }
        let found = try await provider(CalendarScopes.request.write, http).invitedEvent(query, wholeSeries: false)
        #expect(found?.id == "copy", "same title, start and organizer; never the other organizer's or a later event")
        #expect(http.requests.count == 3 && asksForUID(http.requests[0]) && asksForUID(http.requests[1])
                && !asksForUID(http.requests[2]), "the UID at its time, the UID anywhere, then the window")
    }

    @Test func twoCandidatesRefuseAndNoneIsNil() async throws {
        let twice = FakeHTTPTransport()
        twice.on("GET", calendarPath) { _ in
            FakeHTTPTransport.json(200, ["items": [item("copy1", uid: nil), item("copy2", uid: nil, organizer: nil)]])
        }
        await #expect(throws: CalendarError.self) { _ = try await provider(CalendarScopes.request.write, twice).invitedEvent(query, wholeSeries: false) }

        let empty = FakeHTTPTransport()
        empty.on("GET", calendarPath) { _ in FakeHTTPTransport.json(200, ["items": [[String: Any]]()]) }
        #expect(try await provider(CalendarScopes.request.write, empty).invitedEvent(query, wholeSeries: false) == nil)
        #expect(empty.requests.count == 3, "the UID read, the series read, then the window read")
    }

    @Test func theWholeSeriesIsNamedByTheOccurrencesSeries() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", calendarPath) { _ in
            FakeHTTPTransport.json(200, ["items": [item("series1_20261021T170000Z", uid: "weekly-1@example.com",
                                                        series: "series1")]])
        }
        let found = try await provider(CalendarScopes.request.write, http).invitedEvent(query, wholeSeries: true)
        #expect(found?.id == "series1" && found?.recurringEventID == nil, "the answer reads the series' own event by id")
        #expect(found?.canRespond == true)
    }

    @Test func aMovedEventIsFoundByItsUIDWhereverItNowStarts() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", calendarPath, honoring {
            [item("ev", uid: "weekly-1@example.com", title: "Weekly sync, new time", at: "2026-10-23T18:00:00Z"),
             item("lookalike", uid: nil)]
        })
        let found = try await provider(CalendarScopes.request.write, http).invitedEvent(query, wholeSeries: false)
        #expect(found?.id == "ev", "the UID names it two days later and under a new title; the look-alike never wins")
        #expect(http.requests.count == 2 && http.requests.allSatisfy { $0.method == "GET" && asksForUID($0) })
        let series = try #require(http.requests.last)
        #expect(value("singleEvents", in: series) == "false" && value("timeMin", in: series) == nil)
    }

    @Test func aMovedOccurrenceIsFoundByTheStartItHadInTheSeriesAndTheSeriesByItself() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", calendarPath, honoring {
            [shaped("series", item("series1", uid: "weekly-1@example.com", at: "2026-10-07T17:00:00Z"), repeats: true),
             shaped("moved", item("series1_20261021T170000Z", uid: "weekly-1@example.com", at: "2026-10-22T09:00:00Z",
                                  series: "series1"), original: "2026-10-21T17:00:00Z"),
             shaped("occurrence", item("series1_20261028T170000Z", uid: "weekly-1@example.com",
                                       at: "2026-10-28T17:00:00Z", series: "series1"))]
        })
        let calendar = provider(CalendarScopes.request.write, http)
        var one = query
        one.recurrenceID = start
        let moved = try await calendar.invitedEvent(one, wholeSeries: false)
        #expect(moved?.id == "series1_20261021T170000Z" && moved?.recurringEventID == "series1")

        let first = ISO8601DateFormatter().date(from: "2026-10-14T17:00:00Z")!
        let whole = CalendarInviteQuery(uid: "weekly-1@example.com", title: "Weekly sync", start: first,
                                        end: first.addingTimeInterval(1_800), organizer: "dana@example.com", repeats: true)
        let series = try await calendar.invitedEvent(whole, wholeSeries: true)
        #expect(series?.id == "series1" && series?.recurringEventID == nil && series?.canRespond == true,
                "no occurrence at the invitation's first start: the series itself answers for all events")
        let instance = try await calendar.invitedEvent(whole, wholeSeries: false)
        #expect(instance == nil, "one occurrence of a series is found only at its own time")
    }

    @Test func aLookupByUIDOnlyNeverFallsBackToTheTitle() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", calendarPath, honoring { [item("lookalike", uid: nil)] })
        var strict = query
        strict.matchesTitle = false
        #expect(try await provider(CalendarScopes.request.write, http).invitedEvent(strict, wholeSeries: false) == nil)
        #expect(http.requests.count == 2 && http.requests.allSatisfy(asksForUID), "no read by time and title")
    }

    @Test func anAnswerAsAnAliasIsSentAndComesBackAsTheAccountsOwn() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", calendarPath + "/ev") { _ in
            FakeHTTPTransport.json(200, ["id": "ev", "summary": "Weekly sync", "start": ["dateTime": "2026-10-21T17:00:00Z"],
                                         "end": ["dateTime": "2026-10-21T17:30:00Z"],
                                         "attendees": [["email": "dana@example.com", "organizer": true, "responseStatus": "accepted"],
                                                       ["email": "robin@team.example", "responseStatus": "needsAction"]]])
        }
        http.on("PATCH", calendarPath + "/ev") { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]) ?? [:]
            return FakeHTTPTransport.json(200, ["id": "ev", "summary": "Weekly sync",
                                                "start": ["dateTime": "2026-10-21T17:00:00Z"],
                                                "end": ["dateTime": "2026-10-21T17:30:00Z"], "attendees": body["attendees"] ?? []])
        }
        var event = CalendarEvent(id: "ev", title: "Weekly sync", start: start, end: start.addingTimeInterval(1_800),
                                  attendees: [EmailAddress(name: nil, email: "dana@example.com"),
                                              EmailAddress(name: nil, email: "robin@team.example")],
                                  myResponse: .needsAction)
        event.respondsAs = "robin@team.example"
        let answered = try await provider(CalendarScopes.request.write, http).respond(to: event, with: .accepted,
                                                                                      sendUpdates: .all)
        #expect(answered.myResponse == .accepted && answered.respondsAs == "robin@team.example")
        #expect(http.requests.map(\.method) == ["GET", "PATCH"], "the guard let the alias's answer through")
    }
}
