import Foundation
import MailModel
import Observation
import OpenHumanCore

public enum TimeChoice: Sendable, Hashable {
    case at(Date, ReminderKind)
    case clearReminder
    case wakeNow
}

public enum TimePickerCurrent: Sendable, Hashable {
    case none
    case snoozedUntil(Date)
    case wakeTimeUnknown
    case reminder(Date, ReminderKind)
}

@MainActor @Observable
public final class TimePickerModel {
    public struct Row: Identifiable, Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case parsed(Date)
            case preset(Date)
            case pickDate
            case clearReminder
            case wakeNow
            case snoozeAgain
            case someday
        }

        public let id: String
        public let kind: Kind
        public let title: String
        public let detail: String?
        public let number: Int?
    }

    public struct DatePick: Hashable, Sendable {
        public var day: Date
        public var month: Date
        public var timeText: String
    }

    public static let hintExamples = ["tomorrow 9am", "fri 3pm", "in 3 days", "later today", "dec 1", "today 5pm"]
    public static let unparseableHint = "Try “tomorrow 9am”, “in 3 days” or “later today”"
    public static func couldntReadHint(_ typed: String) -> String { "Couldn’t read “\(typed)” — try “today 5pm”" }
    public static let onlyIfNoReplyLabel = "Only if no reply"
    public static let laterTodayMovedNote = "Nothing left today"
    public static let pastHint = "That time has passed"

    public let kind: TimePickerKind
    public let targets: [ThreadKey]
    public private(set) var current: TimePickerCurrent = .none
    public private(set) var snoozeAgainChosen = false
    public var text = "" {
        didSet { if text != oldValue { refresh() } }
    }
    public var onlyIfNoReply = false

    public var offersOnlyIfNoReply: Bool { kind == .remind || (kind == .sendLater && !targets.isEmpty) }

    private var chosenKind: ReminderKind { offersOnlyIfNoReply && onlyIfNoReply ? .ifNoReply : .always }
    public private(set) var rows: [Row] = []
    public private(set) var cursor = 0
    public private(set) var hint: String?
    public private(set) var datePick: DatePick?
    public private(set) var datePickError: String?
    public private(set) var isClosed = false

    @ObservationIgnored public let presets: TimePresets
    @ObservationIgnored public var locale: Locale
    // 1 is Sunday, as in `Calendar.firstWeekday`
    @ObservationIgnored public var firstWeekday: Int
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let onChoose: @MainActor (TimeChoice) -> Void

    public init(kind: TimePickerKind, targets: [ThreadKey], presets: TimePresets = TimePresets(),
                locale: Locale = .current, firstWeekday: Int = Calendar.current.firstWeekday,
                now: @escaping @Sendable () -> Date = { Date() },
                perform: @escaping @MainActor (TimeChoice) -> Void) {
        self.kind = kind
        self.targets = targets
        self.presets = presets
        self.locale = locale
        self.firstWeekday = firstWeekday
        self.now = now
        self.onChoose = perform
        onlyIfNoReply = kind == .remind
        refresh()
    }

    public var title: String { kind.title }
    public var footer: String { kind.footer }
    public var placeholder: String { "Try “fri 3pm”, “in 2 days”, “later today”" }

    public var currentLine: String? {
        switch current {
        case .none: nil
        case .snoozedUntil(let date): "Snoozed until \(format(date))"
        case .wakeTimeUnknown: "Wake time unknown"
        case .reminder(let date, let kind):
            "Current: \(ReminderItem.isSomeday(date) ? "Someday" : format(date))" + (kind == .ifNoReply ? " (if no reply)" : "")
        }
    }

    public func load(from data: any MailDataSource) async {
        guard let key = targets.first else { return }
        do {
            for try await detail in data.threadDetail(key) {
                apply(snooze: detail?.snooze, reminder: detail?.reminder)
                return
            }
        } catch {
            return
        }
    }

    public func apply(snooze: SnoozeState?, reminder: ReminderItem?) {
        switch kind {
        case .snooze:
            switch snooze {
            case .until(let date, _)?: current = .snoozedUntil(date)
            case .wakeTimeUnknown?: current = .wakeTimeUnknown
            case nil: current = .none
            }
        case .remind:
            if let reminder {
                current = .reminder(reminder.dueAt, reminder.kind)
                onlyIfNoReply = reminder.kind == .ifNoReply
            } else {
                current = .none
            }
        case .sendLater:
            current = .none
        }
        refresh()
    }

    public var isWakeTimeUnknown: Bool { current == .wakeTimeUnknown && !snoozeAgainChosen }

    private func refresh() {
        let nowDate = now()
        var result: [Row] = []
        hint = nil
        if isWakeTimeUnknown {
            result = [Row(id: "wakeNow", kind: .wakeNow, title: "Wake now", detail: nil, number: nil),
                      Row(id: "snoozeAgain", kind: .snoozeAgain, title: "Snooze again…", detail: nil, number: nil)]
        } else {
            let typed = text.trimmingCharacters(in: .whitespaces)
            if !typed.isEmpty {
                do {
                    let date = try presets.parser.parse(typed, now: nowDate)
                    if date > nowDate {
                        let moved = WhenParser.isLaterTodayPhrase(typed)
                            && !presets.calendar.isDate(date, inSameDayAs: nowDate)
                        result.append(Row(id: "parsed", kind: .parsed(date), title: format(date),
                                          detail: moved ? Self.laterTodayMovedNote : nil, number: nil))
                    } else {
                        hint = Self.pastHint
                    }
                } catch {
                    hint = Self.couldntReadHint(typed)
                }
            }
            for preset in presets.presets(for: kind, now: nowDate) {
                if let date = preset.date {
                    result.append(Row(id: preset.id, kind: .preset(date), title: preset.title,
                                      detail: shortFormat(date, now: nowDate), number: preset.number))
                } else {
                    result.append(Row(id: preset.id, kind: .pickDate, title: preset.title, detail: nil, number: preset.number))
                }
            }
            if kind == .remind {
                result.append(Row(id: "someday", kind: .someday, title: "Someday", detail: "No date", number: nil))
            }
            if kind == .remind, case .reminder = current {
                result.append(Row(id: "clearReminder", kind: .clearReminder, title: "Clear reminder", detail: nil, number: nil))
            }
        }
        rows = result
        cursor = 0
    }

    public func moveCursor(by delta: Int) {
        guard !rows.isEmpty else { return }
        cursor = (cursor + delta + rows.count) % rows.count
    }

    public func confirm() {
        if datePick != nil { confirmDatePick(); return }
        if hint != nil, !text.trimmingCharacters(in: .whitespaces).isEmpty,
           !rows.contains(where: { if case .parsed = $0.kind { true } else { false } }) { return }
        guard rows.indices.contains(cursor) else { return }
        choose(rows[cursor])
    }

    @discardableResult
    public func chooseNumber(_ number: Int) -> Bool {
        guard text.isEmpty, datePick == nil, let row = rows.first(where: { $0.number == number }) else { return false }
        choose(row)
        return true
    }

    public func choose(_ row: Row) {
        switch row.kind {
        case .parsed(let date), .preset(let date):
            finish(.at(date, chosenKind))
        case .pickDate:
            openDatePick()
        case .clearReminder:
            finish(.clearReminder)
        case .wakeNow:
            finish(.wakeNow)
        case .snoozeAgain:
            snoozeAgainChosen = true
            refresh()
        case .someday:
            finish(.at(ReminderItem.someday, onlyIfNoReply ? .ifNoReply : .always))
        }
    }

    public func close() { isClosed = true }

    private func finish(_ choice: TimeChoice) {
        guard !isClosed else { return }
        isClosed = true
        onChoose(choice)
    }

    public var weekdayInitials: [String] {
        var cal = presets.calendar
        cal.locale = locale
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[($0 + firstWeekday - 1) % 7] }
    }

    public func monthTitle(_ month: Date) -> String {
        month.formatted(Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: presets.timeZone)
            .month(.wide).year())
    }

    public var timeZone: TimeZone { presets.timeZone }

    public var todayStart: Date { presets.calendar.startOfDay(for: now()) }

    public func openDatePick() {
        let start = presets.calendar.startOfDay(for: now())
        let tomorrow = presets.calendar.date(byAdding: .day, value: 1, to: start) ?? start
        datePick = DatePick(day: tomorrow, month: tomorrow,
                            timeText: String(format: "%02d:%02d", presets.defaults.morningHour, presets.defaults.morningMinute))
        datePickError = nil
    }

    public func closeDatePick() {
        datePick = nil
        datePickError = nil
    }

    public func moveDay(by days: Int) {
        guard var pick = datePick, let moved = presets.calendar.date(byAdding: .day, value: days, to: pick.day) else { return }
        pick.day = moved
        pick.month = moved
        datePick = pick
        datePickError = nil
    }

    public func selectDay(_ day: Date) {
        guard var pick = datePick else { return }
        pick.day = day
        datePick = pick
        datePickError = nil
    }

    public func moveMonth(by months: Int) {
        guard var pick = datePick, let moved = presets.calendar.date(byAdding: .month, value: months, to: pick.month) else { return }
        pick.month = moved
        datePick = pick
    }

    public func setTimeText(_ value: String) {
        guard var pick = datePick else { return }
        pick.timeText = value
        datePick = pick
        datePickError = nil
    }

    public var monthGrid: MonthGrid? {
        datePick.map { MonthGrid(month: $0.month, timeZone: presets.timeZone, firstWeekday: firstWeekday) }
    }

    public func resolveDatePick() -> Date? {
        guard let pick = datePick else { return nil }
        let nowDate = now()
        let reference = presets.calendar.startOfDay(for: pick.day).addingTimeInterval(-1)
        guard let t = try? presets.parser.parse(pick.timeText, now: reference, relativeToNow: false) else {
            datePickError = "Enter a time such as 9:00 or 3pm"
            return nil
        }
        let parts = presets.calendar.dateComponents([.hour, .minute], from: t)
        let date = presets.combine(day: pick.day, hour: parts.hour ?? 0, minute: parts.minute ?? 0, now: nowDate)
        guard date > nowDate else {
            datePickError = Self.pastHint
            return nil
        }
        datePickError = nil
        return date
    }

    private func confirmDatePick() {
        guard let date = resolveDatePick() else { return }
        finish(.at(date, chosenKind))
    }

    public func format(_ date: Date) -> String {
        var day = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: presets.timeZone)
        day = day.weekday(.abbreviated).month(.abbreviated).day()
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: presets.timeZone))
        return "\(date.formatted(day)) at \(time)"
    }

    public func shortFormat(_ date: Date, now: Date) -> String {
        let cal = presets.calendar
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: presets.timeZone))
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        if days == 0 { return "Today, \(time)" }
        if days == 1 { return "Tomorrow, \(time)" }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: presets.timeZone)
        style = days < 7 ? style.weekday(.abbreviated) : style.month(.abbreviated).day()
        return "\(date.formatted(style)), \(time)"
    }
}
