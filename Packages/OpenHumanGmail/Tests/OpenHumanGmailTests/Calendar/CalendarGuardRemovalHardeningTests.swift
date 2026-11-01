import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

private enum GuardWire {
    static let calendar = "robin@example.com"
    static let path = "/calendar/v3/calendars/robin@example.com/events"
    static let zone = "America/Los_Angeles"
    static let first = "2026-10-25T16:00:00Z"
    static let middle = "2026-11-01T17:00:00Z"
    static let last = "2026-11-08T17:00:00Z"
    static var guests: [[String: Any]] {
        [["email": calendar, "self": true, "organizer": true, "responseStatus": "accepted"],
         ["email": "sam@example.com", "responseStatus": "accepted"]]
    }

    static func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    static func event(_ id: String, rules: [String]? = nil, attendees: [[String: Any]]? = nil,
                      organizer: [String: Any] = ["self": true]) -> [String: Any] {
        var value: [String: Any] = ["id": id, "etag": "\"v-\(id)\"", "status": "confirmed", "eventType": "default",
            "summary": "Planning", "organizer": organizer,
            "start": ["dateTime": first, "timeZone": zone],
            "end": ["dateTime": "2026-10-25T16:30:00Z", "timeZone": zone]]
        if let rules { value["recurrence"] = rules }
        if let attendees { value["attendees"] = attendees }
        return value
    }

    static func serve(_ http: FakeHTTPTransport, _ event: [String: Any]) {
        let id = event["id"] as! String
        let answer = FakeHTTPTransport.json(200, event)
        http.on("GET", path + "/" + id) { _ in answer }
        http.on("DELETE", path) { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
        http.on("PATCH", path) { _ in answer }
    }

    static func guarded(_ http: FakeHTTPTransport) -> CalendarGuardTransport {
        CalendarGuardTransport(wrapping: http, calendarID: calendar, grantedScopes: CalendarScopes.request.write,
                               verifiesOwnedEventRemoval: true)
    }

    static func trim(_ cutoff: String = middle) -> CalendarRemovalTrim {
        CalendarRemovalTrim(cutoff: .timed(instant(cutoff), timeZone: zone), timeZone: zone)
    }

    static func rules(_ lines: [String]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["recurrence": lines])
    }

    /// Registers the one-use pass exactly as the client would, then sends the request it covers.
    @discardableResult
    static func send(_ guarded: CalendarGuardTransport, method: String = "DELETE", target: String, sendUpdates: String,
                     body: Data? = nil, master: Bool = false, asGuest: Bool = false, trim: CalendarRemovalTrim? = nil,
                     url: String? = nil, headers extra: [String: String] = [:]) async throws -> HTTPResponse {
        let nonce = guarded.authorizeRemoval(CalendarRemovalAuthorization(method: method, target: target,
            etag: "\"v-\(target)\"", parent: nil, original: nil, master: master, body: body, sendUpdates: sendUpdates,
            allowAbsentCleanup: false, asGuest: asGuest, trim: trim))
        let address = url ?? "https://www.googleapis.com\(path)/\(target)?sendUpdates=\(sendUpdates)"
        var headers = [CalendarGuardTransport.scopedRemovalHeader: nonce, "If-Match": "\"v-\(target)\""]
        headers.merge(extra) { _, new in new }
        return try await guarded.send(HTTPRequest(method: method, url: URL(string: address)!, headers: headers, body: body))
    }

    static func writes(_ http: FakeHTTPTransport) -> [HTTPRequest] { http.requests.filter { $0.method != "GET" } }
}

@Suite struct CalendarGuardRemovalHardeningTests {
    @Test func anOrganizedEventWithGuestsIsRefusedWhenThePassTellsNobody() async {
        let lists: [(String, [String: Any])] = [
            ("a guest", GuardWire.event("single", attendees: GuardWire.guests)),
            ("a guest with no address", GuardWire.event("single", attendees: [["responseStatus": "accepted"]])),
            ("a shortened guest list", {
                var event = GuardWire.event("single", attendees: [["email": GuardWire.calendar, "self": true]])
                event["attendeesOmitted"] = true
                return event
            }()),
            ("an organizer known only by address", GuardWire.event("single", attendees: GuardWire.guests,
                                                                  organizer: ["email": GuardWire.calendar]))]
        for (name, event) in lists {
            let http = FakeHTTPTransport()
            GuardWire.serve(http, event)
            await #expect(throws: TransportError.self, "\(name)") {
                _ = try await GuardWire.send(GuardWire.guarded(http), target: "single", sendUpdates: "none")
            }
            #expect(GuardWire.writes(http).isEmpty, "\(name): the guard's own read found guests, so nothing was deleted")
            #expect(http.requests.map(\.method) == ["GET"], "\(name)")
        }
    }

    @Test func ownEventsWithoutGuestsAndToldGuestsStillLeave() async throws {
        let cases: [(String, [String: Any], String)] = [
            ("no attendees", GuardWire.event("single"), "none"),
            ("only the calendar and a room", GuardWire.event("single", attendees: [
                ["email": "Robin@Example.com", "responseStatus": "accepted"],
                ["email": "room-4@resource.example.com", "resource": true]]), "none"),
            ("guests told", GuardWire.event("single", attendees: GuardWire.guests), "all"),
            ("outside guests told", GuardWire.event("single", attendees: GuardWire.guests), "externalOnly")]
        for (name, event, updates) in cases {
            let http = FakeHTTPTransport()
            GuardWire.serve(http, event)
            let response = try await GuardWire.send(GuardWire.guarded(http), target: "single", sendUpdates: updates)
            #expect(response.status == 204, "\(name)")
            let writes = GuardWire.writes(http)
            #expect(writes.count == 1 && writes[0].method == "DELETE", "\(name)")
            #expect(writes.first?.url.query == "sendUpdates=\(updates)", "\(name)")
            #expect(writes.allSatisfy { $0.headers[CalendarGuardTransport.scopedRemovalHeader] == nil })
        }
    }

    @Test func aGuestStillRemovesItsInvitedCopySilently() async throws {
        let http = FakeHTTPTransport()
        GuardWire.serve(http, GuardWire.event("single", attendees: [
            ["email": "sam@example.com", "organizer": true, "responseStatus": "accepted"],
            ["email": GuardWire.calendar, "self": true, "responseStatus": "needsAction"]],
            organizer: ["email": "sam@example.com"]))
        _ = try await GuardWire.send(GuardWire.guarded(http), target: "single", sendUpdates: "none", asGuest: true)
        #expect(GuardWire.writes(http).map(\.method) == ["DELETE"])
        #expect(GuardWire.writes(http).first?.url.query == "sendUpdates=none")
    }

    @Test func aTrimThatIsThePlanForTheFreshReadIsForwarded() async throws {
        let cases: [([String], String, [String])] = [
            (["RRULE:FREQ=WEEKLY;COUNT=3"], GuardWire.middle, ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"]),
            (["RRULE:FREQ=WEEKLY"], GuardWire.middle, ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"]),
            (["RRULE:FREQ=WEEKLY", "EXDATE:20261101T170000Z"], GuardWire.last,
             ["RRULE:FREQ=WEEKLY;UNTIL=20261108T165959Z", "EXDATE:20261101T170000Z"])]
        for (current, cutoff, trimmed) in cases {
            let http = FakeHTTPTransport()
            GuardWire.serve(http, GuardWire.event("parent", rules: current, attendees: GuardWire.guests))
            let body = GuardWire.rules(trimmed)
            _ = try await GuardWire.send(GuardWire.guarded(http), method: "PATCH", target: "parent", sendUpdates: "all",
                                         body: body, master: true, trim: GuardWire.trim(cutoff))
            #expect(GuardWire.writes(http).map(\.method) == ["PATCH"], "\(current)")
            #expect(GuardWire.writes(http).first?.body == body)
        }
    }

    @Test func aTrimThatKeepsMoreChangesTheRuleOrIsNotThePlanIsRefused() async {
        let weekly = ["RRULE:FREQ=WEEKLY;COUNT=3"]
        let cases: [(String, [String], [String], String)] = [
            ("more occurrences", weekly, ["RRULE:FREQ=WEEKLY;COUNT=5"], GuardWire.middle),
            ("a later end", weekly, ["RRULE:FREQ=WEEKLY;UNTIL=20271101T165959Z"], GuardWire.middle),
            ("no end", weekly, ["RRULE:FREQ=WEEKLY"], GuardWire.middle),
            ("the same rules", weekly, weekly, GuardWire.middle),
            ("another rule", weekly, ["RRULE:FREQ=DAILY;UNTIL=20261101T165959Z"], GuardWire.middle),
            ("a dropped interval", ["RRULE:FREQ=WEEKLY;INTERVAL=2"], ["RRULE:FREQ=WEEKLY;UNTIL=20261108T165959Z"],
             GuardWire.last),
            ("an added date", weekly, ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z", "RDATE:20261027T160000Z"],
             GuardWire.middle),
            ("an added rule line", weekly, ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z", "EXRULE:FREQ=DAILY"],
             GuardWire.middle),
            ("two rules", weekly, ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z", "RRULE:FREQ=DAILY;COUNT=2"],
             GuardWire.middle),
            ("a removed exclusion", ["RRULE:FREQ=WEEKLY", "EXDATE:20261101T170000Z"],
             ["RRULE:FREQ=WEEKLY;UNTIL=20261108T165959Z"], GuardWire.last),
            ("an end that is not the plan", weekly, ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"], GuardWire.last),
            ("an end before the series", weekly, ["RRULE:FREQ=WEEKLY;UNTIL=20261001T000000Z"], GuardWire.middle)]
        for (name, current, trimmed, cutoff) in cases {
            let http = FakeHTTPTransport()
            GuardWire.serve(http, GuardWire.event("parent", rules: current))
            await #expect(throws: TransportError.self, "\(name)") {
                _ = try await GuardWire.send(GuardWire.guarded(http), method: "PATCH", target: "parent", sendUpdates: "all",
                                         body: GuardWire.rules(trimmed), master: true, trim: GuardWire.trim(cutoff))
            }
            #expect(GuardWire.writes(http).isEmpty, "\(name) never reached Google")
        }
    }

    @Test func anEmptyMalformedOrUnplannedTrimIsRefusedBeforeTheRead() async {
        let bodies: [(String, Data, CalendarRemovalTrim?)] = [
            ("an empty list", GuardWire.rules([]), GuardWire.trim()),
            ("no list", Data(#"{"recurrence":null}"#.utf8), GuardWire.trim()),
            ("another field", Data(#"{"recurrence":["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"],"summary":"x"}"#.utf8),
             GuardWire.trim()),
            ("no trim details", GuardWire.rules(["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"]), nil)]
        for (name, body, trim) in bodies {
            let http = FakeHTTPTransport()
            GuardWire.serve(http, GuardWire.event("parent", rules: ["RRULE:FREQ=WEEKLY;COUNT=3"]))
            await #expect(throws: TransportError.self, "\(name)") {
                _ = try await GuardWire.send(GuardWire.guarded(http), method: "PATCH", target: "parent", sendUpdates: "all",
                                         body: body, master: true, trim: trim)
            }
            #expect(http.requests.isEmpty, "\(name)")
        }
    }

    @Test func methodOverridesAndPathTricksAreStillRefusedBeforeTheWire() async {
        let base = "https://www.googleapis.com/calendar/v3/calendars/robin@example.com"
        let addresses = [
            base + "/events/../events/single?sendUpdates=all",
            base + "/events/%2E%2E/events/single?sendUpdates=all",
            base + "/events/single/../single?sendUpdates=all",
            base + "/events/x%2Fsingle?sendUpdates=all",
            base + "/events//single?sendUpdates=all",
            "https://www.googleapis.com/calendar/v3/calendars/other@example.com/events/single?sendUpdates=all",
            base + "/events/single?sendUpdates=all&_method=PATCH",
            "http://www.googleapis.com/calendar/v3/calendars/robin@example.com/events/single?sendUpdates=all",
            "https://user@www.googleapis.com/calendar/v3/calendars/robin@example.com/events/single?sendUpdates=all"]
        for address in addresses {
            let http = FakeHTTPTransport()
            GuardWire.serve(http, GuardWire.event("single"))
            await #expect(throws: TransportError.self, "\(address)") {
                _ = try await GuardWire.send(GuardWire.guarded(http), target: "single", sendUpdates: "all", url: address)
            }
            #expect(http.requests.isEmpty, "\(address)")
        }
        for header in ["X-HTTP-Method-Override", "x-http-method", "X-Method-Override"] {
            let http = FakeHTTPTransport()
            GuardWire.serve(http, GuardWire.event("single"))
            await #expect(throws: TransportError.self, "\(header)") {
                _ = try await GuardWire.send(GuardWire.guarded(http), target: "single", sendUpdates: "all",
                                         headers: [header: "PATCH"])
            }
            #expect(http.requests.isEmpty, "\(header)")
        }
    }
}

@Suite struct GoogleRemovalPrefixNarrowingTests {
    @Test func earlierEndsDroppedDatesAndLaterExclusionsNarrow() {
        let narrower: [([String], [String])] = [
            (["RRULE:FREQ=WEEKLY"], ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"]),
            (["RRULE:FREQ=WEEKLY;COUNT=3"], ["RRULE:FREQ=WEEKLY;COUNT=2"]),
            (["RRULE:FREQ=WEEKLY"], ["RRULE:FREQ=WEEKLY;COUNT=2"]),
            (["RRULE:FREQ=WEEKLY;UNTIL=20261201T000000Z"], ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"]),
            (["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261201T000000Z"], ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261101T165959Z"]),
            (["RRULE:FREQ=WEEKLY;UNTIL=20261025T160000Z", "RDATE:20261026T160000Z,20261101T170000Z,20261108T170000Z",
              "EXDATE:20261026T160000Z,20261108T170000Z"],
             ["RRULE:FREQ=WEEKLY;UNTIL=20261025T160000Z", "RDATE:20261026T160000Z", "EXDATE:20261026T160000Z"]),
            (["RRULE:FREQ=DAILY", "EXDATE;VALUE=DATE:20261030,20261104"],
             ["RRULE:FREQ=DAILY;UNTIL=20261101", "EXDATE;VALUE=DATE:20261030"]),
            (["RRULE:FREQ=WEEKLY", "EXDATE;TZID=America/Los_Angeles:20261026T090000,20261108T090000"],
             ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z", "EXDATE;TZID=America/Los_Angeles:20261026T090000"]),
            // Narrowing only: the guard also requires this to equal the plan for the same read.
            (["RRULE:FREQ=WEEKLY;COUNT=3"], ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"])]
        for (current, proposed) in narrower {
            #expect(GoogleRemovalPrefix.narrows(current, to: proposed), "\(current) -> \(proposed)")
        }
    }

    @Test func widerChangedEmptyOrUnreadableRulesDoNotNarrow() {
        let refused: [([String], [String])] = [
            (["RRULE:FREQ=WEEKLY;COUNT=3"], ["RRULE:FREQ=WEEKLY;COUNT=3"]),
            (["RRULE:FREQ=WEEKLY;COUNT=3"], ["RRULE:FREQ=WEEKLY;COUNT=4"]),
            (["RRULE:FREQ=WEEKLY;COUNT=3"], ["RRULE:FREQ=WEEKLY"]),
            (["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"], ["RRULE:FREQ=WEEKLY;UNTIL=20271101T165959Z"]),
            (["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"], ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"]),
            (["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"], ["RRULE:FREQ=WEEKLY;UNTIL=20261031"]),
            (["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"], ["RRULE:FREQ=WEEKLY;COUNT=1"]),
            (["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"], ["RRULE:FREQ=WEEKLY;UNTIL=not-a-date"]),
            (["RRULE:FREQ=WEEKLY"], ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z;COUNT=2"]),
            (["RRULE:FREQ=WEEKLY"], ["RRULE:FREQ=WEEKLY;COUNT=0"]),
            (["RRULE:FREQ=WEEKLY"], ["RRULE:FREQ=DAILY;UNTIL=20261101T165959Z"]),
            (["RRULE:FREQ=WEEKLY;INTERVAL=2"], ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"]),
            (["RRULE:FREQ=WEEKLY;BYDAY=MO"], ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU;UNTIL=20261101T165959Z"]),
            (["RRULE:FREQ=WEEKLY"], []),
            ([], ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"]),
            (["RRULE:FREQ=WEEKLY"], ["RRULE:"]),
            (["RRULE:FREQ=WEEKLY"], ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z", "RRULE:FREQ=DAILY;COUNT=2"]),
            (["RRULE:FREQ=WEEKLY"], ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z", "EXRULE:FREQ=DAILY"]),
            (["RRULE:FREQ=WEEKLY"], ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z", "RDATE:20261027T160000Z"]),
            (["RRULE:FREQ=WEEKLY", "RDATE:20261027T160000Z"],
             ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z", "RDATE:20261028T160000Z"]),
            (["RRULE:FREQ=WEEKLY", "EXDATE:20261101T170000Z"], ["RRULE:FREQ=WEEKLY;UNTIL=20261108T165959Z"]),
            (["RRULE:FREQ=WEEKLY", "EXDATE:20261101T170000Z"], ["RRULE:FREQ=WEEKLY;COUNT=5"]),
            (["RRULE:FREQ=WEEKLY", "EXDATE:20261101T170000Z"],
             ["RRULE:FREQ=WEEKLY;UNTIL=20261108T165959Z", "EXDATE;TZID=America/Los_Angeles:20261101T090000"]),
            (["RRULE:FREQ=WEEKLY", "EXDATE:not-a-date"], ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"]),
            (["RRULE:FREQ=DAILY", "EXDATE;VALUE=DATE:20261030"], ["RRULE:FREQ=DAILY;UNTIL=20261101"]),
            (["RRULE:FREQ=WEEKLY", "EXDATE;VALUE=DATE:20261201"], ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"]),
            (["RRULE:FREQ=WEEKLY"], ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z", "EXDATE:20261025T160000Z"])]
        for (current, proposed) in refused {
            #expect(!GoogleRemovalPrefix.narrows(current, to: proposed), "\(current) -> \(proposed)")
        }
    }

    @Test func everyPlannedTrimAlsoPassesTheIndependentCheck() throws {
        func timed(_ text: String) -> GoogleOriginalStart {
            .timed(GuardWire.instant(text), timeZone: GuardWire.zone)
        }
        let cases: [([String], GoogleOriginalStart, GoogleOriginalStart)] = [
            (["RRULE:FREQ=WEEKLY;COUNT=3"], timed(GuardWire.first), timed(GuardWire.middle)),
            (["RRULE:FREQ=WEEKLY;COUNT=3"], timed(GuardWire.first), timed(GuardWire.last)),
            (["RRULE:FREQ=DAILY;COUNT=5"], .date("2026-10-30"), .date("2026-11-02")),
            (["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"], timed("2026-10-26T16:00:00Z"), timed("2026-11-02T17:00:00Z")),
            (["RRULE:FREQ=MONTHLY;BYMONTHDAY=15;COUNT=3"], timed("2026-09-15T16:00:00Z"), timed("2026-10-15T16:00:00Z")),
            (["RRULE:FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=1;COUNT=3"], timed("2025-11-01T16:00:00Z"), timed(GuardWire.middle)),
            (["RRULE:FREQ=WEEKLY;UNTIL=20261025T160000Z", "RDATE:20261026T160000Z,20261101T170000Z,20261108T170000Z",
              "EXDATE:20261026T160000Z,20261108T170000Z"], timed(GuardWire.first), timed(GuardWire.middle)),
            (["RRULE:FREQ=DAILY", "RDATE;VALUE=DATE:20261029,20261103", "EXDATE;VALUE=DATE:20261030,20261104"],
             .date("2026-10-30"), .date("2026-11-02")),
            (["RRULE:FREQ=WEEKLY", "RDATE;TZID=America/Los_Angeles:20261026T090000,20261108T090000",
              "EXDATE;TZID=America/Los_Angeles:20261026T090000,20261108T090000"], timed(GuardWire.first),
             timed(GuardWire.middle))]
        for (rules, start, cutoff) in cases {
            let plan = try GoogleRemovalPrefix.plan(rules, start: start, cutoff: cutoff, timeZone: GuardWire.zone)
            #expect(!plan.isEmpty && GoogleRemovalPrefix.narrows(rules, to: plan.recurrence), "\(rules)")
        }
    }
}
