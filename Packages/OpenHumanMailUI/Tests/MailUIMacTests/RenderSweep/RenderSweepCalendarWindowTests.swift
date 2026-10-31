import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI
@testable import MailUIMac

@MainActor
enum CalendarWindowSweep {
    static func environment(removalScopes: [CalendarRecurrenceScope] = CalendarRecurrenceScope.removalOptions,
                            longRemovalTitle: Bool = false, removesInvitations: Bool = false,
                            configure: ((FakeCalendar) -> Void)? = nil) -> (AppEnvironment, now: Date) {
        let corpus = FakeCorpus.small
        let accounts = corpus.accounts
        let calendar = CalendarDateMentions.calendar(.current)
        let week = CalendarPeriod.containing(Date(), kind: .week, calendar: calendar)
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: week.days[day]) ?? week.days[day]
        }
        let dana = EmailAddress(name: "Dana Ruiz", email: "dana@example.com")
        let sam = EmailAddress(name: "Sam Rivera", email: "sam@example.org")
        var work: [CalendarEvent] = (1...5).map { day in
            CalendarEvent(id: "standup-\(day)", title: longRemovalTitle
                ? "Weekly planning with the wider product, research, design, and engineering group across all teams"
                : "Team standup", start: at(day, 9, 30), end: at(day, 9, 45),
                          attendees: [dana], organizerIsMe: true, recurringEventID: "standup",
                          originalStartTime: .timed(at(day, 9, 30), timeZone: calendar.timeZone.identifier))
        }
        work += [
            CalendarEvent(id: "review", title: "Design review", start: at(2, 13), end: at(2, 14), attendees: [sam],
                          organizerIsMe: true),
            CalendarEvent(id: "sync", title: "Quarterly sync", start: at(2, 15), end: at(2, 15, 30),
                          attendees: [sam, FakeCorpus.me], organizerIsMe: false, location: nil, myResponse: .needsAction),
            CalendarEvent(id: "lunch", title: "Lunch with Priya", start: at(3, 12), end: at(3, 13), organizerIsMe: true,
                          location: "Corner cafe"),
            CalendarEvent(id: "planning", title: "Planning", start: at(4, 10), end: at(4, 11, 30), organizerIsMe: true),
            CalendarEvent(id: "book", title: "Book club", start: at(4, 17), end: at(4, 18), attendees: [dana],
                          organizerIsMe: false, myResponse: .declined),
            CalendarEvent(id: "offsite", title: "Company offsite", start: week.days[5], end: week.days[6], isAllDay: true),
            CalendarEvent(id: "conference", title: "Agentic Enterprise AI", start: week.days[3], end: week.days[5],
                          isAllDay: true),
            CalendarEvent(id: "oneone", title: "1:1 with Theo", start: at(1, 14), end: at(1, 14, 30), organizerIsMe: true,
                          recurringEventID: "weekly-1on1",
                          originalStartTime: .timed(at(1, 14), timeZone: calendar.timeZone.identifier)),
        ]
        if removesInvitations {
            work += (1...3).map { day in
                CalendarEvent(id: "vendor-\(day)", title: "Vendor check-in", start: at(day, 11), end: at(day, 11, 30),
                              attendees: [sam, FakeCorpus.me], organizerIsMe: false, myResponse: .needsAction,
                              recurringEventID: "vendor",
                              originalStartTime: .timed(at(day, 11), timeZone: calendar.timeZone.identifier))
            }
        }
        let home: [CalendarEvent] = [
            CalendarEvent(id: "call", title: "Customer call", start: at(4, 10, 30), end: at(4, 11)),
            CalendarEvent(id: "dentist", title: "Dentist", start: at(3, 16), end: at(3, 17), location: "Main St clinic"),
            CalendarEvent(id: "gym", title: "Gym", start: at(1, 7), end: at(1, 8)),
        ]
        let workCalendar = FakeCalendar(events: work, info: CalendarProviderInfo(name: "Google Calendar",
                                                                                 account: accounts[0].email),
                                        abilities: removesInvitations ? [.respond, .editDetails, .remove, .editFull, .removeInvite]
                                            : [.respond, .editDetails, .remove, .editFull], removalScopes: removalScopes)
        configure?(workCalendar)
        let homeCalendar = FakeCalendar(events: home, info: CalendarProviderInfo(name: "Google Calendar",
                                                                                 account: accounts[1].email))
        let connections = FakeCalendarConnections(providers: [accounts[0].email: workCalendar,
                                                              accounts[1].email: homeCalendar])
        let environment = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate),
                                              featureFlags: FeatureFlags(), calendar: workCalendar,
                                              calendarConnections: connections)
        return (environment, at(3, 11))
    }
}

extension RenderSweepTests {
    @Test(arguments: SweepTheme.builtIns)
    func calendarWindowScreens(_ theme: SweepTheme) async throws {
        let (environment, now) = CalendarWindowSweep.environment()
        let w = try await SweepWindow.make(environment, theme: theme)
        var didClose = false
        defer { if !didClose { w.close() } }
        let model = try #require(environment.calendarWindow)
        let sidebar = try #require(environment.calendarSidebar)
        model.now = { now }
        sidebar.now = { now }

        await model.open(.week, source: .keyboard)
        try await until { model.state == .loaded && model.events.count > 10 }
        try await sweepShoot(w.window, screen: "calendar-window-week-two-accounts", theme: theme)

        await model.setKind(.month)
        try await until { model.state == .loaded }
        try await sweepShoot(w.window, screen: "calendar-window-month", theme: theme)

        await model.setKind(.day)
        try await until { model.state == .loaded }
        try await sweepShoot(w.window, screen: "calendar-window-day", theme: theme)

        await model.setKind(.week)
        let invite = try #require(model.events.first { $0.canRespond })
        model.openEvent(invite)
        try await sweepShoot(w.window, screen: "calendar-window-event-card", theme: theme)
        model.closeCard()

        let review = try #require(model.events.first { $0.id == "review" })
        model.openEvent(review)
        try await sweepShoot(w.window, screen: "calendar-window-edit-form", theme: theme)
        model.closeCard()
        let planning = try #require(model.events.first { $0.id == "planning" })
        model.confirmsMovesOverride = true
        await model.moveEvent(planning, to: planning.start.addingTimeInterval(86_400 + 3_600),
                              end: planning.end.addingTimeInterval(86_400 + 3_600))
        try await sweepShoot(w.window, screen: "calendar-window-drag-pane", theme: theme)
        model.cancelPendingMove()
        model.confirmsMovesOverride = nil

        await model.close()
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        await sidebar.beginDraft(for: thread)
        sidebar.draft?.title = "Planning follow-up"
        await model.open(source: .keyboard)
        try await until { model.state == .loaded && model.showsPendingCard }
        try await sweepShoot(w.window, screen: "calendar-window-pending-card", theme: theme)
        sidebar.cancelDraft()
        await model.close()
        w.close()
        didClose = true
        try await calendarRemovalFixtures(theme)
        try await calendarInvitationRemovalFixtures(theme)
    }

    // Removing someone else's invitation: the single question, the repeating question with the organizer-only
    // future scope disabled, and the held removal with its Undo.
    private func calendarInvitationRemovalFixtures(_ theme: SweepTheme) async throws {
        let (environment, now) = CalendarWindowSweep.environment(removesInvitations: true)
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let model = try #require(environment.calendarWindow)
        model.now = { now }
        await model.open(.week, source: .keyboard)
        let single = try #require(model.events.first { $0.id == "sync" })
        model.openEvent(single)
        try await sweepShoot(w.window, screen: "calendar-window-invite-card", theme: theme)
        model.askToRemoveCardEvent()
        try await sweepShoot(w.window, screen: "calendar-window-remove-invite", theme: theme)
        await model.escape()
        let occurrence = try #require(model.events.first { $0.id == "vendor-2" })
        model.askToRemove(occurrence)
        try await sweepShoot(w.window, screen: "calendar-window-remove-invite-recurring", theme: theme)
        w.window.setContentSize(NSSize(width: 860, height: 620))
        try await sweepShoot(w.window, screen: "calendar-window-remove-invite-recurring-small", theme: theme)
        model.holdWindow = .seconds(3600)
        await model.confirmRemove(.thisEvent, questionID: try #require(model.removeQuestion).id)
        try await sweepShoot(w.window, screen: "calendar-window-remove-invite-held-undo", theme: theme)
        await environment.undo?.undoLast()
    }

    private func calendarRemovalFixtures(_ theme: SweepTheme) async throws {
        for unavailable in [false, true] {
            var fake: FakeCalendar?
            let (environment, now) = CalendarWindowSweep.environment(
                removalScopes: unavailable ? [.thisEvent] : CalendarRecurrenceScope.removalOptions,
                longRemovalTitle: true, configure: { fake = $0 })
            let w = try await SweepWindow.make(environment, theme: theme)
            defer { w.close() }
            let model = try #require(environment.calendarWindow)
            model.now = { now }
            await model.open(.week, source: .keyboard)
            let recurring = try #require(model.events.first { $0.id == "standup-3" })
            model.openEvent(recurring)
            model.askToRemoveCardEvent()
            try await sweepShoot(w.window, screen: unavailable ? "calendar-window-remove-recurring-unavailable"
                : "calendar-window-remove-recurring", theme: theme)
            if unavailable { continue }
            w.window.setContentSize(NSSize(width: 860, height: 620))
            try await sweepShoot(w.window, screen: "calendar-window-remove-recurring-long-small", theme: theme)
            let question = try #require(model.removeQuestion)
            fake?.failure = "This series has an earlier detached exception. Mail can't guarantee it survives shortening the series."
            model.holdWindow = .zero
            await model.confirmRemove(.thisAndFollowing, questionID: question.id)
            try await until { !model.hasQuitWork && model.card?.note != nil }
            try await sweepShoot(w.window, screen: "calendar-window-remove-error", theme: theme)
            fake?.failure = nil
            model.askToRemoveCardEvent()
            model.holdWindow = .seconds(3600)
            await model.confirmRemove(.allEvents, questionID: try #require(model.removeQuestion).id)
            try await sweepShoot(w.window, screen: "calendar-window-remove-held-undo", theme: theme)
            await environment.undo?.undoLast()
        }
    }
}
