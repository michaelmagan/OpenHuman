import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Synchronization
import Testing
@testable import OpenHumanGmail

private enum RemovalWire {
    static let path = "/calendar/v3/calendars/robin@example.com/events"
    static let zone = "America/Los_Angeles"
    static func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    static let first = "2026-10-25T16:00:00Z"
    static let middle = "2026-11-01T17:00:00Z"
    static let last = "2026-11-08T17:00:00Z"

    static func event(_ id: String, original: String? = nil, display: String? = nil,
                      rules: [String]? = nil, owner: Bool = true) -> [String: Any] {
        let time = display ?? original ?? first
        var value: [String: Any] = ["id": id, "etag": "\"v-\(id)\"", "status": "confirmed", "eventType": "default",
            "summary": "Weekly", "organizer": ["self": owner],
            "start": ["dateTime": time, "timeZone": zone],
            "end": ["dateTime": ISO8601DateFormatter().string(from: instant(time).addingTimeInterval(1800)), "timeZone": zone]]
        if let original {
            value["recurringEventId"] = "parent"
            value["originalStartTime"] = ["dateTime": original, "timeZone": zone]
        }
        if let rules { value["recurrence"] = rules }
        return value
    }

    static func client(_ http: FakeHTTPTransport, writes: Bool = true) -> GoogleCalendarClient {
        GoogleCalendarClient(calendarID: "robin@example.com",
            grantedScopes: writes ? CalendarScopes.request.write : CalendarScopes.request.read,
            tokens: StaticTokenProvider(token: "synthetic-calendar-token"), transport: http,
            clock: InstantClock(), timeZone: TimeZone(identifier: zone)!)
    }

    static func serve(_ http: FakeHTTPTransport, rules: [String] = ["RRULE:FREQ=WEEKLY;COUNT=3"],
                      exceptions: [[String: Any]] = [], selected: [String: Any]? = nil) {
        let list = FakeHTTPTransport.json(200, ["items": exceptions])
        let master = FakeHTTPTransport.json(200, event("parent", rules: rules))
        let instance = FakeHTTPTransport.json(200, selected ?? event("selected", original: middle))
        http.on("GET", path) { _ in list }
        http.on("GET", path + "/parent") { _ in master }
        http.on("GET", path + "/selected") { _ in instance }
        http.on("PATCH", path) { _ in master }
        http.on("DELETE", path) { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
    }

    static func writes(_ http: FakeHTTPTransport) -> [HTTPRequest] { http.requests.filter { $0.method != "GET" } }
    static func remove(_ http: FakeHTTPTransport, scope: GoogleRemovalScope = .thisAndFollowing) async throws -> GoogleRemovalResult {
        try await client(http).removeEvent(id: "selected", expectedParent: "parent", expectedOriginal: nil,
                                           scope: scope, sendUpdates: .none)
    }
}

@Suite struct GoogleCalendarRemovalPrefixTests {
    private func timed(_ text: String) -> GoogleOriginalStart {
        .timed(RemovalWire.instant(text), timeZone: RemovalWire.zone)
    }

    @Test func weeklyCountKeepsExactlyThePrefixAcrossTheFallDSTBoundary() throws {
        let plan = try GoogleRemovalPrefix.plan(["RRULE:FREQ=WEEKLY;COUNT=3"], start: timed(RemovalWire.first),
            cutoff: timed(RemovalWire.middle), timeZone: RemovalWire.zone)
        #expect(plan.recurrence == ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"] && !plan.isEmpty)
        let last = try GoogleRemovalPrefix.plan(["RRULE:FREQ=WEEKLY;COUNT=3"], start: timed(RemovalWire.first),
            cutoff: timed(RemovalWire.last), timeZone: RemovalWire.zone)
        #expect(last.recurrence == ["RRULE:FREQ=WEEKLY;UNTIL=20261108T165959Z"] && !last.isEmpty)
        let first = try GoogleRemovalPrefix.plan(["RRULE:FREQ=WEEKLY;COUNT=3"], start: timed(RemovalWire.first),
            cutoff: timed(RemovalWire.first), timeZone: RemovalWire.zone)
        #expect(first.isEmpty)
    }

    @Test func allDayUsesThePrecedingCalendarDateAcrossDST() throws {
        let plan = try GoogleRemovalPrefix.plan(["RRULE:FREQ=DAILY;COUNT=5"], start: .date("2026-10-30"),
            cutoff: .date("2026-11-02"), timeZone: RemovalWire.zone)
        #expect(plan.recurrence == ["RRULE:FREQ=DAILY;UNTIL=20261101"] && !plan.isEmpty)
    }

    @Test func yearlyMonthDayWithoutAMonthRefusesTheExcludedJanuaryCounterexample() {
        // RFC YEARLY BYMONTHDAY expansion retains eleven predecessors, February through December 2026.
        #expect(throws: GoogleCalendarRemovalError.self) {
            try GoogleRemovalPrefix.plan(["RRULE:FREQ=YEARLY;BYMONTHDAY=1;COUNT=13", "EXDATE;VALUE=DATE:20260101"],
                start: .date("2026-01-01"), cutoff: .date("2027-01-01"), timeZone: "UTC")
        }
        #expect(throws: GoogleCalendarRemovalError.self) {
            try GoogleRemovalPrefix.plan(["RRULE:FREQ=YEARLY;BYMONTHDAY=1"],
                start: .date("2026-01-01"), cutoff: .date("2026-01-01"), timeZone: "UTC")
        }
    }

    @Test func ordinaryPresetsAndConstrainedMonthlyYearlyPositionsWork() throws {
        let cases: [([String], String, String, String)] = [
            (["RRULE:FREQ=DAILY"], RemovalWire.first, "2026-10-27T16:00:00Z", "RRULE:FREQ=DAILY;UNTIL=20261027T155959Z"),
            (["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"], "2026-10-26T16:00:00Z", "2026-11-02T17:00:00Z",
             "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;UNTIL=20261102T165959Z"),
            (["RRULE:FREQ=MONTHLY;BYMONTHDAY=15;COUNT=3"], "2026-09-15T16:00:00Z", "2026-10-15T16:00:00Z",
             "RRULE:FREQ=MONTHLY;BYMONTHDAY=15;UNTIL=20261015T155959Z"),
            (["RRULE:FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=1;COUNT=3"], "2025-11-01T16:00:00Z", RemovalWire.middle,
             "RRULE:FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=1;UNTIL=20261101T165959Z"),
            (["RRULE:FREQ=YEARLY;COUNT=3"], "2025-11-01T16:00:00Z", RemovalWire.middle,
             "RRULE:FREQ=YEARLY;UNTIL=20261101T165959Z")]
        for (rules, start, cutoff, expected) in cases {
            let plan = try GoogleRemovalPrefix.plan(rules, start: timed(start), cutoff: timed(cutoff), timeZone: RemovalWire.zone)
            #expect(plan.recurrence == [expected] && !plan.isEmpty)
        }
        let constrainedFirst = try GoogleRemovalPrefix.plan(["RRULE:FREQ=MONTHLY;BYMONTHDAY=15;COUNT=3"],
            start: timed("2026-09-15T16:00:00Z"), cutoff: timed("2026-09-15T16:00:00Z"), timeZone: RemovalWire.zone)
        #expect(constrainedFirst.isEmpty)
    }

    @Test func mismatchedStartsRefuseEvenWhenTheCutoffLooksLikeTheFirstGeneratedPosition() {
        let cases: [(String, String, String)] = [
            ("RRULE:FREQ=MONTHLY;BYMONTHDAY=15;COUNT=3", "2026-09-10T16:00:00Z", "2026-09-15T16:00:00Z"),
            ("RRULE:FREQ=MONTHLY;BYMONTHDAY=15;COUNT=3", "2026-09-10T16:00:00Z", "2026-10-15T16:00:00Z"),
            ("RRULE:FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=1;COUNT=3", "2025-10-01T16:00:00Z", "2025-11-01T16:00:00Z"),
            ("RRULE:FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=1;COUNT=3", "2025-11-02T17:00:00Z", RemovalWire.middle),
            ("RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", RemovalWire.first, "2026-10-26T16:00:00Z")]
        for (rule, start, cutoff) in cases {
            #expect(throws: GoogleCalendarRemovalError.self) {
                try GoogleRemovalPrefix.plan([rule], start: timed(start), cutoff: timed(cutoff), timeZone: RemovalWire.zone)
            }
        }
        #expect(throws: GoogleCalendarRemovalError.self) {
            try GoogleRemovalPrefix.plan(["RRULE:FREQ=MONTHLY;BYMONTHDAY=15"], start: .date("2026-09-10"),
                cutoff: .date("2026-09-15"), timeZone: RemovalWire.zone)
        }
        #expect(throws: GoogleCalendarRemovalError.self) {
            try GoogleRemovalPrefix.plan(["RRULE:FREQ=DAILY;UNTIL=20261024T160000Z", "RDATE:20261101T170000Z"],
                start: timed(RemovalWire.first), cutoff: timed(RemovalWire.middle), timeZone: RemovalWire.zone)
        }
    }

    @Test func earlierUntilAndEarlierDateListMeaningArePreserved() throws {
        let rules = ["RRULE:FREQ=WEEKLY;UNTIL=20261025T160000Z",
                     "RDATE:20261026T160000Z,20261101T170000Z,20261108T170000Z",
                     "EXDATE:20261026T160000Z,20261108T170000Z"]
        let plan = try GoogleRemovalPrefix.plan(rules, start: timed(RemovalWire.first), cutoff: timed(RemovalWire.middle),
                                                timeZone: RemovalWire.zone)
        #expect(plan.recurrence == ["RRULE:FREQ=WEEKLY;UNTIL=20261025T160000Z",
                                    "RDATE:20261026T160000Z", "EXDATE:20261026T160000Z"])
        let dates = try GoogleRemovalPrefix.plan(["RRULE:FREQ=DAILY", "RDATE;VALUE=DATE:20261029,20261103",
                                                   "EXDATE;VALUE=DATE:20261030,20261104"],
            start: .date("2026-10-30"), cutoff: .date("2026-11-02"), timeZone: RemovalWire.zone)
        #expect(dates.recurrence == ["RRULE:FREQ=DAILY;UNTIL=20261101", "RDATE;VALUE=DATE:20261029",
                                     "EXDATE;VALUE=DATE:20261030"])
        let local = try GoogleRemovalPrefix.plan(["RRULE:FREQ=WEEKLY",
            "RDATE;TZID=America/Los_Angeles:20261026T090000,20261108T090000",
            "EXDATE;TZID=America/Los_Angeles:20261026T090000,20261108T090000"],
            start: timed(RemovalWire.first), cutoff: timed(RemovalWire.middle), timeZone: RemovalWire.zone)
        #expect(local.recurrence == ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z",
            "RDATE;TZID=America/Los_Angeles:20261026T090000", "EXDATE;TZID=America/Los_Angeles:20261026T090000"])
    }

    @Test func unsafeCountCustomMixedMalformedAndAmbiguousFormsRefuse() {
        let rules: [[String]] = [
            ["RRULE:FREQ=WEEKLY;COUNT=1"],
            ["RRULE:FREQ=WEEKLY;COUNT=3", "RDATE:20261101T170000Z"],
            ["RRULE:FREQ=WEEKLY;COUNT=3;COUNT=4"], ["RRULE:FREQ=WEEKLY", "RRULE:FREQ=DAILY"],
            ["RRULE:FREQ=MONTHLY;BYDAY=1SU"], ["RRULE:FREQ=WEEKLY;BYSETPOS=1"],
            ["RRULE:FREQ=WEEKLY", "EXRULE:FREQ=DAILY"],
            ["RRULE:FREQ=WEEKLY", "RDATE:20261101T090000"],
            ["RRULE:FREQ=WEEKLY", "RDATE;TZID=Unknown/Zone:20261101T090000"],
            ["RRULE:FREQ=WEEKLY", "RDATE;TZID=America/Los_Angeles:20261101T013000"],
            ["RRULE:FREQ=WEEKLY", "RDATE;VALUE=DATE:20261101"],
            ["RRULE:FREQ=WEEKLY", "EXDATE:20261101T170000Z"],
            ["RRULE:FREQ=WEEKLY;UNTIL=not-a-date"]]
        for rule in rules {
            #expect(throws: GoogleCalendarRemovalError.self) {
                try GoogleRemovalPrefix.plan(rule, start: timed(RemovalWire.first), cutoff: timed(RemovalWire.middle),
                                             timeZone: RemovalWire.zone)
            }
        }
    }
}

@Suite struct GoogleCalendarRecurringRemovalClientTests {
    @Test func thisAndAllUseFreshActualTargetsConditionalRequestsAndAllNotifications() async throws {
        for (scope, target) in [(GoogleRemovalScope.thisEvent, "selected"), (.allEvents, "parent")] {
            let http = FakeHTTPTransport()
            RemovalWire.serve(http)
            let result = try await RemovalWire.remove(http, scope: scope)
            #expect(result.selectedID == "selected" && result.parentID == "parent")
            #expect(result.confirmedMasterVersion == nil)
            let writes = RemovalWire.writes(http)
            #expect(writes.count == 1 && writes[0].method == "DELETE")
            #expect(writes[0].url.path(percentEncoded: false) == RemovalWire.path + "/" + target)
            #expect(writes[0].headers["If-Match"] == "\"v-\(target)\"")
            #expect(writes[0].url.query?.contains("sendUpdates=all") == true)
            #expect(http.requests.allSatisfy { $0.headers[CalendarGuardTransport.scopedRemovalHeader] == nil })
        }
    }

    @Test func futureTrimsOnlyTheMasterUsingTheOriginalPositionOfAMovedSelection() async throws {
        let http = FakeHTTPTransport()
        RemovalWire.serve(http, selected: RemovalWire.event("selected", original: RemovalWire.middle, display: "2026-10-28T16:00:00Z"))
        let result = try await RemovalWire.remove(http)
        #expect(result.originalCutoff == .timed(RemovalWire.instant(RemovalWire.middle), timeZone: RemovalWire.zone))
        let write = try #require(RemovalWire.writes(http).first)
        let data = try #require(write.body)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(body.keys) == ["recurrence"])
        #expect(body["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"])
        #expect(RemovalWire.writes(http).count == 1 && write.method == "PATCH")
        #expect(write.url.path(percentEncoded: false) == RemovalWire.path + "/parent")
        let discovery = try #require(http.requests.first { $0.url.query?.contains("singleEvents=false") == true })
        #expect(discovery.url.query?.contains("showDeleted=true") == true)
        #expect(discovery.url.query?.contains("timeMin") == false && discovery.url.query?.contains("timeMax") == false)
    }

    @Test func firstPositionDeletesTheMasterWithoutCreatingAnything() async throws {
        let http = FakeHTTPTransport()
        RemovalWire.serve(http, selected: RemovalWire.event("selected", original: RemovalWire.first))
        let result = try await RemovalWire.remove(http)
        #expect(result.confirmedMasterVersion == nil)
        #expect(RemovalWire.writes(http).map(\.method) == ["DELETE"])
        #expect(RemovalWire.writes(http).first?.url.path(percentEncoded: false) == RemovalWire.path + "/parent")
    }

    @Test func yearlyMonthDayExpansionRefusesBeforeAnyMutationThroughTheRealClientAndGuard() async {
        let http = FakeHTTPTransport()
        let rules = ["RRULE:FREQ=YEARLY;BYMONTHDAY=1;COUNT=13", "EXDATE;VALUE=DATE:20260101"]
        var selected = RemovalWire.event("selected", original: RemovalWire.middle)
        selected["start"] = ["date": "2027-01-01", "timeZone": "UTC"]
        selected["end"] = ["date": "2027-01-02", "timeZone": "UTC"]
        selected["originalStartTime"] = ["date": "2027-01-01"]
        var master = RemovalWire.event("parent", rules: rules)
        master["start"] = ["date": "2026-01-01", "timeZone": "UTC"]
        master["end"] = ["date": "2026-01-02", "timeZone": "UTC"]
        RemovalWire.serve(http, rules: rules, selected: selected)
        let selectedResponse = FakeHTTPTransport.json(200, selected)
        let masterResponse = FakeHTTPTransport.json(200, master)
        let completeDiscovery = FakeHTTPTransport.json(200, ["items": [master]])
        http.on("GET", RemovalWire.path) { _ in completeDiscovery }
        http.on("GET", RemovalWire.path + "/parent") { _ in masterResponse }
        http.on("GET", RemovalWire.path + "/selected") { _ in selectedResponse }
        await #expect(throws: GoogleCalendarRemovalError.refused(
            "Mail can't safely shorten this recurrence rule. Remove this event or the whole series instead.")) {
            _ = try await RemovalWire.client(http).removeEvent(id: "selected", expectedParent: "parent",
                expectedOriginal: .date("2027-01-01"), scope: .thisAndFollowing, sendUpdates: .all)
        }
        #expect(http.requests.filter { $0.method == "GET" }.map { $0.url.path(percentEncoded: false) } ==
            [RemovalWire.path + "/selected", RemovalWire.path + "/parent"])
        #expect(http.requests.filter { ["DELETE", "PATCH", "PUT", "POST"].contains($0.method) }.isEmpty,
            "the eleven February–December predecessors cannot be lost through an apparent empty-prefix DELETE")
        #expect(RemovalWire.writes(http).isEmpty)
    }

    @Test func confirmedTrimVersionComesOnlyFromTheMatchingConditionalPatchResponse() async throws {
        for prewriteTime in [nil, "2026-10-26T12:00:00Z", "2026-10-26T12:01:00Z"] as [String?] {
            let http = FakeHTTPTransport()
            var prewrite = RemovalWire.event("parent", rules: ["RRULE:FREQ=WEEKLY;COUNT=3"])
            if let prewriteTime { prewrite["updated"] = prewriteTime }
            var trimmed = RemovalWire.event("parent", rules: ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"])
            trimmed["etag"] = "\"confirmed-trim\""
            trimmed["updated"] = "2026-10-26T12:01:00Z"
            var selected = RemovalWire.event("selected", original: RemovalWire.middle)
            selected["updated"] = "2030-01-01T00:00:00Z"
            RemovalWire.serve(http, selected: selected)
            let before = FakeHTTPTransport.json(200, prewrite)
            let after = FakeHTTPTransport.json(200, trimmed)
            http.on("GET", RemovalWire.path + "/parent") { _ in before }
            http.on("PATCH", RemovalWire.path) { _ in after }
            let result = try await RemovalWire.remove(http)
            let version = try #require(result.confirmedMasterVersion)
            #expect(version.etag == "\"confirmed-trim\"" && version.updated == RemovalWire.instant("2026-10-26T12:01:00Z"))
            #expect(result.parentID == "parent")
            let writes = RemovalWire.writes(http)
            #expect(writes.count == 1 && writes.first?.method == "PATCH")
            #expect(writes.first?.headers["If-Match"] == "\"v-parent\"")
            #expect(writes.first?.url.query?.contains("sendUpdates=all") == true)
            #expect(http.requests.allSatisfy { $0.headers[CalendarGuardTransport.scopedRemovalHeader] == nil })
        }
    }

    @Test func invalidOrMissingPatchEvidenceNeverManufacturesAuthorityOrReplaysTheWrite() async throws {
        for kind in ["empty-body", "malformed-body", "missing-id", "wrong-id", "instance-parent", "instance-original",
                     "cancelled", "missing-status", "unknown-status", "special", "not-owned", "missing-etag", "empty-etag",
                     "unchanged-etag", "missing-updated", "invalid-updated", "wrong-type-updated", "older-updated",
                     "missing-recurrence", "wrong-recurrence", "missing-start"] {
            let http = FakeHTTPTransport()
            RemovalWire.serve(http)
            var prewrite = RemovalWire.event("parent", rules: ["RRULE:FREQ=WEEKLY;COUNT=3"])
            prewrite["updated"] = "2026-10-26T12:00:00Z"
            let before = FakeHTTPTransport.json(200, prewrite)
            http.on("GET", RemovalWire.path + "/parent") { _ in before }
            var trimmed = RemovalWire.event("parent", rules: ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"])
            trimmed["etag"] = "\"confirmed-trim\""
            trimmed["updated"] = "2026-10-26T12:01:00Z"
            switch kind {
            case "missing-id": trimmed.removeValue(forKey: "id")
            case "wrong-id": trimmed["id"] = "other-parent"
            case "instance-parent": trimmed["recurringEventId"] = "parent"
            case "instance-original": trimmed["originalStartTime"] = ["dateTime": RemovalWire.first]
            case "cancelled": trimmed["status"] = "cancelled"
            case "missing-status": trimmed.removeValue(forKey: "status")
            case "unknown-status": trimmed["status"] = "unknown"
            case "special": trimmed["eventType"] = "outOfOffice"
            case "not-owned": trimmed["organizer"] = ["self": false]
            case "missing-etag": trimmed.removeValue(forKey: "etag")
            case "empty-etag": trimmed["etag"] = " "
            case "unchanged-etag": trimmed["etag"] = "\"v-parent\""
            case "missing-updated": trimmed.removeValue(forKey: "updated")
            case "invalid-updated": trimmed["updated"] = "not-a-server-date"
            case "wrong-type-updated": trimmed["updated"] = 123
            case "older-updated": trimmed["updated"] = "2026-10-26T11:59:59Z"
            case "missing-recurrence": trimmed.removeValue(forKey: "recurrence")
            case "wrong-recurrence": trimmed["recurrence"] = ["RRULE:FREQ=WEEKLY;COUNT=3"]
            case "missing-start": trimmed.removeValue(forKey: "start")
            default: break
            }
            let response: HTTPResponse
            if kind == "empty-body" { response = HTTPResponse(status: 204, headers: [:], body: Data()) }
            else if kind == "malformed-body" { response = HTTPResponse(status: 200, headers: [:], body: Data("broken".utf8)) }
            else { response = FakeHTTPTransport.json(200, trimmed) }
            http.on("PATCH", RemovalWire.path) { _ in response }
            let result = try await RemovalWire.remove(http)
            #expect(result.confirmedMasterVersion == nil, "\(kind) is optional absence after the confirmed write")
            #expect(RemovalWire.writes(http).map(\.method) == ["PATCH"], "\(kind) must not replay or claim rollback")
        }
    }

    @Test func deleteResponsesNeverSupplyAConfirmedTrimVersion() async throws {
        for scope in [GoogleRemovalScope.thisEvent, .allEvents, .thisAndFollowing] {
            let http = FakeHTTPTransport()
            RemovalWire.serve(http, selected: RemovalWire.event("selected", original: RemovalWire.first))
            var trimmed = RemovalWire.event("parent", rules: ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"])
            trimmed["etag"] = "\"confirmed-trim\""
            trimmed["updated"] = "2026-10-26T12:01:00Z"
            let response = FakeHTTPTransport.json(200, trimmed)
            http.on("DELETE", RemovalWire.path) { _ in response }
            let result = try await RemovalWire.remove(http, scope: scope)
            #expect(result.confirmedMasterVersion == nil && RemovalWire.writes(http).map(\.method) == ["DELETE"])
        }
    }

    @Test func confirmedPatchWithFailedCleanupReturnsUncertaintyWithoutVersionAuthority() async {
        let http = FakeHTTPTransport()
        let exception = RemovalWire.event("later", original: RemovalWire.last)
        RemovalWire.serve(http, exceptions: [exception])
        var trimmed = RemovalWire.event("parent", rules: ["RRULE:FREQ=WEEKLY;UNTIL=20261101T165959Z"])
        trimmed["etag"] = "\"confirmed-trim\""
        trimmed["updated"] = "2026-10-26T12:01:00Z"
        let patchResponse = FakeHTTPTransport.json(200, trimmed)
        let exceptionResponse = FakeHTTPTransport.json(200, exception)
        http.on("PATCH", RemovalWire.path) { _ in patchResponse }
        http.on("GET", RemovalWire.path + "/later") { _ in exceptionResponse }
        http.on("DELETE", RemovalWire.path + "/later") { _ in HTTPResponse(status: 503, headers: [:], body: Data()) }
        await #expect(throws: GoogleCalendarRemovalError.uncertain) { _ = try await RemovalWire.remove(http) }
        #expect(RemovalWire.writes(http).map(\.method) == ["PATCH", "DELETE"])
    }

    @Test func mismatchedMasterStartsNeverPatchOrDeleteEvenForAnApparentEmptyPrefix() async {
        let cases: [(String, String, String)] = [
            ("RRULE:FREQ=MONTHLY;BYMONTHDAY=15;COUNT=3", "2026-09-10T16:00:00Z", "2026-09-15T16:00:00Z"),
            ("RRULE:FREQ=MONTHLY;BYMONTHDAY=15;COUNT=3", "2026-09-10T16:00:00Z", "2026-10-15T16:00:00Z"),
            ("RRULE:FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=1;COUNT=3", "2025-10-01T16:00:00Z", "2025-11-01T16:00:00Z"),
            ("RRULE:FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=1;COUNT=3", "2025-11-02T17:00:00Z", RemovalWire.middle),
            ("RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", RemovalWire.first, "2026-10-26T16:00:00Z")]
        for (rule, start, cutoff) in cases {
            let http = FakeHTTPTransport()
            RemovalWire.serve(http, rules: [rule], selected: RemovalWire.event("selected", original: cutoff))
            let master = FakeHTTPTransport.json(200, RemovalWire.event("parent", display: start, rules: [rule]))
            http.on("GET", RemovalWire.path + "/parent") { _ in master }
            await #expect(throws: GoogleCalendarRemovalError.self) { _ = try await RemovalWire.remove(http) }
            #expect(RemovalWire.writes(http).isEmpty, "a mismatched start cannot authorize either a trim or a master delete")
        }
        let http = FakeHTTPTransport()
        var selected = RemovalWire.event("selected", original: RemovalWire.middle)
        selected["start"] = ["date": "2026-09-15"]
        selected["end"] = ["date": "2026-09-16"]
        selected["originalStartTime"] = ["date": "2026-09-15"]
        let rules = ["RRULE:FREQ=MONTHLY;BYMONTHDAY=15;COUNT=3"]
        RemovalWire.serve(http, rules: rules, selected: selected)
        var master = RemovalWire.event("parent", rules: rules)
        master["start"] = ["date": "2026-09-10", "timeZone": RemovalWire.zone]
        master["end"] = ["date": "2026-09-11", "timeZone": RemovalWire.zone]
        let response = FakeHTTPTransport.json(200, master)
        http.on("GET", RemovalWire.path + "/parent") { _ in response }
        await #expect(throws: GoogleCalendarRemovalError.self) { _ = try await RemovalWire.remove(http) }
        #expect(RemovalWire.writes(http).isEmpty, "all-day mismatches also refuse before a master delete")
    }

    @Test func earlierDetachedAndCancelledExceptionsRefuseBeforeAnyWrite() async {
        for cancelled in [false, true] {
            let http = FakeHTTPTransport()
            var earlier = RemovalWire.event("earlier", original: RemovalWire.first, display: RemovalWire.last)
            if cancelled { earlier["status"] = "cancelled" }
            RemovalWire.serve(http, exceptions: [earlier])
            await #expect(throws: GoogleCalendarRemovalError.self) { _ = try await RemovalWire.remove(http) }
            #expect(RemovalWire.writes(http).isEmpty)
        }
    }

    @Test func laterOriginalMovedEarlierIsExplicitlyCleanedAfterAllTargetsArePreflighted() async throws {
        let http = FakeHTTPTransport()
        let exception = RemovalWire.event("later", original: RemovalWire.last, display: "2026-10-24T16:00:00Z")
        RemovalWire.serve(http, exceptions: [exception])
        let response = FakeHTTPTransport.json(200, exception)
        http.on("GET", RemovalWire.path + "/later") { _ in response }
        _ = try await RemovalWire.remove(http)
        let writes = RemovalWire.writes(http)
        #expect(writes.map(\.method) == ["PATCH", "DELETE"])
        #expect(writes.last?.url.path(percentEncoded: false) == RemovalWire.path + "/later")
        let firstWrite = try #require(http.requests.firstIndex { $0.method != "GET" })
        #expect(http.requests[..<firstWrite].contains { $0.url.path(percentEncoded: false).hasSuffix("/later") })
        #expect(writes.last?.headers["If-Match"] == "\"v-later\"")
    }

    @Test func incompleteRepeatedUnreadableAndUnidentifiedDiscoveryNeverWrites() async {
        let responses = [FakeHTTPTransport.json(200, ["items": [], "nextPageToken": "again"]),
                         FakeHTTPTransport.json(200, ["items": [["id": "broken", "recurringEventId": "parent"]]]),
                         FakeHTTPTransport.json(200, ["items": [["status": "cancelled"]]]),
                         FakeHTTPTransport.json(200, [:]),
                         HTTPResponse(status: 200, headers: [:], body: Data("broken".utf8))]
        for response in responses {
            let http = FakeHTTPTransport()
            RemovalWire.serve(http)
            let instance = FakeHTTPTransport.json(200, RemovalWire.event("selected", original: RemovalWire.middle))
            let master = FakeHTTPTransport.json(200, RemovalWire.event("parent", rules: ["RRULE:FREQ=WEEKLY"]))
            http.on("GET", RemovalWire.path) { _ in response }
            http.on("GET", RemovalWire.path + "/selected") { _ in instance }
            http.on("GET", RemovalWire.path + "/parent") { _ in master }
            await #expect(throws: (any Error).self) { _ = try await RemovalWire.remove(http) }
            #expect(RemovalWire.writes(http).isEmpty)
        }
    }

    @Test func boundedDiscoveryRejectsTwentyDistinctUnfinishedPagesAndUnauthorizedLaterTargets() async {
        let http = FakeHTTPTransport()
        RemovalWire.serve(http)
        let pages = Mutex(0)
        http.on("GET", RemovalWire.path) { _ in
            let number = pages.withLock { $0 += 1; return $0 }
            return FakeHTTPTransport.json(200, ["items": [], "nextPageToken": "page-\(number)"])
        }
        let selected = FakeHTTPTransport.json(200, RemovalWire.event("selected", original: RemovalWire.middle))
        let master = FakeHTTPTransport.json(200, RemovalWire.event("parent", rules: ["RRULE:FREQ=WEEKLY"]))
        http.on("GET", RemovalWire.path + "/selected") { _ in selected }
        http.on("GET", RemovalWire.path + "/parent") { _ in master }
        await #expect(throws: GoogleCalendarRemovalError.self) { _ = try await RemovalWire.remove(http) }
        #expect(pages.withLock { $0 } == GoogleCalendarClient.maxSyncPages && RemovalWire.writes(http).isEmpty)

        let denied = FakeHTTPTransport()
        let exception = RemovalWire.event("later", original: RemovalWire.last, owner: false)
        RemovalWire.serve(denied, exceptions: [exception])
        let response = FakeHTTPTransport.json(200, exception)
        denied.on("GET", RemovalWire.path + "/later") { _ in response }
        await #expect(throws: GoogleCalendarRemovalError.self) { _ = try await RemovalWire.remove(denied) }
        #expect(RemovalWire.writes(denied).isEmpty, "all cleanup targets must be authorized before the master is shortened")
    }

    @Test func wrongIdentityReadOnlyMissingMasterSpecialAndNonOrganizerNeverWrite() async {
        for kind in ["wrong-parent", "wrong-id", "missing-original", "missing-etag", "special", "non-organizer", "missing-master", "read-only", "custom"] {
            let http = FakeHTTPTransport()
            var selected = RemovalWire.event("selected", original: RemovalWire.middle)
            if kind == "wrong-parent" { selected["recurringEventId"] = "other" }
            if kind == "wrong-id" { selected["id"] = "other" }
            if kind == "missing-original" { selected.removeValue(forKey: "originalStartTime") }
            if kind == "missing-etag" { selected.removeValue(forKey: "etag") }
            if kind == "special" { selected["eventType"] = "outOfOffice" }
            if kind == "non-organizer" { selected["organizer"] = ["self": false] }
            RemovalWire.serve(http, rules: kind == "custom" ? ["RRULE:FREQ=MONTHLY;BYDAY=1SU"] : ["RRULE:FREQ=WEEKLY"], selected: selected)
            if kind == "missing-master" {
                http.on("GET", RemovalWire.path + "/parent") { _ in HTTPResponse(status: 404, headers: [:], body: Data()) }
            }
            await #expect(throws: (any Error).self) {
                _ = try await RemovalWire.client(http, writes: kind != "read-only").removeEvent(id: "selected",
                    expectedParent: "parent", expectedOriginal: nil, scope: .thisAndFollowing, sendUpdates: .all)
            }
            #expect(RemovalWire.writes(http).isEmpty, "\(kind) refuses before mutation")
        }
    }

    @Test func conditionalConflictsAndAmbiguousWritesAreNeverReplayed() async {
        for status in [412, 503] {
            let http = FakeHTTPTransport()
            RemovalWire.serve(http)
            http.on("PATCH", RemovalWire.path) { _ in HTTPResponse(status: status, headers: [:], body: Data()) }
            await #expect(throws: GoogleCalendarError.self) { _ = try await RemovalWire.remove(http) }
            #expect(RemovalWire.writes(http).count == 1)
        }
        let http = FakeHTTPTransport()
        RemovalWire.serve(http)
        http.on("PATCH", RemovalWire.path) { _ in throw TransportError.timedOut }
        await #expect(throws: GoogleCalendarError.unclear) { _ = try await RemovalWire.remove(http) }
        #expect(RemovalWire.writes(http).count == 1)
    }

    @Test func cancellationIdentityDecodesWithoutDisplayedTimesAndMastersStayDistinct() throws {
        let data = FakeHTTPTransport.json(200, ["id": "cancelled", "status": "cancelled", "recurringEventId": "parent",
                                                "originalStartTime": ["date": "2026-11-01"]]).body
        let wire = try JSONDecoder().decode(WireEvent.self, from: data)
        #expect(wire.originalStartTime?.original == .date("2026-11-01") && wire.recurringEventId == "parent")
        #expect(wire.event(defaultZone: .gmt) == nil)
    }
}
