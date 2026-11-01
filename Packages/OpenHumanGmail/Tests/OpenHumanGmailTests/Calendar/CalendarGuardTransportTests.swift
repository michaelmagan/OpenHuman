import Foundation
import OpenHumanCore
import Synchronization
import Testing
@testable import OpenHumanGmail

@Suite struct CalendarGuardTransportTests {
    private static let me = "robin@example.com"
    private static let base = "https://www.googleapis.com/calendar/v3"
    private static let events = base + "/calendars/robin@example.com/events"

    @Test func scopedRemovalAuthorizationIsOneUseAndBoundToTargetBodyNotificationsAndVersion() async throws {
        let wire = ScriptedTransport { request in
            if request.method == "GET" {
                return jsonResponse(200, ["id": "master", "etag": "\"v1\"", "organizer": ["self": true],
                    "recurrence": ["RRULE:FREQ=WEEKLY"],
                    "start": ["dateTime": "2026-10-25T16:00:00Z", "timeZone": "America/Los_Angeles"],
                    "end": ["dateTime": "2026-10-25T17:00:00Z", "timeZone": "America/Los_Angeles"]])
            }
            return HTTPResponse(status: 204, headers: [:], body: Data())
        }
        let calendar = CalendarGuardTransport(wrapping: wire, calendarID: Self.me,
            grantedScopes: CalendarScopes.request.write, verifiesOwnedEventRemoval: true)
        let body = insertBody(["recurrence": ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"]])
        func authorization() -> String {
            calendar.authorizeRemoval(CalendarRemovalAuthorization(method: "PATCH", target: "master", etag: "\"v1\"",
                parent: nil, original: nil, master: true, body: body, sendUpdates: "all", allowAbsentCleanup: false,
                trim: CalendarRemovalTrim(cutoff: .timed(ISO8601DateFormatter().date(from: "2026-11-01T17:00:00Z")!,
                    timeZone: "America/Los_Angeles"), timeZone: "America/Los_Angeles")))
        }
        for change in ["target", "body", "updates", "etag", "invented-token"] {
            let nonce = change == "invented-token" ? "not-registered" : authorization()
            let target = change == "target" ? "other" : "master"
            let updates = change == "updates" ? "none" : "all"
            let call = request("PATCH", Self.events + "/\(target)?sendUpdates=\(updates)",
                body: change == "body" ? insertBody(["summary": "Broader edit"]) : body,
                headers: [CalendarGuardTransport.scopedRemovalHeader: nonce, "If-Match": change == "etag" ? "\"v2\"" : "\"v1\""])
            await #expect(throws: TransportError.self) { _ = try await calendar.send(call) }
        }
        #expect(wire.requests.isEmpty, "an exact authorization is required before even the fresh read")
        let authorized = request("PATCH", Self.events + "/master?sendUpdates=all", body: body,
            headers: [CalendarGuardTransport.scopedRemovalHeader: authorization(), "If-Match": "\"v1\""])
        _ = try await calendar.send(authorized)
        #expect(wire.requests.map(\.method) == ["GET", "PATCH"])
        #expect(wire.requests.allSatisfy { $0.headers[CalendarGuardTransport.scopedRemovalHeader] == nil })
        #expect(wire.requests.last?.headers["If-Match"] == "\"v1\"")
        await #expect(throws: TransportError.self) { _ = try await calendar.send(authorized) }
        #expect(wire.requests.count == 2, "the authorization is consumed before dispatch and cannot be replayed")
    }

    @Test func aScopedMarkerCannotEnableRecurrenceThroughTheLegacyDeleteOrDetailEditMarker() async {
        let wire = ScriptedTransport()
        let calendar = CalendarGuardTransport(wrapping: wire, calendarID: Self.me,
            grantedScopes: CalendarScopes.request.write, verifiesOwnedEventRemoval: true)
        for marker in [CalendarGuardTransport.removalRuleHeader, CalendarGuardTransport.editRuleHeader] {
            let call = request("DELETE", Self.events + "/instance?sendUpdates=all", headers: [
                marker: "organizer", CalendarGuardTransport.scopedRemovalHeader: "not-registered", "If-Match": "\"v1\""])
            await #expect(throws: TransportError.self) { _ = try await calendar.send(call) }
        }
        #expect(wire.requests.isEmpty)
    }

    private func request(_ method: String, _ url: String, body: Data? = nil,
                         headers: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(method: method, url: URL(string: url)!, headers: headers, body: body)
    }

    private func guardFor(_ scopes: [String] = CalendarScopes.request.write, wire: ScriptedTransport = ScriptedTransport(),
                          clock: any OHClock = SystemClock()) -> CalendarGuardTransport {
        CalendarGuardTransport(wrapping: wire, calendarID: Self.me, grantedScopes: scopes, clock: clock)
    }

    private func numberingWire() -> ScriptedTransport {
        let next = Mutex(0)
        return ScriptedTransport { request in
            guard request.method == "POST" else { return HTTPResponse(status: 204, headers: [:], body: Data()) }
            let id = next.withLock { n -> String in
                n += 1
                return "ev\(n)"
            }
            return jsonResponse(200, ["id": id, "status": "confirmed"])
        }
    }

    private func insertBody(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func readsPassWithEitherGrant() {
        for scopes in [CalendarScopes.request.write, CalendarScopes.request.read] {
            let calendar = guardFor(scopes)
            #expect(calendar.refusalReason(for: request("GET", Self.events + "?timeMin=x&singleEvents=true")) == nil, "\(scopes)")
            #expect(calendar.refusalReason(for: request("POST", Self.base + "/freeBusy", body: Data("{}".utf8))) == nil,
                    "freebusy.query is a read sent as a POST")
        }
    }

    @Test func anInsertPassesOnlyWithCalendarEvents() {
        let insert = request("POST", Self.events + "?sendUpdates=none", body: Data("{}".utf8))
        #expect(guardFor().refusalReason(for: insert) == nil)
        #expect(guardFor().allowsWrites)
        #expect(!guardFor(CalendarScopes.request.read).allowsWrites)
        #expect(guardFor(CalendarScopes.request.read).refusalReason(for: insert) == "creating events needs calendar.events",
                "a read grant never creates events")
        #expect(guardFor().refusalReason(for: request("POST", Self.base + "/calendars/someone@example.com/events")) != nil,
                "only the account's own calendar")
    }

    @Test func onlyAnEventCreatedHereCanBeDeletedAndOnlyOnce() async throws {
        let wire = ScriptedTransport { request in
            request.method == "POST" ? jsonResponse(200, ["id": "ev1", "status": "confirmed"])
                                     : HTTPResponse(status: 204, headers: [:], body: Data())
        }
        let calendar = guardFor(wire: wire)
        let delete = request("DELETE", Self.events + "/ev1?sendUpdates=none")
        await #expect(throws: TransportError.refusedByGuard("DELETE /calendar/v3/calendars/<redacted>/events/ev1")) {
            _ = try await calendar.send(delete)
        }
        #expect(wire.requests.isEmpty, "refused before the wire")
        _ = try await calendar.send(request("POST", Self.events, body: Data("{}".utf8)))
        #expect(calendar.createdEventIDs == ["ev1"])
        _ = try await calendar.send(delete)
        #expect(wire.requests.map(\.method) == ["POST", "DELETE"])
        #expect(calendar.createdEventIDs.isEmpty)
        await #expect(throws: TransportError.self) { _ = try await calendar.send(delete) }
        #expect(wire.requests.count == 2, "a second delete of the same event is refused")
        #expect(guardFor(CalendarScopes.request.read).refusalReason(for: delete) != nil)
    }

    @Test func anEventCreatedWithAttendeesIsNeverDeleted() async throws {
        let wire = numberingWire()
        let calendar = guardFor(wire: wire)
        _ = try await calendar.send(request("POST", Self.events + "?sendUpdates=none",
                                            body: insertBody(["summary": "Lunch", "attendees": [["email": "alice@example.com"]]])))
        _ = try await calendar.send(request("POST", Self.events + "?sendUpdates=none", body: Data("not json".utf8)))
        #expect(calendar.createdEventIDs == ["ev1", "ev2"])
        for id in ["ev1", "ev2"] {
            let delete = request("DELETE", Self.events + "/\(id)?sendUpdates=none")
            #expect(calendar.refusalReason(for: delete) != nil, "\(id)")
            await #expect(throws: TransportError.self) { _ = try await calendar.send(delete) }
        }
        #expect(wire.requests.map(\.method) == ["POST", "POST"], "no delete reached the wire")
    }

    @Test func anAttendeeLessEventCanBeDeletedOnlyInsideTheUndoWindow() async throws {
        let wire = numberingWire()
        let clock = TestClock()
        let calendar = guardFor(wire: wire, clock: clock)
        let body = insertBody(["summary": "Focus", "attendees": [Any]()])
        _ = try await calendar.send(request("POST", Self.events, body: body))
        _ = try await calendar.send(request("POST", Self.events, body: insertBody(["summary": "Focus"])))
        clock.advance(by: .seconds(5))
        _ = try await calendar.send(request("DELETE", Self.events + "/ev1?sendUpdates=none"))
        #expect(wire.requests.last?.method == "DELETE", "inside the window: the undo's delete goes out")
        clock.advance(by: .seconds(55))
        let late = request("DELETE", Self.events + "/ev2?sendUpdates=none")
        #expect(calendar.refusalReason(for: late) != nil)
        await #expect(throws: TransportError.self) { _ = try await calendar.send(late) }
        #expect(wire.requests.filter { $0.method == "DELETE" }.count == 1, "a minute later: refused before the wire")
        #expect(CalendarGuardTransport.deleteWindow < 60)
    }

    @Test func everythingElseIsRefusedBeforeTheWire() async throws {
        let wire = ScriptedTransport()
        let calendar = guardFor(wire: wire)
        let refused: [HTTPRequest] = [
            request("GET", "https://gmail.googleapis.com/calendar/v3/calendars/robin@example.com/events"),
            request("GET", "http://www.googleapis.com/calendar/v3/calendars/robin@example.com/events"),
            request("GET", "https://www.googleapis.com:8443/calendar/v3/calendars/robin@example.com/events"),
            request("GET", "https://user@www.googleapis.com/calendar/v3/calendars/robin@example.com/events"),
            request("GET", "https://www.googleapis.com/gmail/v1/users/me/labels"),
            request("GET", Self.base + "/calendars/robin@example.com/../events"),
            request("POST", Self.base + "/calendars/robin@example.com/events/%2E%2E", body: Data("{}".utf8)),
            request("POST", Self.base + "/calendars/robin@example.com//events", body: Data("{}".utf8)),
            request("POST", Self.base + "/freeBusy/", body: Data("{}".utf8)),
            request("PUT", Self.events + "/ev1", body: Data("{}".utf8)),
            request("PATCH", Self.events + "/ev1", body: Data("{}".utf8)),
            request("POST", Self.events + "/ev1/move?destination=x"),
            request("POST", Self.events + "/import", body: Data("{}".utf8)),
            request("POST", Self.events + "/quickAdd?text=x"),
            request("POST", Self.events + "/watch", body: Data("{}".utf8)),
            request("POST", Self.base + "/calendars/robin@example.com/clear"),
            request("DELETE", Self.base + "/calendars/robin@example.com"),
            request("POST", Self.base + "/calendars", body: Data("{}".utf8)),
            request("POST", Self.base + "/users/me/calendarList", body: Data("{}".utf8)),
            request("DELETE", Self.base + "/users/me/calendarList/robin@example.com"),
            request("POST", Self.base + "/calendars/robin@example.com/acl", body: Data("{}".utf8)),
            request("PUT", Self.base + "/users/me/settings/timezone", body: Data("{}".utf8)),
            request("POST", Self.base + "/freeBusy", body: Data("{}".utf8), headers: ["X-HTTP-Method-Override": "DELETE"]),
            request("GET", Self.events + "?$httpMethod=DELETE"),
            request("GET", Self.events, body: Data("{}".utf8)),
            request("get", Self.events),
        ]
        for request in refused {
            #expect(calendar.refusalReason(for: request) != nil, "\(request.method) \(request.url.absoluteString)")
            await #expect(throws: TransportError.self) { _ = try await calendar.send(request) }
        }
        #expect(wire.requests.isEmpty, "nothing refused reached the wire")
    }

    @Test func theRefusalNamesNoAddress() async throws {
        let calendar = guardFor(CalendarScopes.request.read)
        do {
            _ = try await calendar.send(request("POST", Self.events, body: Data("{}".utf8)))
            Issue.record("an insert passed with a read grant")
        } catch TransportError.refusedByGuard(let summary) {
            #expect(summary == "POST /calendar/v3/calendars/<redacted>/events")
            #expect(!summary.contains("@") && !summary.contains("example"))
        }
    }
}
