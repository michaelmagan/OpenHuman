import Foundation

/// Google's original recurrence position is independent of an occurrence's displayed time.
public enum CalendarOriginalStart: Sendable, Hashable, Codable {
    case date(String)
    case timed(Date, timeZone: String?)

    public func isAtOrAfter(_ other: CalendarOriginalStart) -> Bool? {
        guard isValid, other.isValid else { return nil }
        switch (self, other) {
        case (.date(let a), .date(let b)): return a >= b
        case (.timed(let a, _), .timed(let b, _)): return a >= b
        default: return nil
        }
    }

    public var isValid: Bool {
        switch self {
        case .date(let text):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .gmt
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let date = formatter.date(from: text) else { return false }
            return formatter.string(from: date) == text
        case .timed(let date, let zone):
            return date.timeIntervalSinceReferenceDate.isFinite && (zone == nil || zone.flatMap(TimeZone.init(identifier:)) != nil)
        }
    }
}

extension CalendarEvent {
    /// Deliberately separate from isRecurring, which also controls legacy editing.
    public var isRecurringForRemoval: Bool { isRecurring || !extras.recurrence.isEmpty || originalStartTime != nil }

    /// Enrich an older payload without overwriting locally saved fields that still carry the previous etag.
    public func fillingRemovalIdentity(from fresh: CalendarEvent) -> CalendarEvent {
        guard id == fresh.id, originalStartTime == nil, let original = fresh.originalStartTime, original.isValid,
              recurringEventID == nil || recurringEventID == fresh.recurringEventID else { return self }
        var enriched = CalendarEvent(id: id, title: title, start: start, end: end, isAllDay: isAllDay, timeZone: timeZone,
            attendees: attendees, calendarName: calendarName, meetLink: meetLink, organizerIsMe: organizerIsMe,
            account: account, location: location, notes: notes, myResponse: myResponse,
            recurringEventID: recurringEventID ?? fresh.recurringEventID, originalStartTime: original, extras: extras,
            uid: uid ?? fresh.uid, organizer: organizer ?? fresh.organizer, guestsOmitted: guestsOmitted)
        enriched.respondsAs = respondsAs
        return enriched
    }
}

extension CalendarRecurrenceScope {
    public static let removalOptions: [Self] = [.thisEvent, .allEvents, .thisAndFollowing]
    /// A guest removes their own copies; only the organizer can end someone else's series early.
    public static let invitationRemovalOptions: [Self] = [.thisEvent, .allEvents]

    public var removalTitle: String {
        switch self {
        case .thisEvent: String(localized: "This event")
        case .allEvents: String(localized: "All events in the series")
        case .thisAndFollowing: String(localized: "This and future events")
        }
    }
}

/// The server version returned by a verified conditional PATCH of the actual master to its planned strict prefix.
/// Google's read-only updated time bounds later occurrence changes; opaque etags establish identity, not ordering.
public struct CalendarConfirmedMasterVersion: Sendable, Hashable {
    public let etag: String
    public let updated: Date

    public init(etag: String, updated: Date) {
        self.etag = etag
        self.updated = updated
    }
}

/// Returned only after the provider has confirmed every mutation in the requested scope.
public struct CalendarRemovalResult: Sendable, Hashable {
    public let selectedID: String
    public let parentID: String?
    public let scope: CalendarRecurrenceScope
    public let originalCutoff: CalendarOriginalStart?
    public let confirmedMasterVersion: CalendarConfirmedMasterVersion?

    public init(selectedID: String, parentID: String?, scope: CalendarRecurrenceScope,
                originalCutoff: CalendarOriginalStart?, confirmedMasterVersion: CalendarConfirmedMasterVersion? = nil) {
        self.selectedID = selectedID
        self.parentID = parentID
        self.scope = scope
        self.originalCutoff = originalCutoff
        self.confirmedMasterVersion = confirmedMasterVersion
    }

    /// nil means an old cache row cannot be classified; its coverage needs a fresh read.
    public func affects(_ event: CalendarEvent) -> Bool? {
        if event.id == selectedID { return true }
        if scope == .thisEvent { return false }
        guard let parentID else { return false }
        // A distinct master has its own parent ID; an occurrence without its parent is still ambiguous.
        if event.recurringEventID == nil, event.id != parentID, event.originalStartTime != nil { return nil }
        guard event.recurringEventID == parentID || event.id == parentID else { return false }
        if scope == .allEvents { return true }
        guard event.id != parentID, let original = event.originalStartTime, let originalCutoff else { return nil }
        return original.isAtOrAfter(originalCutoff)
    }

    public func affects(_ record: CalendarEventRecord) -> Bool? {
        if record.event.id == selectedID { return true }
        if scope == .thisEvent { return false }
        if let eventParent = record.event.recurringEventID, let recordParent = record.recurringEventID,
           eventParent != recordParent { return nil }
        var event = record.event
        event.recurringEventID = event.recurringEventID ?? record.recurringEventID
        return affects(event)
    }
}

extension CalendarProviding {
    public var removalIdentity: ObjectIdentifier? {
        if Mirror(reflecting: self).displayStyle == .class { return ObjectIdentifier(self as AnyObject) }
        return nil
    }

    public var removalScopes: [CalendarRecurrenceScope] { [] }

    public func removeEvent(_ event: CalendarEvent, scope: CalendarRecurrenceScope,
                            sendUpdates: CalendarSendUpdates) async throws -> CalendarRemovalResult {
        guard scope == .thisEvent, !event.isRecurringForRemoval else {
            throw CalendarError.refused("This calendar doesn't support removing repeating events from Mail.")
        }
        try await removeEvent(event, sendUpdates: sendUpdates)
        return CalendarRemovalResult(selectedID: event.id, parentID: nil, scope: scope, originalCutoff: nil)
    }

    /// Resolve routing once, before an Undo hold; a router must not switch accounts at dispatch time.
    public func removalProvider(for event: CalendarEvent) throws -> any CalendarProviding { self }
}
