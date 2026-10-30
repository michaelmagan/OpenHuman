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
        let response = try await wrapped.send(forwarded)
        learn(from: request, response: response)
        return response
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
