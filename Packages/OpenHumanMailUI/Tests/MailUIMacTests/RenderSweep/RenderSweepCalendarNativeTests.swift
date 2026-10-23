import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    // The event editor as a grouped form in a popover beside its event, and the view switch in the toolbar
    @Test(arguments: SweepTheme.lightAndDark)
    func calendarNativeEditorScreens(_ theme: SweepTheme) async throws {
        let (environment, now) = CalendarWindowSweep.environment()
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let model = try #require(environment.calendarWindow)
        let sidebar = try #require(environment.calendarSidebar)
        model.now = { now }
        sidebar.now = { now }
        await model.open(.week, source: .keyboard)
        try await until { model.state == .loaded && model.events.count > 10 }

        let calendar = CalendarDateMentions.calendar(model.timeZone)
        let free = try #require(calendar.date(bySettingHour: 15, minute: 0, second: 0, of: model.period.days[1]))
        await model.newEvent(start: free, end: free.addingTimeInterval(3_600))
        try await until { model.showsPendingCard }
        try await sweepShoot(w.window, screen: "calendar-native-new-event", theme: theme)
        await model.cancelPending()
        w.window.makeFirstResponder(nil)

        func shoot(_ id: String, _ screen: String, change: (inout CalendarEventForm) -> Void) async throws {
            try await shootCalendarNativeEditor(model, w.window, event: id, screen: screen, theme: theme, change: change)
        }
        try await shoot("review", "calendar-native-existing-event") { _ in }
        try await shoot("offsite", "calendar-native-all-day") { _ in }
        try await shoot("oneone", "calendar-native-recurring") { form in
            form.recurrence = CalendarRepeat.rules(.weekly)
        }
        try await shoot("review", "calendar-native-guests-meet") { form in
            form.guests = [
                CalendarGuest(email: "sam@example.org", name: "Sam Rivera", response: .accepted),
                CalendarGuest(email: "dana@example.com", name: "Dana Ruiz", isOptional: true, response: .tentative),
                CalendarGuest(email: "theo@example.net", response: .declined),
                CalendarGuest(email: "priya@example.com", name: "Priya Shah", response: .needsAction),
            ]
            form.wantsMeet = true
            form.location = "Room 4B"
        }
        try await shoot("planning", "calendar-native-long-title") { form in
            form.title = "Quarterly planning with the design, research and engineering leads and the partner team"
        }
        await model.close()
    }

    private func shootCalendarNativeEditor(_ model: CalendarWindowModel, _ window: NSWindow, event id: String,
                                           screen: String, theme: SweepTheme,
                                           change: (inout CalendarEventForm) -> Void) async throws {
        let event = try #require(model.events.first { $0.id == id })
        model.openEvent(event)
        try await until { model.card?.form != nil }
        if var form = model.card?.form {
            change(&form)
            model.card?.form = form
        }
        try await sweepShoot(window, screen: screen, theme: theme)
        window.makeFirstResponder(nil)
        model.closeCard()
    }
}
