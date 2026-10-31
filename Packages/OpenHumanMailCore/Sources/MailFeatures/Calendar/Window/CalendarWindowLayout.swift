import Foundation
import MailModel

public struct CalendarPeriod: Sendable, Hashable {
    public static let firstWeekday = 1

    public let kind: CalendarViewKind
    public let start: Date
    public let end: Date
    public let days: [Date]
    public let month: Date?

    public init(kind: CalendarViewKind, start: Date, end: Date, days: [Date], month: Date?) {
        self.kind = kind
        self.start = start
        self.end = end
        self.days = days
        self.month = month
    }

    public static func containing(_ date: Date, kind: CalendarViewKind, calendar: Calendar) -> CalendarPeriod {
        let day = calendar.startOfDay(for: date)
        switch kind {
        case .day, .threeDays:
            return make(kind, from: day, count: kind.dayCount, calendar: calendar, month: nil)
        case .week:
            return make(kind, from: weekStart(of: day, calendar: calendar), count: 7, calendar: calendar, month: nil)
        case .month:
            let first = calendar.date(from: calendar.dateComponents([.year, .month], from: day)).map(calendar.startOfDay)
                ?? day
            let next = calendar.date(byAdding: .month, value: 1, to: first) ?? first
            let lastDay = calendar.date(byAdding: .day, value: -1, to: next) ?? first
            let gridStart = weekStart(of: first, calendar: calendar)
            let gridEnd = calendar.date(byAdding: .day, value: 7, to: weekStart(of: lastDay, calendar: calendar))
                ?? next
            var count = 0
            var cursor = gridStart
            while cursor < gridEnd, count < 42 {
                count += 1
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? gridEnd
            }
            return make(kind, from: gridStart, count: count, calendar: calendar, month: first)
        }
    }

    public func moved(by delta: Int, calendar: Calendar) -> CalendarPeriod {
        switch kind {
        case .day, .threeDays, .week:
            let step = kind == .week ? 7 : kind.dayCount
            let target = calendar.date(byAdding: .day, value: step * delta, to: start) ?? start
            return kind == .week ? Self.containing(target, kind: .week, calendar: calendar)
                                 : Self.make(kind, from: target, count: kind.dayCount, calendar: calendar, month: nil)
        case .month:
            let target = calendar.date(byAdding: .month, value: delta, to: month ?? start) ?? start
            return Self.containing(target, kind: .month, calendar: calendar)
        }
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    public var titleDay: Date { month ?? days[days.count / 2] }

    public static func weekStart(of day: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: day)
        let back = (weekday - firstWeekday + 7) % 7
        return calendar.startOfDay(for: calendar.date(byAdding: .day, value: -back, to: day) ?? day)
    }

    private static func make(_ kind: CalendarViewKind, from first: Date, count: Int, calendar: Calendar,
                             month: Date?) -> CalendarPeriod {
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: first)
        for _ in 0..<max(count, 1) {
            days.append(cursor)
            cursor = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: cursor)
                                         ?? cursor.addingTimeInterval(86_400))
        }
        return CalendarPeriod(kind: kind, start: days[0], end: cursor, days: days, month: month)
    }
}

public struct CalendarTimeGrid: Sendable, Hashable {
    public static let minimumHeight = 15.0 / 1_440
    public static let allDayRowLength: TimeInterval = 24 * 3_600

    public struct Block: Identifiable, Sendable, Hashable {
        public let event: CalendarEvent
        public var id: String { "\(event.copyKey)@\(event.start.timeIntervalSince1970)#\(dayIndex)" }
        public let dayIndex: Int
        public let top: Double
        public let height: Double
        public let column: Int
        public let columns: Int
        public let colorIndex: Int
        public let isTentative: Bool
        public let isDeclined: Bool
        // Waits for the user's answer: drawn dashed
        public var isInvited = false
        public let startsBefore: Bool
        public let endsAfter: Bool
        public let isPast: Bool
    }

    public struct AllDayBar: Identifiable, Sendable, Hashable {
        public let event: CalendarEvent
        public var id: String { "\(event.copyKey)@\(event.start.timeIntervalSince1970)" }
        public let firstDay: Int
        public let lastDay: Int
        public let lane: Int
        public let colorIndex: Int
    }

    public struct NowMark: Sendable, Hashable {
        public let dayIndex: Int
        public let offset: Double
    }

    public let days: [Date]
    public let blocks: [Block]
    public let allDay: [AllDayBar]
    public let allDayLanes: Int
    public let now: NowMark?
    public let todayIndex: Int?
    public let zoneLabel: String
    public let scrollTarget: Double
    public let openingHour: Int

    public init(days: [Date], events: [CalendarEvent], timeZone: TimeZone, now: Date,
                colorIndex: (CalendarEvent) -> Int = CalendarDayTimeline.colorIndex(for:)) {
        let calendar = CalendarDateMentions.calendar(timeZone)
        let midnights = days.map { calendar.startOfDay(for: $0) }
        self.days = midnights
        zoneLabel = midnights.first.flatMap { timeZone.abbreviation(for: $0) } ?? timeZone.identifier
        let nextDays = midnights.map { Self.nextMidnight(after: $0, calendar: calendar) }

        let bars = events.filter(Self.belongsInAllDayRow)
        let timed = events.filter { !Self.belongsInAllDayRow($0) }

        var placed: [Block] = []
        for (index, day) in midnights.enumerated() {
            let next = nextDays[index]
            let todays = timed.filter { $0.overlaps(from: day, to: next) }
            for item in CalendarDayTimeline.columns(todays) {
                let event = item.event
                let top = Self.offset(event.start, day: day, next: next, calendar: calendar)
                let bottom = Self.offset(event.end, day: day, next: next, calendar: calendar)
                let attendance = event.drawnAttendance
                placed.append(Block(event: event, dayIndex: index, top: top,
                                    height: max(bottom - top, Self.minimumHeight), column: item.column,
                                    columns: item.columns, colorIndex: colorIndex(event),
                                    isTentative: attendance == .maybe, isDeclined: attendance == .declined,
                                    isInvited: attendance == .invited,
                                    startsBefore: event.start < day, endsAfter: event.end > next,
                                    isPast: event.end <= now))
            }
        }
        blocks = placed

        let spans: [(CalendarEvent, Int, Int)] = bars.compactMap { event in
            let covered = midnights.indices.filter { event.overlaps(from: midnights[$0], to: nextDays[$0]) }
            guard let first = covered.first, let last = covered.last else { return nil }
            return (event, first, last)
        }.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 > b.2 }
            return a.0.copyKey < b.0.copyKey
        }
        var laneEnds: [Int] = []
        var laid: [AllDayBar] = []
        for (event, first, last) in spans {
            let lane = laneEnds.firstIndex { $0 < first } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(last) } else { laneEnds[lane] = last }
            laid.append(AllDayBar(event: event, firstDay: first, lastDay: last, lane: lane,
                                  colorIndex: colorIndex(event)))
        }
        allDay = laid
        allDayLanes = laneEnds.count

        let today = midnights.firstIndex { calendar.isDate($0, inSameDayAs: now) }
        todayIndex = today
        if let today {
            self.now = NowMark(dayIndex: today,
                               offset: Self.offset(now, day: midnights[today], next: nextDays[today], calendar: calendar))
        } else {
            self.now = nil
        }
        if let mark = self.now {
            scrollTarget = max(mark.offset - 1.0 / 24, 0)
        } else if let first = placed.map(\.top).min() {
            scrollTarget = max(first - 0.5 / 24, 0)
        } else {
            scrollTarget = 8.0 / 24
        }
        openingHour = Self.openingHour(nowHour: self.now.map { $0.offset * 24 }, blocks: placed)
    }

    public static let openingLead = 0.25
    public static let shortestDrawnHours = 20.0 / 60
    public static let openingMaxLift = 3

    // Why: a quarter hour of lead keeps the hour label visible, and lifting the hour beats cutting a block
    public static func openingHour(nowHour: Double?, blocks: [Block]) -> Int {
        let starts = blocks.filter { !$0.startsBefore }.map { (top: $0.top * 24, height: $0.height * 24) }
        var hour: Int
        if let nowHour {
            hour = Int(nowHour.rounded(.down)) - 1
        } else if let first = starts.map(\.top).min() {
            hour = Int(first.rounded(.down))
        } else {
            hour = 8
        }
        hour = min(max(hour, 0), 23)
        let highest = max(hour - openingMaxLift, 0)
        while hour > highest {
            let edge = Double(hour) - openingLead
            let cut = starts.filter { $0.top < edge && max($0.top + $0.height, $0.top + shortestDrawnHours) > edge }
            guard let earliest = cut.map(\.top).min() else { break }
            hour = max(Int(earliest.rounded(.down)), highest)
        }
        return hour
    }

    public static func belongsInAllDayRow(_ event: CalendarEvent) -> Bool {
        event.isAllDay || event.end.timeIntervalSince(event.start) >= allDayRowLength
    }

    public static func offset(_ date: Date, day: Date, next: Date, calendar: Calendar) -> Double {
        if date <= day { return 0 }
        if date >= next { return 1 }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let seconds = Double((parts.hour ?? 0) * 3_600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0))
        return min(max(seconds / 86_400, 0), 1)
    }

    static func nextMidnight(after day: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400))
    }
}

public struct CalendarMonthGrid: Sendable, Hashable {
    public static let shownPerCell = 3

    public struct Cell: Identifiable, Sendable, Hashable {
        public let day: Date
        public var id: Date { day }
        public let isInMonth: Bool
        public let isToday: Bool
        public let events: [CalendarEvent]
        public let more: Int
    }

    public let weeks: [[Cell]]

    public init(period: CalendarPeriod, events: [CalendarEvent], timeZone: TimeZone, now: Date) {
        let calendar = CalendarDateMentions.calendar(timeZone)
        let month = period.month.map { calendar.component(.month, from: $0) }
        let cells = period.days.map { day -> Cell in
            let next = CalendarTimeGrid.nextMidnight(after: day, calendar: calendar)
            let todays = events.filter { $0.overlaps(from: day, to: next) }.sorted { a, b in
                if CalendarTimeGrid.belongsInAllDayRow(a) != CalendarTimeGrid.belongsInAllDayRow(b) {
                    return CalendarTimeGrid.belongsInAllDayRow(a)
                }
                return a.start != b.start ? a.start < b.start : a.id < b.id
            }
            return Cell(day: day, isInMonth: month.map { calendar.component(.month, from: day) == $0 } ?? true,
                        isToday: calendar.isDate(day, inSameDayAs: now),
                        events: Array(todays.prefix(Self.shownPerCell)), more: max(todays.count - Self.shownPerCell, 0))
        }
        weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
    }
}

public struct CalendarMiniMonth: Sendable, Hashable {
    public let month: Date
    public let weeks: [[Date]]

    public init(containing date: Date, timeZone: TimeZone) {
        let calendar = CalendarDateMentions.calendar(timeZone)
        let period = CalendarPeriod.containing(date, kind: .month, calendar: calendar)
        month = period.month ?? period.start
        var days = period.days
        while days.count < 42, let last = days.last {
            days.append(CalendarTimeGrid.nextMidnight(after: last, calendar: calendar))
        }
        weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }
}

public enum CalendarDragMath {
    public static let step: TimeInterval = 15 * 60

    public static func time(atFraction fraction: Double, on day: Date, calendar: Calendar) -> Date {
        let minutes = Int((min(max(fraction, 0), 1) * 1_440 / 15).rounded()) * 15
        let midnight = calendar.startOfDay(for: day)
        if minutes >= 1_440 { return CalendarTimeGrid.nextMidnight(after: midnight, calendar: calendar) }
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: midnight,
                             matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
            ?? midnight.addingTimeInterval(TimeInterval(minutes * 60))
    }

    public static func moved(_ event: CalendarEvent, to start: Date) -> (start: Date, end: Date) {
        moved(from: event.start, until: event.end, to: start)
    }

    public static func resized(_ event: CalendarEvent, to end: Date) -> (start: Date, end: Date) {
        resized(from: event.start, to: end)
    }

    public static func moved(from start: Date, until end: Date, to newStart: Date) -> (start: Date, end: Date) {
        (newStart, newStart.addingTimeInterval(max(end.timeIntervalSince(start), step)))
    }

    public static func resized(from start: Date, to end: Date) -> (start: Date, end: Date) {
        (start, max(end, start.addingTimeInterval(step)))
    }

    public static func slot(from a: Date, to b: Date) -> (start: Date, end: Date) {
        let start = min(a, b)
        let end = max(a, b)
        if end.timeIntervalSince(start) < step { return (start, start.addingTimeInterval(30 * 60)) }
        return (start, end)
    }
}
