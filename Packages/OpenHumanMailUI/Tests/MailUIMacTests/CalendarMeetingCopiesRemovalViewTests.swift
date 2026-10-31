import AppKit
import MailFakes
@testable import MailFeatures
import MailModel
import MailTheme
@testable import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct CalendarMeetingCopiesRemovalViewTests {
    private static let removes: CalendarAbilities = [.respond, .remove, .removeInvite]
    private static let start = ISO8601DateFormatter().date(from: "2026-11-02T17:00:00Z")!

    private func elements(_ hosting: NSView) -> [HostedControl] { HostedAccessibility.elements(in: hosting) }

    private func host(_ view: some View, size: NSSize) -> (NSWindow, NSHostingView<AnyView>) {
        HostedAccessibility.setAssistiveClient(true)
        let hosting = NSHostingView(rootView: AnyView(view.environment(\.theme, ResolvedTheme.light)
            .frame(width: size.width, height: size.height)))
        hosting.sizingOptions = []
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 20, y: screen.minY + 20, width: size.width,
                                                  height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
        HostedAccessibility.setAssistiveClient(false)
    }

    private func meetingCopy(_ id: String, organizerIsMe: Bool, attendees: [EmailAddress]) -> CalendarEvent {
        CalendarEvent(id: id, title: "Roadmap review", start: Self.start, end: Self.start.addingTimeInterval(3600),
                      timeZone: "America/Los_Angeles", attendees: attendees, organizerIsMe: organizerIsMe,
                      myResponse: organizerIsMe ? nil : .needsAction, uid: "roadmap-1@example.com")
    }

    // One meeting the work account organizes and the home account is invited to, on two connected calendars
    private func calendars() async throws -> (AppEnvironment, CalendarWindowModel, work: FakeCalendar, home: FakeCalendar) {
        let corpus = FakeCorpus.rich(threadCount: 4, now: Self.start)
        let accounts = corpus.accounts
        let workAddress = EmailAddress(email: accounts[0].email.lowercased())
        let homeAddress = EmailAddress(email: accounts[1].email.lowercased())
        let work = FakeCalendar(events: [meetingCopy("work-copy", organizerIsMe: true, attendees: [homeAddress])],
                                info: CalendarProviderInfo(name: "Google Calendar", account: accounts[0].email),
                                abilities: Self.removes)
        let home = FakeCalendar(events: [meetingCopy("home-copy", organizerIsMe: false,
                                                     attendees: [workAddress, homeAddress])],
                                info: CalendarProviderInfo(name: "Google Calendar", account: accounts[1].email),
                                abilities: Self.removes)
        let connections = FakeCalendarConnections(connected: [accounts[0].email, accounts[1].email],
                                                  providers: [accounts[0].email: work, accounts[1].email: home])
        let env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), featureFlags: FeatureFlags(),
                                      calendar: work, calendarConnections: connections)
        let model = try #require(env.calendarWindow)
        model.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = Self.start.addingTimeInterval(-3600)
        model.now = { now }
        await model.open()
        return (env, model, work, home)
    }

    @Test func removingTheInvitedCopyOfAMergedMeetingNamesBothCalendarsAndLeavesOnlyThatCopy() async throws {
        let (env, model, work, home) = try await calendars()
        defer { withExtendedLifetime(env) {} }
        model.holdWindow = .zero
        let meeting = try #require(model.shownEvents.first)
        #expect(meeting.isMerged)
        let invited = try #require(model.copyRemovals(for: meeting).first)
        model.askToRemove(meeting, copy: invited.copyKey)
        let question = try #require(model.removeQuestion)
        let homeEmail = try #require(question.account)
        let (window, hosting) = host(CalendarRemovalQuestionView(model: model, question: question),
                                     size: NSSize(width: 480, height: 360))
        defer { close(window) }
        let confirm = try await HostedAccessibility.control("calendar.remove.confirm", in: hosting)
        #expect(confirm.label == "Remove")
        #expect(elements(hosting).contains { control in
            ((control.label ?? control.value as? String) ?? "").contains("Remove Roadmap review from \(homeEmail)?")
        }, "the question names the calendar the copy leaves")
        #expect(confirm.press(), "activate the actual SwiftUI control")
        try await until { home.calls.contains(.scopedRemove(id: "home-copy", scope: .thisEvent, sendUpdates: .none)) }
        try await until { !model.hasQuitWork }
        #expect(!work.calls.contains { if case .scopedRemove = $0 { true } else { false } })
        #expect(!home.calls.contains { if case .respond = $0 { true } else { false } })
        #expect(model.shownEvents.count == 1 && model.shownEvents.first?.isMerged == false)
        await model.prepareForQuit()
    }
}
