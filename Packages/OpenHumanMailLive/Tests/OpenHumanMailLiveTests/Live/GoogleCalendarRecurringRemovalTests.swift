import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import Synchronization
import Testing
@testable import OpenHumanMailLive

private enum RecurringRemovalFixture {
    static let path = "/calendar/v3/calendars/robin@example.com/events"
    static let original = ISO8601DateFormatter().date(from: "2026-11-01T17:00:00Z")!
    static func wire(_ id: String, master: Bool = false, original: String? = "2026-11-01T17:00:00Z") -> [String: Any] {
        var out: [String: Any] = ["id": id, "etag": "\"\(id)-v1\"", "status": "confirmed", "eventType": "default",
            "summary": "Planning", "organizer": ["self": true],
            "start": ["dateTime": master ? "2026-10-25T16:00:00Z" : "2026-10-28T16:00:00Z", "timeZone": "America/Los_Angeles"],
            "end": ["dateTime": master ? "2026-10-25T17:00:00Z" : "2026-10-28T17:00:00Z", "timeZone": "America/Los_Angeles"]]
        if master {
            out["recurrence"] = ["RRULE:FREQ=WEEKLY;COUNT=3"]
            out["attendees"] = [["email": "sam@example.org"]]
        } else {
            out["recurringEventId"] = "master"
            if let original { out["originalStartTime"] = ["dateTime": original, "timeZone": "America/Los_Angeles"] }
        }
        return out
    }
    static var selected: CalendarEvent {
        CalendarEvent(id: "selected", title: "Planning", start: original, end: original.addingTimeInterval(3600),
            timeZone: "America/Los_Angeles", organizerIsMe: true, recurringEventID: "master")
    }
    static func provider(_ http: FakeHTTPTransport) -> GoogleCalendarProvider {
        let client = GoogleCalendarClient(calendarID: "robin@example.com", grantedScopes: CalendarScopes.request.write,
            tokens: StaticTokenProvider(token: "synthetic-calendar-token"), transport: http, clock: InstantClock(), timeZone: .gmt)
        return GoogleCalendarProvider(client: client, account: "robin@example.com", createRefusal: nil)
    }
    static func serve(_ http: FakeHTTPTransport, exceptions: [[String: Any]] = []) {
        let page = FakeHTTPTransport.json(200, ["items": exceptions])
        let selected = FakeHTTPTransport.json(200, wire("selected"))
        let master = FakeHTTPTransport.json(200, wire("master", master: true))
        http.on("GET", path) { _ in page }
        http.on("GET", path + "/selected") { _ in selected }
        http.on("GET", path + "/master") { _ in master }
        http.on("PATCH", path) { _ in master }
        http.on("DELETE", path) { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
    }
    static func writes(_ http: FakeHTTPTransport) -> [HTTPRequest] { http.requests.filter { $0.method != "GET" } }
}

@Suite struct GoogleCalendarRecurringRemovalTests {
    @Test func everyScopeGoesThroughTheRealClientAndGuardAndReturnsFreshIdentity() async throws {
        for scope in CalendarRecurrenceScope.removalOptions {
            let http = FakeHTTPTransport()
            RecurringRemovalFixture.serve(http)
            let provider = RecurringRemovalFixture.provider(http)
            let answer = try await provider.removeEvent(RecurringRemovalFixture.selected, scope: scope, sendUpdates: .none)
            #expect(answer.selectedID == "selected" && answer.parentID == "master" && answer.scope == scope)
            #expect(answer.originalCutoff == .timed(RecurringRemovalFixture.original, timeZone: "America/Los_Angeles"))
            let write = try #require(RecurringRemovalFixture.writes(http).first)
            let target = scope == .thisEvent ? "selected" : "master"
            #expect(write.url.path(percentEncoded: false) == RecurringRemovalFixture.path + "/" + target)
            #expect(write.headers["If-Match"] == "\"\(target)-v1\"")
            #expect(write.url.query?.contains("sendUpdates=all") == true, "master guests differ from selected guests")
            #expect(RecurringRemovalFixture.writes(http).count == 1)
            if scope == .thisAndFollowing {
                #expect(write.method == "PATCH")
                let data = try #require(write.body)
                let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(body["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"])
            } else { #expect(write.method == "DELETE") }
        }
    }

    @Test func confirmedTrimServerEvidenceMapsThroughTheRealProviderWithoutFallbacks() async throws {
        let updated = ISO8601DateFormatter().date(from: "2026-10-26T12:01:00Z")!
        for kind in ["confirmed", "missing-time", "invalid-time", "wrong-master", "unchanged-etag"] {
            let http = FakeHTTPTransport()
            RecurringRemovalFixture.serve(http)
            var trimmed = RecurringRemovalFixture.wire("master", master: true)
            trimmed["etag"] = "\"master-trimmed\""
            trimmed["updated"] = "2026-10-26T12:01:00Z"
            trimmed["recurrence"] = ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"]
            if kind == "missing-time" { trimmed.removeValue(forKey: "updated") }
            if kind == "invalid-time" { trimmed["updated"] = "invalid" }
            if kind == "wrong-master" { trimmed["id"] = "another-master" }
            if kind == "unchanged-etag" { trimmed["etag"] = "\"master-v1\"" }
            let response = FakeHTTPTransport.json(200, trimmed)
            http.on("PATCH", RecurringRemovalFixture.path) { _ in response }
            let result = try await RecurringRemovalFixture.provider(http).removeEvent(RecurringRemovalFixture.selected,
                scope: .thisAndFollowing, sendUpdates: .all)
            #expect(result.parentID == "master" && result.originalCutoff == .timed(RecurringRemovalFixture.original,
                timeZone: "America/Los_Angeles"))
            if kind == "confirmed" {
                #expect(result.confirmedMasterVersion == CalendarConfirmedMasterVersion(etag: "\"master-trimmed\"", updated: updated))
            } else {
                #expect(result.confirmedMasterVersion == nil, "\(kind) must not gain authority in the Live mapping")
            }
            #expect(RecurringRemovalFixture.writes(http).map(\.method) == ["PATCH"])
        }
    }

    @Test func occurrenceServerVersionsMapUnchangedThroughFullAndDeltaReads() async throws {
        for kind in ["confirmed", "missing-time", "invalid-time"] {
            let http = FakeHTTPTransport()
            var occurrence = RecurringRemovalFixture.wire("selected")
            occurrence["etag"] = "\"extension-v2\""
            if kind != "missing-time" { occurrence["updated"] = kind == "confirmed" ? "2026-10-26T12:02:00Z" : "invalid" }
            let page = FakeHTTPTransport.json(200, ["items": [occurrence], "nextSyncToken": "after-extension"])
            http.on("GET", RecurringRemovalFixture.path) { _ in page }
            let provider = RecurringRemovalFixture.provider(http)
            let full = try await provider.eventWindow(from: RecurringRemovalFixture.original.addingTimeInterval(-7 * 86_400),
                to: RecurringRemovalFixture.original.addingTimeInterval(86_400))
            let delta = try await provider.eventDelta(since: "before-extension")
            #expect(full.isComplete && full.records.count == 1 && delta.changed.count == 1)
            for record in full.records + delta.changed {
                #expect(record.event.id == "selected" && record.etag == "\"extension-v2\"")
                #expect(record.recurringEventID == "master" && record.event.recurringEventID == "master")
                #expect(record.event.originalStartTime == .timed(RecurringRemovalFixture.original, timeZone: "America/Los_Angeles"))
                if kind == "confirmed" {
                    #expect(record.updated == ISO8601DateFormatter().date(from: "2026-10-26T12:02:00Z"))
                } else { #expect(record.updated == nil) }
            }
            #expect(RecurringRemovalFixture.writes(http).isEmpty)
        }
    }

    @Test func aSelectedMasterCannotBeDeletedAsOneOccurrence() async {
        let http = FakeHTTPTransport()
        RecurringRemovalFixture.serve(http)
        let master = FakeHTTPTransport.json(200, RecurringRemovalFixture.wire("selected", master: true))
        http.on("GET", RecurringRemovalFixture.path + "/selected") { _ in master }
        let source = CalendarEvent(id: "selected", title: "Planning", start: RecurringRemovalFixture.original,
                                   end: RecurringRemovalFixture.original.addingTimeInterval(3600), organizerIsMe: true)
        await #expect(throws: CalendarError.self) {
            _ = try await RecurringRemovalFixture.provider(http).removeEvent(source, scope: .thisEvent, sendUpdates: .all)
        }
        #expect(RecurringRemovalFixture.writes(http).isEmpty)
    }

    @Test func failedPreflightIsNeverReportedAsSuccessfulRemoval() async {
        for status in [404, 403] {
            let http = FakeHTTPTransport()
            RecurringRemovalFixture.serve(http)
            http.on("GET", RecurringRemovalFixture.path + "/master") { _ in HTTPResponse(status: status, headers: [:], body: Data()) }
            await #expect(throws: CalendarError.self) {
                _ = try await RecurringRemovalFixture.provider(http).removeEvent(RecurringRemovalFixture.selected,
                    scope: .allEvents, sendUpdates: .all)
            }
            #expect(RecurringRemovalFixture.writes(http).isEmpty)
        }
    }

    @Test func earlierDetachedExceptionRefusesAndLaterCleanupFailureReportsUncertainty() async throws {
        let earlier = FakeHTTPTransport()
        RecurringRemovalFixture.serve(earlier, exceptions: [RecurringRemovalFixture.wire("earlier", original: "2026-10-25T16:00:00Z")])
        await #expect(throws: CalendarError.self) {
            _ = try await RecurringRemovalFixture.provider(earlier).removeEvent(RecurringRemovalFixture.selected,
                scope: .thisAndFollowing, sendUpdates: .all)
        }
        #expect(RecurringRemovalFixture.writes(earlier).isEmpty)
        let later = FakeHTTPTransport()
        let exception = RecurringRemovalFixture.wire("later", original: "2026-11-08T17:00:00Z")
        RecurringRemovalFixture.serve(later, exceptions: [exception])
        let fresh = FakeHTTPTransport.json(200, exception)
        later.on("GET", RecurringRemovalFixture.path + "/later") { _ in fresh }
        var trimmed = RecurringRemovalFixture.wire("master", master: true)
        trimmed["etag"] = "\"master-trimmed\""
        trimmed["updated"] = "2026-10-26T12:01:00Z"
        trimmed["recurrence"] = ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"]
        let confirmed = FakeHTTPTransport.json(200, trimmed)
        later.on("PATCH", RecurringRemovalFixture.path) { _ in confirmed }
        later.on("DELETE", RecurringRemovalFixture.path + "/later") { _ in HTTPResponse(status: 503, headers: [:], body: Data()) }
        do {
            _ = try await RecurringRemovalFixture.provider(later).removeEvent(RecurringRemovalFixture.selected,
                scope: .thisAndFollowing, sendUpdates: .all)
            Issue.record("Partial cleanup must not return a confirmed result")
        } catch CalendarError.unclear(let why) {
            #expect(why.contains("some exceptions may remain"))
        }
        #expect(RecurringRemovalFixture.writes(later).map(\.method) == ["PATCH", "DELETE"])
    }

    @Test func aFreshGuardVersionChangeRefusesWithoutWriting() async {
        let http = FakeHTTPTransport()
        RecurringRemovalFixture.serve(http)
        let reads = Mutex(0)
        http.on("GET", RecurringRemovalFixture.path + "/master") { _ in
            let version = reads.withLock { $0 += 1; return $0 }
            var master = RecurringRemovalFixture.wire("master", master: true)
            if version > 1 { master["etag"] = "\"changed\"" }
            return FakeHTTPTransport.json(200, master)
        }
        await #expect(throws: CalendarError.self) {
            _ = try await RecurringRemovalFixture.provider(http).removeEvent(RecurringRemovalFixture.selected,
                scope: .thisAndFollowing, sendUpdates: .all)
        }
        #expect(RecurringRemovalFixture.writes(http).isEmpty)
    }

    @Test func allDayTrimmingUsesFreshCalendarZoneAndPreservesDateIdentity() async throws {
        let http = FakeHTTPTransport()
        let selected: [String: Any] = ["id": "selected", "etag": "\"selected-v1\"", "organizer": ["self": true],
            "start": ["date": "2026-11-02"], "end": ["date": "2026-11-03"], "recurringEventId": "master",
            "originalStartTime": ["date": "2026-11-02"]]
        let master: [String: Any] = ["id": "master", "etag": "\"master-v1\"", "organizer": ["self": true],
            "start": ["date": "2026-10-30"], "end": ["date": "2026-10-31"], "recurrence": ["RRULE:FREQ=DAILY;COUNT=5"]]
        let selectedResponse = FakeHTTPTransport.json(200, selected)
        let masterResponse = FakeHTTPTransport.json(200, master)
        let calendarResponse = FakeHTTPTransport.json(200, ["id": "robin@example.com", "timeZone": "America/Los_Angeles"])
        http.on("GET", "/calendar/v3/calendars/robin@example.com") { _ in calendarResponse }
        http.on("GET", RecurringRemovalFixture.path) { _ in FakeHTTPTransport.json(200, ["items": []]) }
        http.on("GET", RecurringRemovalFixture.path + "/selected") { _ in selectedResponse }
        http.on("GET", RecurringRemovalFixture.path + "/master") { _ in masterResponse }
        http.on("PATCH", RecurringRemovalFixture.path) { _ in masterResponse }
        let result = try await RecurringRemovalFixture.provider(http).removeEvent(RecurringRemovalFixture.selected,
            scope: .thisAndFollowing, sendUpdates: .all)
        #expect(result.originalCutoff == .date("2026-11-02"))
        let write = try #require(RecurringRemovalFixture.writes(http).first)
        let data = try #require(write.body)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["recurrence"] as? [String] == ["RRULE:FREQ=DAILY;UNTIL=20261101"])
    }
}

@Suite struct GoogleCalendarInvitationRemovalProviderTests {
    private static func guestCopy(_ wire: [String: Any]) -> [String: Any] {
        var copy = wire
        copy["organizer"] = ["email": "sam@example.org"]
        copy["attendees"] = [["email": "sam@example.org", "organizer": true], ["email": "robin@example.com", "self": true]]
        return copy
    }

    private static func serveInvitation(_ http: FakeHTTPTransport) {
        RecurringRemovalFixture.serve(http)
        let selected = FakeHTTPTransport.json(200, guestCopy(RecurringRemovalFixture.wire("selected")))
        let master = FakeHTTPTransport.json(200, guestCopy(RecurringRemovalFixture.wire("master", master: true)))
        http.on("GET", RecurringRemovalFixture.path + "/selected") { _ in selected }
        http.on("GET", RecurringRemovalFixture.path + "/master") { _ in master }
    }

    private static var invitation: CalendarEvent {
        let start = RecurringRemovalFixture.original
        return CalendarEvent(id: "selected", title: "Planning", start: start, end: start.addingTimeInterval(3600),
            timeZone: "America/Los_Angeles", attendees: [EmailAddress(name: "Sam", email: "sam@example.org")],
            organizerIsMe: false, myResponse: .needsAction, recurringEventID: "master")
    }

    @Test func theGoogleProviderOffersRemovingInvitations() {
        let provider = RecurringRemovalFixture.provider(FakeHTTPTransport())
        #expect(provider.abilities.contains(.removeInvite) && provider.abilities.contains(.remove))
    }

    @Test func anInvitationCardTakesTheSilentGuestPathEvenWhenTheCallerAsksToNotify() async throws {
        for (scope, target) in [(CalendarRecurrenceScope.thisEvent, "selected"), (.allEvents, "master")] {
            let http = FakeHTTPTransport()
            Self.serveInvitation(http)
            let answer = try await RecurringRemovalFixture.provider(http).removeEvent(Self.invitation, scope: scope,
                                                                                       sendUpdates: .all)
            #expect(answer.selectedID == "selected" && answer.parentID == "master" && answer.scope == scope)
            let writes = RecurringRemovalFixture.writes(http)
            #expect(writes.map(\.method) == ["DELETE"])
            #expect(writes.first?.url.path(percentEncoded: false) == RecurringRemovalFixture.path + "/" + target)
            #expect(writes.first?.url.query == "sendUpdates=none")
        }
    }

    @Test func theFutureScopeAndAnOwnEventCardedAsAnInvitationRefuseWithoutWriting() async {
        let http = FakeHTTPTransport()
        Self.serveInvitation(http)
        await #expect(throws: CalendarError.self) {
            _ = try await RecurringRemovalFixture.provider(http).removeEvent(Self.invitation, scope: .thisAndFollowing,
                                                                             sendUpdates: .none)
        }
        let own = FakeHTTPTransport()
        RecurringRemovalFixture.serve(own)
        await #expect(throws: CalendarError.self, "the fresh event is the user's own, so the guest path refuses") {
            _ = try await RecurringRemovalFixture.provider(own).removeEvent(Self.invitation, scope: .thisEvent,
                                                                            sendUpdates: .none)
        }
        #expect(RecurringRemovalFixture.writes(http).isEmpty && RecurringRemovalFixture.writes(own).isEmpty)
    }
}
