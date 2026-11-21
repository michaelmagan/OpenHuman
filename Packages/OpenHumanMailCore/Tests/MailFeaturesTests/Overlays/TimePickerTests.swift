import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private func utc(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

private func plain(_ text: String?) -> String? { text?.replacingOccurrences(of: "\u{202F}", with: " ") }

private let zone = TimeZone(identifier: "UTC")!
private let newYork = TimeZone(identifier: "America/New_York")!
private let english = Locale(identifier: "en_US_POSIX")
private let wednesday = utc("2026-10-14T10:00:00Z")
private let thread = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1"))

@MainActor
private func picker(_ kind: TimePickerKind, now: Date = wednesday, zone: TimeZone = zone,
                    _ choices: Recorder? = nil) -> TimePickerModel {
    TimePickerModel(kind: kind, targets: [thread], presets: TimePresets(timeZone: zone), locale: english,
                    now: { now }, perform: { choices?.values.append($0) })
}

@MainActor
private final class Recorder {
    var values: [TimeChoice] = []
}

@MainActor
@Suite struct TimePresetTests {
    @Test func snoozePresetsOnAWednesday() {
        let presets = TimePresets(timeZone: zone).presets(for: .snooze, now: wednesday)
        #expect(presets.map(\.title) == ["Later today", "Tomorrow morning", "This weekend", "Next week", "In a month", "Pick a date…"])
        #expect(presets.map(\.number) == [1, 2, 3, 4, 5, 6])
        #expect(presets[0].date == utc("2026-10-14T13:00:00Z"), "now + 3 h")
        #expect(presets[1].date == utc("2026-10-15T08:00:00Z"))
        #expect(presets[2].date == utc("2026-10-17T09:00:00Z"), "Saturday 09:00")
        #expect(presets[3].date == utc("2026-10-19T08:00:00Z"), "next Monday")
        #expect(presets[4].date == utc("2026-11-14T08:00:00Z"))
        #expect(presets[5].isPickDate)
    }

    @Test func laterTodayRoundsUpAndChangesWithTheHour() {
        let presets = TimePresets(timeZone: zone)
        let afternoon = presets.presets(for: .snooze, now: utc("2026-10-14T14:20:00Z"))
        #expect(afternoon[0].title == "Later today" && afternoon[0].date == utc("2026-10-14T18:00:00Z"), "17:20 rounds up to 18:00")
        let evening = presets.presets(for: .snooze, now: utc("2026-10-14T18:30:00Z"))
        #expect(evening[0].title == "This evening" && evening[0].date == utc("2026-10-14T20:00:00Z"), "hidden after 18:00, then 20:00")
        let night = presets.presets(for: .snooze, now: utc("2026-10-14T21:00:00Z"))
        #expect(night[0].title == "Tomorrow morning", "nothing left today after 20:00")
        #expect(night.map(\.number) == Array(1...night.count), "numbers follow the visible rows")
    }

    @Test func weekendPresetIsHiddenOnTheWeekend() {
        let saturday = utc("2026-10-17T10:00:00Z")
        let titles = TimePresets(timeZone: zone).presets(for: .snooze, now: saturday).map(\.title)
        #expect(!titles.contains("This weekend"))
    }

    @Test func remindAndSendLaterVariants() {
        let presets = TimePresets(timeZone: zone)
        let remind = presets.presets(for: .remind, now: wednesday)
        #expect(remind.map(\.title) == ["Later today", "Tomorrow morning", "In 2 days", "Next week", "Pick a date…"])
        #expect(remind[0].date == utc("2026-10-14T13:00:00Z"))
        #expect(remind[2].date == utc("2026-10-16T08:00:00Z"))
        let later = presets.presets(for: .sendLater, now: wednesday)
        #expect(later.map(\.title) == ["In 1 hour", "Tomorrow morning", "Tomorrow afternoon", "Monday", "Pick a date…"])
        #expect(later[0].date == utc("2026-10-14T11:00:00Z"))
        #expect(later[2].date == utc("2026-10-15T13:00:00Z"))
        #expect(later[3].date == utc("2026-10-19T08:00:00Z"))
    }

    @Test func defaultTimesAreConfigurable() {
        let presets = TimePresets(timeZone: zone, defaults: TimeDefaults(morningHour: 7, weekendHour: 10))
        let snooze = presets.presets(for: .snooze, now: wednesday)
        #expect(snooze[1].date == utc("2026-10-15T07:00:00Z"))
        #expect(snooze[2].date == utc("2026-10-17T10:00:00Z"))
    }

    @Test func daylightSavingGapAndOverlap() {
        let presets = TimePresets(timeZone: newYork)
        let gapDay = utc("2026-03-08T12:00:00Z")
        #expect(presets.combine(day: gapDay, hour: 2, minute: 30, now: utc("2026-03-01T00:00:00Z")) == utc("2026-03-08T07:00:00Z"))
        let overlapDay = utc("2026-11-01T12:00:00Z")
        #expect(presets.combine(day: overlapDay, hour: 1, minute: 30, now: utc("2026-10-25T00:00:00Z")) == utc("2026-11-01T05:30:00Z"))
        let early = TimePresets(timeZone: newYork, defaults: TimeDefaults(morningHour: 2))
        let tomorrow = early.presets(for: .remind, now: utc("2026-03-07T17:00:00Z")).first { $0.id == "tomorrowMorning" }!
        #expect(tomorrow.date == utc("2026-03-08T07:00:00Z"))
    }

    @Test func monthGridStartsOnMondayAndHasSixWeeks() {
        let grid = MonthGrid(month: utc("2026-10-14T10:00:00Z"), timeZone: zone, firstWeekday: 2)
        #expect(grid.days.count == 42)
        #expect(grid.days[0].start == utc("2026-09-28T00:00:00Z"), "October 2026 starts on a Thursday; the grid on Monday 28 Sep")
        #expect(grid.days.filter(\.isInMonth).count == 31)
    }

    @Test func monthGridStartsOnTheGivenFirstWeekday() {
        let month = utc("2026-10-14T10:00:00Z")
        #expect(MonthGrid(month: month, timeZone: zone, firstWeekday: 1).days[0].start == utc("2026-09-27T00:00:00Z"), "Sunday")
        #expect(MonthGrid(month: month, timeZone: zone, firstWeekday: 7).days[0].start == utc("2026-09-26T00:00:00Z"), "Saturday")
        #expect(MonthGrid(month: utc("2026-11-10T10:00:00Z"), timeZone: zone, firstWeekday: 1).days[0].start
                == utc("2026-11-01T00:00:00Z"), "November 2026 starts on a Sunday: no leading days")
    }
}

@MainActor
@Suite struct TimePickerModelTests {
    @Test func typedEnglishTextBecomesTheTopRow() throws {
        let cases: [(String, String)] = [
            ("fri 3pm", "2026-10-16T15:00:00Z"),
            ("next tue", "2026-10-20T08:00:00Z"),
            ("tomorrow 7", "2026-10-15T07:00:00Z"),
            ("dec 1", "2026-12-01T08:00:00Z"),
            ("in 2 days", "2026-10-16T10:00:00Z"),
            ("monday 9am", "2026-10-19T09:00:00Z"),
            ("next week", "2026-10-19T08:00:00Z"),
        ]
        for (text, expected) in cases {
            let model = picker(.snooze)
            model.text = text
            guard case .parsed(let date)? = model.rows.first?.kind else {
                Issue.record("\(text): no parsed row")
                continue
            }
            #expect(date == utc(expected), "\(text)")
            #expect(model.hint == nil)
            #expect(model.cursor == 0, "the parsed row has the cursor")
        }
    }

    @Test func parsedRowShowsTheTimeInTheUsersZone() {
        let model = picker(.snooze, zone: newYork)
        model.text = "fri 3pm"
        #expect(plain(model.rows.first?.title) == "Fri, Oct 16 at 3:00 PM")
    }

    @Test func unparseableAndPastTextOffersAHint() {
        let model = picker(.snooze)
        model.text = "whenever"
        #expect(model.hint == TimePickerModel.couldntReadHint(model.text))
        #expect(!model.rows.contains { if case .parsed = $0.kind { true } else { false } })
        #expect(model.rows.count == 6, "the presets stay")
        model.text = "now"
        #expect(model.hint == TimePickerModel.pastHint)
        model.text = ""
        #expect(model.hint == nil)
    }

    @Test func enterChoosesTheCursorRowAndOnlyOnce() {
        let out = Recorder()
        let model = picker(.snooze, out)
        model.text = "fri 3pm"
        model.confirm()
        model.confirm()
        #expect(out.values == [.at(utc("2026-10-16T15:00:00Z"), .always)])
        #expect(model.isClosed)
    }

    @Test func numberKeysChooseWhileTheFieldIsEmpty() {
        let out = Recorder()
        let model = picker(.snooze, out)
        model.text = "x"
        #expect(!model.chooseNumber(2), "with text in the field a digit is typing")
        model.text = ""
        #expect(model.chooseNumber(2))
        #expect(out.values == [.at(utc("2026-10-15T08:00:00Z"), .always)])
        let other = picker(.snooze, Recorder())
        #expect(!other.chooseNumber(9), "no such preset")
    }

    @Test func cursorWraps() {
        let model = picker(.remind)
        model.moveCursor(by: -1)
        #expect(model.cursor == model.rows.count - 1)
        model.moveCursor(by: 1)
        #expect(model.cursor == 0)
    }

    @Test func remindVariantHasTheCheckboxAndFooter() {
        let out = Recorder()
        let model = picker(.remind, out)
        #expect(model.title == "Remind me…")
        #expect(model.footer == "Reminders stay on this Mac.")
        #expect(model.rows.map(\.title) == ["Later today", "Tomorrow morning", "In 2 days", "Next week", "Pick a date…", "Someday"])
        model.onlyIfNoReply = true
        model.chooseNumber(3)
        #expect(out.values == [.at(utc("2026-10-16T08:00:00Z"), .ifNoReply)])
    }

    @Test func anExistingReminderIsShownFromTheCacheAndCanBeCleared() {
        let out = Recorder()
        let model = picker(.remind, out)
        let item = ReminderItem(id: "r1", thread: thread, subject: "s", dueAt: utc("2026-10-20T09:00:00Z"), kind: .ifNoReply)
        model.apply(snooze: nil, reminder: item)
        #expect(plain(model.currentLine) == "Current: Tue, Oct 20 at 9:00 AM (if no reply)")
        #expect(model.onlyIfNoReply, "the checkbox starts as the current reminder's")
        #expect(model.rows.last?.title == "Clear reminder")
        model.choose(model.rows.last!)
        #expect(out.values == [.clearReminder])
    }

    @Test func aSnoozedThreadShowsItsCurrentTimeAndStillOffersPresets() {
        let model = picker(.snooze)
        model.apply(snooze: .until(utc("2026-10-16T09:00:00Z"), stampCount: 1), reminder: nil)
        #expect(plain(model.currentLine) == "Snoozed until Fri, Oct 16 at 9:00 AM")
        #expect(model.rows.count == 6)
    }

    @Test func aMalformedSnoozeOffersWakeNowOrSnoozeAgain() {
        let out = Recorder()
        let model = picker(.snooze, out)
        model.apply(snooze: .wakeTimeUnknown, reminder: nil)
        #expect(model.currentLine == "Wake time unknown")
        #expect(model.rows.map(\.title) == ["Wake now", "Snooze again…"])
        model.moveCursor(by: 1)
        model.confirm()
        #expect(model.rows.count == 6 && !model.isClosed, "Snooze again shows the presets")
        #expect(out.values.isEmpty)
        let wake = picker(.snooze, out)
        wake.apply(snooze: .wakeTimeUnknown, reminder: nil)
        wake.confirm()
        #expect(out.values == [.wakeNow])
    }

    @Test func pickADateUsesTheGridAndATimeField() throws {
        let out = Recorder()
        let model = picker(.snooze, out)
        model.chooseNumber(6)
        #expect(model.datePick != nil && !model.isClosed)
        #expect(model.datePick?.day == utc("2026-10-15T00:00:00Z"), "starts on tomorrow")
        model.moveDay(by: 7)
        model.moveDay(by: -1)
        #expect(model.datePick?.day == utc("2026-10-21T00:00:00Z"))
        model.setTimeText("9:30 pm")
        model.confirm()
        #expect(out.values == [.at(utc("2026-10-21T21:30:00Z"), .always)])
    }

    @Test func pickADateRejectsBadAndPastTimes() {
        let model = picker(.snooze, Recorder())
        model.openDatePick()
        model.setTimeText("later")
        #expect(model.resolveDatePick() == nil && model.datePickError != nil)
        model.selectDay(utc("2026-10-10T00:00:00Z"))
        model.setTimeText("9am")
        #expect(model.resolveDatePick() == nil && model.datePickError == TimePickerModel.pastHint)
        model.closeDatePick()
        #expect(model.datePick == nil)
    }

    @Test func nothingIsKeptByThePickerItself() async {
        let a = picker(.snooze), b = picker(.snooze)
        a.apply(snooze: .until(utc("2026-10-16T09:00:00Z"), stampCount: 1), reminder: nil)
        #expect(b.currentLine == nil)
    }
}

@MainActor
@Suite struct RemindLaterTodayTests {
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        utc(String(format: "2026-10-14T%02d:%02d:00Z", hour, minute))
    }

    @Test func remindHasLaterTodayAtEightInTheMorning() {
        let remind = TimePresets(timeZone: zone).presets(for: .remind, now: at(8))
        #expect(remind.first?.title == "Later today" && remind.first?.date == at(11))
        #expect(remind.map(\.number) == Array(1...remind.count))
    }

    @Test(arguments: [0, 7, 8, 12, 15, 17, 18, 19, 20, 21, 23])
    func remindAndSnoozeAgreeOnTheFirstRow(hour: Int) {
        let presets = TimePresets(timeZone: zone)
        let remind = presets.presets(for: .remind, now: at(hour, 10))
        let snooze = presets.presets(for: .snooze, now: at(hour, 10))
        let r = remind.first { $0.id == "laterToday" || $0.id == "thisEvening" }
        let s = snooze.first { $0.id == "laterToday" || $0.id == "thisEvening" }
        #expect(r == s, "hour \(hour)")
        if hour < 18 { #expect(r?.title == "Later today") }
        else if hour < 20 { #expect(r?.title == "This evening" && r?.date == at(20)) }
        else { #expect(r == nil && remind[0].title == "Tomorrow morning", "nothing left today at \(hour):10") }
        #expect(remind.allSatisfy { $0.date.map { $0 > at(hour, 10) } ?? true }, "no preset is in the past")
    }

    @Test func typedLaterTodayMatchesTheRow() {
        let model = picker(.remind, now: at(8))
        model.text = "later today"
        guard case .parsed(let date)? = model.rows.first?.kind else { Issue.record("no parsed row"); return }
        #expect(date == at(11) && model.hint == nil && model.rows.first?.detail == nil)
        let tonight = picker(.remind, now: at(8))
        for phrase in ["tonight", "this evening", "this afternoon", "later", "in an hour"] {
            tonight.text = phrase
            #expect(tonight.hint == nil, "\(phrase)")
        }
    }

    @Test func lateAtNightLaterTodayIsLabelledAsTomorrow() {
        let model = picker(.remind, now: at(21))
        model.text = "later today"
        guard case .parsed(let date)? = model.rows.first?.kind else { Issue.record("no parsed row"); return }
        #expect(date == utc("2026-10-15T08:00:00Z"))
        #expect(model.rows.first?.detail == TimePickerModel.laterTodayMovedNote)
        #expect(plain(model.rows.first?.title)?.contains("Oct 15") == true, "the title names the real day")
    }

    @Test func everyExampleInTheHintsParses() {
        let hint = TimePickerModel.unparseableHint, placeholder = picker(.remind).placeholder
        let parser = TimePresets(timeZone: zone).parser
        for example in TimePickerModel.hintExamples {
            #expect((try? parser.parse(example, now: wednesday)) != nil, "\(example)")
        }
        for text in [hint, placeholder] {
            let quoted = text.split(separator: "“").dropFirst().compactMap { $0.split(separator: "”").first }
            #expect(!quoted.isEmpty)
            for phrase in quoted { #expect((try? parser.parse(String(phrase), now: wednesday)) != nil, "\(phrase)") }
        }
    }

    @Test func gibberishShowsTheHonestHint() {
        let model = picker(.remind)
        model.text = "gibberish"
        #expect(model.hint == TimePickerModel.couldntReadHint("gibberish") && TimePickerModel.unparseableHint.contains("later today"))
    }

    @Test func theCheckboxLabelIsTheOnlyIfNoReplyText() {
        #expect(TimePickerModel.onlyIfNoReplyLabel == "Only if no reply")
        #expect(picker(.remind).offersOnlyIfNoReply)
    }
}

@MainActor
@Suite struct RemindGridAndPhraseTests {
    private func at(_ h: Int, _ m: Int = 0) -> Date { utc(String(format: "2026-10-14T%02d:%02d:00Z", h, m)) }

    @Test func timeAndDayInEitherOrder() throws {
        let parser = TimePresets(timeZone: zone).parser
        let now = at(8)
        for (text, expected) in [("today 5pm", at(17)), ("5pm today", at(17)), ("5 pm today", at(17)),
                                 ("today at 5", at(17)), ("noon today", at(12)), ("tonight at 9", at(21)),
                                 ("tonight 9pm", at(21)), ("9pm tonight", at(21)),
                                 ("9am tomorrow", utc("2026-10-15T09:00:00Z")), ("3pm fri", utc("2026-10-16T15:00:00Z")),
                                 ("dec 1 9am", utc("2026-12-01T09:00:00Z"))] {
            #expect(try parser.parse(text, now: now) == expected, "\(text)")
        }
    }

    @Test func unreadableTextShowsAOneLineHintKeepsThePresetsAndNeverChoosesOrOpensTheGrid() {
        let out = Recorder()
        let model = picker(.remind, now: at(8), out)
        model.text = "pm today"
        #expect(model.hint == "Couldn’t read “pm today” — try “today 5pm”")
        #expect(model.rows.contains { $0.id == "tomorrowMorning" } && model.rows.contains { $0.kind == .pickDate })
        model.confirm()
        #expect(out.values.isEmpty && model.datePick == nil && !model.isClosed, "Return does nothing")
        model.text = "today 5pm"
        #expect(model.hint == nil)
        model.confirm()
        #expect(out.values == [.at(at(17), .ifNoReply)])
    }

    @Test func thePickersGridAndInitialsFollowItsFirstWeekday() {
        func model(_ firstWeekday: Int) -> TimePickerModel {
            let model = TimePickerModel(kind: .remind, targets: [], presets: TimePresets(timeZone: zone), locale: english,
                                        firstWeekday: firstWeekday, now: { wednesday }) { _ in }
            model.openDatePick()
            return model
        }
        #expect(model(1).weekdayInitials == ["S", "M", "T", "W", "T", "F", "S"])
        #expect(model(2).weekdayInitials == ["M", "T", "W", "T", "F", "S", "S"])
        #expect(model(7).weekdayInitials.prefix(2) == ["S", "S"])
        #expect(model(1).monthGrid?.days.first?.start == utc("2026-09-27T00:00:00Z"))
        #expect(model(2).monthGrid?.days.first?.start == utc("2026-09-28T00:00:00Z"))
    }

    @Test func gridKnowsToday() {
        let model = picker(.remind, now: at(8))
        #expect(model.todayStart == utc("2026-10-14T00:00:00Z"))
    }

    @Test func theMonthTitleFollowsThePickersZoneNotTheSystemOnes() {
        let auckland = TimeZone(identifier: "Pacific/Auckland")!
        let model = TimePickerModel(kind: .remind, targets: [], presets: TimePresets(timeZone: auckland), locale: english,
                                    now: { utc("2026-10-13T00:00:00Z") }) { _ in }
        model.openDatePick()
        let grid = model.monthGrid
        #expect(model.monthTitle(grid!.month) == "October 2026")
        #expect(model.monthTitle(utc("2026-09-30T11:00:00Z")) == "October 2026", "Oct 1 00:00 Auckland")
        let la = TimePickerModel(kind: .remind, targets: [], presets: TimePresets(timeZone: TimeZone(identifier: "America/Los_Angeles")!),
                                 locale: english, now: { wednesday }) { _ in }
        #expect(la.monthTitle(utc("2026-10-01T05:00:00Z")) == "September 2026", "Sep 30 22:00 in Los Angeles")
    }
}
