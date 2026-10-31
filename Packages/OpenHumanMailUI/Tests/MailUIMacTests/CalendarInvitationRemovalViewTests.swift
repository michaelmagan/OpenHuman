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
@Suite(.serialized) struct CalendarInvitationRemovalViewTests {
    private static let removes: CalendarAbilities = [.respond, .remove, .removeInvite]

    private func elements(_ hosting: NSView) -> [HostedControl] { HostedAccessibility.elements(in: hosting) }

    private func control(_ id: String, in hosting: NSView) async throws -> HostedControl {
        try await HostedAccessibility.control(id, in: hosting)
    }

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

    // The clock sits an hour before the event under test, so its week is the one the window loads.
    private func calendar(_ events: [CalendarEvent], around id: String) async throws
        -> (AppEnvironment, CalendarWindowModel, FakeCalendar) {
        let fake = FakeCalendar(events: events, abilities: Self.removes)
        let env = AppEnvironment.fake(corpus: .small, options: .init(remoteAck: .immediate),
                                      featureFlags: FeatureFlags(), calendar: fake)
        let model = try #require(env.calendarWindow)
        model.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = try #require(events.first { $0.id == id }).start.addingTimeInterval(-3600)
        model.now = { now }
        await model.open()
        return (env, model, fake)
    }

    private func invitation(_ id: String, _ text: String, series: String? = nil) -> CalendarEvent {
        let start = ISO8601DateFormatter().date(from: text)!
        return CalendarEvent(id: id, title: "Vendor check-in", start: start, end: start.addingTimeInterval(1800),
            timeZone: "America/Los_Angeles", attendees: [EmailAddress(email: "sam@example.org"), FakeCorpus.me],
            organizerIsMe: false, myResponse: .needsAction, recurringEventID: series,
            originalStartTime: series == nil ? nil : .timed(start, timeZone: "America/Los_Angeles"))
    }

    @Test func theRemoveControlOfASingleInvitationSaysRemoveAndLeavesSilently() async throws {
        let (env, model, fake) = try await calendar([invitation("inv", "2026-11-02T17:00:00Z")], around: "inv")
        defer { withExtendedLifetime(env) {} }
        model.holdWindow = .zero
        model.askToRemove(try #require(model.events.first))
        let question = try #require(model.removeQuestion)
        let (window, hosting) = host(CalendarRemovalQuestionView(model: model, question: question),
                                     size: NSSize(width: 480, height: 360))
        defer { close(window) }
        let confirm = try await control("calendar.remove.confirm", in: hosting)
        #expect(confirm.label == "Remove")
        #expect(elements(hosting).allSatisfy { $0.identifier != "calendar.scope.future" })
        #expect(confirm.press(), "activate the actual SwiftUI control")
        try await until { fake.calls.contains(.scopedRemove(id: "inv", scope: .thisEvent, sendUpdates: .none)) }
        try await until { !model.hasQuitWork }
        #expect(!fake.calls.contains { if case .respond = $0 { true } else { false } } && fake.created.isEmpty)
    }

    @Test func aRepeatingInvitationShowsTheFutureScopeDisabledWithTheReason() async throws {
        let events = [invitation("first", "2026-10-26T17:00:00Z", series: "vendor"),
                      invitation("middle", "2026-11-02T17:00:00Z", series: "vendor"),
                      invitation("last", "2026-11-09T17:00:00Z", series: "vendor")]
        let (env, model, fake) = try await calendar(events, around: "middle")
        defer { withExtendedLifetime(env) {} }
        model.holdWindow = .zero
        let middle = try #require(model.events.first { $0.id == "middle" })
        model.askToRemove(middle)
        let question = try #require(model.removeQuestion)
        let (window, hosting) = host(CalendarRemovalQuestionView(model: model, question: question),
                                     size: NSSize(width: 480, height: 480))
        defer { close(window) }
        let future = try await control("calendar.scope.future", in: hosting)
        let this = try await control("calendar.scope.this", in: hosting)
        let all = try await control("calendar.scope.all", in: hosting)
        #expect(!future.isEnabled && this.isEnabled && all.isEnabled)
        let note = try await control("calendar.remove.note", in: hosting)
        #expect((note.label ?? note.value as? String)?.contains("Only the organizer") == true)
        #expect(all.press())
        try await until { fake.calls.contains(.scopedRemove(id: "middle", scope: .allEvents, sendUpdates: .none)) }
        try await until { !model.hasQuitWork && fake.allEvents.isEmpty }
    }

    @Test func theReaderCardOffersRemoveAsksInPlaceAndCancelSendsNothing() async throws {
        let corpus = FakeCorpus.small
        let fake = FakeCalendar(info: CalendarProviderInfo(name: "Google Calendar", account: corpus.accounts[0].email),
                                abilities: Self.removes)
        let env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), calendar: fake,
                                      calendarConnections: FakeCalendarConnections(providers: [corpus.accounts[0].email: fake]))
        let (thread, message) = try await InviteFixtures.invitation(env, corpus: corpus)
        await InviteFixtures.loadCard(env, thread, message)
        #expect(env.invites.offersRemoval(message.id))
        let (window, hosting) = host(InviteCardView(center: env.invites, message: message.id) { _ in },
                                     size: NSSize(width: 640, height: 720))
        defer { close(window) }
        let remove = try await control("invite.remove", in: hosting)
        #expect(remove.label == "Remove from calendar")
        #expect(remove.press())
        try await until { env.invites.removalQuestion?.message == message.id }
        let confirm = try await control("invite.remove.thisEvent", in: hosting)
        #expect(confirm.label == "Remove")
        #expect(elements(hosting).allSatisfy { $0.identifier != "invite.remove" },
                "the control gives way to its question")
        let cancel = try await control("invite.remove.cancel", in: hosting)
        #expect(cancel.press())
        try await until { env.invites.removalQuestion == nil }
        #expect(env.invites.heldCount == 0 && env.invites.removalStates.isEmpty)
        #expect(!fake.calls.contains { if case .scopedRemove = $0 { true } else { false } })
    }

    @Test func withoutTheAbilityTheReaderCardHasNoRemoveControl() async throws {
        let corpus = FakeCorpus.small
        let env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate))
        let (thread, message) = try await InviteFixtures.invitation(env, corpus: corpus)
        await InviteFixtures.loadCard(env, thread, message)
        let (window, hosting) = host(InviteCardView(center: env.invites, message: message.id) { _ in },
                                     size: NSSize(width: 640, height: 720))
        defer { close(window) }
        _ = try await control("invite.rsvp", in: hosting)
        #expect(elements(hosting).allSatisfy { $0.identifier != "invite.remove" })
    }
}
