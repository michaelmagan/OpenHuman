import Foundation
import OpenHumanCore

public enum TimePickerKind: String, Sendable, Hashable, CaseIterable {
    case snooze, remind, sendLater

    public var title: String {
        switch self {
        case .snooze: "Snooze until…"
        case .remind: "Remind me…"
        case .sendLater: "Send later…"
        }
    }

    public var footer: String {
        switch self {
        case .snooze: "Comes back to your inbox. Syncs to your other Mac."
        case .remind: "Reminders stay on this Mac."
        case .sendLater:
            "Sends from whichever of your Macs is open. If they're all asleep, it sends as soon as one wakes, up to 24 hours late; after that it asks you first."
        }
    }
}

public struct TimeDefaults: Sendable, Hashable {
    public var morningHour = 8
    public var weekendHour = 9
    public var afternoonHour = 13
    public var eveningHour = 20
    public var morningMinute = 0
    public var weekdaysOnly = false

    public init(morningHour: Int = 8, weekendHour: Int = 9, afternoonHour: Int = 13, eveningHour: Int = 20,
                morningMinute: Int = 0, weekdaysOnly: Bool = false) {
        self.morningHour = morningHour
        self.weekendHour = weekendHour
        self.afternoonHour = afternoonHour
        self.eveningHour = eveningHour
        self.morningMinute = morningMinute
        self.weekdaysOnly = weekdaysOnly
    }

    public init(defaultTime minutes: Int, weekdaysOnly: Bool) {
        let clamped = min(max(minutes, 0), 23 * 60 + 59)
        self.init(morningHour: clamped / 60, morningMinute: clamped % 60, weekdaysOnly: weekdaysOnly)
    }
}

public struct TimePreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let number: Int
    public let title: String
    public let date: Date?

    public var isPickDate: Bool { date == nil }
}

public struct TimePresets: Sendable {
    public let timeZone: TimeZone
    public let defaults: TimeDefaults

    public init(timeZone: TimeZone = .current, defaults: TimeDefaults = TimeDefaults()) {
        self.timeZone = timeZone
        self.defaults = defaults
    }

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "en_US_POSIX")
        c.firstWeekday = 2
        return c
    }

    var parser: WhenParser { WhenParser(timeZone: timeZone, defaultHour: defaults.morningHour, eveningHour: defaults.eveningHour) }

    func local(_ day: Date, hour: Int, minute: Int = 0, fallback: Date) -> Date {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        let text = String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1, hour, minute)
        return (try? parser.parse(text, now: fallback)) ?? day
    }

    public func combine(day: Date, hour: Int, minute: Int, now: Date) -> Date {
        local(day, hour: hour, minute: minute, fallback: now)
    }

    public func presets(for kind: TimePickerKind, now: Date) -> [TimePreset] {
        let cal = calendar
        let today = cal.startOfDay(for: now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today) ?? today }
        func nextWeekday(_ weekday: Int) -> Date {
            let delta = (weekday - cal.component(.weekday, from: today) + 7) % 7
            return day(delta == 0 ? 7 : delta)
        }
        let morning = defaults.morningHour
        let minute = defaults.morningMinute
        func workday(_ date: Date) -> Date {
            guard defaults.weekdaysOnly, kind != .sendLater else { return date }
            switch cal.component(.weekday, from: date) {
            case 7: return cal.date(byAdding: .day, value: 2, to: date) ?? date
            case 1: return cal.date(byAdding: .day, value: 1, to: date) ?? date
            default: return date
            }
        }
        func morningOf(_ date: Date) -> Date { local(workday(date), hour: morning, minute: minute, fallback: now) }
        var laterSlot: (String, String, Date?)? {
            guard let later = parser.laterToday(now: now) else { return nil }
            return later.isEvening ? ("thisEvening", "This evening", later.date) : ("laterToday", "Later today", later.date)
        }
        var items: [(String, String, Date?)] = []
        switch kind {
        case .snooze:
            if let later = laterSlot { items.append(later) }
            items.append(("tomorrowMorning", "Tomorrow morning", morningOf(day(1))))
            let weekday = cal.component(.weekday, from: today)
            if weekday != 7 && weekday != 1 {
                items.append(("weekend", "This weekend", local(nextWeekday(7), hour: defaults.weekendHour, fallback: now)))
            }
            items.append(("nextWeek", "Next week", morningOf(nextWeekday(2))))
            let month = cal.date(byAdding: .month, value: 1, to: today) ?? day(30)
            items.append(("inAMonth", "In a month", morningOf(month)))
        case .remind:
            if let later = laterSlot { items.append(later) }
            items.append(("tomorrowMorning", "Tomorrow morning", morningOf(day(1))))
            items.append(("inTwoDays", "In 2 days", morningOf(day(2))))
            items.append(("nextWeek", "Next week", morningOf(nextWeekday(2))))
        case .sendLater:
            items.append(("inAnHour", "In 1 hour", now.addingTimeInterval(3600)))
            items.append(("tomorrowMorning", "Tomorrow morning", morningOf(day(1))))
            items.append(("tomorrowAfternoon", "Tomorrow afternoon", local(day(1), hour: defaults.afternoonHour, fallback: now)))
            items.append(("monday", "Monday", morningOf(nextWeekday(2))))
        }
        items.append(("pickDate", "Pick a date…", nil))
        return items.enumerated().map { TimePreset(id: $1.0, number: $0 + 1, title: $1.1, date: $1.2) }
    }
}

public struct MonthGrid: Sendable, Hashable {
    public struct Day: Hashable, Sendable, Identifiable {
        public var id: Date { start }
        public let start: Date
        public let number: Int
        public let isInMonth: Bool
    }

    public let month: Date
    public let days: [Day]

    public init(month: Date, timeZone: TimeZone, firstWeekday: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = firstWeekday
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -lead, to: first) ?? first
        let monthNumber = cal.component(.month, from: first)
        self.month = first
        days = (0..<42).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: offset, to: start) else { return nil }
            return Day(start: cal.startOfDay(for: d), number: cal.component(.day, from: d),
                       isInMonth: cal.component(.month, from: d) == monthNumber)
        }
    }
}
