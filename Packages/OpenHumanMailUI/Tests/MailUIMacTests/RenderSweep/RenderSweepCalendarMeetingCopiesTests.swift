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

// One meeting held by two connected accounts: the organizer's copy on the first, an invited copy on the second
@MainActor
enum CalendarMeetingCopiesSweep {
    static func environment() -> (AppEnvironment, now: Date) {
        let corpus = FakeCorpus.small
        let accounts = corpus.accounts
        let calendar = CalendarDateMentions.calendar(.current)
        let week = CalendarPeriod.containing(Date(), kind: .week, calendar: calendar)
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: week.days[day]) ?? week.days[day]
        }
        let work = EmailAddress(name: FakeCorpus.me.name, email: accounts[0].email.lowercased())
        let home = EmailAddress(name: FakeCorpus.me.name, email: accounts[1].email.lowercased())
        let dana = EmailAddress(name: "Dana Ruiz", email: "dana@example.com")
        let sam = EmailAddress(name: "Sam Rivera", email: "sam@example.org")
        let fullList = [CalendarGuest(email: work.email, name: work.name, response: .accepted, isOrganizer: true),
                        CalendarGuest(email: home.email, name: home.name, response: .needsAction),
                        CalendarGuest(dana), CalendarGuest(email: sam.email, name: sam.name, response: .accepted)]
        let workEvents = [
            CalendarEvent(id: "roadmap-work", title: "Roadmap review", start: at(2, 10), end: at(2, 12),
                          attendees: [home, dana, sam], organizerIsMe: true, location: "Juniper room",
                          extras: CalendarEventExtras(guests: fullList), uid: "roadmap-1@example.com", organizer: work),
            CalendarEvent(id: "budget-work", title: "Budget check-in", start: at(3, 14), end: at(3, 15),
                          attendees: [home], organizerIsMe: true, uid: "budget-2@example.com", organizer: work),
            CalendarEvent(id: "vendor-demo", title: "Vendor demo", start: at(4, 15), end: at(4, 16),
                          attendees: [dana, work, home], organizerIsMe: false, myResponse: .needsAction,
                          uid: "vendor-3@example.com", organizer: dana),
            CalendarEvent(id: "standup", title: "Team standup", start: at(1, 9, 30), end: at(1, 9, 45),
                          attendees: [dana], organizerIsMe: true),
        ]
        let homeEvents = [
            CalendarEvent(id: "roadmap-home", title: "Roadmap review", start: at(2, 10), end: at(2, 12),
                          attendees: [work, home], organizerIsMe: false, location: "Juniper room", myResponse: .needsAction,
                          extras: CalendarEventExtras(guests: [CalendarGuest(email: work.email, name: work.name,
                                                                             response: .accepted, isOrganizer: true),
                                                               CalendarGuest(email: home.email, name: home.name,
                                                                             response: .needsAction)]),
                          uid: "roadmap-1@example.com", organizer: work, guestsOmitted: true),
            CalendarEvent(id: "budget-home", title: "Budget check-in", start: at(3, 13), end: at(3, 14),
                          attendees: [work, home], organizerIsMe: false, myResponse: .accepted,
                          uid: "budget-2@example.com", organizer: work),
            CalendarEvent(id: "vendor-demo", title: "Vendor demo", start: at(4, 15), end: at(4, 16),
                          attendees: [dana, work, home], organizerIsMe: false, myResponse: .needsAction,
                          uid: "vendor-3@example.com", organizer: dana),
            CalendarEvent(id: "gym", title: "Gym", start: at(1, 7), end: at(1, 8)),
        ]
        let workCalendar = FakeCalendar(events: workEvents, info: CalendarProviderInfo(name: "Google Calendar",
                                                                                       account: accounts[0].email),
                                        abilities: [.respond, .editDetails, .remove, .editFull, .removeInvite])
        let homeCalendar = FakeCalendar(events: homeEvents, info: CalendarProviderInfo(name: "Google Calendar",
                                                                                       account: accounts[1].email),
                                        abilities: [.respond, .editDetails, .remove, .editFull, .removeInvite])
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
    func calendarMeetingCopiesScreens(_ theme: SweepTheme) async throws {
        try await shootMeetingCopies(theme, size: SweepWindow.size, suffix: "")
        // A narrow window within any screen: the card's rows and answer pills must still fit
        try await shootMeetingCopies(theme, size: NSSize(width: 900, height: 720), suffix: "-narrow")
    }

    private func shootMeetingCopies(_ theme: SweepTheme, size: NSSize, suffix: String) async throws {
        let (environment, now) = CalendarMeetingCopiesSweep.environment()
        let w = try await SweepWindow.make(environment, theme: theme, size: size)
        defer { w.close() }
        let model = try #require(environment.calendarWindow)
        let sidebar = try #require(environment.calendarSidebar)
        model.now = { now }
        sidebar.now = { now }

        await model.open(.week, source: .keyboard)
        try await until { model.state == .loaded && model.shownEvents.filter(\.isMerged).count == 3 }
        try await sweepShoot(w.window, screen: "calendar-window-meeting-one-block\(suffix)", theme: theme)

        let roadmap = try #require(model.shownEvents.first { $0.title == "Roadmap review" })
        model.openEvent(roadmap)
        try await sweepShoot(w.window, screen: "calendar-window-meeting-card\(suffix)", theme: theme)
        model.closeCard()

        let budget = try #require(model.shownEvents.first { $0.title == "Budget check-in" })
        model.openEvent(budget)
        try await sweepShoot(w.window, screen: "calendar-window-meeting-card-time-mismatch\(suffix)", theme: theme)
        model.closeCard()

        let vendor = try #require(model.shownEvents.first { $0.title == "Vendor demo" })
        model.openEvent(vendor)
        try await sweepShoot(w.window, screen: "calendar-window-meeting-card-invited-both\(suffix)", theme: theme)
        model.closeCard()

        await model.setKind(.month)
        try await until { model.state == .loaded }
        try await sweepShoot(w.window, screen: "calendar-window-meeting-month\(suffix)", theme: theme)
        await model.close()
    }

    // Removing a meeting held by two accounts: the organizer's delete cancels the invited copy too, while removing the
    // invited copy alone keeps the meeting on the organizer's calendar. Each question, then its held state with Undo.
    @Test(arguments: SweepTheme.builtIns)
    func calendarMeetingCopiesRemovalScreens(_ theme: SweepTheme) async throws {
        try await shootMeetingCopiesRemoval(theme, size: SweepWindow.size, suffix: "")
        try await shootMeetingCopiesRemoval(theme, size: NSSize(width: 900, height: 720), suffix: "-narrow")
    }

    private func shootMeetingCopiesRemoval(_ theme: SweepTheme, size: NSSize, suffix: String) async throws {
        let (environment, now) = CalendarMeetingCopiesSweep.environment()
        let w = try await SweepWindow.make(environment, theme: theme, size: size)
        defer { w.close() }
        let model = try #require(environment.calendarWindow)
        let sidebar = try #require(environment.calendarSidebar)
        model.now = { now }
        sidebar.now = { now }
        model.holdWindow = .seconds(3600)
        await model.open(.week, source: .keyboard)
        try await until { model.state == .loaded && model.shownEvents.filter(\.isMerged).count == 3 }

        let roadmap = try #require(model.shownEvents.first { $0.title == "Roadmap review" })
        model.askToRemove(roadmap)
        try await sweepShoot(w.window, screen: "calendar-window-meeting-remove-organizer\(suffix)", theme: theme)
        await model.confirmRemove()
        try await sweepShoot(w.window, screen: "calendar-window-meeting-remove-organizer-held\(suffix)", theme: theme)
        await environment.undo?.undoLast()
        #expect(model.shownEvents.filter(\.isMerged).count == 3, "Undo during the hold brings both copies back")

        let invited = try #require(model.copyRemovals(for: roadmap).first)
        model.askToRemove(roadmap, copy: invited.copyKey)
        try await sweepShoot(w.window, screen: "calendar-window-meeting-remove-invited-copy\(suffix)", theme: theme)
        await model.confirmRemove()
        try await sweepShoot(w.window, screen: "calendar-window-meeting-remove-invited-copy-held\(suffix)", theme: theme)
        await environment.undo?.undoLast()

        let vendor = try #require(model.shownEvents.first { $0.title == "Vendor demo" })
        model.askToRemove(vendor)
        try await sweepShoot(w.window, screen: "calendar-window-meeting-remove-invited-both\(suffix)", theme: theme)
        await model.escape()
        await model.close()
    }
}
