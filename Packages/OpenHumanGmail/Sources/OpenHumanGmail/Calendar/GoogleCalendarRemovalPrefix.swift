import Foundation

public enum GoogleOriginalStart: Sendable, Hashable {
    case date(String)
    case timed(Date, timeZone: String?)

    func atOrAfter(_ other: Self) throws -> Bool {
        switch (self, other) {
        case (.date(let a), .date(let b)): return a >= b
        case (.timed(let a, _), .timed(let b, _)): return a >= b
        default: throw GoogleCalendarRemovalError.refused("The series mixes date and timed recurrence positions.")
        }
    }

    func instant(in zone: TimeZone) throws -> Date {
        switch self {
        case .date(let text):
            guard let value = GoogleRemovalPrefix.parse(text, pattern: "yyyy-MM-dd", zone: zone) else {
                throw GoogleCalendarRemovalError.refused("The original recurrence date is unreadable.")
            }
            return value
        case .timed(let instant, let name):
            if let name, TimeZone(identifier: name) == nil {
                throw GoogleCalendarRemovalError.refused("The original recurrence time zone is unknown.")
            }
            return instant
        }
    }
}

public enum GoogleCalendarRemovalError: Error, Sendable, Equatable {
    case refused(String)
    case conflict
    case uncertain
}

/// A bounded prefix planner for ordinary daily, weekly, monthly and yearly rules.
/// It never uses the edit splitter, display windows, or occurrence IDs to establish membership.
public struct GoogleRemovalPrefix: Sendable, Equatable {
    public let recurrence: [String]
    public let isEmpty: Bool
    static let limit = 36_600

    public static func plan(_ lines: [String], start: GoogleOriginalStart, cutoff: GoogleOriginalStart,
                            timeZone: String) throws -> Self {
        func refuse() -> GoogleCalendarRemovalError {
            .refused("Mail can't safely shorten this recurrence rule. Remove this event or the whole series instead.")
        }
        guard let zone = TimeZone(identifier: timeZone) else { throw refuse() }
        let first = try start.instant(in: zone)
        let boundary = try cutoff.instant(in: zone)
        guard try cutoff.atOrAfter(start) else { throw refuse() }
        let allDay: Bool
        switch (start, cutoff) {
        case (.date, .date): allDay = true
        case (.timed, .timed): allDay = false
        default: throw refuse()
        }
        var rule: [String: String] = [:]
        var components: [(String, [String], [Date])] = []
        var names = Set<String>()
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else { throw refuse() }
            if parts[0] == "RRULE" {
                guard rule.isEmpty else { throw refuse() }
                for item in parts[1].split(separator: ";", omittingEmptySubsequences: false) {
                    let pair = item.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
                    guard pair.count == 2, !pair[1].isEmpty, rule[pair[0]] == nil else { throw refuse() }
                    rule[pair[0]] = pair[1]
                }
            } else {
                let header = parts[0].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                guard let name = header.first, ["RDATE", "EXDATE"].contains(name), names.insert(name).inserted else {
                    throw refuse()
                }
                let pattern: String
                let dateZone: TimeZone
                if allDay {
                    guard header == [name, "VALUE=DATE"] else { throw refuse() }
                    pattern = "yyyyMMdd"
                    dateZone = zone
                } else if header == [name] {
                    pattern = "yyyyMMdd'T'HHmmss'Z'"
                    dateZone = .gmt
                } else if header.count == 2, header[1].hasPrefix("TZID="),
                          let known = TimeZone(identifier: String(header[1].dropFirst(5))) {
                    pattern = "yyyyMMdd'T'HHmmss"
                    dateZone = known
                } else { throw refuse() }
                let texts = parts[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                var dates: [Date] = []
                for text in texts {
                    guard let date = parse(text, pattern: pattern, zone: dateZone), !dates.contains(date),
                          allDay || uniqueWallTime(date, zone: dateZone) else { throw refuse() }
                    dates.append(date)
                }
                components.append((parts[0], texts, dates))
            }
        }
        let allowed: Set<String> = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "WKST"]
        guard !rule.isEmpty, Set(rule.keys).isSubset(of: allowed), let freq = rule["FREQ"],
              ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].contains(freq),
              let interval = Int(rule["INTERVAL"] ?? "1"), (1...10_000).contains(interval),
              rule["COUNT"] == nil || rule["UNTIL"] == nil else { throw refuse() }
        let count = rule["COUNT"].flatMap(Int.init)
        if rule["COUNT"] != nil {
            guard let count, (1...10_000).contains(count), !names.contains("RDATE") else { throw refuse() }
        }
        let weekdays = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        let days = rule["BYDAY"]?.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if let days {
            guard freq == "WEEKLY", !days.isEmpty, Set(days).count == days.count,
                  days.allSatisfy(weekdays.contains) else { throw refuse() }
        }
        if rule["WKST"] != nil && freq != "WEEKLY" { throw refuse() }
        guard let weekStart = weekdays.firstIndex(of: rule["WKST"] ?? "MO") else { throw refuse() }
        let monthDay = rule["BYMONTHDAY"].flatMap(Int.init)
        if rule["BYMONTHDAY"] != nil {
            guard ["MONTHLY", "YEARLY"].contains(freq), let monthDay, (1...31).contains(monthDay) else { throw refuse() }
        }
        let month = rule["BYMONTH"].flatMap(Int.init)
        if rule["BYMONTH"] != nil {
            guard freq == "YEARLY", let month, (1...12).contains(month) else { throw refuse() }
        }
        // YEARLY BYMONTHDAY expands across months; this planner only proves a single yearly month.
        if freq == "YEARLY", monthDay != nil, month == nil { throw refuse() }
        let until: Date?
        if let text = rule["UNTIL"] {
            guard let value = parse(text, pattern: allDay ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'",
                                    zone: allDay ? zone : .gmt) else { throw refuse() }
            until = value
        } else { until = nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let startDay = cal.startOfDay(for: first)
        let cutoffDay = cal.startOfDay(for: boundary)
        guard let distance = cal.dateComponents([.day], from: startDay, to: cutoffDay).day,
              (0..<limit).contains(distance) else { throw refuse() }
        let wall = cal.dateComponents([.hour, .minute, .second], from: first)
        let base = cal.dateComponents([.year, .month, .day, .weekday], from: first)
        // A mismatched DTSTART does not establish the rule's first position or its COUNT semantics.
        guard days?.contains(weekdays[(base.weekday ?? 1) - 1]) ?? true,
              monthDay.map({ $0 == base.day }) ?? true,
              month.map({ $0 == base.month }) ?? true,
              until.map({ first <= $0 }) ?? true,
              allDay || uniqueWallTime(first, zone: zone) else { throw refuse() }
        let baseWeekOffset = ((base.weekday ?? 1) - 1 - weekStart + 7) % 7
        let excluded = components.filter { $0.0.hasPrefix("EXDATE") }.flatMap { $0.2 }
        let added = components.filter { $0.0.hasPrefix("RDATE") }.flatMap { $0.2 }
        var generated = 0
        var before = added.contains { $0 < boundary && !excluded.contains($0) }
        var selected = added.contains(boundary) && !excluded.contains(boundary)
        for offset in 0...distance {
            guard let day = cal.date(byAdding: .day, value: offset, to: startDay) else { throw refuse() }
            let bits = cal.dateComponents([.year, .month, .day, .weekday], from: day)
            let matches: Bool
            switch freq {
            case "DAILY": matches = offset % interval == 0
            case "WEEKLY":
                let weekday = weekdays[(bits.weekday ?? 1) - 1]
                matches = ((offset + baseWeekOffset) / 7) % interval == 0
                    && (days?.contains(weekday) ?? (bits.weekday == base.weekday))
            case "MONTHLY":
                let months = ((bits.year ?? 0) - (base.year ?? 0)) * 12 + (bits.month ?? 0) - (base.month ?? 0)
                matches = months % interval == 0 && bits.day == (monthDay ?? base.day ?? 1)
            default:
                matches = ((bits.year ?? 0) - (base.year ?? 0)) % interval == 0
                    && bits.month == (month ?? base.month ?? 1) && bits.day == (monthDay ?? base.day ?? 1)
            }
            guard matches else { continue }
            let position: Date
            if allDay { position = day } else {
                guard let value = cal.date(bySettingHour: wall.hour ?? 0, minute: wall.minute ?? 0,
                                           second: wall.second ?? 0, of: day, matchingPolicy: .strict),
                      cal.isDate(value, inSameDayAs: day), uniqueWallTime(value, zone: zone) else { throw refuse() }
                position = value
            }
            guard position >= first, until.map({ position <= $0 }) ?? true else { continue }
            generated += 1
            if let count, generated > count { continue }
            if excluded.contains(position) { continue }
            if position < boundary { before = true }
            if position == boundary { selected = true }
        }
        guard selected else { throw refuse() }
        let strictUntil: Date
        if allDay {
            guard let previous = cal.date(byAdding: .day, value: -1, to: cutoffDay) else { throw refuse() }
            strictUntil = previous
        } else {
            strictUntil = Date(timeIntervalSince1970: ceil(boundary.timeIntervalSince1970) - 1)
        }
        let ending = min(until ?? strictUntil, strictUntil)
        var rewritten = lines.first { $0.hasPrefix("RRULE:") }!.dropFirst(6).split(separator: ";").map(String.init)
        rewritten.removeAll { $0.hasPrefix("COUNT=") || $0.hasPrefix("UNTIL=") }
        rewritten.append("UNTIL=" + format(ending, pattern: allDay ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'",
                                          zone: allDay ? zone : .gmt))
        var result = ["RRULE:" + rewritten.joined(separator: ";")]
        for (header, texts, dates) in components {
            let kept = zip(texts, dates).filter { $0.1 < boundary }.map { $0.0 }
            if !kept.isEmpty { result.append(header + ":" + kept.joined(separator: ",")) }
        }
        return Self(recurrence: result, isEmpty: !before)
    }

    static func parse(_ text: String, pattern: String, zone: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = pattern
        f.isLenient = false
        guard let date = f.date(from: text), f.string(from: date) == text else { return nil }
        return date
    }

    static func format(_ date: Date, pattern: String, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = pattern
        return f.string(from: date)
    }

    static func uniqueWallTime(_ date: Date, zone: TimeZone) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let bits = cal.dateComponents([.hour, .minute, .second], from: date)
        let day = cal.startOfDay(for: date)
        let a = cal.date(bySettingHour: bits.hour ?? 0, minute: bits.minute ?? 0, second: bits.second ?? 0,
                         of: day, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let b = cal.date(bySettingHour: bits.hour ?? 0, minute: bits.minute ?? 0, second: bits.second ?? 0,
                         of: day, matchingPolicy: .strict, repeatedTimePolicy: .last)
        return a == b && a == date
    }
}

extension GoogleRemovalPrefix {
    private enum Kind { case day, timed }

    private struct Lines {
        var rule: [String: String] = [:]
        var dates: [String: [String]] = [:]

        init?(_ lines: [String]) {
            var rules = 0
            for line in lines {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, !parts[1].isEmpty else { return nil }
                if parts[0] == "RRULE" {
                    rules += 1
                    guard rules == 1 else { return nil }
                    for item in parts[1].split(separator: ";", omittingEmptySubsequences: false) {
                        let pair = item.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
                        guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty, rule[pair[0]] == nil else { return nil }
                        rule[pair[0]] = pair[1]
                    }
                } else {
                    let name = parts[0].split(separator: ";", omittingEmptySubsequences: false).first.map(String.init)
                    guard name == "RDATE" || name == "EXDATE", dates[parts[0]] == nil else { return nil }
                    let values = parts[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    guard !values.contains(where: \.isEmpty) else { return nil }
                    dates[parts[0]] = values
                }
            }
            guard rules == 1, rule["FREQ"] != nil else { return nil }
        }
    }

    /// Whether `proposed` keeps only an earlier part of `current`, read line by line without the planner: the same
    /// RRULE apart from an end no later than before, RDATE values taken from the same line, and every EXDATE value up
    /// to the new end kept. A COUNT replaced by an UNTIL passes here; the guard bounds it by planning from the same read.
    static func narrows(_ current: [String], to proposed: [String]) -> Bool {
        guard proposed != current, let old = Lines(current), let new = Lines(proposed) else { return false }
        var oldBase = old.rule
        var newBase = new.rule
        for key in ["COUNT", "UNTIL"] {
            oldBase[key] = nil
            newBase[key] = nil
        }
        guard oldBase == newBase else { return false }
        var narrower = old.rule["COUNT"] == nil && old.rule["UNTIL"] == nil
        switch (new.rule["UNTIL"], new.rule["COUNT"]) {
        case (let until?, nil):
            guard let end = endInstant(until) else { return false }
            if let before = old.rule["UNTIL"] {
                guard let was = endInstant(before), was.0 == end.0, end.1 <= was.1 else { return false }
                narrower = narrower || end.1 < was.1
            } else if old.rule["COUNT"] != nil {
                narrower = true
            }
        case (nil, let count?):
            guard let value = Int(count), value >= 1, old.rule["UNTIL"] == nil else { return false }
            if let before = old.rule["COUNT"] {
                guard let was = Int(before), value <= was else { return false }
                narrower = narrower || value < was
            }
        default:
            return false
        }
        for (header, values) in new.dates {
            guard let had = old.dates[header], Set(values).isSubset(of: had) else { return false }
            if header.hasPrefix("RDATE"), Set(values).count < Set(had).count { narrower = true }
        }
        for (header, values) in old.dates where header.hasPrefix("RDATE") && new.dates[header] == nil {
            narrower = narrower || !values.isEmpty
        }
        let end = new.rule["UNTIL"].flatMap(endInstant)
        for (header, values) in old.dates where header.hasPrefix("EXDATE") {
            let kept = Set(new.dates[header] ?? [])
            for value in values where !kept.contains(value) {
                // Only an exclusion after the new end may go; anything unreadable stays excluded.
                guard let end, let date = dateInstant(value, header: header), date.0 == end.0, date.1 > end.1 else {
                    return false
                }
            }
        }
        return narrower
    }

    private static func endInstant(_ text: String) -> (Kind, Date)? {
        if text.count == 8 { return parse(text, pattern: "yyyyMMdd", zone: .gmt).map { (.day, $0) } }
        return parse(text, pattern: "yyyyMMdd'T'HHmmss'Z'", zone: .gmt).map { (.timed, $0) }
    }

    private static func dateInstant(_ text: String, header: String) -> (Kind, Date)? {
        let params = header.split(separator: ";").dropFirst().map(String.init)
        if params == ["VALUE=DATE"] { return parse(text, pattern: "yyyyMMdd", zone: .gmt).map { (.day, $0) } }
        if params.isEmpty { return parse(text, pattern: "yyyyMMdd'T'HHmmss'Z'", zone: .gmt).map { (.timed, $0) } }
        guard params.count == 1, params[0].hasPrefix("TZID="),
              let zone = TimeZone(identifier: String(params[0].dropFirst(5))),
              let date = parse(text, pattern: "yyyyMMdd'T'HHmmss", zone: zone), uniqueWallTime(date, zone: zone) else {
            return nil
        }
        return (.timed, date)
    }
}
