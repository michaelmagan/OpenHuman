import Foundation
import MailModel

public struct CalendarDayTimeline: Sendable, Hashable {
    public static let hours = 8..<19
    public static let colorCount = 6
    public static let minimumHeight = 0.04

    public struct Block: Identifiable, Sendable, Hashable {
        public let event: CalendarEvent
        public var id: String { CalendarDayTimeline.key(for: event) }
        public let top: Double
        public let height: Double
        public let column: Int
        public let columns: Int
        public let colorIndex: Int
        public let isConflict: Bool
        public let startsBefore: Bool
        public let endsAfter: Bool
    }

    public struct Span: Sendable, Hashable {
        public let start: Date
        public let end: Date
        public let top: Double
        public let height: Double
    }

    public struct HourMark: Sendable, Hashable {
        public let date: Date
        public let offset: Double
    }

    public let day: Date
    public let blocks: [Block]
    public let allDay: [CalendarEvent]
    public let hourMarks: [HourMark]
    public let now: Double?
    public let focus: Span?
    public let zoneLabel: String

    public init(day: Date, events: [CalendarEvent], focus: DateInterval?, timeZone: TimeZone, now: Date) {
        let calendar = CalendarDateMentions.calendar(timeZone)
        let midnight = calendar.startOfDay(for: day)
        self.day = midnight
        let open = calendar.date(bySettingHour: Self.hours.lowerBound, minute: 0, second: 0, of: midnight) ?? midnight
        let close = calendar.date(bySettingHour: Self.hours.upperBound, minute: 0, second: 0, of: midnight)
            ?? open.addingTimeInterval(TimeInterval(Self.hours.count) * 3_600)
        let length = max(close.timeIntervalSince(open), 1)
        func offset(_ date: Date) -> Double { min(max(date.timeIntervalSince(open) / length, 0), 1) }

        zoneLabel = timeZone.abbreviation(for: midnight) ?? timeZone.identifier
        hourMarks = (Self.hours.lowerBound...Self.hours.upperBound).compactMap { hour in
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: midnight).map { HourMark(date: $0, offset: offset($0)) }
        }
        let nextDay = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight.addingTimeInterval(86_400)
        allDay = events.filter { $0.isAllDay && $0.overlaps(from: midnight, to: nextDay) }
        let timed = events.filter { !$0.isAllDay && $0.overlaps(from: open, to: close) }

        var slot: Span?
        if let focus, focus.end > open, focus.start < close {
            let top = offset(focus.start)
            slot = Span(start: focus.start, end: focus.end, top: top,
                        height: max(offset(focus.end) - top, Self.minimumHeight))
        }
        self.focus = slot

        let placed = Self.columns(timed)
        blocks = placed.map { item in
            let top = offset(item.event.start)
            let conflict = focus.map { item.event.overlaps(from: $0.start, to: $0.end) } ?? false
            return Block(event: item.event, top: top, height: max(offset(item.event.end) - top, Self.minimumHeight),
                         column: item.column, columns: item.columns, colorIndex: Self.colorIndex(for: item.event),
                         isConflict: conflict, startsBefore: item.event.start < open, endsAfter: item.event.end > close)
        }
        if calendar.isDate(now, inSameDayAs: midnight), now >= open, now <= close {
            self.now = offset(now)
        } else {
            self.now = nil
        }
    }

    public var conflicts: [CalendarEvent] {
        blocks.filter(\.isConflict).map(\.event).sorted { $0.start < $1.start }
    }

    public var shownEvents: [CalendarEvent] { allDay + blocks.map(\.event) }

    public static func key(for event: CalendarEvent) -> String { event.copyKey }

    static func columns(_ events: [CalendarEvent]) -> [(event: CalendarEvent, column: Int, columns: Int)] {
        let sorted = events.sorted { ($0.start, $1.end, $0.copyKey) < ($1.start, $0.end, $1.copyKey) }
        var out: [(event: CalendarEvent, column: Int, columns: Int)] = []
        var group: [(event: CalendarEvent, column: Int)] = []
        var columnEnds: [Date] = []
        var groupEnd = Date.distantPast
        func flush() {
            let count = max(columnEnds.count, 1)
            out += group.map { ($0.event, $0.column, count) }
            group = []
            columnEnds = []
        }
        for event in sorted {
            if !group.isEmpty, event.start >= groupEnd { flush() }
            if let free = columnEnds.firstIndex(where: { $0 <= event.start }) {
                columnEnds[free] = event.end
                group.append((event, free))
            } else {
                columnEnds.append(event.end)
                group.append((event, columnEnds.count - 1))
            }
            groupEnd = group.count == 1 ? event.end : max(groupEnd, event.end)
        }
        if !group.isEmpty { flush() }
        return out
    }

    public static func colorIndex(for event: CalendarEvent) -> Int {
        colorIndex(forCalendar: event.account ?? event.calendarName)
    }

    public static func colorIndex(forCalendar name: String?) -> Int {
        guard let name, !name.isEmpty else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(colorCount))
    }
}

public struct CalendarLoadProgress: Sendable, Hashable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    public var text: String { String(localized: "Updating: \(done) of \(total)") }
}
