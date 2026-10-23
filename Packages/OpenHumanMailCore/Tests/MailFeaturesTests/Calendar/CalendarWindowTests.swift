import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
private let laCalendar = CalendarDateMentions.calendar(losAngeles)

private func la(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    laCalendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
}

private let sam = EmailAddress(name: "Sam Rivera", email: "sam@example.org")

private func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false, attendees: [EmailAddress] = [],
                   organizerIsMe: Bool? = nil, location: String? = nil, response: CalendarResponse? = nil,
                   series: String? = nil) -> CalendarEvent {
    CalendarEvent(id: id, title: "Event \(id)", start: start, end: end, isAllDay: allDay, attendees: attendees,
                  organizerIsMe: organizerIsMe, location: location, myResponse: response, recurringEventID: series)
}

@MainActor
private final class WindowClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
private struct CalendarWindowFixture {
    let env: AppEnvironment
    let work: FakeCalendar
    let home: FakeCalendar
    let corpus: FakeCorpus

    var workEmail: String { corpus.accounts[0].email.lowercased() }
    var homeEmail: String { corpus.accounts[1].email.lowercased() }

    init(work: [CalendarEvent] = [], home: [CalendarEvent] = [],
         workAbilities: CalendarAbilities = [.respond, .editDetails, .remove], cache: InMemoryCalendarCache? = nil) {
        corpus = .rich(threadCount: 12, now: fixedNow)
        let accounts = corpus.accounts
        self.work = FakeCalendar(events: work, info: CalendarProviderInfo(name: "Google Calendar", account: accounts[0].email),
                                 abilities: workAbilities)
        self.home = FakeCalendar(events: home, info: CalendarProviderInfo(name: "Google Calendar", account: accounts[1].email))
        let connections = FakeCalendarConnections(providers: [accounts[0].email: self.work, accounts[1].email: self.home])
        env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate),
                                  featureFlags: FeatureFlags(), calendar: self.work, calendarConnections: connections,
                                  calendarCache: cache)
    }

    var workKey: CalendarCacheKey { CalendarEventStore.key(for: work) }

    func window(clock: WindowClock = WindowClock(la(10, 12, 11))) -> CalendarWindowModel {
        let sidebar = env.calendarSidebar!
        sidebar.timeZone = losAngeles
        sidebar.now = { clock.now }
        sidebar.loadText = { _ in CalendarThreadText(subject: "Planning", texts: ["Planning"], participants: [sam]) }
        let model = env.calendarWindow!
        model.timeZone = losAngeles
        model.now = { clock.now }
        model.confirmsMovesOverride = false
        return model
    }

    func run(_ id: ActionID, source: ActionSource = .keyboard) async -> Bool {
        await env.actions.run(id, source: source, host: env.router)
    }
}

@Suite struct CalendarWindowLayoutTests {
    @Test func theViewsCoverTheirDaysAndMoveByTheirLength() {
        let week = CalendarPeriod.containing(la(10, 14, 15), kind: .week, calendar: laCalendar)
        #expect(week.start == la(10, 11) && week.end == la(10, 18) && week.days.count == 7, "Sunday 11 to Saturday 17")
        #expect(week.days.last == la(10, 17))
        #expect(week.moved(by: 1, calendar: laCalendar).start == la(10, 18))
        #expect(week.moved(by: -1, calendar: laCalendar).start == la(10, 4))
        let day = CalendarPeriod.containing(la(10, 14, 15), kind: .day, calendar: laCalendar)
        #expect(day.days == [la(10, 14)] && day.end == la(10, 15))
        #expect(day.moved(by: -1, calendar: laCalendar).days == [la(10, 13)])
        let three = CalendarPeriod.containing(la(10, 14, 15), kind: .threeDays, calendar: laCalendar)
        #expect(three.days == [la(10, 14), la(10, 15), la(10, 16)])
        #expect(three.moved(by: 1, calendar: laCalendar).start == la(10, 17))
        #expect(week.titleDay == la(10, 14), "a week is named by its middle day")
    }

    @Test func weeksOverASummerTimeChangeKeepSevenMidnightsAndWallClockPlaces() {
        let fallBack = CalendarPeriod.containing(la(11, 4), kind: .week, calendar: laCalendar)
        #expect(fallBack.start == la(11, 1) && fallBack.end == la(11, 8))
        #expect(fallBack.days.allSatisfy { laCalendar.component(.hour, from: $0) == 0 && laCalendar.component(.minute, from: $0) == 0 })
        #expect(fallBack.end.timeIntervalSince(fallBack.start) == 7 * 86_400 + 3_600, "this week has 169 hours")
        let spring = CalendarPeriod.containing(la(3, 10), kind: .week, calendar: laCalendar)
        #expect(spring.start == la(3, 8) && spring.end.timeIntervalSince(spring.start) == 7 * 86_400 - 3_600)
        let grid = CalendarTimeGrid(days: spring.days,
                                    events: [event("a", la(3, 8, 9), la(3, 8, 10)), event("b", la(3, 9, 9), la(3, 9, 10))],
                                    timeZone: losAngeles, now: la(3, 1))
        let a = grid.blocks.first { $0.event.id == "a" }
        let b = grid.blocks.first { $0.event.id == "b" }
        #expect(a?.dayIndex == 0 && b?.dayIndex == 1)
        #expect(abs((a?.top ?? 0) - 9.0 / 24) < 0.0001 && abs((b?.top ?? 0) - 9.0 / 24) < 0.0001,
                "9 AM sits at 9/24 on the 23-hour day too")
        #expect(abs((a?.height ?? 0) - 1.0 / 24) < 0.0001)
        #expect(grid.zoneLabel == losAngeles.abbreviation(for: la(3, 8)))
        let month = CalendarPeriod.containing(la(11, 15), kind: .month, calendar: laCalendar)
        #expect(month.days.count == 35 && month.days.allSatisfy { laCalendar.component(.hour, from: $0) == 0 })
    }

    @Test func overlapsSitSideBySideInTheirOwnDayColumn() {
        let events = [event("a", la(10, 13, 9), la(10, 13, 10)), event("b", la(10, 13, 9, 30), la(10, 13, 10, 30)),
                      event("c", la(10, 13, 10, 30), la(10, 13, 11)), event("d", la(10, 14, 9), la(10, 14, 10)),
                      event("late", la(10, 13, 23), la(10, 14, 1))]
        let week = CalendarPeriod.containing(la(10, 13), kind: .week, calendar: laCalendar)
        let grid = CalendarTimeGrid(days: week.days, events: events, timeZone: losAngeles, now: la(10, 12, 11))
        func block(_ id: String, day: Int) -> CalendarTimeGrid.Block? {
            grid.blocks.first { $0.event.id == id && $0.dayIndex == day }
        }
        #expect(block("a", day: 2)?.column == 0 && block("a", day: 2)?.columns == 2)
        #expect(block("b", day: 2)?.column == 1 && block("b", day: 2)?.columns == 2)
        #expect(block("c", day: 2)?.columns == 1, "touching is not overlapping")
        #expect(block("d", day: 3)?.columns == 1 && block("d", day: 2) == nil)
        #expect(block("late", day: 2)?.endsAfter == true && abs((block("late", day: 2)?.top ?? 0) - 23.0 / 24) < 0.0001)
        #expect(block("late", day: 3)?.startsBefore == true && block("late", day: 3)?.top == 0)
        #expect(Set(grid.blocks.map(\.id)).count == grid.blocks.count, "each column's block has its own id")
    }

    @Test func allDayEventsAreBarsOverTheirDaysInLanes() {
        let events = [event("offsite", la(10, 12), la(10, 15), allDay: true), event("holiday", la(10, 13), la(10, 14), allDay: true),
                      event("conference", la(10, 16, 9), la(10, 17, 10)), event("standup", la(10, 13, 9), la(10, 13, 9, 15))]
        let week = CalendarPeriod.containing(la(10, 13), kind: .week, calendar: laCalendar)
        let grid = CalendarTimeGrid(days: week.days, events: events, timeZone: losAngeles, now: la(10, 12, 11))
        let bars = Dictionary(uniqueKeysWithValues: grid.allDay.map { ($0.event.id, $0) })
        #expect(bars["offsite"]?.firstDay == 1 && bars["offsite"]?.lastDay == 3 && bars["offsite"]?.lane == 0)
        #expect(bars["holiday"]?.firstDay == 2 && bars["holiday"]?.lane == 1)
        #expect(bars["conference"]?.firstDay == 5 && bars["conference"]?.lastDay == 6 && bars["conference"]?.lane == 0,
                "a timed event of a day or more is a bar; lane 0 is free again after Tuesday")
        #expect(grid.allDayLanes == 2)
        #expect(grid.blocks.map(\.event.id) == ["standup"])
        let standup = grid.blocks[0]
        #expect(abs(standup.height - 15.0 / 1_440) < 0.0001, "a quarter hour")
    }

    @Test func theCurrentTimeShowsOnTodayOnlyAndTheGridOpensNearIt() {
        let week = CalendarPeriod.containing(la(10, 12), kind: .week, calendar: laCalendar)
        let thisWeek = CalendarTimeGrid(days: week.days, events: [], timeZone: losAngeles, now: la(10, 12, 11))
        #expect(thisWeek.todayIndex == 1 && thisWeek.now?.dayIndex == 1)
        #expect(abs((thisWeek.now?.offset ?? 0) - 11.0 / 24) < 0.0001)
        #expect(abs(thisWeek.scrollTarget - 10.0 / 24) < 0.0001, "an hour above now")
        let next = week.moved(by: 1, calendar: laCalendar)
        let withEvent = CalendarTimeGrid(days: next.days, events: [event("x", la(10, 20, 14), la(10, 20, 15))],
                                         timeZone: losAngeles, now: la(10, 12, 11))
        #expect(withEvent.now == nil && withEvent.todayIndex == nil)
        #expect(abs(withEvent.scrollTarget - 13.5 / 24) < 0.0001, "half an hour above the first event")
        let empty = CalendarTimeGrid(days: next.days, events: [], timeZone: losAngeles, now: la(10, 12, 11))
        #expect(abs(empty.scrollTarget - 8.0 / 24) < 0.0001)
    }

    @Test func onlyAMaybeAnswerIsOutlined() {
        func block(_ response: CalendarResponse?, location: String? = nil, attendees: [EmailAddress] = [],
                   organizerIsMe: Bool? = nil) -> CalendarTimeGrid.Block? {
            let item = event("b", la(10, 13, 9), la(10, 13, 10), attendees: attendees, organizerIsMe: organizerIsMe,
                             location: location, response: response)
            return CalendarTimeGrid(days: [la(10, 13)], events: [item], timeZone: losAngeles, now: la(10, 12, 11)).blocks.first
        }
        #expect(block(.accepted, location: "Corner cafe", attendees: [sam])?.isTentative == false,
                "a place or an outside guest does not outline an accepted event")
        #expect(block(nil, location: "Corner cafe", attendees: [sam], organizerIsMe: true)?.isTentative == false)
        #expect(block(.tentative)?.isTentative == true)
        #expect(block(.needsAction)?.isTentative == false)
        #expect(block(.declined)?.isDeclined == true)
    }

    @Test func theMonthGridHoldsWholeWeeksAndSaysHowManyMore() {
        let october = CalendarPeriod.containing(la(10, 20), kind: .month, calendar: laCalendar)
        #expect(october.month == la(10, 1) && october.start == la(9, 27) && october.end == la(11, 1))
        let busy = (0..<4).map { event("t\($0)", la(10, 14, 9 + $0), la(10, 14, 10 + $0)) }
            + [event("all", la(10, 14), la(10, 15), allDay: true)]
        let grid = CalendarMonthGrid(period: october, events: busy, timeZone: losAngeles, now: la(10, 12, 11))
        #expect(grid.weeks.count == 5 && grid.weeks.allSatisfy { $0.count == 7 })
        #expect(grid.weeks[0][0].day == la(9, 27) && !grid.weeks[0][0].isInMonth)
        let cell = grid.weeks.joined().first { $0.day == la(10, 14) }
        #expect(cell?.events.map(\.id) == ["all", "t0", "t1"] && cell?.more == 2, "all-day first, then by start")
        #expect(grid.weeks.joined().filter(\.isToday).map(\.day) == [la(10, 12)])
        let november = october.moved(by: 1, calendar: laCalendar)
        #expect(november.month == la(11, 1) && november.start == la(11, 1) && november.days.count == 35)
        let mini = CalendarMiniMonth(containing: la(10, 20), timeZone: losAngeles)
        #expect(mini.weeks.count == 6 && mini.weeks[0][0] == la(9, 27) && mini.month == la(10, 1))
    }

    @Test func dragsSnapToQuarterHoursAndKeepTheLength() {
        #expect(CalendarDragMath.time(atFraction: 9.1 / 24, on: la(10, 13), calendar: laCalendar) == la(10, 13, 9))
        #expect(CalendarDragMath.time(atFraction: 9.2 / 24, on: la(10, 13), calendar: laCalendar) == la(10, 13, 9, 15))
        #expect(CalendarDragMath.time(atFraction: 1, on: la(10, 13), calendar: laCalendar) == la(10, 14))
        let meeting = event("m", la(10, 13, 9), la(10, 13, 10))
        let moved = CalendarDragMath.moved(meeting, to: la(10, 15, 14))
        #expect(moved.start == la(10, 15, 14) && moved.end == la(10, 15, 15))
        let resized = CalendarDragMath.resized(meeting, to: la(10, 13, 9, 5))
        #expect(resized.end == la(10, 13, 9, 15), "never shorter than a quarter hour")
        let click = CalendarDragMath.slot(from: la(10, 13, 10), to: la(10, 13, 10))
        #expect(click.start == la(10, 13, 10) && click.end == la(10, 13, 10, 30), "a click is half an hour")
        let upward = CalendarDragMath.slot(from: la(10, 13, 11), to: la(10, 13, 10))
        #expect(upward.start == la(10, 13, 10) && upward.end == la(10, 13, 11))
    }

    @Test func theRefreshScheduleReadsEveryMinuteAndOnFocusAfterAPause() {
        var schedule = CalendarRefreshSchedule()
        #expect(schedule.isDue(now: la(10, 12, 11)) && schedule.refreshesOnFocus(now: la(10, 12, 11)), "never read")
        schedule.lastRead = la(10, 12, 11)
        let base = la(10, 12, 11)
        #expect(!schedule.isDue(now: base.addingTimeInterval(59)) && schedule.isDue(now: base.addingTimeInterval(60)))
        #expect(!schedule.refreshesOnFocus(now: base.addingTimeInterval(9)))
        #expect(schedule.refreshesOnFocus(now: base.addingTimeInterval(10)))
        #expect(schedule.isDue(now: base.addingTimeInterval(-5)), "a clock that went back reads again")
    }
}

@MainActor
@Suite struct CalendarWindowModelTests {
    @Test func openingShowsTheWeekOfEveryConnectedCalendarTaggedWithItsAccount() async throws {
        let f = CalendarWindowFixture(work: [event("w1", la(10, 13, 9), la(10, 13, 10))],
                                      home: [event("h1", la(10, 13, 9, 30), la(10, 13, 10, 30))])
        let model = f.window()
        await model.open(source: .keyboard)
        #expect(model.isOpen && model.kind == .week && model.period.start == la(10, 11))
        #expect(model.sources.map(\.key) == [f.workEmail, f.homeEmail])
        #expect(model.sources.allSatisfy { $0.isVisible })
        #expect(model.events.map(\.id) == ["w1", "h1"])
        #expect(model.events.map(\.account) == [f.workEmail, f.homeEmail], "the account chip and colour")
        #expect(model.progress == nil && model.state == .loaded && model.note == nil)
        #expect(model.timeGrid.blocks.map(\.columns) == [2, 2], "two calendars' overlapping events side by side")
        #expect(model.sources.map(\.colorIndex) == [CalendarWindowModel.colorOrder[0], CalendarWindowModel.colorOrder[1]])
        #expect(model.timeGrid.blocks.map(\.colorIndex) == model.sources.map(\.colorIndex))
        #expect(f.work.readCalls == 1 && f.home.readCalls == 1)
        #expect(model.title == la(10, 14).formatted(Date.FormatStyle(timeZone: losAngeles).month(.wide).year()))
        await model.move(by: 1)
        await model.move(by: -1)
        #expect(f.work.readCalls == 1 && f.home.readCalls == 1, "both weeks come from the cache")
        #expect(f.work.windowCalls == 1 && f.work.changeCalls == 0)
    }

    @Test func theFirstClickShowsEachTipOnceAndTheKeyCountsAsLearnt() async throws {
        let f = CalendarWindowFixture()
        let model = f.window()
        await model.open(source: .toolbar)
        await model.close(source: .toolbar)
        await model.open(source: .palette)
        await model.close(source: .menu)
        let messages = f.env.notices.toasts.map(\.message)
        #expect(messages.filter { $0 == "Next time, hit 2 to go to Calendar instantly!" }.count == 1)
        #expect(messages.filter { $0 == "Next time, hit 1 to go back to your mail." }.count == 1)
        #expect(Set(try await f.env.settings?.get(AppSettings.calendarTipsShown) ?? []) == ["1", "2"])

        let keys = CalendarWindowFixture()
        let keyed = keys.window()
        await keyed.open(source: .keyboard)
        await keyed.close(source: .keyboard)
        await keyed.open(source: .toolbar)
        #expect(!keys.env.notices.toasts.contains { $0.message.hasPrefix("Next time") }, "using the key teaches it")
    }

    @Test func aCalendarTickedOffIsNotReadAndStaysOff() async throws {
        let f = CalendarWindowFixture(work: [event("w1", la(10, 13, 9), la(10, 13, 10))],
                                      home: [event("h1", la(10, 13, 9, 30), la(10, 13, 10, 30))])
        let model = f.window()
        await model.open()
        await model.setVisible(f.homeEmail, false)
        #expect(model.events.map(\.id) == ["w1"])
        #expect(model.sources.first { $0.key == f.homeEmail }?.isVisible == false)
        let homeReads = f.home.readCalls
        await model.move(by: 1)
        #expect(f.home.readCalls == homeReads, "a hidden calendar is not read")
        #expect(try await f.env.settings?.get(AppSettings.calendarHiddenCalendars) == [f.homeEmail])
        let again = CalendarWindowModel(environment: f.env, sidebar: try #require(f.env.calendarSidebar),
                                        timeZone: losAngeles, now: { la(10, 12, 11) })
        await again.open()
        #expect(again.hiddenKeys == [f.homeEmail] && again.events.map(\.id) == ["w1"])
        await again.setVisible(f.homeEmail, true)
        #expect(again.events.map(\.id) == ["w1", "h1"])
    }

    @Test func theMinuteTimerAndTheFocusReadAgainButNotTooOften() async {
        let f = CalendarWindowFixture()
        let clock = WindowClock(la(10, 12, 11))
        let model = f.window(clock: clock)
        await model.open()
        let reads = f.work.readCalls
        clock.now = clock.now.addingTimeInterval(5)
        await model.windowDidBecomeKey()
        #expect(f.work.readCalls == reads, "a focus change right after a read reads nothing")
        clock.now = clock.now.addingTimeInterval(10)
        await model.windowDidBecomeKey()
        #expect(f.work.readCalls == reads + 1)
        await model.tick()
        #expect(f.work.readCalls == reads + 1, "the minute is not up")
        clock.now = clock.now.addingTimeInterval(61)
        await model.tick()
        #expect(f.work.readCalls == reads + 2, "every minute, past the cache")
        await model.close()
        clock.now = clock.now.addingTimeInterval(120)
        await model.tick()
        await model.windowDidBecomeKey()
        #expect(f.work.readCalls == reads + 2, "a closed calendar reads nothing")
    }

    @Test func offlineShowsTheLastEventsWithACalmNote() async {
        let f = CalendarWindowFixture(work: [event("w1", la(10, 13, 9), la(10, 13, 10))],
                                      home: [event("h1", la(10, 14, 9), la(10, 14, 10))])
        let model = f.window()
        await model.open()
        #expect(model.events.count == 2)
        f.work.failure = "offline"
        f.home.failure = "offline"
        await model.refresh()
        #expect(model.events.map(\.id) == ["w1", "h1"] && model.state == .loaded)
        #expect(model.note?.hasPrefix("Offline: showing your calendar as of") == true)
        await model.move(by: 1)
        #expect(model.events.isEmpty && model.note?.hasPrefix("Offline:") == true, "next week is cached: no events, no failure")
        await model.move(by: 10)
        #expect(model.events.isEmpty && model.note?.hasPrefix("Couldn't read the calendar of") == true)
        if case .failed = model.state {} else { Issue.record("nothing read for that week: \(model.state)") }
        f.work.failure = nil
        f.home.failure = nil
        await model.refresh()
        #expect(model.note == nil && model.state == .loaded)
        #expect(f.env.notices.toasts.allSatisfy { $0.style != .error }, "a calendar failure is calm, never a mail error")
    }

    @Test func theEventCardContinuesFromTheEmailAndCancelReturnsToIt() async throws {
        let f = CalendarWindowFixture()
        let model = f.window()
        let sidebar = model.sidebar
        let thread = f.corpus.threads[0].row.id
        await sidebar.beginDraft(for: thread)
        sidebar.draft?.title = "Edited title"
        sidebar.draft?.start = la(10, 20, 15)
        sidebar.draft?.end = la(10, 20, 16)
        await model.open(source: .keyboard)
        #expect(model.showsPendingCard && sidebar.draft?.title == "Edited title", "the same card, edits intact")
        #expect(model.period.contains(la(10, 20, 15)), "on the event's week")
        #expect(model.pendingSlot == DateInterval(start: la(10, 20, 15), end: la(10, 20, 16)))
        #expect(!model.pendingIsFromCalendar)
        await model.newEvent(start: la(10, 21, 9), end: la(10, 21, 10))
        #expect(sidebar.draft?.title == "Edited title" && sidebar.draft?.start == la(10, 21, 9))
        #expect(f.env.pendingEvents.pending(for: .thread(thread))?.draft.start == la(10, 21, 9))
        model.openEvent(event("x", la(10, 21, 13), la(10, 21, 14)))
        #expect(!model.showsPendingCard && model.pendingSlot == nil)
        model.closeCard()
        #expect(model.showsPendingCard)
        await model.close(source: .keyboard)
        #expect(sidebar.draft?.title == "Edited title")
        await model.open(source: .keyboard)
        await model.cancelPending()
        #expect(!model.isOpen && sidebar.draft == nil)
        #expect(f.env.pendingEvents.returnRequest?.thread == thread, "back to the email")
        #expect(f.work.createCalls == 0)
    }

    @Test func anEventMadeInTheCalendarClosesOnCancelAndSaves() async throws {
        let f = CalendarWindowFixture()
        let model = f.window()
        let sidebar = model.sidebar
        await model.open()
        await model.newEvent(start: la(10, 14, 13), end: la(10, 14, 14))
        #expect(sidebar.draft?.title == "Meeting" && sidebar.draft?.start == la(10, 14, 13) && sidebar.draft?.end == la(10, 14, 14))
        #expect(model.pendingIsFromCalendar && model.showsPendingCard)
        #expect(!sidebar.isVisible, "the sidebar stays as it was")
        await model.cancelPending()
        #expect(model.isOpen && sidebar.draft == nil, "Cancel closes the card only")
        #expect(f.env.pendingEvents.returnRequest == nil && f.env.pendingEvents.events.isEmpty)

        await model.newEvent(start: la(10, 14, 13), end: la(10, 14, 14))
        sidebar.draft?.title = "Focus"
        #expect(await sidebar.createEvent())
        #expect(f.work.createCalls == 1, "on the active account's calendar")
        await eventually { model.events.contains { $0.title == "Focus" } }
        #expect(model.events.first { $0.title == "Focus" }?.account == f.workEmail)
    }

    @Test func draggingTheEventBeingPreparedMovesItToAnotherDayAndKeepsItsLength() async throws {
        let f = CalendarWindowFixture()
        let model = f.window()
        let sidebar = model.sidebar
        await model.open()
        await model.newEvent(start: la(10, 14, 13), end: la(10, 14, 14))
        sidebar.draft?.title = "Focus"
        let key = try #require(sidebar.draftKey)
        #expect(model.pendingPlacement?.dayIndex == 3)
        model.movePending(to: la(10, 15, 15))
        #expect(sidebar.draft?.start == la(10, 15, 15) && sidebar.draft?.end == la(10, 15, 16), "the same hour, a day later")
        #expect(sidebar.draft?.title == "Focus")
        #expect(model.pendingSlot == DateInterval(start: la(10, 15, 15), end: la(10, 15, 16)))
        #expect(model.pendingPlacement?.dayIndex == 4 && model.showsPendingCard, "the editor stays with the moved event")
        let saved = try #require(f.env.pendingEvents.pending(for: key))
        #expect(saved.draft.start == la(10, 15, 15) && saved.draft.end == la(10, 15, 16) && saved.draft.title == "Focus")
        #expect(f.work.createCalls == 0 && f.work.created.isEmpty, "moving the draft creates nothing")
    }

    @Test func theBottomEdgeOfTheEventBeingPreparedChangesOnlyItsEnd() async throws {
        let f = CalendarWindowFixture()
        let model = f.window()
        let sidebar = model.sidebar
        await model.open()
        await model.newEvent(start: la(10, 14, 13), end: la(10, 14, 14))
        let key = try #require(sidebar.draftKey)
        model.resizePending(to: la(10, 14, 15, 30))
        #expect(sidebar.draft?.start == la(10, 14, 13) && sidebar.draft?.end == la(10, 14, 15, 30))
        #expect(model.pendingSlot == DateInterval(start: la(10, 14, 13), end: la(10, 14, 15, 30)) && model.showsPendingCard)
        #expect(f.env.pendingEvents.pending(for: key)?.draft.end == la(10, 14, 15, 30))
        model.resizePending(to: la(10, 14, 12))
        #expect(sidebar.draft?.end == la(10, 14, 13, 15), "never shorter than a quarter hour")
        #expect(f.work.createCalls == 0)
    }

    @Test func meetFindsTheFirstFreeHalfHourWithThatPerson() async throws {
        let f = CalendarWindowFixture(work: [event("busy", la(10, 12, 11), la(10, 12, 12, 30))])
        let model = f.window()
        await model.open()
        #expect(await model.meet(with: "Sam") == "Type an email address.")
        #expect(model.sidebar.draft == nil)
        #expect(await model.meet(with: "Sam Rivera <sam@example.org>") == nil)
        #expect(model.sidebar.draft?.start == la(10, 12, 12, 30), "after now and the busy block")
        #expect(model.sidebar.draft?.attendees.map(\.email) == ["sam@example.org"])
        #expect(model.sidebar.draft?.sendUpdates == .all, "the person is invited by email")
    }

    @Test func draggingAnOwnEventMovesItAtOnceAndUndoPutsItBack() async throws {
        let own = event("own", la(10, 13, 9), la(10, 13, 10))
        let f = CalendarWindowFixture(work: [own])
        let model = f.window()
        await model.open()
        await model.moveEvent(try #require(model.events.first), to: la(10, 13, 14), end: la(10, 13, 15))
        #expect(f.work.calls.contains(.move(id: "own", start: la(10, 13, 14), end: la(10, 13, 15), sendUpdates: .none)))
        #expect(model.events.first?.start == la(10, 13, 14) && model.overlays.isEmpty)
        await f.env.undo?.undoLast()
        #expect(f.work.calls.last { if case .move = $0 { true } else { false } }
                == .move(id: "own", start: la(10, 13, 9), end: la(10, 13, 10), sendUpdates: .none))
        #expect(model.events.first?.start == la(10, 13, 9))
        let shown = try #require(model.events.first)
        let resized = CalendarDragMath.resized(shown, to: la(10, 13, 11))
        await model.moveEvent(shown, to: resized.start, end: resized.end)
        #expect(model.events.first?.end == la(10, 13, 11))
        #expect(f.env.notices.toasts.contains { $0.message.hasPrefix("Undone.") })
    }

    @Test func aMeetingWithAttendeesIsHeldAndUndoSendsNothing() async throws {
        let meeting = event("meet", la(10, 13, 9), la(10, 13, 10), attendees: [sam], organizerIsMe: true)
        let f = CalendarWindowFixture(work: [meeting])
        let model = f.window()
        model.sleep = { _ in try await Task.sleep(for: .seconds(3_600)) }
        await model.open()
        let shown = try #require(model.events.first)
        await model.moveEvent(shown, to: la(10, 13, 15), end: la(10, 13, 16))
        #expect(f.work.moveCalls == 0 && model.heldCount == 1, "nothing reaches the calendar inside the window")
        #expect(model.shownEvents.first?.start == la(10, 13, 15), "drawn at its new place at once")
        await f.env.undo?.undoLast()
        #expect(model.heldCount == 0 && f.work.moveCalls == 0)
        #expect(model.shownEvents.first?.start == la(10, 13, 9))

        let gate = TestGate()
        model.sleep = { _ in await gate.wait() }
        await model.moveEvent(shown, to: la(10, 13, 15), end: la(10, 13, 16))
        gate.release()
        await eventually { f.work.moveCalls == 1 }
        #expect(f.work.calls.contains(.move(id: "meet", start: la(10, 13, 15), end: la(10, 13, 16), sendUpdates: .all)),
                "Google emails the attendees")
        let theirs = event("theirs", la(10, 14, 9), la(10, 14, 10), attendees: [sam], organizerIsMe: false)
        await model.moveEvent(theirs, to: la(10, 14, 15), end: la(10, 14, 16))
        #expect(f.work.moveCalls == 1 && model.heldCount == 0)
    }

    @Test func answersAreHeldBehindUndo() async throws {
        let invite = event("inv", la(10, 15, 9), la(10, 15, 10), attendees: [sam, FakeCorpus.me], organizerIsMe: false,
                           response: .needsAction)
        let f = CalendarWindowFixture(work: [invite])
        let model = f.window()
        let gate = TestGate()
        model.sleep = { _ in await gate.wait() }
        await model.open()
        model.openEvent(try #require(model.events.first))
        #expect(model.card?.canRespond == true && model.card?.canMove == false, "an invitation: answer it, never move it")
        await model.respond(.accepted)
        #expect(model.card?.response == .accepted && model.shownEvents.first?.myResponse == .accepted)
        #expect(!f.work.calls.contains { if case .respond = $0 { true } else { false } }, "held: Google tells the organizer")
        gate.release()
        await eventually { f.work.calls.contains(.respond(id: "inv", response: .accepted, sendUpdates: .all)) }
        await eventually { model.events.first?.myResponse == .accepted }

        let noAnswers = CalendarWindowFixture(work: [invite], workAbilities: [])
        let plain = noAnswers.window()
        await plain.open()
        plain.openEvent(try #require(plain.events.first))
        #expect(plain.card?.canRespond == false, "a calendar that can't answer from Mail offers no buttons")
    }

    @Test func aRecurringEventAsksThisOrAllAndChangesOnlyThisOne() async throws {
        let weekly = event("weekly-1013", la(10, 13, 9), la(10, 13, 10), series: "weekly")
        let f = CalendarWindowFixture(work: [weekly])
        let model = f.window()
        await model.open()
        let shown = try #require(model.events.first)
        await model.moveEvent(shown, to: la(10, 13, 11), end: la(10, 13, 12))
        #expect(model.scopeQuestion?.eventID == "weekly-1013" && f.work.moveCalls == 0)
        await model.answerScope(.allEvents)
        #expect(model.scopeQuestion == nil && f.work.moveCalls == 0)
        #expect(f.env.notices.toasts.contains { $0.message.hasPrefix("Mail changes one event of a series") })
        await model.moveEvent(shown, to: la(10, 13, 11), end: la(10, 13, 12))
        await model.answerScope(.thisEvent)
        #expect(f.work.calls.contains(.move(id: "weekly-1013", start: la(10, 13, 11), end: la(10, 13, 12), sendUpdates: .none)))
        await model.moveEvent(try #require(model.events.first), to: la(10, 13, 15), end: la(10, 13, 16))
        await model.escape()
        #expect(model.scopeQuestion == nil && f.work.moveCalls == 1 && model.isOpen)
    }

    @Test func editsSaveAtOnceWithoutAttendeesAndUndoRestoresThem() async throws {
        let own = event("own", la(10, 13, 9), la(10, 13, 10))
        let f = CalendarWindowFixture(work: [own])
        let model = f.window()
        await model.open()
        model.openEvent(try #require(model.events.first))
        #expect(model.card?.canEditDetails == true && model.card?.canRemove == true && model.card?.canMove == true)
        model.card?.title = "Renamed"
        await model.saveCard()
        #expect(model.card == nil)
        #expect(f.work.calls.contains(.update(id: "own", changes: CalendarEventChanges(title: "Renamed"), sendUpdates: .none)))
        #expect(model.events.first?.title == "Renamed")
        await f.env.undo?.undoLast()
        #expect(f.work.calls.last { if case .update = $0 { true } else { false } }
                == .update(id: "own", changes: CalendarEventChanges(title: "Event own"), sendUpdates: .none))
        #expect(model.events.first?.title == "Event own")
    }

    @Test func deleteIsHeldAndUndoKeepsTheEvent() async throws {
        let own = event("own", la(10, 13, 9), la(10, 13, 10))
        let f = CalendarWindowFixture(work: [own])
        let model = f.window()
        model.sleep = { _ in try await Task.sleep(for: .seconds(3_600)) }
        await model.open()
        model.openEvent(try #require(model.events.first))
        await model.removeCardEvent()
        #expect(model.card == nil && model.shownEvents.isEmpty && model.heldCount == 1)
        await f.env.undo?.undoLast()
        #expect(model.shownEvents.map(\.id) == ["own"])
        #expect(!f.work.calls.contains { if case .remove = $0 { true } else { false } }, "nothing was removed")

        let google = CalendarWindowFixture(work: [own], workAbilities: [.respond])
        let limited = google.window()
        await limited.open()
        limited.openEvent(try #require(limited.events.first))
        #expect(limited.card?.canRemove == false && limited.card?.canEditDetails == false && limited.card?.canMove == true,
                "a calendar that only moves and answers (not the Google provider since the delete-event rule)")
        await limited.removeCardEvent()
        #expect(limited.card?.note != nil && limited.heldCount == 0)
    }

    @Test func theTrashButtonAsksFirstAndNothingIsHeldOrSentUntilConfirmed() async throws {
        let own = event("own", la(10, 13, 9), la(10, 13, 10), organizerIsMe: true)
        let f = CalendarWindowFixture(work: [own])
        let model = f.window()
        model.sleep = { _ in try await Task.sleep(for: .seconds(3_600)) }
        await model.open()
        model.openEvent(try #require(model.events.first))
        model.askToRemoveCardEvent()
        let question = try #require(model.removeQuestion)
        #expect(question.eventID == "own" && !question.emailsPeople && question.text.contains("Undo brings it back"))
        #expect(model.heldCount == 0 && model.shownEvents.map(\.id) == ["own"], "asking changes nothing")
        await model.escape()
        #expect(model.removeQuestion == nil && model.card != nil && model.heldCount == 0)
        model.askToRemoveCardEvent()
        await model.confirmRemove()
        #expect(model.removeQuestion == nil && model.card == nil && model.heldCount == 1 && model.shownEvents.isEmpty)
        #expect(!f.work.calls.contains { if case .remove = $0 { true } else { false } }, "still inside the Undo window")
        await f.env.undo?.undoLast()
        #expect(model.shownEvents.map(\.id) == ["own"])
    }

    @Test func aMeetingWithGuestsSaysGoogleEmailsThemAndCannotBeBroughtBack() async throws {
        let meeting = event("meet", la(10, 13, 9), la(10, 13, 10), attendees: [sam], organizerIsMe: true)
        let f = CalendarWindowFixture(work: [meeting])
        let model = f.window()
        let gate = TestGate()
        model.sleep = { _ in await gate.wait() }
        await model.open()
        model.openEvent(try #require(model.events.first))
        model.askToRemoveCardEvent()
        #expect(model.removeQuestion?.emailsPeople == true)
        #expect(model.removeQuestion?.text.contains("email the guests") == true)
        await model.confirmRemove()
        gate.release()
        await eventually { f.work.calls.contains(.remove(id: "meet", sendUpdates: .all)) }
        await eventually { model.heldCount == 0 }
        #expect(model.undoableCount == 0, "the guests were emailed: nothing to undo")
        #expect(f.work.created.isEmpty)
    }

    @Test func anEventNobodyWasInvitedToComesBackAsANewEventOnUndoAfterItWasDeleted() async throws {
        let own = event("own", la(10, 13, 9), la(10, 13, 10), organizerIsMe: true, location: "Room 4")
        let f = CalendarWindowFixture(work: [own])
        let model = f.window()
        let gate = TestGate()
        model.sleep = { _ in await gate.wait() }
        await model.open()
        model.openEvent(try #require(model.events.first))
        model.askToRemoveCardEvent()
        await model.confirmRemove()
        gate.release()
        await eventually { f.work.calls.contains(.remove(id: "own", sendUpdates: .none)) }
        await eventually { model.undoableCount == 1 }
        await f.env.undo?.undoLast()
        let made = try #require(f.work.created.first)
        #expect(made.title == "Event own" && made.start == la(10, 13, 9) && made.end == la(10, 13, 10))
        let draft = try #require(f.work.calls.compactMap { call -> CalendarEventDraft? in
            if case .create(let draft) = call { draft } else { nil }
        }.first)
        #expect(draft.attendees.isEmpty && draft.sendUpdates == .none && draft.location == "Room 4", "emails nobody")
        await eventually { model.shownEvents.contains { $0.title == "Event own" } }
    }

    @Test func nothingIsAskedOnACalendarThatCannotRemove() async throws {
        let own = event("own", la(10, 13, 9), la(10, 13, 10), organizerIsMe: true)
        let limited = CalendarWindowFixture(work: [own], workAbilities: [.respond])
        let model = limited.window()
        await model.open()
        model.openEvent(try #require(model.events.first))
        model.askToRemoveCardEvent()
        #expect(model.removeQuestion == nil && model.card?.note != nil)
    }

    @Test func theKeysOpenAndDriveTheCalendar() async throws {
        let f = CalendarWindowFixture()
        let router = f.env.router
        router.start()
        await eventually { router.active != nil }
        let model = f.window()
        #expect(await f.run(.calendarOpen))
        await eventually { model.isOpen }
        #expect(model.kind == .week, "2 is Week")
        #expect(router.actionContext().scope == .calendar)
        #expect(f.env.actions.availability(.markDone, host: router) == .hidden, "no mail keys under the calendar")
        #expect(await f.run(.calendarShowMonth))
        await eventually { model.kind == .month }
        #expect(await f.run(.calendarNextPeriod))
        await eventually { model.period.month == la(11, 1) }
        #expect(await f.run(.calendarShowToday))
        await eventually { model.period.month == la(10, 1) }
        #expect(await f.run(.calendarShowDay))
        await eventually { model.kind == .day }
        #expect(await f.run(.calendarCycleView))
        await eventually { model.kind == .week }
        #expect(await f.run(.calendarCycleView))
        await eventually { !model.isOpen }
        #expect(model.sidebar.isVisible, "0 ends on the mail with the sidebar")
        #expect(router.actionContext().scope != .calendar)
        #expect(await f.run(.calendarToggleSidebar, source: .keyboard))
        await eventually { model.isOpen && model.kind == .day }
        #expect(await f.run(.calendarBackToMail))
        await eventually { !model.isOpen }
        #expect(await f.run(.calendarToggleSidebar, source: .menu))
        #expect(!model.sidebar.isVisible && !model.isOpen)
    }

    @Test func searchAndTheGoKeysShowTheMailInsteadOfChangingItUnderTheCalendar() async throws {
        let f = CalendarWindowFixture()
        let router = f.env.router
        let search = f.env.overlays.search
        router.start()
        await eventually { router.active?.list?.state == .loaded }
        let model = f.window()

        #expect(await f.run(.calendarOpen))
        await eventually { model.isOpen }
        #expect(await f.run(.search))
        #expect(!model.isOpen, "`/` closes the Calendar")
        #expect(search.isOpen && router.active?.searchOpen == true, "and the search opens over the mail")
        #expect(router.actionContext().scope != .calendar)
        search.escape()

        #expect(await f.run(.calendarOpen))
        await eventually { model.isOpen }
        #expect(await f.run(.goStarred))
        #expect(!model.isOpen && router.location == .system(.starred), "`G S` shows Starred")

        #expect(await f.run(.calendarOpen))
        await eventually { model.isOpen }
        #expect(await f.run(.goInbox, source: .palette))
        #expect(!model.isOpen && router.active?.isOnTab == true, "the palette's Go to Inbox too")

        #expect(await f.run(.calendarOpen))
        await eventually { model.isOpen }
        #expect(await f.run(.calendarShowMonth))
        #expect(await f.run(.calendarNextPeriod))
        #expect(model.isOpen && model.kind == .month, "the Calendar's own keys keep it open")
        #expect(!CalendarWindowActions.showsMail(try #require(ActionCatalog.descriptor(.calendarShowMonth))))
        #expect(!CalendarWindowActions.showsMail(try #require(ActionCatalog.descriptor(.goSnippets))))
        #expect(CalendarWindowActions.showsMail(try #require(ActionCatalog.descriptor(.switchToAccount(2)))))
    }

    @Test func openingAConversationOrALocationThroughTheRouterClosesTheCalendar() async throws {
        let f = CalendarWindowFixture()
        let router = f.env.router
        router.start()
        await eventually { router.active?.list?.state == .loaded }
        let model = f.window()

        #expect(await f.run(.calendarOpen))
        await eventually { model.isOpen }
        router.go(to: .system(.starred))
        #expect(!model.isOpen && router.location == .system(.starred))

        #expect(await f.run(.calendarOpen))
        await eventually { model.isOpen }
        let key = ThreadKey(account: try #require(router.active?.id), rowID: 1, gmailThreadID: GmailThreadID("t1"))
        router.open(key)
        #expect(!model.isOpen)
    }

    @Test func theCalendarKeysAreItsOwnAndTakeNoMenuKeyEquivalent() throws {
        let open = try #require(ActionCatalog.descriptor(.calendarOpen))
        #expect(open.defaultBindings.map(\.chords) == [KeyBinding.key("2").chords])
        #expect(open.scopes(of: open.defaultBindings[0]) == [.list, .reader])
        #expect(open.appearsInMenu && open.menuKeyEquivalent == nil && open.category == .view && !open.changesMail)
        let inCalendar: [(ActionID, [String])] = [
            (.calendarShowToday, ["t"]), (.calendarPreviousPeriod, ["-", "k"]), (.calendarNextPeriod, ["=", "j"]),
            (.calendarShowDay, ["d"]), (.calendarShowWeek, ["w", "2"]), (.calendarShowMonth, ["m"]),
            (.calendarNewEvent, ["n", "b"]), (.calendarCycleView, ["0"]), (.calendarBackToMail, ["1"]),
        ]
        for (id, keys) in inCalendar {
            let descriptor = try #require(ActionCatalog.descriptor(id))
            #expect(descriptor.defaultBindings.map(\.chords) == keys.map { KeyBinding.key($0).chords }, "\(id)")
            for binding in descriptor.defaultBindings { #expect(descriptor.scopes(of: binding) == [.calendar], "\(id)") }
            #expect(!descriptor.changesMail && descriptor.module == .calendar && !descriptor.allowsKeyRepeat)
        }
        let close = try #require(ActionCatalog.descriptor(.calendarClose))
        #expect(close.defaultBindings == [.named(.escape)] && close.scopes == [.calendar])
        #expect(ShortcutLine.placeName(of: [.calendar]) == "Calendar")
        #expect(ActionCatalog.descriptor(.calendarToday)?.defaultBindings.isEmpty == true, "the palette's entry stays key-less")
    }
}


@MainActor
private final class StoreChanges {
    var all: [CalendarEventStoreChange] = []
    var ids: Set<String> { all.reduce(into: []) { $0.formUnion($1.changedIDs) } }
}

@MainActor
@Suite struct CalendarWindowInstantTests {
    @Test func aCoveredPeriodIsDrawnFromTheCacheWithoutAnyRead() async {
        let f = CalendarWindowFixture(work: [event("w1", la(10, 13, 9), la(10, 13, 10)),
                                             event("w2", la(10, 20, 9), la(10, 20, 10))])
        let model = f.window()
        await model.open()
        #expect(model.events.map(\.id) == ["w1"] && f.work.readCalls == 1)
        f.work.failure = "offline"
        await model.move(by: 1)
        #expect(model.events.map(\.id) == ["w2"] && model.state == .loaded && model.note == nil)
        await model.goToToday()
        #expect(model.events.map(\.id) == ["w1"])
        await model.setKind(.threeDays)
        #expect(model.events.map(\.id) == ["w1"])
        await model.setKind(.day)
        await model.show(day: la(10, 13))
        #expect(model.events.map(\.id) == ["w1"])
        #expect(f.work.readCalls == 1 && f.home.readCalls == 1, "one window read each covered all of it")
    }

    @Test func aPeriodOutsideWhatIsCoveredReadsOnceAndTheFarWeeksStayCached() async {
        let f = CalendarWindowFixture(work: [event("far", la(12, 23, 9), la(12, 23, 10))])
        let model = f.window()
        await model.open()
        #expect(f.work.windowCalls == 1)
        await model.move(by: 10)
        #expect(model.events.map(\.id) == ["far"] && f.work.windowCalls == 2)
        await model.move(by: -10)
        await model.move(by: 10)
        #expect(f.work.windowCalls == 2, "both are covered now")
    }

    @Test func nearAnEdgeTheNextMonthIsReadInTheBackground() async {
        let f = CalendarWindowFixture(work: [event("later", la(12, 8, 9), la(12, 8, 10))])
        let model = f.window()
        await model.open()
        #expect(f.work.windowCalls == 1)
        await model.move(by: 5)
        await eventually { f.work.windowCalls == 2 }
        await eventually { f.env.calendarEvents.covers(f.workKey, from: la(12, 1), to: la(12, 8)) }
        await model.move(by: 3)
        #expect(f.work.windowCalls == 2 && model.events.map(\.id) == ["later"], "already prefetched")
    }

    @Test func aRefreshReplacesOnlyTheEventsThatChanged() async {
        let f = CalendarWindowFixture(work: [event("w1", la(10, 13, 9), la(10, 13, 10)),
                                             event("w2", la(10, 14, 9), la(10, 14, 10))])
        let model = f.window()
        await model.open()
        let before = model.events
        let seen = StoreChanges()
        f.env.calendarEvents.observe { seen.all.append($0) }
        await model.refresh()
        #expect(seen.ids.isEmpty && model.events == before, "nothing changed: nothing is told")
        f.work.update(CalendarEvent(id: "w1", title: "Moved by someone", start: la(10, 13, 11), end: la(10, 13, 12)))
        f.work.add(event("w3", la(10, 15, 9), la(10, 15, 10)))
        await model.refresh()
        #expect(seen.ids == ["w1", "w3"], "only these were touched")
        #expect(model.events.map(\.id) == ["w1", "w2", "w3"])
        #expect(model.events.first { $0.id == "w2" } == before.first { $0.id == "w2" }, "the rest is as it was")
        #expect(model.events.first { $0.id == "w1" }?.title == "Moved by someone")
        #expect(f.work.changeCalls == 2 && f.work.windowCalls == 1, "change reads, not window reads")
        f.work.remove(id: "w2")
        await model.refresh()
        #expect(seen.ids.contains("w2") && model.events.map(\.id) == ["w1", "w3"])
    }

    @Test func declinedEventsAreKeptAndDrawnDeclinedButNeverBlockTime() async {
        let f = CalendarWindowFixture(work: [event("kept", la(10, 13, 9), la(10, 13, 10)),
                                             event("no", la(10, 13, 11), la(10, 13, 12), attendees: [sam], organizerIsMe: false)])
        f.work.decline(id: "no")
        let model = f.window()
        await model.open()
        #expect(model.events.map(\.id) == ["kept", "no"])
        #expect(model.events.last?.myResponse == .declined, "the grid strikes it through")
        let store = f.env.calendarEvents
        #expect(store.record(f.workKey, id: "no")?.declinedByMe == true)
        #expect(store.events(f.workKey, from: la(10, 13), to: la(10, 14))?.map(\.id) == ["kept"], "the sidebar never sees it")
        #expect(store.busy(f.workKey, from: la(10, 13), to: la(10, 14))?.count == 1)
    }

    @Test func aMoveAndItsUndoUpdateTheCacheAtOnce() async throws {
        let f = CalendarWindowFixture(work: [event("own", la(10, 13, 9), la(10, 13, 10), location: "Room 4")])
        let model = f.window()
        await model.open()
        let store = f.env.calendarEvents
        await model.moveEvent(try #require(model.events.first), to: la(10, 13, 14), end: la(10, 13, 15))
        #expect(store.record(f.workKey, id: "own")?.event.start == la(10, 13, 14))
        #expect(store.record(f.workKey, id: "own")?.event.location == "Room 4", "the rest of the event is kept")
        #expect(f.work.windowCalls == 1, "reconciled by a change read, not a window read")
        await f.env.undo?.undoLast()
        #expect(store.record(f.workKey, id: "own")?.event.start == la(10, 13, 9))
        #expect(model.events.first?.start == la(10, 13, 9))
    }

    @Test func editsAnswersAndRemovalsGoThroughTheCache() async throws {
        let own = event("own", la(10, 13, 9), la(10, 13, 10), location: "Room 4")
        let invite = event("inv", la(10, 15, 9), la(10, 15, 10), attendees: [sam, FakeCorpus.me], organizerIsMe: false,
                           response: .needsAction)
        let f = CalendarWindowFixture(work: [own, invite])
        let model = f.window()
        let gate = TestGate()
        await model.open()
        let store = f.env.calendarEvents
        model.openEvent(try #require(model.events.first { $0.id == "own" }))
        model.card?.title = "Renamed"
        await model.saveCard()
        #expect(store.record(f.workKey, id: "own")?.event.title == "Renamed")
        #expect(store.record(f.workKey, id: "own")?.event.location == "Room 4")
        model.sleep = { _ in await gate.wait() }
        model.openEvent(try #require(model.events.first { $0.id == "inv" }))
        await model.respond(.tentative)
        #expect(store.record(f.workKey, id: "inv")?.event.myResponse == .needsAction, "held: nothing has gone out")
        gate.release()
        await eventually { store.record(f.workKey, id: "inv")?.event.myResponse == .tentative }
        await eventually { model.events.first { $0.id == "inv" }?.myResponse == .tentative }
        let again = TestGate()
        model.sleep = { _ in await again.wait() }
        model.openEvent(try #require(model.events.first { $0.id == "own" }))
        await model.removeCardEvent()
        #expect(store.record(f.workKey, id: "own") != nil && model.shownEvents.map(\.id) == ["inv"])
        again.release()
        await eventually { store.record(f.workKey, id: "own") == nil }
        await eventually { model.events.map(\.id) == ["inv"] }
    }

    @Test func theSavedEventsShowAtOnceWithTheirDetailsEvenWhenTheCalendarCannotBeRead() async throws {
        let f0 = CalendarWindowFixture()
        let key = f0.workKey
        let saved = CalendarEventRecord(event: event("saved", la(10, 13, 9), la(10, 13, 10), attendees: [sam],
                                                     location: "Room 4", response: .tentative, series: "weekly"),
                                        etag: "v3", recurringEventID: "weekly")
        let cache = InMemoryCalendarCache(entries: [CalendarCacheEntry(key: key, records: [saved], ranges: [
            CalendarCoveredRange(start: la(9, 28), end: la(11, 26), fetchedAt: la(10, 12, 8))], syncToken: "fake-0")])
        let f = CalendarWindowFixture(cache: cache)
        f.work.failure = "offline"
        f.home.failure = "offline"
        let model = f.window()
        await model.open()
        let shown = try #require(model.events.first)
        #expect(shown.id == "saved" && shown.location == "Room 4" && shown.myResponse == .tentative
                && shown.recurringEventID == "weekly")
        #expect(model.state == .loaded && model.note?.hasPrefix("Offline: showing your calendar as of") == true)
    }

    @Test func theKeptEventsKeepTheirDetailsForAllDayEventsToo() {
        let all = CalendarEvent(id: "day", title: "Offsite", start: la(10, 13), end: la(10, 14), isAllDay: true,
                                location: "Lisbon", notes: "Bring a charger", myResponse: .accepted, recurringEventID: "yearly")
        let kept = CalendarEventRecord(event: all, readIn: losAngeles).materialized(in: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(kept.event.location == "Lisbon" && kept.event.notes == "Bring a charger")
        #expect(kept.event.myResponse == .accepted && kept.event.recurringEventID == "yearly")
    }
}

@Suite struct CalendarDragStateTests {
    @Test func snapsToQuarterHoursAndRoundsToTheNearest() {
        #expect(CalendarDragState.snapped(5, hourHeight: 44) == 0)
        #expect(CalendarDragState.snapped(6, hourHeight: 44) == 11)
        #expect(CalendarDragState.snapped(-17, hourHeight: 44) == -22)
        #expect(CalendarDragState.quarters(23, hourHeight: 44) == 2)
    }

    @Test func aDragOnlyChangesItsOwnStateAndCommitsOnce() {
        var drag = CalendarDragState(kind: .move)
        for step in 1...50 { drag.update(translation: CGSize(width: 0, height: CGFloat(step))) }
        #expect(drag.updates == 50 && drag.isActive, "50 pointer moves, nothing proposed yet")
        let first = drag.end(translation: CGSize(width: 130, height: 23), hourHeight: 44, columnWidth: 100)
        #expect(first == .init(dayDelta: 1, quarterDelta: 2))
        #expect(drag.end(translation: CGSize(width: 130, height: 23), hourHeight: 44, columnWidth: 100) == nil, "single commit")
        drag.update(translation: CGSize(width: 9, height: 9))
        #expect(drag.updates == 50, "an ended drag ignores late updates")
    }

    @Test func aDragThatStaysInItsSlotOrIsCancelledProposesNothing() {
        var still = CalendarDragState(kind: .move)
        #expect(still.end(translation: CGSize(width: 10, height: 4), hourHeight: 44, columnWidth: 100) == nil)
        var cancelled = CalendarDragState(kind: .resize)
        cancelled.cancel()
        #expect(cancelled.end(translation: CGSize(width: 0, height: 60), hourHeight: 44, columnWidth: 100) == nil)
    }

    @Test func aMovedDraftKeepsItsLengthAndAResizedOneItsStart() {
        let moved = CalendarDragMath.moved(from: la(10, 14, 13), until: la(10, 14, 14), to: la(10, 15, 15))
        #expect(moved.start == la(10, 15, 15) && moved.end == la(10, 15, 16))
        let tiny = CalendarDragMath.moved(from: la(10, 14, 13), until: la(10, 14, 13), to: la(10, 14, 9))
        #expect(tiny.end == la(10, 14, 9, 15), "at least a quarter hour")
        let resized = CalendarDragMath.resized(from: la(10, 14, 13), to: la(10, 14, 12))
        #expect(resized.start == la(10, 14, 13) && resized.end == la(10, 14, 13, 15))
    }

    @Test func aResizeNeverChangesTheDay() {
        let p = CalendarDragState.proposal(translation: CGSize(width: 250, height: -22), kind: .resize, hourHeight: 44, columnWidth: 100)
        #expect(p == .init(dayDelta: 0, quarterDelta: -2))
    }
}


@MainActor
@Suite struct CalendarFullEditModelTests {
    private let fullAbilities: CalendarAbilities = [.respond, .editDetails, .remove, .editFull]

    private func patches(_ f: CalendarWindowFixture) -> [(patch: CalendarEventPatch, scope: CalendarRecurrenceScope, updates: CalendarSendUpdates)] {
        f.work.calls.compactMap { call in
            if case .patch(_, let patch, let scope, let updates) = call { return (patch, scope, updates) }
            return nil
        }
    }

    @Test func theCardsDateIsTheDayOfTheGridColumnTheEventSitsIn() async throws {
        let evening = event("eve", la(12, 4, 18), la(12, 4, 19), organizerIsMe: true)
        let f = CalendarWindowFixture(work: [evening], workAbilities: fullAbilities)
        let model = f.window(clock: WindowClock(la(12, 1, 9)))
        await model.open()
        let grid = model.timeGrid
        let block = try #require(grid.blocks.first { $0.event.id == "eve" })
        let column = grid.days[block.dayIndex]
        #expect(column == la(12, 4), "the event sits in the Friday December 4 column")
        model.openEvent(block.event)
        let form = try #require(model.card?.form)
        let us = Locale(identifier: "en_US")
        let shown = CalendarDateField.text(form.start, zone: model.cardTimeZone, locale: us)
        #expect(shown == "12/04/2026")
        #expect(shown == CalendarDateField.text(column, zone: model.cardTimeZone, locale: us),
                "the popover's date and the column name the same day")
    }

    @Test func aGuestlessEventSavesAtOnceThroughTheSharedFormAndUndoPutsItBack() async throws {
        let own = event("own", la(10, 13, 9), la(10, 13, 10), organizerIsMe: true)
        let f = CalendarWindowFixture(work: [own], workAbilities: fullAbilities)
        let model = f.window()
        await model.open()
        model.openEvent(try #require(model.events.first))
        #expect(model.card?.form != nil && model.card?.rights.access(.title) == .editable)
        model.card?.form?.title = "Planning"
        model.card?.form?.location = "Room 4"
        model.card?.form?.busy = .free
        await model.saveCard()
        let sent = try #require(patches(f).first)
        #expect(sent.patch.title == "Planning" && sent.patch.location == "Room 4" && sent.patch.busy == .free)
        #expect(sent.patch.time == nil && sent.updates == CalendarSendUpdates.none && sent.scope == .thisEvent)
        #expect(model.events.first?.title == "Planning" && model.card == nil)
        await f.env.undo?.undoLast()
        let back = try #require(patches(f).last)
        #expect(back.patch.title == "Event own" && back.patch.busy == .busy, "the original form diffed against what the calendar has")
    }

    @Test func anEventWithGuestsIsHeldAndTheChoiceDecidesWhoIsEmailed() async throws {
        let meeting = event("meet", la(10, 13, 9), la(10, 13, 10), attendees: [sam], organizerIsMe: true)
        let f = CalendarWindowFixture(work: [meeting], workAbilities: fullAbilities)
        let model = f.window()
        let gate = TestGate()
        model.sleep = { _ in await gate.wait() }
        await model.open()
        model.openEvent(try #require(model.events.first))
        model.card?.form?.setStart(la(10, 13, 15))
        let shown = try #require(model.card)
        #expect(model.asksSendUpdates(for: shown) && model.sendUpdates(for: shown) == .all, "time changed: guests preselected")
        model.card?.form?.title = "Retitled only"
        model.card?.form?.start = meeting.start
        model.card?.form?.end = meeting.end
        #expect(model.sendUpdates(for: try #require(model.card)) == CalendarSendUpdates.none, "title only: nobody preselected")
        model.chooseSendUpdates(.all)
        await model.saveCard()
        #expect(model.heldCount == 1 && patches(f).isEmpty, "nothing reaches the calendar inside the Undo window")
        gate.release()
        await eventually { !patches(f).isEmpty }
        #expect(patches(f).first?.updates == .all, "the explicit choice wins")
    }

    @Test func anAddressLeftInTheGuestFieldIsAddedWhenTheCardSaves() async throws {
        let own = event("own", la(10, 13, 9), la(10, 13, 10), organizerIsMe: true)
        let f = CalendarWindowFixture(work: [own], workAbilities: fullAbilities)
        let model = f.window()
        let gate = TestGate()
        model.sleep = { _ in await gate.wait() }
        await model.open()
        model.openEvent(try #require(model.events.first))
        model.card?.pendingGuest = "Sam"
        #expect(model.card?.hasChanges == true, "typed text is something Save acts on")
        await model.saveCard()
        #expect(model.card?.pendingGuestNote == CalendarPendingGuest.notAnAddress && model.card?.pendingGuest == "Sam")
        #expect(patches(f).isEmpty, "text that is not an address stops the save")
        model.card?.pendingGuest = "sam@example.org"
        #expect(model.card?.pendingGuestNote == nil)
        await model.saveCard()
        #expect(model.card == nil && model.heldCount == 1)
        gate.release()
        await eventually { !patches(f).isEmpty }
        let sent = try #require(patches(f).first)
        #expect(sent.patch.guestsAdded == ["sam@example.org"] && sent.updates == .all)
    }

    @Test func aRecurringEventAsksThisThisAndFollowingOrAllEvents() async throws {
        let weekly = event("w1", la(10, 13, 9), la(10, 13, 10), organizerIsMe: true, series: "series")
        let f = CalendarWindowFixture(work: [weekly], workAbilities: fullAbilities)
        let model = f.window()
        await model.open()
        model.openEvent(try #require(model.events.first))
        model.card?.form?.title = "Standup"
        await model.saveCard()
        #expect(model.scopeQuestion?.scopes == [.thisEvent, .thisAndFollowing, .allEvents] && patches(f).isEmpty)
        await model.answerRecurrenceScope(.thisAndFollowing)
        #expect(patches(f).first?.scope == .thisAndFollowing && model.scopeQuestion == nil)
    }

    @Test func aGuestsEventShowsEachFieldReadOnlyWithItsReasonAndRefusesAnEdit() async throws {
        let theirs = event("theirs", la(10, 14, 9), la(10, 14, 10), attendees: [sam, FakeCorpus.me], organizerIsMe: false,
                           response: .needsAction)
        let f = CalendarWindowFixture(work: [theirs], workAbilities: fullAbilities)
        let model = f.window()
        await model.open()
        model.openEvent(try #require(model.events.first))
        let rights = try #require(model.card?.rights)
        #expect(rights.access(.title).reason == "Someone else organizes this event: only they can change it.")
        #expect(rights.access(.busy) == .editable && rights.access(.reminders) == .editable)
        if case .declineInstead = rights.delete {} else { Issue.record("a guest declines instead of deleting") }
        model.card?.form?.title = "Mine now"
        await model.saveCard()
        #expect(model.card?.note == "Someone else organizes this event: only they can change it." && patches(f).isEmpty)
    }

    @Test func aDropOpensTheEditPaneAndNothingIsWrittenUntilAccept() async throws {
        let own = event("own", la(10, 13, 9), la(10, 13, 10), organizerIsMe: true)
        let f = CalendarWindowFixture(work: [own], workAbilities: fullAbilities)
        let model = f.window()
        model.confirmsMovesOverride = true
        await model.open()
        let shown = try #require(model.events.first)
        await model.moveEvent(shown, to: la(10, 14, 14), end: la(10, 14, 15))
        let pending = try #require(model.card?.pendingMove)
        #expect(pending.kind == .moved && model.card?.form?.start == la(10, 14, 14))
        #expect(f.work.moveCalls == 0 && patches(f).isEmpty && model.overlays.isEmpty, "no write, no overlay yet")
        model.card?.form?.setEnd(la(10, 14, 16))
        await model.acceptPendingMove()
        let sent = try #require(patches(f).first)
        #expect(sent.patch.time?.start == la(10, 14, 14) && sent.patch.time?.end == la(10, 14, 16))
        #expect(model.card == nil)
    }

    @Test func cancellingTheEditPaneSnapsTheEventBackAndWritesNothing() async throws {
        let own = event("own", la(10, 13, 9), la(10, 13, 10), organizerIsMe: true)
        let f = CalendarWindowFixture(work: [own], workAbilities: fullAbilities)
        let model = f.window()
        model.confirmsMovesOverride = true
        await model.open()
        await model.moveEvent(try #require(model.events.first), to: la(10, 14, 14), end: la(10, 14, 15))
        model.cancelPendingMove()
        #expect(model.card == nil && f.work.moveCalls == 0 && patches(f).isEmpty)
        #expect(model.shownEvents.first?.start == la(10, 13, 9))
    }

    @Test func whileTheEditPaneIsOpenTheGridDrawsTheEventAtItsProposedPlace() async throws {
        let own = event("own", la(10, 13, 9), la(10, 13, 10), organizerIsMe: true)
        let f = CalendarWindowFixture(work: [own], workAbilities: fullAbilities)
        let model = f.window()
        model.confirmsMovesOverride = true
        await model.open()
        await model.moveEvent(try #require(model.events.first), to: la(10, 14, 14), end: la(10, 14, 15))
        #expect(model.shownEvents.first?.start == la(10, 14, 14) && model.shownEvents.first?.end == la(10, 14, 15))
        #expect(model.overlays.isEmpty && f.work.moveCalls == 0 && patches(f).isEmpty, "drawn, not written")
        model.card?.form?.setEnd(la(10, 14, 16))
        #expect(model.shownEvents.first?.end == la(10, 14, 16), "a length changed in the pane is drawn too")
        model.cancelPendingMove()
        #expect(model.shownEvents.first?.start == la(10, 13, 9) && model.shownEvents.first?.end == la(10, 13, 10))
    }

    @Test func withTheSettingOffADropAppliesAtOnceWithUndo() async throws {
        let own = event("own", la(10, 13, 9), la(10, 13, 10), organizerIsMe: true)
        let f = CalendarWindowFixture(work: [own], workAbilities: fullAbilities)
        let model = f.window()
        await model.open()
        await model.moveEvent(try #require(model.events.first), to: la(10, 13, 14), end: la(10, 13, 15))
        #expect(model.card == nil && f.work.moveCalls == 1)
    }

    @Test func duplicateOpensANewEventCardWithTheSameDetails() async throws {
        let own = event("own", la(10, 13, 9), la(10, 13, 10), attendees: [sam], organizerIsMe: true, location: "Room 4")
        let f = CalendarWindowFixture(work: [own], workAbilities: fullAbilities)
        let model = f.window()
        await model.open()
        model.openEvent(try #require(model.events.first))
        await model.duplicateCardEvent()
        #expect(model.card == nil && model.sidebar.draft?.title == "Event own" && model.sidebar.draft?.location == "Room 4")
        #expect(model.sidebar.draft?.attendees == [sam] && f.work.created.isEmpty, "nothing is created until Save")
        #expect(model.sidebar.draft?.sendUpdates == .all, "the copy's guests are invited by email")
    }

    @Test func decliningStandsInForDeletingSomeoneElsesEvent() async throws {
        let theirs = event("theirs", la(10, 14, 9), la(10, 14, 10), attendees: [sam, FakeCorpus.me], organizerIsMe: false,
                           response: .needsAction)
        let f = CalendarWindowFixture(work: [theirs], workAbilities: fullAbilities)
        let model = f.window()
        let gate = TestGate()
        model.sleep = { _ in await gate.wait() }
        await model.open()
        model.openEvent(try #require(model.events.first))
        await model.declineInsteadOfDelete()
        gate.release()
        await eventually { f.work.calls.contains(.respond(id: "theirs", response: .declined, sendUpdates: .all)) }
        #expect(!f.work.calls.contains { if case .remove = $0 { true } else { false } }, "Mail never deletes what others organize")
    }
}
