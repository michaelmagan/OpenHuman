import Foundation
import OpenHumanCore

public enum GoogleRemovalScope: String, Sendable, Hashable { case thisEvent, allEvents, thisAndFollowing }

/// Evidence from the matching Events resource returned by a confirmed conditional prefix PATCH, never a local clock.
public struct GoogleConfirmedMasterVersion: Sendable {
    public let etag: String
    public let updated: Date
}

public struct GoogleRemovalResult: Sendable {
    public let selectedID: String
    public let parentID: String?
    public let originalCutoff: GoogleOriginalStart?
    public let confirmedMasterVersion: GoogleConfirmedMasterVersion?
}

// Only the scoped planner can register one of these one-use authorizations with its own guard.
struct CalendarRemovalAuthorization: Sendable {
    let method: String
    let target: String
    let etag: String
    let parent: String?
    let original: GoogleOriginalStart?
    let master: Bool
    let body: Data?
    let sendUpdates: String
    let allowAbsentCleanup: Bool
    /// Removes this calendar's copy of an event another calendar organizes; never notifies anyone.
    var asGuest = false
}

extension GoogleCalendarClient {
    private struct RemovalSnapshot {
        let wire: WireEvent
        let updated: Date?
    }

    public func removeEvent(id: String, expectedParent: String?, expectedOriginal: GoogleOriginalStart?,
                            scope: GoogleRemovalScope, sendUpdates: GoogleSendUpdates) async throws -> GoogleRemovalResult {
        guard allowsWrites else { throw GoogleCalendarRemovalError.refused("This calendar connection is read only.") }
        let selectedSnapshot = try await removalSnapshot(id)
        let selected = selectedSnapshot.wire
        let parent = WireEvent.text(selected.recurringEventId)
        if let expectedParent, parent != expectedParent {
            throw GoogleCalendarRemovalError.refused("The event's series changed. Refresh the calendar before deleting.")
        }
        if let expectedOriginal, selected.originalStartTime?.original != expectedOriginal {
            throw GoogleCalendarRemovalError.refused("The original recurrence position changed. Refresh the calendar.")
        }
        let master = selected.recurrence?.isEmpty == false
        let recurring = master || parent != nil
        // A master is never a valid 'this event' target. Expanded instances supply an authoritative position.
        if master && scope != .allEvents {
            throw GoogleCalendarRemovalError.refused("Open an occurrence of this series before choosing this deletion scope.")
        }
        guard recurring || scope == .thisEvent else {
            throw GoogleCalendarRemovalError.refused("This event no longer belongs to a repeating series.")
        }
        if parent != nil && selected.originalStartTime?.original == nil {
            throw GoogleCalendarRemovalError.refused("Google didn't supply the original recurrence position. Refresh the calendar.")
        }
        let updates: GoogleSendUpdates = recurring ? .all : sendUpdates
        try authorizeSnapshot(selected, updates: updates)
        let result = GoogleRemovalResult(selectedID: id, parentID: parent ?? (master ? id : nil),
                                         originalCutoff: selected.originalStartTime?.original, confirmedMasterVersion: nil)
        if scope == .thisEvent {
            try await performRemoval(selected, method: "DELETE", body: nil, updates: updates)
            return result
        }
        let seriesID = parent ?? id
        let seriesSnapshot: RemovalSnapshot
        if master { seriesSnapshot = selectedSnapshot } else { seriesSnapshot = try await removalSnapshot(seriesID) }
        let series = seriesSnapshot.wire
        guard series.recurringEventId == nil, series.recurrence?.isEmpty == false else {
            throw GoogleCalendarRemovalError.refused("Google didn't return the actual series master. Refresh the calendar.")
        }
        try authorizeSnapshot(series, updates: .all)
        if scope == .allEvents {
            try await performRemoval(series, method: "DELETE", body: nil, updates: .all)
            return result
        }
        guard let cutoff = selected.originalStartTime?.original, let start = series.start?.original else {
            throw GoogleCalendarRemovalError.refused("The series needs a readable original position and an explicit time zone.")
        }
        let zone = try await removalTimeZone(series)
        let prefix = try GoogleRemovalPrefix.plan(series.recurrence ?? [], start: start, cutoff: cutoff, timeZone: zone)
        let exceptions = try await removalExceptions(parent: seriesID)
        var cleanup: [WireEvent] = []
        for exception in exceptions {
            guard let original = exception.originalStartTime?.original else {
                throw GoogleCalendarRemovalError.refused("An exception has no original recurrence position. Nothing was deleted.")
            }
            guard try original.atOrAfter(cutoff) else {
                throw GoogleCalendarRemovalError.refused("This series has an earlier detached or canceled exception. Mail can't guarantee it survives shortening the series. Remove this event or all events instead.")
            }
            if exception.status == "cancelled" { continue }
            guard let exceptionID = exception.id else { throw GoogleCalendarRemovalError.refused("An exception is unreadable.") }
            let freshSnapshot = try await removalSnapshot(exceptionID)
            let fresh = freshSnapshot.wire
            guard fresh.recurringEventId == seriesID, fresh.originalStartTime?.original == original else {
                throw GoogleCalendarRemovalError.refused("An exception changed while preparing deletion. Refresh the calendar.")
            }
            try authorizeSnapshot(fresh, updates: .all)
            cleanup.append(fresh)
        }
        // Every target is read and authorized before the first write. No ordinary generated instance is enumerated here.
        let body: Data?
        if prefix.isEmpty { body = nil } else { body = try json(["recurrence": prefix.recurrence]) }
        let response = try await performRemoval(series, method: prefix.isEmpty ? "DELETE" : "PATCH", body: body, updates: .all)
        if !prefix.isEmpty {
            do {
                for exception in cleanup {
                    try await performRemoval(exception, method: "DELETE", body: nil, updates: .all, allowAbsentCleanup: true)
                }
            } catch {
                // The trim was confirmed; a later cleanup failure cannot be represented as whole-scope success.
                throw GoogleCalendarRemovalError.uncertain
            }
        }
        let version = prefix.isEmpty ? nil : confirmedTrimVersion(response.body, series: seriesSnapshot, recurrence: prefix.recurrence)
        return GoogleRemovalResult(selectedID: result.selectedID, parentID: result.parentID,
                                   originalCutoff: result.originalCutoff, confirmedMasterVersion: version)
    }

    /// Removes this calendar's copy of an invitation without answering it. Only the organizer can change the
    /// series itself, so a guest removes one occurrence or every occurrence, never "this and following".
    public func removeInvitation(id: String, expectedParent: String?, expectedOriginal: GoogleOriginalStart?,
                                 scope: GoogleRemovalScope) async throws -> GoogleRemovalResult {
        guard allowsWrites else { throw GoogleCalendarRemovalError.refused("This calendar connection is read only.") }
        guard scope != .thisAndFollowing else {
            throw GoogleCalendarRemovalError.refused("Only the organizer can end this series early. Remove this event or all events instead.")
        }
        let selected = try await removalSnapshot(id).wire
        let parent = WireEvent.text(selected.recurringEventId)
        if let expectedParent, parent != expectedParent {
            throw GoogleCalendarRemovalError.refused("The event's series changed. Refresh the calendar before removing it.")
        }
        if let expectedOriginal, selected.originalStartTime?.original != expectedOriginal {
            throw GoogleCalendarRemovalError.refused("The original recurrence position changed. Refresh the calendar.")
        }
        let master = selected.recurrence?.isEmpty == false
        if master && scope != .allEvents {
            throw GoogleCalendarRemovalError.refused("Open an occurrence of this series before choosing this scope.")
        }
        guard master || parent != nil || scope == .thisEvent else {
            throw GoogleCalendarRemovalError.refused("This event no longer belongs to a repeating series.")
        }
        try authorizeGuestSnapshot(selected)
        let result = GoogleRemovalResult(selectedID: id, parentID: parent ?? (master ? id : nil),
                                         originalCutoff: selected.originalStartTime?.original, confirmedMasterVersion: nil)
        if scope == .thisEvent {
            try await performRemoval(selected, method: "DELETE", body: nil, updates: .none, asGuest: true)
            return result
        }
        let series = master ? selected : try await removalSnapshot(parent ?? id).wire
        guard series.recurringEventId == nil, series.recurrence?.isEmpty == false else {
            throw GoogleCalendarRemovalError.refused("Google didn't return the actual series. Refresh the calendar.")
        }
        try authorizeGuestSnapshot(series)
        try await performRemoval(series, method: "DELETE", body: nil, updates: .none, asGuest: true)
        return result
    }

    private func authorizeGuestSnapshot(_ event: WireEvent) throws {
        guard event.eventType == nil || event.eventType == "default", event.isGuestCopy(on: calendarID) else {
            throw GoogleCalendarRemovalError.refused("Mail removes only ordinary invitations someone else organizes.")
        }
    }

    private func removalSnapshot(_ id: String) async throws -> RemovalSnapshot {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw GoogleCalendarRemovalError.refused("The event ID is unreadable.")
        }
        let answer = try await send("GET", url(["calendars", calendarID, "events", id]))
        let wire: WireEvent = try decode(answer.body, "removal preflight")
        guard wire.id == id, wire.status != "cancelled", wire.event(defaultZone: .gmt) != nil,
              wire.etag?.isEmpty == false else {
            throw GoogleCalendarRemovalError.refused("Google didn't return a current, versioned event. Refresh before deleting.")
        }
        return RemovalSnapshot(wire: wire, updated: removalServerUpdated(answer.body, id: id))
    }

    private func removalServerUpdated(_ body: Data, id: String) -> Date? {
        guard let meta = try? JSONDecoder().decode(WireEventMeta.self, from: body), meta.id == id,
              let updated = meta.updated.flatMap(RFC3339.date), updated.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return updated
    }

    private func confirmedTrimVersion(_ body: Data, series: RemovalSnapshot, recurrence: [String]) -> GoogleConfirmedMasterVersion? {
        guard let id = series.wire.id,
              let wire = try? JSONDecoder().decode(WireEvent.self, from: body), wire.id == id,
              wire.recurringEventId == nil, wire.originalStartTime == nil,
              wire.status == "confirmed" || wire.status == "tentative",
              wire.eventType == nil || wire.eventType == "default",
              wire.removalOwned(by: calendarID, allowCreator: false), wire.event(defaultZone: .gmt) != nil,
              wire.recurrence == recurrence, !recurrence.isEmpty,
              let etag = wire.etag, !etag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              etag != series.wire.etag, let updated = removalServerUpdated(body, id: id),
              series.updated.map({ updated >= $0 }) ?? true else { return nil }
        // PATCH returns the modified master. Missing/mismatched evidence does not undo or replay a confirmed write.
        return GoogleConfirmedMasterVersion(etag: etag, updated: updated)
    }

    private func authorizeSnapshot(_ event: WireEvent, updates: GoogleSendUpdates) throws {
        let recurring = event.recurringEventId != nil || event.recurrence?.isEmpty == false
        guard event.eventType == nil || event.eventType == "default",
              event.removalOwned(by: calendarID, allowCreator: !recurring) else {
            throw GoogleCalendarRemovalError.refused("Mail deletes only ordinary events this calendar organizes.")
        }
        if recurring {
            guard updates == .all else { throw GoogleCalendarRemovalError.refused("Recurring deletion must notify all guests.") }
        } else if (event.attendees ?? []).contains(where: {
            $0.`self` != true && $0.email?.lowercased() != calendarID.lowercased() && $0.resource != true
        }) && updates == .none {
            throw GoogleCalendarRemovalError.refused("Deleting an event with guests must notify them.")
        }
    }

    private func removalTimeZone(_ series: WireEvent) async throws -> String {
        if let name = series.start?.timeZone ?? series.end?.timeZone, TimeZone(identifier: name) != nil { return name }
        let answer = try await send("GET", url(["calendars", calendarID]))
        guard let object = try? JSONSerialization.jsonObject(with: answer.body) as? [String: Any],
              (object["id"] as? String)?.lowercased() == calendarID.lowercased(),
              let name = object["timeZone"] as? String, TimeZone(identifier: name) != nil else {
            throw GoogleCalendarRemovalError.refused("Google didn't return the series calendar's time zone.")
        }
        return name
    }

    private func removalExceptions(parent: String) async throws -> [WireEvent] {
        var result: [WireEvent] = []
        var token: String?
        var seenTokens = Set<String>()
        var seenIDs = Set<String>()
        for _ in 0..<Self.maxSyncPages {
            var query = [URLQueryItem(name: "singleEvents", value: "false"),
                         URLQueryItem(name: "showDeleted", value: "true"),
                         URLQueryItem(name: "maxResults", value: String(Self.pageSize))]
            if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let answer = try await send("GET", url(["calendars", calendarID, "events"], query: query))
            let page: WireEventList = try decode(answer.body, "removal exceptions")
            guard let items = page.items, items.count <= Self.pageSize else {
                throw GoogleCalendarRemovalError.refused("Google returned an incomplete exception list. Nothing was deleted.")
            }
            for item in items {
                guard let id = item.id, !id.isEmpty, seenIDs.insert(id).inserted else {
                    throw GoogleCalendarRemovalError.refused("Google returned an unreadable or repeated exception. Nothing was deleted.")
                }
                if item.recurringEventId == parent {
                    guard item.originalStartTime?.original != nil else {
                        throw GoogleCalendarRemovalError.refused("An exception has no original recurrence position. Nothing was deleted.")
                    }
                    result.append(item)
                } else if item.originalStartTime != nil && item.recurringEventId == nil {
                    throw GoogleCalendarRemovalError.refused("An exception's parent is unreadable. Nothing was deleted.")
                }
            }
            guard let next = page.nextPageToken else { return result }
            guard !next.isEmpty, seenTokens.insert(next).inserted else {
                throw GoogleCalendarRemovalError.refused("The exception list did not finish. Nothing was deleted.")
            }
            token = next
        }
        throw GoogleCalendarRemovalError.refused("The exception list exceeds Mail's safe limit. Nothing was deleted.")
    }

    @discardableResult
    private func performRemoval(_ target: WireEvent, method: String, body: Data?, updates: GoogleSendUpdates,
                                allowAbsentCleanup: Bool = false, asGuest: Bool = false) async throws -> HTTPResponse {
        guard let id = target.id, let etag = target.etag else { throw GoogleCalendarRemovalError.conflict }
        let authorization = CalendarRemovalAuthorization(method: method, target: id, etag: etag,
            parent: target.recurringEventId, original: target.originalStartTime?.original,
            master: target.recurrence?.isEmpty == false, body: body, sendUpdates: updates.rawValue,
            allowAbsentCleanup: allowAbsentCleanup, asGuest: asGuest)
        let nonce = transport.authorizeRemoval(authorization)
        defer { transport.discardRemovalAuthorization(nonce) }
        return try await send(method, url(["calendars", calendarID, "events", id],
            query: [URLQueryItem(name: "sendUpdates", value: updates.rawValue)]), body: body, isWrite: true,
            extraHeaders: [CalendarGuardTransport.scopedRemovalHeader: nonce, "If-Match": etag])
    }
}
