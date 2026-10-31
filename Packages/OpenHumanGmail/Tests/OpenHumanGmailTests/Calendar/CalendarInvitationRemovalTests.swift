import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Synchronization
import Testing
@testable import OpenHumanGmail

private enum InviteWire {
    static let calendar = "robin@example.com"
    static let path = "/calendar/v3/calendars/robin@example.com/events"
    static let zone = "America/Los_Angeles"
    static let first = "2026-10-25T16:00:00Z"
    static let middle = "2026-11-01T17:00:00Z"

    static func event(_ id: String, original: String? = nil, rules: [String]? = nil,
                      organizer: [String: Any] = ["email": "sam@example.com"]) -> [String: Any] {
        let time = original ?? first
        let end = ISO8601DateFormatter().string(from: ISO8601DateFormatter().date(from: time)!.addingTimeInterval(1800))
        var value: [String: Any] = ["id": id, "etag": "\"v-\(id)\"", "status": "confirmed", "eventType": "default",
            "summary": "Supplier sync", "organizer": organizer,
            "attendees": [["email": "sam@example.com", "organizer": true, "responseStatus": "accepted"],
                          ["email": calendar, "self": true, "responseStatus": "needsAction"]],
            "start": ["dateTime": time, "timeZone": zone], "end": ["dateTime": end, "timeZone": zone]]
        if let original {
            value["recurringEventId"] = "parent"
            value["originalStartTime"] = ["dateTime": original, "timeZone": zone]
        }
        if let rules { value["recurrence"] = rules }
        return value
    }

    static func client(_ http: FakeHTTPTransport, writes: Bool = true) -> GoogleCalendarClient {
        GoogleCalendarClient(calendarID: calendar,
            grantedScopes: writes ? CalendarScopes.request.write : CalendarScopes.request.read,
            tokens: StaticTokenProvider(token: "synthetic-calendar-token"), transport: http,
            clock: InstantClock(), timeZone: TimeZone(identifier: zone)!)
    }

    static func serve(_ http: FakeHTTPTransport, selected: [String: Any] = event("selected", original: middle),
                      master: [String: Any] = event("parent", rules: ["RRULE:FREQ=WEEKLY;COUNT=3"]),
                      single: [String: Any] = event("single")) {
        let masterAnswer = FakeHTTPTransport.json(200, master)
        let selectedAnswer = FakeHTTPTransport.json(200, selected)
        let singleAnswer = FakeHTTPTransport.json(200, single)
        http.on("GET", path + "/parent") { _ in masterAnswer }
        http.on("GET", path + "/selected") { _ in selectedAnswer }
        http.on("GET", path + "/single") { _ in singleAnswer }
        http.on("DELETE", path) { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
    }

    static func writes(_ http: FakeHTTPTransport) -> [HTTPRequest] { http.requests.filter { $0.method != "GET" } }
}

private final class ReadCount: Sendable {
    private let value = Mutex(0)

    func next() -> Int {
        value.withLock { count in
            count += 1
            return count
        }
    }

    var count: Int { value.withLock { $0 } }
}

@Suite struct GoogleCalendarInvitationRemovalTests {
    @Test func aSingleInvitationLeavesThisCalendarSilentlyWithAConditionalDelete() async throws {
        let http = FakeHTTPTransport()
        InviteWire.serve(http)
        let result = try await InviteWire.client(http).removeInvitation(id: "single", expectedParent: nil,
                                                                         expectedOriginal: nil, scope: .thisEvent)
        #expect(result.selectedID == "single" && result.parentID == nil && result.confirmedMasterVersion == nil)
        let writes = InviteWire.writes(http)
        #expect(writes.count == 1 && writes[0].method == "DELETE")
        #expect(writes[0].url.path(percentEncoded: false) == InviteWire.path + "/single")
        #expect(writes[0].url.query == "sendUpdates=none", "no one is emailed about a guest's removal")
        #expect(writes[0].headers["If-Match"] == "\"v-single\"")
        #expect(writes[0].body == nil)
        #expect(http.requests.allSatisfy { $0.headers[CalendarGuardTransport.scopedRemovalHeader] == nil })
        #expect(!http.requests.contains { $0.method == "PATCH" }, "removing never answers the invitation")
    }

    @Test func aRepeatingInvitationRemovesOneOccurrenceOrTheWholeSeriesCopy() async throws {
        for (scope, target) in [(GoogleRemovalScope.thisEvent, "selected"), (.allEvents, "parent")] {
            let http = FakeHTTPTransport()
            InviteWire.serve(http)
            let result = try await InviteWire.client(http).removeInvitation(id: "selected", expectedParent: "parent",
                                                                             expectedOriginal: nil, scope: scope)
            #expect(result.selectedID == "selected" && result.parentID == "parent")
            let writes = InviteWire.writes(http)
            #expect(writes.map(\.method) == ["DELETE"], "\(scope)")
            #expect(writes.first?.url.path(percentEncoded: false) == InviteWire.path + "/" + target)
            #expect(writes.first?.url.query == "sendUpdates=none")
            #expect(writes.first?.headers["If-Match"] == "\"v-\(target)\"")
        }
        let http = FakeHTTPTransport()
        InviteWire.serve(http)
        _ = try await InviteWire.client(http).removeInvitation(id: "parent", expectedParent: nil, expectedOriginal: nil,
                                                               scope: .allEvents)
        #expect(InviteWire.writes(http).map { $0.url.path(percentEncoded: false) } == [InviteWire.path + "/parent"])
    }

    @Test func onlyTheOrganizerCanEndASeriesEarlySoNothingIsReadOrWritten() async {
        let http = FakeHTTPTransport()
        InviteWire.serve(http)
        await #expect(throws: GoogleCalendarRemovalError.self) {
            _ = try await InviteWire.client(http).removeInvitation(id: "selected", expectedParent: "parent",
                                                                   expectedOriginal: nil, scope: .thisAndFollowing)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func anOwnSpecialUnorganizedReadOnlyOrChangedEventIsNeverRemovedAsAGuest() async {
        let cases: [(String, [String: Any])] = [
            ("organizer self", InviteWire.event("single", organizer: ["self": true, "email": InviteWire.calendar])),
            ("organizer is this calendar", InviteWire.event("single", organizer: ["email": "Robin@Example.com"])),
            ("no organizer email", InviteWire.event("single", organizer: ["self": false])),
            ("special", InviteWire.event("single").merging(["eventType": "focusTime"]) { $1 }),
            ("cancelled", InviteWire.event("single").merging(["status": "cancelled"]) { $1 }),
            ("no etag", InviteWire.event("single").filter { $0.key != "etag" }),
            ("read only", InviteWire.event("single"))]
        for (name, single) in cases {
            let http = FakeHTTPTransport()
            InviteWire.serve(http, single: single)
            await #expect(throws: (any Error).self, "\(name)") {
                _ = try await InviteWire.client(http, writes: name != "read only").removeInvitation(id: "single",
                    expectedParent: nil, expectedOriginal: nil, scope: .thisEvent)
            }
            #expect(InviteWire.writes(http).isEmpty, "\(name) refuses before any write")
        }
    }

    @Test func aMasterOrAnUnrelatedSeriesIsNeverTheTargetOfThisEvent() async {
        let http = FakeHTTPTransport()
        InviteWire.serve(http)
        await #expect(throws: GoogleCalendarRemovalError.self) {
            _ = try await InviteWire.client(http).removeInvitation(id: "parent", expectedParent: nil, expectedOriginal: nil,
                                                                   scope: .thisEvent)
        }
        await #expect(throws: GoogleCalendarRemovalError.self) {
            _ = try await InviteWire.client(http).removeInvitation(id: "selected", expectedParent: "another-series",
                                                                   expectedOriginal: nil, scope: .allEvents)
        }
        #expect(InviteWire.writes(http).isEmpty)
    }

    @Test func theSeriesMustAlsoBeSomeoneElsesBeforeAllEventsLeave() async {
        let http = FakeHTTPTransport()
        InviteWire.serve(http, master: InviteWire.event("parent", rules: ["RRULE:FREQ=WEEKLY"],
                                                        organizer: ["self": true, "email": InviteWire.calendar]))
        await #expect(throws: GoogleCalendarRemovalError.self) {
            _ = try await InviteWire.client(http).removeInvitation(id: "selected", expectedParent: "parent",
                                                                   expectedOriginal: nil, scope: .allEvents)
        }
        #expect(InviteWire.writes(http).isEmpty)
    }

    @Test func theGuardRereadsTheCopyAndRefusesWhenItBecameTheUsersOwn() async {
        let http = FakeHTTPTransport()
        InviteWire.serve(http)
        let reads = ReadCount()
        let guest = FakeHTTPTransport.json(200, InviteWire.event("single"))
        let owned = FakeHTTPTransport.json(200, InviteWire.event("single", organizer: ["self": true]))
        http.on("GET", InviteWire.path + "/single") { _ in reads.next() == 1 ? guest : owned }
        await #expect(throws: (any Error).self) {
            _ = try await InviteWire.client(http).removeInvitation(id: "single", expectedParent: nil, expectedOriginal: nil,
                                                                   scope: .thisEvent)
        }
        #expect(reads.count == 2, "the preflight read, then the guard's own read")
        #expect(InviteWire.writes(http).isEmpty)
    }

    @Test func aGuestAuthorizationCannotNotifyPatchOrCleanUp() async throws {
        let shapes: [(method: String, sendUpdates: String, body: Data?, cleanup: Bool)] = [
            ("DELETE", "all", nil, false), ("DELETE", "externalOnly", nil, false),
            ("PATCH", "none", Data(#"{"recurrence":["RRULE:FREQ=DAILY"]}"#.utf8), false), ("DELETE", "none", nil, true)]
        for shape in shapes {
            let http = FakeHTTPTransport()
            InviteWire.serve(http)
            let guarded = CalendarGuardTransport(wrapping: http, calendarID: InviteWire.calendar,
                                                 grantedScopes: CalendarScopes.request.write,
                                                 verifiesOwnedEventRemoval: true)
            let nonce = guarded.authorizeRemoval(CalendarRemovalAuthorization(method: shape.method, target: "single",
                etag: "\"v-single\"", parent: nil, original: nil, master: false, body: shape.body,
                sendUpdates: shape.sendUpdates, allowAbsentCleanup: shape.cleanup, asGuest: true))
            let url = try #require(URL(string: "https://www.googleapis.com\(InviteWire.path)/single?sendUpdates=\(shape.sendUpdates)"))
            let request = HTTPRequest(method: shape.method, url: url,
                                      headers: [CalendarGuardTransport.scopedRemovalHeader: nonce, "If-Match": "\"v-single\""],
                                      body: shape.body)
            await #expect(throws: TransportError.self, "\(shape.method) \(shape.sendUpdates)") {
                _ = try await guarded.send(request)
            }
            #expect(InviteWire.writes(http).isEmpty)
        }
    }

    @Test func aSilentDeleteStillNeedsTheGuestAuthorizationToPass() async throws {
        let http = FakeHTTPTransport()
        InviteWire.serve(http)
        let guarded = CalendarGuardTransport(wrapping: http, calendarID: InviteWire.calendar,
                                             grantedScopes: CalendarScopes.request.write, verifiesOwnedEventRemoval: true)
        let nonce = guarded.authorizeRemoval(CalendarRemovalAuthorization(method: "DELETE", target: "single",
            etag: "\"v-single\"", parent: nil, original: nil, master: false, body: nil, sendUpdates: "none",
            allowAbsentCleanup: false))
        let url = try #require(URL(string: "https://www.googleapis.com\(InviteWire.path)/single?sendUpdates=none"))
        await #expect(throws: TransportError.self, "an organizer authorization does not cover someone else's event") {
            _ = try await guarded.send(HTTPRequest(method: "DELETE", url: url,
                headers: [CalendarGuardTransport.scopedRemovalHeader: nonce, "If-Match": "\"v-single\""], body: nil))
        }
        #expect(InviteWire.writes(http).isEmpty)
    }
}
