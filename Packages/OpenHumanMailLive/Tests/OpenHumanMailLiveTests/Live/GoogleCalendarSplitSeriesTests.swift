import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanMailLive

private let eventsPath = "/calendar/v3/calendars/robin@example.com/events"
private let split = ISO8601DateFormatter().date(from: "2026-12-04T02:00:00Z")!

private func provider(_ http: FakeHTTPTransport) -> GoogleCalendarProvider {
    let client = GoogleCalendarClient(calendarID: "robin@example.com", grantedScopes: CalendarScopes.request.write,
                                      tokens: StaticTokenProvider(token: "synthetic-cal-access"), transport: http,
                                      clock: InstantClock(), timeZone: TimeZone(identifier: "UTC")!)
    return GoogleCalendarProvider(client: client, account: "robin@example.com", createRefusal: nil)
}

private func master(_ recurrence: [String]) -> [String: Any] {
    ["id": "series1", "summary": "Weekly planning", "start": ["dateTime": "2026-11-06T02:00:00Z"],
     "end": ["dateTime": "2026-11-06T03:00:00Z"], "recurrence": recurrence, "visibility": "private",
     "transparency": "transparent", "guestsCanModify": true,
     "reminders": ["useDefault": false, "overrides": [["method": "popup", "minutes": 30]]],
     "organizer": ["email": "robin@example.com", "self": true]]
}

private func serve(_ recurrence: [String]) -> FakeHTTPTransport {
    let http = FakeHTTPTransport()
    http.on("GET", eventsPath) { _ in FakeHTTPTransport.json(200, master(recurrence)) }
    http.on("POST", eventsPath) { _ in
        FakeHTTPTransport.json(200, ["id": "following1", "summary": "Renamed", "start": ["dateTime": "2026-12-04T02:00:00Z"],
                                     "end": ["dateTime": "2026-12-04T03:00:00Z"]])
    }
    http.on("PATCH", eventsPath) { _ in FakeHTTPTransport.json(200, master(recurrence)) }
    return http
}

private let instance = CalendarEvent(id: "series1_20261204T020000Z", title: "Weekly planning", start: split,
                                     end: split.addingTimeInterval(3_600), timeZone: "UTC", organizerIsMe: true,
                                     recurringEventID: "series1")

private func body(_ request: HTTPRequest) throws -> [String: Any] {
    let data = try #require(request.body)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite struct GoogleCalendarSplitSeriesTests {
    @Test func thisAndFollowingKeepsTheEndTheLaterExceptionsAndTheSeriesSettings() async throws {
        let http = serve(["RRULE:FREQ=WEEKLY;UNTIL=20270101T000000Z", "EXDATE:20261127T020000Z,20261218T020000Z"])
        var patch = CalendarEventPatch()
        patch.title = "Renamed"
        _ = try await provider(http).patchEvent(instance, with: patch, scope: .thisAndFollowing, sendUpdates: .none)
        let insert = try body(try #require(http.requests.first { $0.method == "POST" }))
        #expect(insert["summary"] as? String == "Renamed")
        #expect(insert["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY;UNTIL=20270101T000000Z", "EXDATE:20261218T020000Z"])
        #expect(insert["visibility"] as? String == "private", "a private series stays private")
        #expect(insert["transparency"] as? String == "transparent")
        #expect(insert["guestsCanModify"] as? Bool == true)
        let reminders = try #require(insert["reminders"] as? [String: Any])
        #expect(reminders["useDefault"] as? Bool == false)
        #expect((reminders["overrides"] as? [[String: Any]])?.first?["minutes"] as? Int == 30)
        let cut = try body(try #require(http.requests.first { $0.method == "PATCH" }))
        #expect(cut["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY;UNTIL=20261204T015959Z",
                                                   "EXDATE:20261127T020000Z,20261218T020000Z"])
    }

    @Test func theEditOverridesTheSeriesSettingsItChanges() async throws {
        let http = serve(["RRULE:FREQ=WEEKLY"])
        var patch = CalendarEventPatch()
        patch.visibility = .public
        patch.reminders = .calendarDefault
        _ = try await provider(http).patchEvent(instance, with: patch, scope: .thisAndFollowing, sendUpdates: .none)
        let insert = try body(try #require(http.requests.first { $0.method == "POST" }))
        #expect(insert["visibility"] as? String == "public")
        #expect((insert["reminders"] as? [String: Any])?["useDefault"] as? Bool == true)
        #expect(insert["transparency"] as? String == "transparent", "settings the edit leaves alone are kept")
        #expect(insert["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY"])
    }

    @Test func movingAllEventsAcrossADaylightChangeKeepsTheTimeOfDay() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        func at(_ month: Int, _ day: Int, _ hour: Int, year: Int = 2026) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = la
            return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let first = at(1, 5, 9)
        #expect(GoogleCalendarProvider.shiftedSeriesStart(first, instant: at(10, 31, 9), movedTo: at(11, 1, 9), zone: la)
                == at(1, 6, 9), "a day later at 9:00, not 25 hours later at 10:00")
        #expect(GoogleCalendarProvider.shiftedSeriesStart(first, instant: at(10, 31, 9), movedTo: at(10, 31, 11), zone: la)
                == at(1, 5, 11))
        #expect(GoogleCalendarProvider.shiftedSeriesStart(at(7, 1, 9), instant: at(12, 1, 9), movedTo: at(11, 30, 8), zone: la)
                == at(6, 30, 8))
    }

    @Test func aSeriesThatEndsAfterANumberOfTimesIsNotSplit() async throws {
        let http = serve(["RRULE:FREQ=WEEKLY;COUNT=10"])
        var patch = CalendarEventPatch()
        patch.title = "Renamed"
        await #expect(throws: CalendarError.self) {
            _ = try await provider(http).patchEvent(instance, with: patch, scope: .thisAndFollowing, sendUpdates: .none)
        }
        #expect(!http.requests.contains { $0.method == "POST" || $0.method == "PATCH" }, "nothing is created or cut")
    }
}
