import Foundation
import MailModel

public struct CalendarInvite: Sendable, Hashable {
    public enum Method: Sendable, Hashable {
        case request, cancel, reply, counter, publish
        case other(String)

        init(_ raw: String?) {
            switch raw?.uppercased() {
            case "REQUEST"?: self = .request
            case "CANCEL"?: self = .cancel
            case "REPLY"?: self = .reply
            case "COUNTER"?: self = .counter
            case "PUBLISH"?, nil: self = .publish
            case let other?: self = .other(other)
            }
        }
    }

    public struct Person: Sendable, Hashable {
        public let email: String
        public let name: String?
        public let response: CalendarResponse?
        public let isOptional: Bool
        public let isResource: Bool

        public init(email: String, name: String? = nil, response: CalendarResponse? = nil, isOptional: Bool = false,
                    isResource: Bool = false) {
            self.email = email.lowercased()
            self.name = name
            self.response = response
            self.isOptional = isOptional
            self.isResource = isResource
        }
    }

    public let method: Method
    public let uid: String
    public let sequence: Int
    public let recurrenceID: Date?
    public let repeatFrequency: String?
    public let isCancelled: Bool
    public let title: String?
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let timeZoneID: String?
    public let location: String?
    public let notes: String?
    public let url: URL?
    public let conferenceURL: URL?
    public let conferenceIsGoogle: Bool
    public let organizer: Person?
    public let attendees: [Person]

    public var repeats: Bool { repeatFrequency != nil }
    public var occurrence: Date { recurrenceID ?? start }

    public init(method: Method, uid: String, sequence: Int = 0, recurrenceID: Date? = nil, repeatFrequency: String? = nil,
                isCancelled: Bool = false, title: String?, start: Date, end: Date, isAllDay: Bool = false,
                timeZoneID: String? = nil, location: String? = nil, notes: String? = nil, url: URL? = nil,
                conferenceURL: URL? = nil, conferenceIsGoogle: Bool = false, organizer: Person? = nil,
                attendees: [Person] = []) {
        self.method = method
        self.uid = uid
        self.sequence = sequence
        self.recurrenceID = recurrenceID
        self.repeatFrequency = repeatFrequency
        self.isCancelled = isCancelled
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZoneID = timeZoneID
        self.location = location
        self.notes = notes
        self.url = url
        self.conferenceURL = conferenceURL
        self.conferenceIsGoogle = conferenceIsGoogle
        self.organizer = organizer
        self.attendees = attendees
    }

    public func attendee(in addresses: Set<String>) -> Person? {
        attendees.first { addresses.contains($0.email) }
    }
}

public enum ICSParser {
    public static let maxBytes = 512 * 1024
    public static let meetingHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com"]

    public static func parse(_ text: String, defaultZone: TimeZone) -> CalendarInvite? {
        let capped = text.utf8.count > maxBytes ? String(decoding: Array(text.utf8.prefix(maxBytes)), as: UTF8.self) : text
        let lines = contentLines(capped)
        var method: String?
        var stack: [String] = []
        var events: [[Line]] = []
        var event: [Line] = []
        var zones: [String: ZoneRule] = [:]
        var zoneID: String?
        var observances: [Observance] = []
        var observance: [Line] = []
        for line in lines {
            if line.name == "BEGIN" {
                let kind = line.value.uppercased()
                stack.append(kind)
                if kind == "VEVENT" { event = [] }
                if kind == "VTIMEZONE" { zoneID = nil; observances = [] }
                if kind == "STANDARD" || kind == "DAYLIGHT" { observance = [] }
                continue
            }
            if line.name == "END" {
                let kind = line.value.uppercased()
                if kind == "VEVENT", stack.last == "VEVENT" { events.append(event) }
                if kind == "VTIMEZONE", let zoneID, !observances.isEmpty { zones[zoneID] = ZoneRule(observances: observances) }
                if (kind == "STANDARD" || kind == "DAYLIGHT"), let made = Observance(observance) { observances.append(made) }
                if let index = stack.lastIndex(of: kind) { stack.removeSubrange(index...) }
                continue
            }
            switch stack.last {
            case "VCALENDAR"?:
                if line.name == "METHOD" { method = line.value.trimmingCharacters(in: .whitespaces) }
            case "VEVENT"?:
                event.append(line)
            case "VTIMEZONE"?:
                if line.name == "TZID" { zoneID = line.value.trimmingCharacters(in: .whitespaces) }
            case "STANDARD"?, "DAYLIGHT"?:
                observance.append(line)
            default:
                break
            }
        }
        let chosen = events.first { lines in !lines.contains { $0.name == "RECURRENCE-ID" } } ?? events.first
        guard let chosen else { return nil }
        return invite(chosen, method: CalendarInvite.Method(method), zones: zones, defaultZone: defaultZone)
    }


    private static func invite(_ lines: [Line], method: CalendarInvite.Method, zones: [String: ZoneRule],
                               defaultZone: TimeZone) -> CalendarInvite? {
        func first(_ name: String) -> Line? { lines.first { $0.name == name } }
        func text(_ name: String) -> String? {
            guard let value = first(name)?.value else { return nil }
            let unescaped = unescape(value).trimmingCharacters(in: .whitespacesAndNewlines)
            return unescaped.isEmpty ? nil : unescaped
        }
        guard let uid = first("UID")?.value.trimmingCharacters(in: .whitespaces), !uid.isEmpty,
              let startLine = first("DTSTART"), let begins = moment(startLine, zones: zones, defaultZone: defaultZone)
        else { return nil }
        var end: Date
        if let endLine = first("DTEND"), let ends = moment(endLine, zones: zones, defaultZone: defaultZone) {
            end = ends.date
        } else if let duration = first("DURATION").flatMap({ seconds(duration: $0.value) }) {
            end = begins.date.addingTimeInterval(duration)
        } else if begins.allDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = defaultZone
            end = calendar.date(byAdding: .day, value: 1, to: begins.date) ?? begins.date.addingTimeInterval(86_400)
        } else {
            end = begins.date
        }
        if end < begins.date { end = begins.date }
        let status = first("STATUS")?.value.uppercased()
        let recurrence = first("RECURRENCE-ID").flatMap { moment($0, zones: zones, defaultZone: defaultZone)?.date }
        let frequency = first("RRULE").flatMap { rule in
            rule.value.split(separator: ";").first { $0.uppercased().hasPrefix("FREQ=") }
                .map { String($0.dropFirst(5)).uppercased() }
        }
        let location = text("LOCATION")
        let notes = text("DESCRIPTION")
        let url = first("URL").flatMap { safeURL($0.value) }
        var conference = first("X-GOOGLE-CONFERENCE").flatMap { safeURL($0.value) }
        let isGoogle = conference != nil
        if conference == nil {
            conference = [location, url?.absoluteString, notes].compactMap { $0 }.lazy
                .compactMap { meetingLink(in: $0) }.first
        }
        let organizer = first("ORGANIZER").flatMap(person)
        let attendees = lines.filter { $0.name == "ATTENDEE" }.compactMap(person)
        return CalendarInvite(method: method, uid: uid, sequence: Int(first("SEQUENCE")?.value.trimmingCharacters(in: .whitespaces) ?? "") ?? 0,
                              recurrenceID: recurrence, repeatFrequency: frequency,
                              isCancelled: method == .cancel || status == "CANCELLED",
                              title: text("SUMMARY"), start: begins.date, end: end, isAllDay: begins.allDay,
                              timeZoneID: begins.zoneID, location: location, notes: notes, url: url,
                              conferenceURL: conference, conferenceIsGoogle: isGoogle, organizer: organizer,
                              attendees: attendees)
    }

    private static func person(_ line: Line) -> CalendarInvite.Person? {
        var address = line.value.trimmingCharacters(in: .whitespaces)
        if address.lowercased().hasPrefix("mailto:") { address = String(address.dropFirst(7)) }
        if !address.contains("@"), let email = line.params["EMAIL"] { address = email }
        address = address.trimmingCharacters(in: .whitespaces)
        guard address.contains("@"), !address.contains(" ") else { return nil }
        let name = line.params["CN"].map(unescape)?.trimmingCharacters(in: .whitespaces)
        let response: CalendarResponse? = switch line.params["PARTSTAT"]?.uppercased() {
        case "ACCEPTED"?: .accepted
        case "DECLINED"?: .declined
        case "TENTATIVE"?: .tentative
        case "NEEDS-ACTION"?: .needsAction
        default: nil
        }
        let cutype = line.params["CUTYPE"]?.uppercased()
        return CalendarInvite.Person(email: address, name: name?.isEmpty == false && name != address ? name : nil,
                                     response: response, isOptional: line.params["ROLE"]?.uppercased() == "OPT-PARTICIPANT",
                                     isResource: cutype == "RESOURCE" || cutype == "ROOM")
    }


    static func safeURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return url
    }

    static func meetingLink(in text: String) -> URL? {
        for word in text.split(whereSeparator: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\"" }) {
            guard word.lowercased().hasPrefix("https://"),
                  let url = safeURL(String(word).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)("))),
                  let host = url.host(percentEncoded: false)?.lowercased() else { continue }
            if meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
        }
        return nil
    }


    struct Line: Sendable, Hashable {
        let name: String
        let params: [String: String]
        let value: String
    }

    static func contentLines(_ text: String) -> [Line] {
        var unfolded: [String] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            if let first = raw.first, first == " " || first == "\t", !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                unfolded.append(String(raw))
            }
        }
        return unfolded.compactMap(line)
    }

    static func line(_ text: String) -> Line? {
        var inQuotes = false
        var colon: String.Index?
        for index in text.indices {
            let character = text[index]
            if character == "\"" { inQuotes.toggle() }
            if character == ":", !inQuotes { colon = index; break }
        }
        guard let colon else { return nil }
        let head = text[..<colon]
        let value = String(text[text.index(after: colon)...])
        var parts: [String] = []
        var current = ""
        inQuotes = false
        for character in head {
            if character == "\"" { inQuotes.toggle() }
            if character == ";", !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        guard let name = parts.first?.trimmingCharacters(in: .whitespaces).uppercased(), !name.isEmpty else { return nil }
        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = part[..<equals].trimmingCharacters(in: .whitespaces).uppercased()
            var raw = String(part[part.index(after: equals)...])
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 { raw = String(raw.dropFirst().dropLast()) }
            params[key] = raw
        }
        return Line(name: name, params: params, value: value)
    }

    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        var escaping = false
        for character in text {
            if escaping {
                switch character {
                case "n", "N": out.append("\n")
                default: out.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                out.append(character)
            }
        }
        return out
    }


    struct Moment {
        let date: Date
        let allDay: Bool
        let zoneID: String?
    }

    static func moment(_ line: Line, zones: [String: ZoneRule], defaultZone: TimeZone) -> Moment? {
        let value = line.value.trimmingCharacters(in: .whitespaces)
        if line.params["VALUE"]?.uppercased() == "DATE" || (value.count == 8 && !value.contains("T")) {
            guard let day = Wall(value) else { return nil }
            return day.date(in: defaultZone).map { Moment(date: $0, allDay: true, zoneID: nil) }
        }
        guard let wall = Wall(value) else { return nil }
        if value.uppercased().hasSuffix("Z") {
            return wall.date(in: TimeZone(identifier: "UTC") ?? .gmt).map { Moment(date: $0, allDay: false, zoneID: nil) }
        }
        if var tzid = line.params["TZID"]?.trimmingCharacters(in: .whitespaces), !tzid.isEmpty {
            if tzid.hasPrefix("/") { tzid.removeFirst() }
            if let zone = TimeZone(identifier: tzid) {
                return wall.date(in: zone).map { Moment(date: $0, allDay: false, zoneID: zone.identifier) }
            }
            let original = line.params["TZID"]?.trimmingCharacters(in: .whitespaces) ?? tzid
            if let rule = zones[original] ?? zones[tzid] {
                return Moment(date: wall.naive.addingTimeInterval(-TimeInterval(rule.offset(at: wall))), allDay: false,
                              zoneID: tzid)
            }
        }
        return wall.date(in: defaultZone).map { Moment(date: $0, allDay: false, zoneID: nil) }
    }

    static func seconds(duration text: String) -> TimeInterval? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces).uppercased())
        var sign: Double = 1
        if rest.hasPrefix("-") { sign = -1; rest = rest.dropFirst() } else if rest.hasPrefix("+") { rest = rest.dropFirst() }
        guard rest.hasPrefix("P") else { return nil }
        rest = rest.dropFirst()
        var total: Double = 0
        var number = ""
        var inTime = false
        var any = false
        for character in rest {
            if character.isNumber { number.append(character); continue }
            if character == "T" { inTime = true; continue }
            guard let value = Double(number) else { return nil }
            number = ""
            any = true
            switch (character, inTime) {
            case ("W", false): total += value * 604_800
            case ("D", false): total += value * 86_400
            case ("H", true): total += value * 3_600
            case ("M", true): total += value * 60
            case ("S", true): total += value
            default: return nil
            }
        }
        guard any, number.isEmpty, total.isFinite, total <= maxDuration else { return nil }
        return sign * total
    }

    static let maxDuration: TimeInterval = 366 * 86_400 * 10

    struct Wall: Hashable {
        let year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int

        init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
            self.year = year; self.month = month; self.day = day; self.hour = hour; self.minute = minute; self.second = second
        }

        init?(_ text: String) {
            let digits = Array(text.uppercased().replacingOccurrences(of: "Z", with: ""))
            func number(_ from: Int, _ count: Int) -> Int? {
                guard digits.count >= from + count else { return nil }
                return Int(String(digits[from..<(from + count)]))
            }
            guard let year = number(0, 4), let month = number(4, 2), let day = number(6, 2), (1...12).contains(month),
                  (1...31).contains(day) else { return nil }
            var hour = 0, minute = 0, second = 0
            if digits.count > 8 {
                guard digits[8] == "T", let h = number(9, 2), let m = number(11, 2), (0...23).contains(h),
                      (0...59).contains(m) else { return nil }
                hour = h
                minute = m
                second = number(13, 2) ?? 0
            }
            self.init(year: year, month: month, day: day, hour: hour, minute: minute, second: min(second, 59))
        }

        func date(in zone: TimeZone) -> Date? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute,
                                                      second: second))
        }

        var naive: Date { date(in: TimeZone(identifier: "UTC") ?? .gmt) ?? .distantPast }
    }

    struct Observance {
        let start: Wall
        let offset: Int
        let month: Int?
        let weekday: Int?
        let ordinal: Int?

        init?(_ lines: [Line]) {
            guard let start = lines.first(where: { $0.name == "DTSTART" }).flatMap({ Wall($0.value) }),
                  let offset = lines.first(where: { $0.name == "TZOFFSETTO" }).flatMap({ ICSParser.offset($0.value) })
            else { return nil }
            self.start = start
            self.offset = offset
            var month: Int?, weekday: Int?, ordinal: Int?
            if let rule = lines.first(where: { $0.name == "RRULE" })?.value.uppercased(), rule.contains("FREQ=YEARLY") {
                for part in rule.split(separator: ";") {
                    if part.hasPrefix("BYMONTH=") { month = Int(part.dropFirst(8).split(separator: ",").first ?? "") }
                    if part.hasPrefix("BYDAY=") {
                        let day = String(part.dropFirst(6).split(separator: ",").first ?? "")
                        let code = String(day.suffix(2))
                        weekday = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"].firstIndex(of: code).map { $0 + 1 }
                        let count = day.dropLast(2)
                        ordinal = count.isEmpty ? 1 : Int(count)
                    }
                }
            }
            if let value = month, !(1...12).contains(value) { month = nil }
            if let value = ordinal, !Self.ordinals.contains(value) { ordinal = nil }
            if month != nil, weekday != nil, ordinal != nil {
                self.month = month; self.weekday = weekday; self.ordinal = ordinal
            } else {
                self.month = nil; self.weekday = nil; self.ordinal = nil
            }
        }

        func onset(atOrBefore wall: Wall) -> Date? {
            let target = wall.naive
            guard let month, let weekday, let ordinal else { return start.naive <= target ? start.naive : nil }
            for year in [wall.year, wall.year - 1] {
                guard let day = Self.day(year: year, month: month, weekday: weekday, ordinal: ordinal) else { continue }
                let onset = Wall(year: year, month: month, day: day, hour: start.hour, minute: start.minute,
                                 second: start.second).naive
                if onset <= target, onset >= start.naive { return onset }
            }
            return nil
        }

        static let ordinals: Set<Int> = [-5, -4, -3, -2, -1, 1, 2, 3, 4, 5]

        static func day(year: Int, month: Int, weekday: Int, ordinal: Int) -> Int? {
            guard (1...12).contains(month), (1...7).contains(weekday), ordinals.contains(ordinal),
                  (1...9_999).contains(year) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let days = calendar.range(of: .day, in: .month, for: first)?.count else { return nil }
            if ordinal > 0 {
                let firstWeekday = calendar.component(.weekday, from: first)
                let day = 1 + (weekday - firstWeekday + 7) % 7 + (ordinal - 1) * 7
                return day > days ? day - ((day - days + 6) / 7) * 7 : day
            }
            guard let last = calendar.date(from: DateComponents(year: year, month: month, day: days)) else { return nil }
            let lastWeekday = calendar.component(.weekday, from: last)
            let day = days - (lastWeekday - weekday + 7) % 7 - (-ordinal - 1) * 7
            return day >= 1 ? day : nil
        }
    }

    struct ZoneRule {
        let observances: [Observance]

        func offset(at wall: Wall) -> Int {
            let candidates = observances.compactMap { observance in observance.onset(atOrBefore: wall).map { ($0, observance) } }
            if let latest = candidates.max(by: { $0.0 < $1.0 }) { return latest.1.offset }
            return observances.min(by: { $0.start.naive < $1.start.naive })?.offset ?? 0
        }
    }

    static func offset(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let digits = Array(trimmed.dropFirst())
        guard digits.count == 4 || digits.count == 6, digits.allSatisfy(\.isNumber),
              let hours = Int(String(digits[0..<2])), let minutes = Int(String(digits[2..<4])) else { return nil }
        let seconds = digits.count == 6 ? Int(String(digits[4..<6])) ?? 0 : 0
        let total = hours * 3_600 + minutes * 60 + seconds
        return sign == "-" ? -total : total
    }
}
