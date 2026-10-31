import Foundation
import OpenHumanCore
import Synchronization

public enum GoogleCalendarError: Error, Equatable, Sendable {
    case unauthorized
    case reauthRequired
    case forbidden(reason: String)
    case notFound
    case gone
    case rateLimited
    case badRequest(reason: String)
    case server(status: Int)
    case transport(TransportError)
    // The event may exist, so never retry; the caller looks before trying again
    case unclear
    case refusedByGuard(String)
    case decoding(String)
    case cancelled

    public var code: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .reauthRequired: "reauth_required"
        case .forbidden(let reason): "forbidden:\(reason)"
        case .notFound: "not_found"
        case .gone: "gone"
        case .rateLimited: "rate_limited"
        case .badRequest(let reason): "bad_request:\(reason)"
        case .server(let status): "server_\(status)"
        case .transport: "transport"
        case .unclear: "unclear"
        case .refusedByGuard: "refused_by_guard"
        case .decoding: "decoding"
        case .cancelled: "cancelled"
        }
    }
}

public final class CalendarRequestBudget: Sendable {
    public static let perMinute = 300
    public static let pause: TimeInterval = 60
    public static let longestPause: TimeInterval = 300
    public let limit: Int
    private struct State {
        var sent: [Date] = []
        var pausedUntil: Date?
    }
    private let state = Mutex(State())

    public init(perMinute: Int = CalendarRequestBudget.perMinute) {
        limit = max(1, perMinute)
    }

    public func take(now: Date) -> Bool {
        state.withLock { s in
            if let until = s.pausedUntil, now < until { return false }
            s.sent.removeAll { now.timeIntervalSince($0) >= 60 || $0 > now }
            guard s.sent.count < limit else { return false }
            s.sent.append(now)
            return true
        }
    }

    public func noteRateLimited(now: Date, retryAfter: TimeInterval?) {
        let wait = min(max(retryAfter ?? Self.pause, Self.pause), Self.longestPause)
        state.withLock { $0.pausedUntil = now.addingTimeInterval(wait) }
    }
}

public struct GoogleCalendarClient: Sendable {
    public static let meetSolutionType = "hangoutsMeet"
    // Fails closed: a video entry point on any other host shows no Join button
    public static let meetHosts: Set<String> = ["meet.google.com"]
    static let base = URL(string: "https://www.googleapis.com/calendar/v3")!
    static let pageSize = 2_500
    static let maxPages = 4

    public let calendarID: String
    private let tokens: any AccessTokenProvider
    let transport: CalendarGuardTransport
    private let clock: any OHClock
    private let budget: CalendarRequestBudget
    private let timeZone: TimeZone
    private let makeRequestID: @Sendable () -> String

    public init(calendarID: String, grantedScopes: [String], tokens: any AccessTokenProvider,
                transport: any HTTPTransport, clock: any OHClock, budget: CalendarRequestBudget = CalendarRequestBudget(),
                timeZone: TimeZone = .current, makeRequestID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.calendarID = calendarID
        self.tokens = tokens
        self.transport = CalendarGuardTransport(wrapping: transport, calendarID: calendarID,
                                                grantedScopes: grantedScopes, clock: clock,
                                                verifiesOwnedEventRemoval: true)
        self.clock = clock
        self.budget = budget
        self.timeZone = timeZone
        self.makeRequestID = makeRequestID
    }

    public var allowsWrites: Bool { transport.allowsWrites }

    public func listEvents(from: Date, to: Date) async throws -> [GoogleCalendarEvent] {
        var events: [GoogleCalendarEvent] = []
        var skipped = 0
        var pageToken: String?
        for _ in 0..<Self.maxPages {
            var query = [
                URLQueryItem(name: "timeMin", value: RFC3339.string(from, in: .gmt)),
                URLQueryItem(name: "timeMax", value: RFC3339.string(to, in: .gmt)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "maxResults", value: String(Self.pageSize)),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let response = try await send("GET", url(["calendars", calendarID, "events"], query: query))
            let page: WireEventList = try decode(response.body, "events.list")
            for item in page.items ?? [] {
                if let event = item.event(defaultZone: timeZone, calendarID: calendarID, selfAddress: calendarID) { events.append(event) } else { skipped += 1 }
            }
            guard let next = page.nextPageToken, !next.isEmpty, next != pageToken else { break }
            pageToken = next
        }
        if skipped > 0 { Log(.gmail).notice("calendar events.list: \(skipped) item(s) skipped (no id or no readable time)") }
        return events.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
    }

    public func freeBusy(from: Date, to: Date) async throws -> GoogleFreeBusy {
        let body: [String: Any] = [
            "timeMin": RFC3339.string(from, in: .gmt), "timeMax": RFC3339.string(to, in: .gmt), "timeZone": "UTC",
            "items": [["id": calendarID]],
        ]
        let response = try await send("POST", url(["freeBusy"]), body: try json(body))
        let answer: WireFreeBusy = try decode(response.body, "freebusy.query")
        let entry = answer.calendars?[calendarID]
            ?? answer.calendars?.first(where: { $0.key.lowercased() == calendarID.lowercased() })?.value
            ?? answer.calendars?.values.first
        let busy = (entry?.busy ?? []).compactMap { block -> GoogleBusyInterval? in
            guard let start = block.start.flatMap(RFC3339.date), let end = block.end.flatMap(RFC3339.date), end > start
            else { return nil }
            return GoogleBusyInterval(start: start, end: end)
        }
        let errors = (entry?.errors ?? []).map { $0.reason ?? "unknown" }
        return GoogleFreeBusy(busy: busy.sorted { $0.start < $1.start }, errors: errors)
    }

    public static let syncPageSize = 250
    public static let maxSyncPages = 20

    public func listEventWindow(from: Date, to: Date) async throws -> GoogleEventSyncPage {
        try await syncPages([
            URLQueryItem(name: "timeMin", value: RFC3339.string(from, in: .gmt)),
            URLQueryItem(name: "timeMax", value: RFC3339.string(to, in: .gmt)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "maxResults", value: String(Self.syncPageSize)),
        ], what: "window")
    }

    public func listEventChanges(syncToken: String) async throws -> GoogleEventSyncPage {
        try await syncPages([
            URLQueryItem(name: "syncToken", value: syncToken),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "maxResults", value: String(Self.syncPageSize)),
        ], what: "changes")
    }

    private func syncPages(_ base: [URLQueryItem], what: String) async throws -> GoogleEventSyncPage {
        var events: [GoogleSyncedEvent] = []
        var removed: [String] = []
        var cancellations: [GoogleCalendarCancellation] = []
        var skipped = 0
        var pageToken: String?
        var token: String?
        var complete = false
        for _ in 0..<Self.maxSyncPages {
            var query = base
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let response = try await send("GET", url(["calendars", calendarID, "events"], query: query))
            let page: WireEventList = try decode(response.body, "events.list")
            let meta = (try? JSONDecoder().decode(WireEventMetaList.self, from: response.body)) ?? WireEventMetaList()
            let metas = meta.items ?? []
            for (index, item) in (page.items ?? []).enumerated() {
                let info = index < metas.count && metas[index].id == item.id ? metas[index] : WireEventMeta()
                if item.status == "cancelled" {
                    if let id = item.id, !id.isEmpty {
                        removed.append(id)
                        cancellations.append(GoogleCalendarCancellation(id: id, parentID: item.recurringEventId,
                            originalStartTime: item.originalStartTime?.original))
                    } else { skipped += 1 }
                    continue
                }
                guard let event = item.event(defaultZone: timeZone, calendarID: calendarID, selfAddress: calendarID) else {
                    skipped += 1
                    continue
                }
                events.append(GoogleSyncedEvent(event: event, etag: info.etag, updated: info.updated.flatMap(RFC3339.date),
                                                recurringEventID: info.recurringEventId,
                                                isTransparent: info.transparency == "transparent",
                                                selfDeclined: info.declined(by: calendarID)))
            }
            guard let next = page.nextPageToken, !next.isEmpty, next != pageToken else {
                token = meta.nextSyncToken.flatMap { $0.isEmpty ? nil : $0 }
                complete = true
                break
            }
            pageToken = next
        }
        Log(.gmail).notice("calendar events.list (\(what)): \(events.count) event(s), \(removed.count) removed, "
                           + "\(skipped) skipped\(complete ? "" : ", pages ran out")")
        return GoogleEventSyncPage(events: events, removed: removed, nextSyncToken: complete ? token : nil,
                                   isComplete: complete, cancellations: cancellations)
    }


    // With singleEvents off and no window, a UID read lists the series itself, a single event and each moved occurrence,
    // wherever they now start
    public func inviteCandidates(iCalUID: String?, from: Date?, to: Date?,
                                 singleEvents: Bool = true) async throws -> [GoogleInviteCandidate] {
        var query: [URLQueryItem] = []
        if let iCalUID { query.append(URLQueryItem(name: "iCalUID", value: iCalUID)) }
        if let from { query.append(URLQueryItem(name: "timeMin", value: RFC3339.string(from, in: .gmt))) }
        if let to { query.append(URLQueryItem(name: "timeMax", value: RFC3339.string(to, in: .gmt))) }
        query.append(URLQueryItem(name: "singleEvents", value: singleEvents ? "true" : "false"))
        query.append(URLQueryItem(name: "maxResults", value: "50"))
        let response = try await send("GET", url(["calendars", calendarID, "events"], query: query))
        let page: WireEventList = try decode(response.body, "events.list")
        let identities: WireInviteIdentityList = try decode(response.body, "events.list")
        var byID: [String: WireInviteIdentityList.Item] = [:]
        for item in identities.items ?? [] {
            if let id = item.id { byID[id] = item }
        }
        let candidates = (page.items ?? []).compactMap { $0.event(defaultZone: timeZone, calendarID: calendarID, selfAddress: calendarID) }
            .map { event in
                let identity = byID[event.id]
                let original = identity?.originalStartTime.flatMap { time in
                    time.dateTime.flatMap(RFC3339.date) ?? time.date.flatMap { RFC3339.day($0, in: timeZone) }
                }
                return GoogleInviteCandidate(event: event, iCalUID: identity?.iCalUID,
                                             organizerEmail: identity?.organizer?.email?.lowercased(),
                                             originalStart: original,
                                             isSeries: identity?.recurrence?.isEmpty == false && event.recurringEventID == nil)
            }
        let kind = iCalUID == nil ? ", by time" : singleEvents ? "" : ", series"
        Log(.gmail).notice("calendar events.list (invitation\(kind)): \(candidates.count) event(s)")
        return candidates.sorted { $0.event.start != $1.event.start ? $0.event.start < $1.event.start : $0.event.id < $1.event.id }
    }

    public func insertEvent(_ event: GoogleEventInsert, sendUpdates: GoogleSendUpdates,
                            addMeet: Bool) async throws -> GoogleCalendarEvent {
        let zone = TimeZone(identifier: event.timeZone) ?? timeZone
        var body = Self.insertBody(event, zone: zone)
        var query = [URLQueryItem(name: "sendUpdates", value: sendUpdates.rawValue)]
        if addMeet {
            let createRequest: [String: Any] = ["requestId": makeRequestID(),
                                                "conferenceSolutionKey": ["type": Self.meetSolutionType]]
            body["conferenceData"] = ["createRequest": createRequest]
            query.append(URLQueryItem(name: "conferenceDataVersion", value: "1"))
        }
        let response = try await send("POST", url(["calendars", calendarID, "events"], query: query), body: try json(body),
                                      isWrite: true)
        Log(.gmail).notice("calendar event created (attendees \(event.attendees.count), meet \(addMeet), "
                           + "sendUpdates \(sendUpdates.rawValue))")
        // Why: after a 2xx the event exists, so an unreadable answer is not reported as a failure
        let wire = (try? JSONDecoder().decode(WireEvent.self, from: response.body)) ?? WireEvent()
        if let created = wire.event(defaultZone: zone, calendarID: calendarID) { return created }
        Log(.gmail).notice("calendar event created; its answer could not be read in full")
        return GoogleCalendarEvent(id: wire.id ?? "", title: event.title, start: event.start, end: event.end,
                                   timeZone: zone.identifier,
                                   attendees: event.attendees.map { GoogleCalendarAttendee(email: $0) },
                                   meetLink: wire.meetLink,
                                   conferenceStatus: wire.conferenceData?.createRequest?.status?.statusCode)
    }

    static func insertBody(_ event: GoogleEventInsert, zone: TimeZone) -> [String: Any] {
        var body: [String: Any] = ["summary": event.title]
        let times = timeFields(start: event.start, end: event.end, isAllDay: event.isAllDay, zone: zone, forPatch: false)
        body["start"] = times.start
        body["end"] = times.end
        if !event.attendees.isEmpty {
            body["attendees"] = event.attendees.map { email -> [String: Any] in
                event.optionalAttendees.contains(email.lowercased()) ? ["email": email, "optional": true] : ["email": email]
            }
        }
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            body["location"] = location
        }
        if let notes = event.description?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            body["description"] = notes
        }
        for (key, value) in event.details.fields() where !(value is NSNull) { body[key] = value }
        return body
    }

    static func timeFields(start: Date, end: Date, isAllDay: Bool, zone: TimeZone,
                           forPatch: Bool) -> (start: [String: Any], end: [String: Any]) {
        if isAllDay {
            func day(_ date: Date) -> String {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = zone
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.string(from: date)
            }
            var first: [String: Any] = ["date": day(start)]
            var last: [String: Any] = ["date": day(end)]
            if forPatch { first["dateTime"] = NSNull(); last["dateTime"] = NSNull() }
            return (first, last)
        }
        var first: [String: Any] = ["dateTime": RFC3339.string(start, in: zone), "timeZone": zone.identifier]
        var last: [String: Any] = ["dateTime": RFC3339.string(end, in: zone), "timeZone": zone.identifier]
        if forPatch { first["date"] = NSNull(); last["date"] = NSNull() }
        return (first, last)
    }

    public func deleteEvent(id: String) async throws {
        let query = [URLQueryItem(name: "sendUpdates", value: GoogleSendUpdates.none.rawValue)]
        do {
            _ = try await send("DELETE", url(["calendars", calendarID, "events", id], query: query))
        } catch GoogleCalendarError.notFound {
            return
        } catch GoogleCalendarError.gone {
            return
        }
        Log(.gmail).notice("calendar event deleted (undo of a create)")
    }

    public func removeEvent(id: String, sendUpdates: GoogleSendUpdates) async throws {
        let query = [URLQueryItem(name: "sendUpdates", value: sendUpdates.rawValue)]
        do {
            _ = try await send("DELETE", url(["calendars", calendarID, "events", id], query: query), isWrite: true,
                               extraHeaders: [CalendarGuardTransport.removalRuleHeader: CalendarGuardTransport.removalRuleValue])
        } catch GoogleCalendarError.notFound {
            return
        } catch GoogleCalendarError.gone {
            return
        }
        Log(.gmail).notice("calendar event removed (sendUpdates \(sendUpdates.rawValue))")
    }

    public func moveEvent(id: String, start: Date, end: Date, timeZone zoneID: String,
                          sendUpdates: GoogleSendUpdates) async throws -> GoogleCalendarEvent? {
        let zone = TimeZone(identifier: zoneID) ?? timeZone
        let body: [String: Any] = [
            "start": ["dateTime": RFC3339.string(start, in: zone), "timeZone": zone.identifier],
            "end": ["dateTime": RFC3339.string(end, in: zone), "timeZone": zone.identifier],
        ]
        let query = [URLQueryItem(name: "sendUpdates", value: sendUpdates.rawValue)]
        let response = try await send("PATCH", url(["calendars", calendarID, "events", id], query: query),
                                      body: try json(body), isWrite: true)
        Log(.gmail).notice("calendar event moved (sendUpdates \(sendUpdates.rawValue))")
        let wire = try? JSONDecoder().decode(WireEvent.self, from: response.body)
        return wire?.event(defaultZone: zone, calendarID: calendarID)
    }

    // `alias` is the account's other address the invitation was sent to; it answers only when no entry is the calendar's own
    public func respond(eventID id: String, response: String, sendUpdates: GoogleSendUpdates,
                        as alias: String? = nil) async throws -> GoogleCalendarEvent? {
        guard Self.answers.contains(response) else { throw GoogleCalendarError.badRequest(reason: "response") }
        let current = try await send("GET", url(["calendars", calendarID, "events", id]))
        guard let object = try? JSONSerialization.jsonObject(with: current.body) as? [String: Any],
              let attendees = object["attendees"] as? [[String: Any]], !attendees.isEmpty else {
            throw GoogleCalendarError.decoding("events.get attendees")
        }
        let usesAlias = !attendees.contains { Self.isOwnEntry($0, calendarID: calendarID) }
        let answerAs = usesAlias ? alias?.trimmingCharacters(in: .whitespaces).lowercased() : nil
        let organizerEmail = ((object["organizer"] as? [String: Any])?["email"] as? String)?.lowercased()
        if answerAs != nil, organizerEmail == nil, !attendees.contains(where: { $0["organizer"] as? Bool == true }) {
            throw GoogleCalendarError.badRequest(reason: "not_invited")
        }
        var mine = 0
        let answered = attendees.map { entry -> [String: Any] in
            guard Self.isOwnEntry(entry, calendarID: calendarID, alias: answerAs) else { return entry }
            guard entry["organizer"] as? Bool != true,
                  (entry["email"] as? String)?.lowercased() != organizerEmail else { return entry }
            mine += 1
            var own = entry
            own["responseStatus"] = response
            return own
        }
        guard mine == 1 else { throw GoogleCalendarError.badRequest(reason: "not_invited") }
        var body: [String: Any] = ["attendees": answered]
        // Why: a shortened guest list sent back as it is would drop the guests Google left out
        if object["attendeesOmitted"] as? Bool == true { body["attendeesOmitted"] = true }
        let query = [URLQueryItem(name: "sendUpdates", value: sendUpdates.rawValue)]
        let headers = answerAs.map { [CalendarGuardTransport.answerAsHeader: $0] } ?? [:]
        let answer = try await send("PATCH", url(["calendars", calendarID, "events", id], query: query),
                                    body: try json(body), isWrite: true, extraHeaders: headers)
        Log(.gmail).notice("calendar invitation answered (sendUpdates \(sendUpdates.rawValue)"
                           + (answerAs == nil ? ")" : ", as an alias)"))
        let wire = try? JSONDecoder().decode(WireEvent.self, from: answer.body)
        return wire?.event(defaultZone: timeZone, calendarID: calendarID, selfAddress: answerAs ?? calendarID)
    }

    public func patchEvent(id: String, patch: GoogleEventPatch, sendUpdates: GoogleSendUpdates) async throws -> GoogleCalendarEvent? {
        var current: [[String: Any]] = []
        var attendeesOmitted = false
        if patch.guests != nil {
            let read = try await send("GET", url(["calendars", calendarID, "events", id]))
            guard let object = try? JSONSerialization.jsonObject(with: read.body) as? [String: Any] else {
                throw GoogleCalendarError.decoding("events.get attendees")
            }
            current = object["attendees"] as? [[String: Any]] ?? []
            attendeesOmitted = object["attendeesOmitted"] as? Bool == true
        }
        var body = Self.patchBody(patch, currentAttendees: current, zone: timeZone, requestID: makeRequestID())
        if attendeesOmitted { body["attendeesOmitted"] = true }
        var query = [URLQueryItem(name: "sendUpdates", value: sendUpdates.rawValue)]
        if body["conferenceData"] != nil { query.append(URLQueryItem(name: "conferenceDataVersion", value: "1")) }
        let response = try await send("PATCH", url(["calendars", calendarID, "events", id], query: query),
                                      body: try json(body), isWrite: true,
                                      extraHeaders: [CalendarGuardTransport.editRuleHeader: CalendarGuardTransport.editRuleValue])
        Log(.gmail).notice("calendar event patched (fields \(body.count), sendUpdates \(sendUpdates.rawValue))")
        let wire = try? JSONDecoder().decode(WireEvent.self, from: response.body)
        return wire?.event(defaultZone: timeZone, calendarID: calendarID, selfAddress: calendarID)
    }

    public func readEvent(id: String) async throws -> GoogleCalendarEvent? {
        let read = try await send("GET", url(["calendars", calendarID, "events", id]))
        let wire = try? JSONDecoder().decode(WireEvent.self, from: read.body)
        return wire?.event(defaultZone: timeZone, calendarID: calendarID, selfAddress: calendarID)
    }

    public func seriesRecurrence(id: String) async throws -> [String] {
        let read = try await send("GET", url(["calendars", calendarID, "events", id]))
        let object = try? JSONSerialization.jsonObject(with: read.body) as? [String: Any]
        return object?["recurrence"] as? [String] ?? []
    }

    static func patchBody(_ patch: GoogleEventPatch, currentAttendees: [[String: Any]], zone: TimeZone,
                          requestID: String) -> [String: Any] {
        var body = patch.details.fields()
        if let title = patch.title { body["summary"] = title }
        if let location = patch.location { body["location"] = location }
        if let description = patch.description { body["description"] = description }
        if let time = patch.time {
            let zone = TimeZone(identifier: time.timeZone) ?? zone
            let fields = timeFields(start: time.start, end: time.end, isAllDay: time.isAllDay, zone: zone, forPatch: true)
            body["start"] = fields.start
            body["end"] = fields.end
        }
        if let guests = patch.guests { body["attendees"] = mergeAttendees(current: currentAttendees, wanted: guests) }
        switch patch.meet {
        case .add?:
            body["conferenceData"] = ["createRequest": ["requestId": requestID,
                                                        "conferenceSolutionKey": ["type": meetSolutionType]]]
        case .remove?:
            body["conferenceData"] = NSNull()
        case nil: break
        }
        return body
    }

    static func mergeAttendees(current: [[String: Any]], wanted: [GoogleGuestEdit]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var kept = Set<String>()
        for guest in wanted {
            let key = guest.email.lowercased()
            guard kept.insert(key).inserted else { continue }
            if var entry = current.first(where: { ($0["email"] as? String)?.lowercased() == key }) {
                if guest.isOptional { entry["optional"] = true } else { entry.removeValue(forKey: "optional") }
                result.append(entry)
            } else {
                var entry: [String: Any] = ["email": guest.email]
                if let name = guest.name, !name.isEmpty { entry["displayName"] = name }
                if guest.isOptional { entry["optional"] = true }
                result.append(entry)
            }
        }
        for entry in current {
            let key = (entry["email"] as? String)?.lowercased() ?? ""
            let protected = entry["self"] as? Bool == true || entry["organizer"] as? Bool == true
            if protected, !kept.contains(key) { result.append(entry) }
        }
        return result
    }

    public static let answers: Set<String> = ["accepted", "declined", "tentative"]

    static func isOwnEntry(_ entry: [String: Any], calendarID: String, alias: String? = nil) -> Bool {
        if entry["self"] as? Bool == true { return true }
        let email = (entry["email"] as? String)?.lowercased()
        if email == calendarID.lowercased() { return true }
        guard let alias, !alias.isEmpty else { return false }
        return email == alias.lowercased()
    }

    // Why: URLComponents leaves `+` in a query value and Google would read it as a space, so it is encoded
    func url(_ segments: [String], query: [URLQueryItem] = []) -> URL {
        var url = Self.base
        for segment in segments { url = url.appendingPathComponent(segment, isDirectory: false) }
        guard !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? url
    }

    func json(_ object: [String: Any]) throws -> Data {
        do { return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) } catch {
            throw GoogleCalendarError.decoding("request body")
        }
    }

    func decode<T: Decodable>(_ body: Data, _ what: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: body) } catch { throw GoogleCalendarError.decoding(what) }
    }

    func send(_ method: String, _ url: URL, body: Data? = nil, isWrite: Bool = false,
                      extraHeaders: [String: String] = [:]) async throws -> HTTPResponse {
        var forceRefresh = false
        while true {
            if Task.isCancelled { throw GoogleCalendarError.cancelled }
            guard budget.take(now: clock.now) else {
                Log(.gmail).notice("calendar request not sent: Mail's per-minute budget is spent or Google asked to wait")
                throw GoogleCalendarError.rateLimited
            }
            let token: String
            do { token = try await tokens.accessToken(forceRefresh: forceRefresh) } catch {
                throw Self.tokenError(error)
            }
            var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
            if body != nil { headers["Content-Type"] = "application/json" }
            headers.merge(extraHeaders) { $1 }
            let response: HTTPResponse
            do {
                response = try await transport.send(HTTPRequest(method: method, url: url, headers: headers, body: body))
            } catch let error as GoogleCalendarRemovalError {
                throw error
            } catch let error as TransportError {
                switch error {
                case .refusedByGuard(let summary): throw GoogleCalendarError.refusedByGuard(summary)
                case .cancelled: throw GoogleCalendarError.cancelled
                default:
                    if isWrite, Self.mayHaveBeenSent(error) {
                        Log(.gmail).notice("calendar \(method): outcome unclear (transport)")
                        throw GoogleCalendarError.unclear
                    }
                    throw GoogleCalendarError.transport(error)
                }
            } catch is CancellationError {
                throw GoogleCalendarError.cancelled
            } catch {
                if isWrite { throw GoogleCalendarError.unclear }
                throw GoogleCalendarError.transport(.other(String(describing: type(of: error))))
            }
            if (200..<300).contains(response.status) { return response }
            if response.status == 401, !forceRefresh, extraHeaders[CalendarGuardTransport.scopedRemovalHeader] == nil {
                forceRefresh = true
                continue
            }
            let failure = Self.error(response)
            if failure == .rateLimited {
                let wait = response.headers["retry-after"].flatMap { RetryAfter.parse($0, now: clock.now) }
                budget.noteRateLimited(now: clock.now, retryAfter: wait?.timeInterval)
            }
            Log(.gmail).notice("calendar \(method) failed (\(failure.code))")
            if isWrite, case .server = failure { throw GoogleCalendarError.unclear }
            throw failure
        }
    }

    static func mayHaveBeenSent(_ error: TransportError) -> Bool {
        switch error {
        case .timedOut, .connectionLost(requestMayHaveBeenSent: true), .other: true
        case .notConnected, .connectionLost(requestMayHaveBeenSent: false), .cannotConnect, .tls, .cancelled,
             .refusedByGuard: false
        }
    }

    static func error(_ response: HTTPResponse) -> GoogleCalendarError {
        let reason = GoogleErrorBody.parse(response.body)?.reason.flatMap(Self.code)
        switch response.status {
        case 400: return .badRequest(reason: reason ?? "bad_request")
        case 401: return .unauthorized
        case 403:
            if reason == "rateLimitExceeded" || reason == "userRateLimitExceeded" { return .rateLimited }
            return .forbidden(reason: reason ?? "forbidden")
        case 404: return .notFound
        case 410: return .gone
        case 412: return .badRequest(reason: "precondition_failed")
        case 429: return .rateLimited
        case 500...599: return .server(status: response.status)
        default: return .badRequest(reason: reason ?? "http_\(response.status)")
        }
    }

    static func code(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 64,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }),
              value.allSatisfy(\.isASCII) else { return nil }
        return value
    }

    static func tokenError(_ error: Error) -> GoogleCalendarError {
        switch error {
        case OAuthError.reauthRequired: return .reauthRequired
        case OAuthError.cancelled, is CancellationError: return .cancelled
        case OAuthError.tokenEndpoint(let status, _, _) where status >= 500: return .server(status: status)
        case let transport as TransportError: return transport == .cancelled ? .cancelled : .transport(transport)
        default: return .unauthorized
        }
    }
}
