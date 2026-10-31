import Foundation
import OpenHumanCore

public struct CalendarCacheKey: Hashable, Sendable, Codable, Comparable {
    public let account: String
    public let calendar: String

    public init(account: String, calendar: String) {
        self.account = account.lowercased()
        self.calendar = calendar.lowercased()
    }

    public init(provider info: CalendarProviderInfo) {
        let account = info.account ?? ""
        self.init(account: account, calendar: account.isEmpty ? info.name : account)
    }

    public static func < (a: CalendarCacheKey, b: CalendarCacheKey) -> Bool {
        (a.account, a.calendar) < (b.account, b.calendar)
    }
}

public struct CalendarAllDayDates: Sendable, Hashable, Codable {
    public let start: String
    public let end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }

    public init(start: Date, end: Date, in zone: TimeZone) {
        self.start = Self.text(start, zone)
        self.end = Self.text(end, zone)
    }

    public static func midnight(_ text: String, in zone: TimeZone) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func text(_ date: Date, _ zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

public struct CalendarEventRecord: Sendable, Hashable {
    public var event: CalendarEvent
    public var etag: String?
    public var updated: Date?
    public var recurringEventID: String?
    public var isBusy: Bool
    public var declinedByMe: Bool
    public var allDayDates: CalendarAllDayDates?

    public init(event: CalendarEvent, etag: String? = nil, updated: Date? = nil, recurringEventID: String? = nil,
                isBusy: Bool? = nil, declinedByMe: Bool = false, readIn zone: TimeZone = .current) {
        self.event = event
        self.etag = etag
        self.updated = updated
        self.recurringEventID = recurringEventID
        self.isBusy = event.isAllDay ? false : (isBusy ?? true)
        self.declinedByMe = declinedByMe
        allDayDates = event.isAllDay
            ? CalendarAllDayDates(start: event.start, end: event.end,
                                  in: event.timeZone.flatMap(TimeZone.init(identifier:)) ?? zone)
            : nil
    }

    public func isSameVersion(as other: CalendarEventRecord) -> Bool {
        if let etag, let theirs = other.etag { return etag == theirs && event.id == other.event.id }
        return self == other
    }

    public func materialized(in zone: TimeZone) -> CalendarEventRecord {
        var moved = self
        // Older payloads can carry the known parent only on the record.
        moved.event.recurringEventID = event.recurringEventID ?? recurringEventID
        guard event.isAllDay, event.timeZone == nil, let dates = allDayDates,
              let start = CalendarAllDayDates.midnight(dates.start, in: zone),
              let end = CalendarAllDayDates.midnight(dates.end, in: zone),
              start != event.start || end != event.end else { return moved }
        moved.event = CalendarEvent(id: event.id, title: event.title, start: start, end: end, isAllDay: true,
                                    timeZone: nil, attendees: event.attendees, calendarName: event.calendarName,
                                    meetLink: event.meetLink, organizerIsMe: event.organizerIsMe, account: event.account,
                                    location: event.location, notes: event.notes, myResponse: event.myResponse,
                                    recurringEventID: moved.event.recurringEventID, originalStartTime: event.originalStartTime,
                                    extras: event.extras)
        moved.event.respondsAs = event.respondsAs
        return moved
    }
}

public struct CalendarEventWindow: Sendable, Hashable {
    public var records: [CalendarEventRecord]
    public var syncToken: String?
    public var isComplete: Bool

    public init(records: [CalendarEventRecord], syncToken: String? = nil, isComplete: Bool = true) {
        self.records = records
        self.syncToken = syncToken
        self.isComplete = isComplete
    }
}

public struct CalendarEventCancellation: Sendable, Hashable {
    public let id: String
    public let parentID: String?
    public let originalStartTime: CalendarOriginalStart?

    public init(id: String, parentID: String?, originalStartTime: CalendarOriginalStart?) {
        self.id = id
        self.parentID = parentID
        self.originalStartTime = originalStartTime
    }
}

public struct CalendarEventDelta: Sendable, Hashable {
    public var changed: [CalendarEventRecord]
    public var removed: [String]
    public var syncToken: String?
    public var cancellations: [CalendarEventCancellation]

    public init(changed: [CalendarEventRecord] = [], removed: [String] = [], syncToken: String? = nil,
                cancellations: [CalendarEventCancellation] = []) {
        self.cancellations = cancellations
        self.changed = changed
        self.removed = removed
        self.syncToken = syncToken
    }
}

public enum CalendarSyncError: Error, Sendable, Hashable {
    case tokenExpired
    case unsupported
    case rateLimited(retryAfter: TimeInterval?)
}

extension CalendarProviding {
    public func eventWindow(from: Date, to: Date) async throws -> CalendarEventWindow {
        CalendarEventWindow(records: try await events(from: from, to: to).map { CalendarEventRecord(event: $0) })
    }

    public func eventDelta(since token: String) async throws -> CalendarEventDelta {
        throw CalendarSyncError.unsupported
    }
}

public struct CalendarCoveredRange: Sendable, Hashable, Codable {
    public let start: Date
    public let end: Date
    public let fetchedAt: Date

    public init(start: Date, end: Date, fetchedAt: Date) {
        self.start = start
        self.end = end
        self.fetchedAt = fetchedAt
    }
}

public struct CalendarCacheEntry: Sendable, Hashable {
    public var key: CalendarCacheKey
    public var records: [CalendarEventRecord]
    public var ranges: [CalendarCoveredRange]
    public var syncToken: String?

    public init(key: CalendarCacheKey, records: [CalendarEventRecord] = [], ranges: [CalendarCoveredRange] = [],
                syncToken: String? = nil) {
        self.key = key
        self.records = records
        self.ranges = ranges
        self.syncToken = syncToken
    }
}

public enum CalendarCacheWrite: Sendable, Hashable {
    case save(CalendarCacheKey, upserted: [CalendarEventRecord], removed: [String], ranges: [CalendarCoveredRange],
              syncToken: String?)
    case replace(CalendarCacheEntry)
    case forgetCalendar(CalendarCacheKey)
    case forgetAccount(String)
    case forgetAll
}

public protocol CalendarCachePersisting: Sendable {
    func load() async -> [CalendarCacheEntry]
    func apply(_ write: CalendarCacheWrite) async
}

public actor InMemoryCalendarCache: CalendarCachePersisting {
    private var entries: [CalendarCacheKey: CalendarCacheEntry]
    public private(set) var writes: [CalendarCacheWrite] = []

    public init(entries: [CalendarCacheEntry] = []) {
        self.entries = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func load() async -> [CalendarCacheEntry] { entries.values.sorted { $0.key < $1.key } }

    public func apply(_ write: CalendarCacheWrite) async {
        writes.append(write)
        switch write {
        case .save(let key, let upserted, let removed, let ranges, let token):
            var entry = entries[key] ?? CalendarCacheEntry(key: key)
            var byID = Dictionary(entry.records.map { ($0.event.id, $0) }, uniquingKeysWith: { _, last in last })
            for id in removed { byID[id] = nil }
            for record in upserted { byID[record.event.id] = record }
            entry.records = byID.values.sorted { $0.event.id < $1.event.id }
            entry.ranges = ranges
            entry.syncToken = token
            entries[key] = entry
        case .replace(let entry):
            entries[entry.key] = entry
        case .forgetCalendar(let key):
            entries[key] = nil
        case .forgetAccount(let account):
            entries = entries.filter { $0.key.account != account.lowercased() }
        case .forgetAll:
            entries.removeAll()
        }
    }

    public var stored: [CalendarCacheEntry] { entries.values.sorted { $0.key < $1.key } }
}
