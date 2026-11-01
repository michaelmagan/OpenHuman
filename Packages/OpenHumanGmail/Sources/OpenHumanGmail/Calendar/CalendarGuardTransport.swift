import Foundation
import OpenHumanCore
import Synchronization

public final class CalendarGuardTransport: HTTPTransport {
    public static let host = "www.googleapis.com"
    public static let root = ["calendar", "v3"]

    public let calendarID: String
    public static let deleteWindow: TimeInterval = 15
    public let allowsWrites: Bool
    public static let removalRuleHeader = "X-OpenHuman-Delete-Rule"
    public static let removalRuleValue = "organizer"
    public static let editRuleHeader = "X-OpenHuman-Calendar-Edit"
    public static let editRuleValue = "form"
    static let scopedRemovalHeader = "X-OpenHuman-Calendar-Removal"
    private let removalAuthorizations = Mutex<[String: CalendarRemovalAuthorization]>([:])
    // Names the account's other address an answer is given as, when the guest list has no entry of the calendar's own
    public static let answerAsHeader = "X-OpenHuman-Answer-As"
    public let verifiesOwnedEventRemoval: Bool
    private let wrapped: any HTTPTransport
    private let clock: any OHClock
    private struct Created {
        let answeredAt: Date
        let hadAttendees: Bool
    }
    private let created = Mutex<[String: Created]>([:])

    public init(wrapping transport: any HTTPTransport, calendarID: String, grantedScopes: [String],
                clock: any OHClock = SystemClock(), verifiesOwnedEventRemoval: Bool = false) {
        self.verifiesOwnedEventRemoval = verifiesOwnedEventRemoval
        wrapped = transport
        self.calendarID = calendarID
        self.clock = clock
        allowsWrites = CalendarScopes.allowsWrites(granted: grantedScopes)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.headers[Self.scopedRemovalHeader] != nil { return try await sendScopedRemoval(request) }
        let summary = ReadOnlyTransport.redactingAddresses(ReadOnlyTransport.summary(of: request))
        if let reason = refusalReason(for: request) {
            guard verifiesOwnedEventRemoval, request.method == "DELETE",
                  request.headers[Self.removalRuleHeader] == Self.removalRuleValue,
                  refusalReason(for: request, ownerVerified: true) == nil else {
                Log(.gmail).notice("calendar guard refused \(summary): \(reason)")
                throw TransportError.refusedByGuard(summary)
            }
            if let why = await ownedRemovalRefusal(for: request) {
                Log(.gmail).notice("calendar guard refused \(summary): \(why)")
                throw TransportError.refusedByGuard(summary)
            }
        }
        var forwarded = request
        forwarded.headers[Self.removalRuleHeader] = nil
        forwarded.headers[Self.editRuleHeader] = nil
        forwarded.headers[Self.answerAsHeader] = nil
        forwarded.headers[Self.scopedRemovalHeader] = nil
        let response = try await wrapped.send(forwarded)
        learn(from: request, response: response)
        return response
    }

    func authorizeRemoval(_ authorization: CalendarRemovalAuthorization) -> String {
        let nonce = UUID().uuidString
        removalAuthorizations.withLock { $0[nonce] = authorization }
        return nonce
    }

    func discardRemovalAuthorization(_ nonce: String) {
        _ = removalAuthorizations.withLock { $0.removeValue(forKey: nonce) }
    }

    private func sendScopedRemoval(_ request: HTTPRequest) async throws -> HTTPResponse {
        let summary = ReadOnlyTransport.redactingAddresses(ReadOnlyTransport.summary(of: request))
        func refused() -> TransportError { .refusedByGuard(summary) }
        guard verifiesOwnedEventRemoval, allowsWrites,
              let nonce = request.headers[Self.scopedRemovalHeader],
              let auth = removalAuthorizations.withLock({ $0.removeValue(forKey: nonce) }) else { throw refused() }
        let segments = Self.segments(of: request.url)
        let rest = Array(segments.dropFirst(Self.root.count))
        guard segments.starts(with: Self.root), isEvent(rest), rest[3] == auth.target,
              !segments.contains("."), !segments.contains(".."), !segments.contains(""),
              request.url.scheme == "https", request.url.host(percentEncoded: true) == Self.host,
              request.url.port == nil || request.url.port == 443, request.url.user == nil, request.url.password == nil,
              ReadOnlyTransport.methodOverrideHeader(in: request.headers) == nil,
              ReadOnlyTransport.methodOverrideQueryName(in: request.url) == nil,
              request.method == auth.method, ["DELETE", "PATCH"].contains(auth.method),
              request.body == auth.body, request.headers["If-Match"] == auth.etag,
              Self.sendUpdatesValue(request.url) == auth.sendUpdates else { throw refused() }
        // A guest's copy leaves silently; the organizer's recurring change always tells every guest.
        if auth.asGuest {
            guard auth.method == "DELETE", auth.body == nil, auth.sendUpdates == "none", !auth.allowAbsentCleanup else {
                throw refused()
            }
        } else if !(auth.parent == nil && !auth.master) && auth.sendUpdates != "all" {
            throw refused()
        }
        var proposed: [String]?
        if auth.method == "PATCH" {
            guard auth.master, auth.trim != nil, let body = request.body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  Set(object.keys) == ["recurrence"], let rules = object["recurrence"] as? [String], !rules.isEmpty else {
                throw refused()
            }
            proposed = rules
        }
        var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        components?.query = nil
        guard let readURL = components?.url else { throw refused() }
        var headers = request.headers
        for name in [Self.scopedRemovalHeader, Self.removalRuleHeader, Self.editRuleHeader, Self.answerAsHeader,
                     "If-Match", "Content-Type"] { headers[name] = nil }
        let read = try await wrapped.send(HTTPRequest(method: "GET", url: readURL, headers: headers, body: nil))
        if auth.allowAbsentCleanup && [404, 410].contains(read.status) {
            return HTTPResponse(status: 204, headers: [:], body: Data())
        }
        guard (200..<300).contains(read.status),
              let wire = try? JSONDecoder().decode(WireEvent.self, from: read.body), wire.id == auth.target else {
            throw refused()
        }
        if auth.allowAbsentCleanup && wire.status == "cancelled", wire.recurringEventId == auth.parent,
           wire.originalStartTime?.original == auth.original {
            return HTTPResponse(status: 204, headers: [:], body: Data())
        }
        guard wire.etag == auth.etag else { throw GoogleCalendarRemovalError.conflict }
        let ownership = auth.asGuest ? wire.isGuestCopy(on: calendarID)
            : wire.removalOwned(by: calendarID, allowCreator: auth.parent == nil && !auth.master)
        guard wire.status != "cancelled", wire.eventType == nil || wire.eventType == "default", ownership,
              wire.recurringEventId == auth.parent,
              wire.originalStartTime?.original == auth.original,
              (wire.recurrence?.isEmpty == false) == auth.master,
              wire.event(defaultZone: .gmt) != nil else { throw refused() }
        // Checked here on the fresh read as well as in the client: the organizer's guests are always told.
        if !auth.asGuest, Self.hasGuests(wire, calendarID: calendarID), !["all", "externalOnly"].contains(auth.sendUpdates) {
            throw refused()
        }
        // A trim may only keep an earlier part of the rules just read, and must be the plan for that read.
        if let proposed {
            guard let trim = auth.trim, let current = wire.recurrence, let start = wire.start?.original,
                  GoogleRemovalPrefix.narrows(current, to: proposed),
                  let plan = try? GoogleRemovalPrefix.plan(current, start: start, cutoff: trim.cutoff, timeZone: trim.timeZone),
                  !plan.isEmpty, plan.recurrence == proposed else { throw refused() }
        }
        var forwarded = request
        for name in [Self.scopedRemovalHeader, Self.removalRuleHeader, Self.editRuleHeader, Self.answerAsHeader] {
            forwarded.headers[name] = nil
        }
        return try await wrapped.send(forwarded)
    }

    public func refusalReason(for request: HTTPRequest) -> String? {
        refusalReason(for: request, ownerVerified: false)
    }

    private func refusalReason(for request: HTTPRequest, ownerVerified: Bool) -> String? {
        let url = request.url
        guard url.scheme?.lowercased() == "https", url.host(percentEncoded: true)?.lowercased() == Self.host,
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else {
            return "only https://\(Self.host) is allowed"
        }
        if let header = ReadOnlyTransport.methodOverrideHeader(in: request.headers) { return "method override header \(header)" }
        if let name = ReadOnlyTransport.methodOverrideQueryName(in: url) { return "method override query parameter \(name)" }
        let segments = Self.segments(of: url)
        if segments.contains(".") || segments.contains("..") { return "a `.` or `..` path segment is never allowed" }
        if segments.contains("") { return "an empty path segment is never allowed" }
        guard segments.starts(with: Self.root), segments.count > Self.root.count else {
            return "only /calendar/v3/ is allowed"
        }
        let rest = Array(segments.dropFirst(Self.root.count))
        switch request.method {
        case "GET":
            if let body = request.body, !body.isEmpty { return "GET with a body" }
            return nil
        case "POST" where rest == ["freeBusy"]:
            return nil
        case "POST" where isEventsCollection(rest):
            return allowsWrites ? nil : "creating events needs calendar.events"
        case "PATCH" where isEvent(rest):
            guard allowsWrites else { return "moving events needs calendar.events" }
            guard Self.isTimeOnlyPatch(request.body)
                    || Self.isResponsePatch(request.body, calendarID: calendarID, alias: request.headers[Self.answerAsHeader])
                    || (request.headers[Self.editRuleHeader] == Self.editRuleValue && Self.isDetailPatch(request.body)) else {
                return "an event patch may change only fields on the edit list, or the account's own answer"
            }
            guard Self.hasSendUpdates(url) else { return "an event patch must say whom Google emails (sendUpdates)" }
            return nil
        case "DELETE" where isEvent(rest):
            guard allowsWrites else { return "deleting events needs calendar.events" }
            if ownerVerified { return Self.hasSendUpdates(url) ? nil : "a delete must say whom Google emails (sendUpdates)" }
            let id = rest[3]
            guard let made = created.withLock({ $0[id] }) else { return "only an event Mail created in this run can be deleted" }
            if made.hadAttendees { return "an event created with attendees is never deleted (it may have emailed them)" }
            let age = clock.now.timeIntervalSince(made.answeredAt)
            guard age >= 0, age <= Self.deleteWindow else { return "only inside the create's undo window" }
            return nil
        default:
            return "\(request.method.isEmpty ? "<empty>" : request.method) is not a calendar call Mail makes"
        }
    }

    private func ownedRemovalRefusal(for request: HTTPRequest) async -> String? {
        var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        components?.query = nil
        guard let eventURL = components?.url else { return "the event address could not be read" }
        var headers = request.headers
        headers[Self.removalRuleHeader] = nil
        let read = HTTPRequest(method: "GET", url: eventURL, headers: headers, body: nil)
        guard refusalReason(for: read) == nil else { return "the event could not be read" }
        guard let response = try? await wrapped.send(read), (200..<300).contains(response.status),
              let event = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            return "the event could not be read, so it is not deleted"
        }
        return Self.removalRefusal(event: event, calendarID: calendarID, sendUpdates: Self.sendUpdatesValue(request.url))
    }

    static func removalRefusal(event: [String: Any], calendarID: String, sendUpdates: String?) -> String? {
        if (event["status"] as? String) == "cancelled" { return "the event is already cancelled" }
        if let type = event["eventType"] as? String, type != "default" { return "only a plain event is deleted (\(type))" }
        if event["recurrence"] != nil || (event["recurringEventId"] as? String)?.isEmpty == false {
            return "a recurring event is deleted in Google Calendar, not from here"
        }
        let organizerOwn: Bool
        if let organizer = event["organizer"] as? [String: Any] {
            organizerOwn = GoogleCalendarClient.isOwnEntry(organizer, calendarID: calendarID)
        } else if let creator = event["creator"] as? [String: Any] {
            organizerOwn = GoogleCalendarClient.isOwnEntry(creator, calendarID: calendarID)
        } else {
            organizerOwn = false
        }
        guard organizerOwn else { return "only an event the account organizes is deleted" }
        let guests = (event["attendees"] as? [[String: Any]] ?? []).filter {
            !GoogleCalendarClient.isOwnEntry($0, calendarID: calendarID) && ($0["resource"] as? Bool) != true
        }
        if guests.isEmpty { return nil }
        return ["all", "externalOnly"].contains(sendUpdates ?? "") ? nil
            : "an event with guests is deleted only with sendUpdates all or externalOnly, so they are told"
    }

    // Fail closed: a guest list Google shortened may still name guests
    static func hasGuests(_ event: WireEvent, calendarID: String) -> Bool {
        if event.attendeesOmitted == true { return true }
        return (event.attendees ?? []).contains {
            $0.`self` != true && $0.email?.lowercased() != calendarID.lowercased() && $0.resource != true
        }
    }

    static func sendUpdatesValue(_ url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = items.filter { $0.name == "sendUpdates" }.compactMap(\.value)
        return values.count == 1 ? values[0] : nil
    }

    public var createdEventIDs: Set<String> { created.withLock { Set($0.keys) } }

    private func learn(from request: HTTPRequest, response: HTTPResponse) {
        let segments = Self.segments(of: request.url)
        guard segments.starts(with: Self.root) else { return }
        let rest = Array(segments.dropFirst(Self.root.count))
        if request.method == "POST", isEventsCollection(rest), (200..<300).contains(response.status),
           let id = Self.eventID(response.body) {
            let made = Created(answeredAt: clock.now, hadAttendees: Self.hasAttendees(request.body))
            created.withLock { $0[id] = made }
        }
        if request.method == "DELETE", isEvent(rest),
           (200..<300).contains(response.status) || response.status == 404 || response.status == 410 {
            _ = created.withLock { $0.removeValue(forKey: rest[3]) }
        }
    }

    // Fail closed: a body that cannot be read counts as naming attendees
    static func hasAttendees(_ body: Data?) -> Bool {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return true }
        guard let attendees = object["attendees"] else { return false }
        return (attendees as? [Any])?.isEmpty != true
    }

    static func isTimeOnlyPatch(_ body: Data?) -> Bool {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return Set(object.keys) == ["start", "end"] && object["start"] is [String: Any] && object["end"] is [String: Any]
    }

    static func isResponsePatch(_ body: Data?, calendarID: String, alias: String? = nil) -> Bool {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let list = object["attendees"] as? [Any], !list.isEmpty else {
            return false
        }
        let keys = Set(object.keys)
        guard keys == ["attendees"] || (keys == ["attendees", "attendeesOmitted"] && object["attendeesOmitted"] as? Bool == true)
        else { return false }
        var own = 0
        for item in list {
            guard let entry = item as? [String: Any], let email = entry["email"] as? String, !email.isEmpty else {
                return false
            }
            guard GoogleCalendarClient.isOwnEntry(entry, calendarID: calendarID, alias: alias) else { continue }
            guard entry["organizer"] as? Bool != true else { return false }
            own += 1
            guard let answer = entry["responseStatus"] as? String, GoogleCalendarClient.answers.contains(answer) else {
                return false
            }
        }
        return own == 1
    }

    static let detailKeys: Set<String> = [
        "summary", "description", "location", "start", "end", "attendees", "guestsCanModify", "guestsCanInviteOthers",
        "guestsCanSeeOtherGuests", "conferenceData", "recurrence", "reminders", "transparency", "visibility", "colorId",
        "attendeesOmitted",
    ]

    static func isDetailPatch(_ body: Data?) -> Bool {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], !object.isEmpty,
              Set(object.keys).isSubset(of: detailKeys) else { return false }
        if object["start"] != nil || object["end"] != nil {
            guard object["start"] is [String: Any], object["end"] is [String: Any] else { return false }
        }
        if let attendees = object["attendees"] {
            guard let list = attendees as? [[String: Any]], list.allSatisfy({ ($0["email"] as? String)?.isEmpty == false }) else {
                return false
            }
        }
        if object["attendeesOmitted"] != nil {
            guard object["attendees"] != nil, object["attendeesOmitted"] as? Bool == true else { return false }
        }
        if let rules = object["recurrence"] {
            guard let list = rules as? [String], list.allSatisfy({ line in
                ["RRULE:", "EXRULE:", "RDATE", "EXDATE"].contains { line.uppercased().hasPrefix($0) }
            }) else { return false }
        }
        if let conference = object["conferenceData"], !(conference is NSNull) {
            guard let map = conference as? [String: Any], Set(map.keys) == ["createRequest"],
                  let create = map["createRequest"] as? [String: Any],
                  let key = create["conferenceSolutionKey"] as? [String: Any],
                  key["type"] as? String == GoogleCalendarClient.meetSolutionType else { return false }
        }
        for key in ["guestsCanModify", "guestsCanInviteOthers", "guestsCanSeeOtherGuests"] where object[key] != nil {
            guard object[key] is Bool else { return false }
        }
        return true
    }

    static func hasSendUpdates(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = items.filter { $0.name == "sendUpdates" }.compactMap(\.value)
        return values.count == 1 && ["all", "externalOnly", "none"].contains(values[0])
    }

    private func isEventsCollection(_ rest: [String]) -> Bool {
        rest.count == 3 && rest[0] == "calendars" && sameCalendar(rest[1]) && rest[2] == "events"
    }

    private func isEvent(_ rest: [String]) -> Bool {
        rest.count == 4 && rest[0] == "calendars" && sameCalendar(rest[1]) && rest[2] == "events" && !rest[3].isEmpty
    }

    private func sameCalendar(_ segment: String) -> Bool {
        segment.lowercased() == calendarID.lowercased()
    }

    static func segments(of url: URL) -> [String] {
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return [""] }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    static func eventID(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty, !id.contains("/") else { return nil }
        return id
    }
}
