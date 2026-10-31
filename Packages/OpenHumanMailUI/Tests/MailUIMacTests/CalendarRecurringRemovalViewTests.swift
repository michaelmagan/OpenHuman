import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct CalendarRecurringRemovalViewTests {
    private func fixture(scopes: [CalendarRecurrenceScope] = CalendarRecurrenceScope.removalOptions)
        async throws -> (AppEnvironment, CalendarWindowModel, FakeCalendar) {
        let iso = ISO8601DateFormatter()
        let times = ["2026-10-25T16:00:00Z", "2026-11-01T17:00:00Z", "2026-11-08T17:00:00Z"]
        let ids = ["first", "middle", "last"]
        let events = zip(ids, times).map { id, text in
            let start = iso.date(from: text)!
            return CalendarEvent(id: id, title: "Weekly planning with the wider product and research group",
                start: start, end: start.addingTimeInterval(1800), timeZone: "America/Los_Angeles",
                organizerIsMe: true, recurringEventID: "weekly",
                originalStartTime: .timed(start, timeZone: "America/Los_Angeles"))
        }
        let fake = FakeCalendar(events: events, removalScopes: scopes)
        let env = AppEnvironment.fake(corpus: .small, options: .init(remoteAck: .immediate),
                                      featureFlags: FeatureFlags(), calendar: fake)
        let model = try #require(env.calendarWindow)
        model.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = iso.date(from: times[1])!
        model.now = { now }
        await model.open()
        model.openEvent(try #require(model.events.first { $0.id == "middle" }))
        model.askToRemoveCardEvent()
        return (env, model, fake)
    }

    private func host(_ model: CalendarWindowModel) throws -> (NSWindow, NSHostingView<AnyView>) {
        let question = try #require(model.removeQuestion)
        let root = CalendarRemovalQuestionView(model: model, question: question)
            .environment(\.theme, ResolvedTheme.light).frame(width: 480, height: 480)
        HostedAccessibility.setAssistiveClient(true)
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        // The test compares control frames, so the window sits inside the visible screen.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 20, y: screen.minY + 20, width: 480, height: 480),
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

    private func control(_ id: String, in hosting: NSView) async throws -> HostedControl {
        try await HostedAccessibility.control(id, in: hosting)
    }

    @Test func actualThisAllAndFutureControlsDispatchTheirScopeAndProduceDifferentSurvivors() async throws {
        let cases: [(CalendarRecurrenceScope, String, [String])] = [
            (.thisEvent, "calendar.scope.this", ["first", "last"]),
            (.allEvents, "calendar.scope.all", []), (.thisAndFollowing, "calendar.scope.future", ["first"])]
        for (scope, identifier, survivors) in cases {
            let (env, model, fake) = try await fixture()
            defer { withExtendedLifetime(env) {} }
            model.holdWindow = .zero
            let (window, hosting) = try host(model)
            defer { close(window) }
            for (id, title) in [("calendar.scope.this", "This event"), ("calendar.scope.all", "All events in the series"),
                                ("calendar.scope.future", "This and future events"), ("calendar.remove.cancel", "Cancel")] {
                let button = try await control(id, in: hosting)
                #expect(button.label == title)
            }
            let this = try await control("calendar.scope.this", in: hosting)
            let all = try await control("calendar.scope.all", in: hosting)
            let future = try await control("calendar.scope.future", in: hosting)
            #expect(this.frame.minY > all.frame.minY)
            #expect(all.frame.minY > future.frame.minY, "the three full labels are vertical in this/all/future order")
            let button = try await control(identifier, in: hosting)
            #expect(button.press(), "activate the actual SwiftUI control")
            try await until { fake.calls.contains(.scopedRemove(id: "middle", scope: scope, sendUpdates: .all)) }
            try await until { !model.hasQuitWork && fake.allEvents.map(\.id).sorted() == survivors }
            #expect(fake.created.isEmpty && model.removeQuestion == nil)
        }
    }

    @Test func actualCancelControlAndEscapeSendNothingAndKeepTheCard() async throws {
        let (env, model, fake) = try await fixture()
        defer { withExtendedLifetime(env) {} }
        let (window, hosting) = try host(model)
        defer { close(window) }
        let cancel = try await control("calendar.remove.cancel", in: hosting)
        #expect(cancel.press())
        try await until { model.removeQuestion == nil }
        #expect(model.card != nil && !model.hasQuitWork)
        model.askToRemoveCardEvent()
        await model.escape()
        #expect(model.removeQuestion == nil && model.card != nil)
        #expect(fake.allEvents.map(\.id) == ["first", "middle", "last"])
        #expect(!fake.calls.contains { if case .scopedRemove = $0 { true } else { false } })
    }

    @Test func unavailableChoicesRemainVisibleWithAnExplanationAndHeldUndoDoesNotDispatch() async throws {
        let (env, model, fake) = try await fixture(scopes: [.thisEvent])
        model.holdWindow = .seconds(3600)
        let (window, hosting) = try host(model)
        defer { close(window) }
        let all = try await control("calendar.scope.all", in: hosting)
        let future = try await control("calendar.scope.future", in: hosting)
        #expect(!all.isEnabled && !future.isEnabled)
        let question = try #require(model.removeQuestion)
        #expect(question.note?.contains("can't remove") == true)
        let this = try await control("calendar.scope.this", in: hosting)
        #expect(this.press())
        try await until { model.hasQuitWork }
        await env.undo?.undoLast()
        #expect(!model.hasQuitWork && fake.allEvents.count == 3)
        #expect(!fake.calls.contains { if case .scopedRemove = $0 { true } else { false } })
    }
}
