import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import Testing
@testable import MailUI
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.selected(SweepTheme.allBuiltIns, slugs: "light,dark"))
    func selectMode(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment()
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let list = try #require(w.router.list)
        #expect(environment.actions.perform(.toggleContextSidebar, source: .menu, host: w.router))
        try await w.cursorAndHover(steps: 2, offset: 2)
        #expect(list.headerCheck == .hidden)
        try await sweepShoot(w.window, screen: "select-hover-and-cursor", theme: theme)

        #expect(await environment.actions.run(.toggleCheck, source: .keyboard, host: w.router))
        #expect(list.headerCheck == .some)
        try await sweepShoot(w.window, screen: "select-one-checked-shortcuts", theme: theme)

        list.checkAll()
        #expect(list.headerCheck == .all)
        try await sweepShoot(w.window, screen: "select-all-checked", theme: theme)

        list.clearChecks()
        list.setCursor(list.rows[4].id)
        list.checkFromHere()
        #expect(list.offersCheckBefore)
        try await sweepShoot(w.window, screen: "select-cmd-a-middle-toast", theme: theme)

        list.clearChecks()
        let rows = try #require(SelectAllShortcuts.tip())
        let tip = sweepStandaloneWindow(ShortcutTipView(tip: rows), store: theme.makeStore(),
                                        size: NSSize(width: 360, height: 90))
        defer { tip.close() }
        try await sweepShoot(tip, screen: "select-header-tip", theme: theme)
    }

    @Test(arguments: SweepTheme.selected(SweepTheme.allBuiltIns, slugs: "light,dark"))
    func selectBeforeHintStaysOffTheCalendar(_ theme: SweepTheme) async throws {
        let (environment, now) = CalendarWindowSweep.environment()
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let list = try #require(w.router.list)
        try #require(list.rows.count >= 3)
        list.setCursor(list.rows[1].id)
        list.checkFromHere()
        #expect(list.offersCheckBefore)
        #expect(CheckBeforeHint.shows(router: w.router) != nil, "the list offers the conversation above")

        let model = try #require(environment.calendarWindow)
        model.now = { now }
        environment.calendarSidebar?.now = { now }
        await model.open(.week, source: .keyboard)
        #expect(model.state == .loaded)
        #expect(CheckBeforeHint.shows(router: w.router) == nil, "the hint stays with the list behind the Calendar")
        try await sweepShoot(w.window, screen: "select-cmd-a-middle-calendar", theme: theme)
    }

    @Test(arguments: SweepTheme.selected(SweepTheme.allBuiltIns, slugs: "light,dark"))
    func recentOpensWithContactPane(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment()
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let list = try #require(w.router.list)
        for key in list.rows.prefix(4).map(\.id) { _ = try await w.open(key) }
        w.router.closeReader()
        #expect(w.router.recentOpens.entries.count == 4)
        #expect(environment.actions.perform(.toggleContextSidebar, source: .menu, host: w.router))
        try await sweepShoot(w.window, screen: "recent-opens-contact-pane", theme: theme)
    }

    @Test(arguments: SweepTheme.selected(SweepTheme.allBuiltIns + [SweepTheme.lightBlueAccent],
                                         slugs: "light,dark,system-light,system-dark,light-blue"))
    func selectModeCursorUnderACheckedRow(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment()
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let list = try #require(w.router.list)
        #expect(environment.actions.perform(.toggleContextSidebar, source: .menu, host: w.router))
        let rows = list.rows.map(\.id)
        try #require(rows.count >= 2)
        _ = list.toggleCheck(rows[0])
        list.setCursor(rows[1])
        #expect(list.isChecked(rows[0]) && !list.isChecked(rows[1]) && list.headerCheck == .some)
        try await sweepShoot(w.window, screen: "select-checked-above-cursor", theme: theme)
    }

    @Test(arguments: SweepTheme.selected(SweepTheme.allBuiltIns, slugs: "light,dark"))
    func selectAllTipInTheToolbar(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment()
        let w = try await SweepWindow.make(environment, theme: theme, selectAllTipPinned: true)
        defer { w.close() }
        let list = try #require(w.router.list)
        let first = try #require(list.rows.first?.id)
        _ = list.toggleCheck(first)
        #expect(list.headerCheck == .some)
        try await sweepShoot(w.window, screen: "select-header-tip-in-place", theme: theme)
    }

    @Test(arguments: SweepTheme.selected(SweepTheme.allBuiltIns, slugs: "light,dark"))
    func recentOpensAcrossTheWeek(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment()
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let list = try #require(w.router.list)
        try #require(list.rows.count >= 7)
        let calendar = Calendar.autoupdatingCurrent
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15, minute: 20)))
        func at(days: Int, hour: Int, minute: Int) throws -> Date {
            let day = try #require(calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)))
            return try #require(calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day))
        }
        let opens = try [at(days: 13, hour: 10, minute: 0), at(days: 5, hour: 8, minute: 15), at(days: 3, hour: 18, minute: 40),
                         at(days: 1, hour: 9, minute: 5), at(days: 1, hour: 17, minute: 45), at(days: 0, hour: 12, minute: 20)]
        for (row, date) in zip(list.rows.prefix(opens.count), opens) { w.router.recentOpens.record(row, at: date) }
        w.router.recentOpens.record(RecentOpens.Entry(
            id: list.rows[6].id, sender: "statements-and-billing-notifications@example-invoices.test",
            subject: "Your statement for the quarter ending in September is ready to review and download",
            openedAt: now.addingTimeInterval(-25 * 60)))
        w.router.recentOpens.now = { now }
        let kinds = RecentOpenGroup.groups(w.router.recentOpens.entries, now: now).map(\.kind)
        #expect(kinds == [.recent, .yesterday, .lastSevenDays, .earlier])
        #expect(environment.actions.perform(.toggleContextSidebar, source: .menu, host: w.router))
        try await sweepShoot(w.window, screen: "recent-opens-across-the-week", theme: theme)
    }
}

extension SweepTheme {
    static let lightBlueAccent = SweepTheme(name: "Light + Blue", slug: "light-blue",
                                            preferences: ThemePreferences(mode: .light, lightThemeID: BuiltinThemeID.light,
                                                                          accentID: "blue"))
}
