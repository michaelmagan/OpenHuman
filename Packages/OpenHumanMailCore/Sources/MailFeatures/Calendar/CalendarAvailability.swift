import Foundation
import MailModel

public struct CalendarAvailability: Sendable, Hashable {
    public struct Slot: Sendable, Hashable {
        public let start: Date
        public let end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }
    }

    public var slots: [Slot]
    public var asOf: Date
    public var ignoresConflicts: Bool

    public init(slots: [Slot], asOf: Date, ignoresConflicts: Bool) {
        self.slots = slots
        self.asOf = asOf
        self.ignoresConflicts = ignoresConflicts
    }

    public static let slotLength: TimeInterval = 30 * 60
    public static let slotCount = 3
    public static let workingDays = 5

    @MainActor public static func days(from now: Date, calendar: Calendar) -> [Date] {
        var out: [Date] = []
        var day = calendar.startOfDay(for: now)
        let todayClose = calendar.date(bySettingHour: CalendarSidebarModel.workdayHours.upperBound, minute: 0, second: 0,
                                       of: day) ?? day
        if now.addingTimeInterval(slotLength) > todayClose, let next = calendar.date(byAdding: .day, value: 1, to: day) {
            day = next
        }
        var guardCount = 0
        while out.count < workingDays, guardCount < 14 {
            if !calendar.isDateInWeekend(day) { out.append(day) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            guardCount += 1
        }
        return out
    }

    @MainActor public static func slots(days: [Date], busy: [CalendarBusyInterval], now: Date, calendar: Calendar,
                             ignoreConflicts: Bool, excluding: Set<Slot> = [], count: Int = slotCount) -> [Slot] {
        var perDay: [[Slot]] = []
        for day in days {
            guard let open = calendar.date(bySettingHour: CalendarSidebarModel.workdayHours.lowerBound, minute: 0,
                                           second: 0, of: day),
                  let close = calendar.date(bySettingHour: CalendarSidebarModel.workdayHours.upperBound, minute: 0,
                                            second: 0, of: day) else { continue }
            var free: [Slot] = []
            var start = open
            while start.addingTimeInterval(slotLength) <= close {
                let slot = Slot(start: start, end: start.addingTimeInterval(slotLength))
                let clash = busy.contains { $0.start < slot.end && $0.end > slot.start }
                if slot.start >= now, ignoreConflicts || !clash, !excluding.contains(slot) { free.append(slot) }
                start = start.addingTimeInterval(slotLength)
            }
            perDay.append(free)
        }
        var picked = perDay.compactMap(\.first).prefix(count).map { $0 }
        if picked.count < count {
            let rest = perDay.flatMap { $0 }.filter { !picked.contains($0) }.sorted { $0.start < $1.start }
            picked += rest.prefix(count - picked.count)
        }
        return picked.sorted { $0.start < $1.start }
    }

    @MainActor public func text(timeZone: TimeZone, secondTimeZone: TimeZone?) -> String? {
        guard !slots.isEmpty else { return nil }
        let city = CalendarSidebarModel.city(timeZone)
        let asOfText = asOf.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone))
        let intro = ignoresConflicts
            ? String(localized: "Here are a few times that work for me (\(city) time):")
            : String(localized: "Here are a few times that work for me (\(city) time, free as of \(asOfText)):")
        let day = Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).month(.abbreviated).day()
        let lines = slots.map { slot in
            var line = "• " + slot.start.formatted(day) + ", " + CalendarSidebarModel.range(slot.start, slot.end, timeZone)
            if let second = secondTimeZone, second.identifier != timeZone.identifier {
                line += " (" + CalendarSidebarModel.range(slot.start, slot.end, second) + " "
                    + CalendarSidebarModel.city(second) + ")"
            }
            return line
        }
        return ([intro] + lines).joined(separator: "\n")
    }
}
