import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.builtIns)
    func inlineDraftComposer(_ theme: SweepTheme) async throws {
        do {
            let w = try await SweepWindow.make(SweepOverlayFixture.environment(), theme: theme)
            defer { w.close() }
            let (thread, _) = try await w.longestConversation()
            _ = try await w.open(thread)
            #expect(w.router.perform(.reply))
            let composer = try await w.inlineComposer()
            try await sweepShoot(w.window, screen: "reader-inline-draft", theme: theme)

            let editor = try #require(w.editors.first)
            editor.insertText(SweepOverlayFixture.inlineReply, replacementRange: editor.selectedRange())
            try await until { composer.session.plainText.contains("Thursday at 10") }
            try await sweepShoot(w.window, screen: "reader-inline-draft-typed", theme: theme)
        }
        do {
            let w = try await SweepWindow.make(SweepOverlayFixture.environment(), theme: theme)
            defer { w.close() }
            let (thread, messages) = try await w.longestConversation()
            let model = try await w.open(thread)
            let copied = try #require(messages.first { !$0.cc.isEmpty }, "a message with a Cc in the conversation")
            model.reveal(copied.id)
            model.focus(copied.id)
            #expect(w.router.perform(.replyAll))
            _ = try await w.inlineComposer()
            try await sweepShoot(w.window, screen: "reader-inline-draft-reply-all", theme: theme)
        }
    }

    @Test(arguments: SweepTheme.builtIns)
    func eventCardLongDescription(_ theme: SweepTheme) async throws {
        let environment = EventCardSweep.environment()
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let model = try #require(environment.calendarWindow)
        let sidebar = try #require(environment.calendarSidebar)
        let now = EventCardSweep.now
        model.timeZone = SweepClock.timeZone
        model.firstWeekday = 1
        model.now = { now }
        sidebar.now = { now }

        await model.open(.week)
        try await until { model.state == .loaded && model.events.contains { $0.id == EventCardSweep.acceptedID } }
        for (id, screen) in [(EventCardSweep.longID, "calendar-window-event-card-long"),
                             (EventCardSweep.acceptedID, "calendar-window-event-card-long-accepted")] {
            let event = try #require(model.events.first { $0.id == id })
            model.openEvent(event)
            try await sweepShoot(w.window, screen: screen, theme: theme)
            model.closeCard()
        }
        await model.close()
    }
}
