import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.calendarEditor)
    func composerRecipientListFloats(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let compose = w.environment.compose
        #expect(w.router.perform(.compose))
        try await until { compose.windowSession?.placement == .modal }
        let session = try #require(compose.windowSession)
        await session.settle()
        session.subject = "Plan for the offsite"
        let root = try #require(w.window.contentView)
        let field = try await ComposerSuggestionProbe.waitForField(.to, in: root)
        let prefix = try await ComposerSuggestionProbe.contactPrefix(w.environment, session)
        try await CalendarEditorProbe.type(prefix, into: field, in: w.window)
        _ = try await CalendarEditorProbe.shownPanel(of: w.window)
        if session.to.suggestions.count > 1 { session.to.moveSuggestion(by: 1) }
        try await sweepShootWithPanels(w.window, screen: "composer-recipient-suggestions-floating", theme: theme)
        session.to.dismissSuggestions()
    }

    @Test(arguments: SweepTheme.calendarEditor)
    func calendarOpensOnAClickedTime(_ theme: SweepTheme) async throws {
        let (environment, now) = CalendarWindowSweep.environment()
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let sidebar = try #require(environment.calendarSidebar)
        sidebar.now = { now }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        let calendar = CalendarDateMentions.calendar(sidebar.timeZone)
        let free = try #require(calendar.date(bySettingHour: 14, minute: 30, second: 0, of: now))
        await sidebar.reveal(CalendarDateMention(date: free, hasTime: true, duration: 3_600), in: thread)
        try await until { sidebar.isVisible && sidebar.state == .loaded && sidebar.showsPickedTime }
        try await sweepShoot(w.window, screen: "calendar-sidebar-time-from-message", theme: theme)

        let lunch = try #require(calendar.date(bySettingHour: 12, minute: 30, second: 0, of: now))
        await sidebar.reveal(CalendarDateMention(date: lunch, hasTime: true, duration: 3_600), in: thread)
        try await until { sidebar.showsPickedTime && sidebar.pickedTime?.start == lunch }
        try await sweepShoot(w.window, screen: "calendar-sidebar-time-from-message-busy", theme: theme)

        await sidebar.createEventAtPickedTime()
        try await until { sidebar.draft != nil }
        try await sweepShoot(w.window, screen: "calendar-sidebar-create-event-over-the-day", theme: theme)
        sidebar.cancelDraft()
        try await until { sidebar.showsPickedTime }
        #expect(sidebar.draft == nil, "Cancel with the title field focused leaves no draft behind")

        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        let session = composer.session
        let tea = try #require(calendar.date(bySettingHour: 16, minute: 0, second: 0, of: now))
        w.environment.compose.openEvent(at: CalendarDateMention(date: tea, hasTime: true, duration: 1_800), from: session)
        try await until { sidebar.showsPickedTime && sidebar.pickedTime?.key == .draft(session.id) }
        #expect(sidebar.draft == nil, "a time in the draft opens the calendar first, like one in a message")
        try await sweepShoot(w.window, screen: "calendar-sidebar-time-from-draft", theme: theme)
        sidebar.dismissPickedTime()
        sidebar.setVisible(false)
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func composerAIRewriteDockedBeforeAndAfterAccept(_ theme: SweepTheme) async throws {
        let center = AICenter.make(registry: ProviderRegistry(providers: [ScriptedProvider()]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore(
                                       AISettings(draftReplies: .onDeviceAuto))))
        let environment = AppEnvironment.fake(corpus: .small, options: .init(remoteAck: .immediate),
                                              featureFlags: FeatureFlags(), ai: center)
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let compose = w.environment.compose
        #expect(w.router.perform(.compose))
        try await until { compose.windowSession?.placement == .modal }
        let session = try #require(compose.windowSession)
        await session.settle()
        session.to.setTokens([EmailAddress(name: "Dana Reyes", email: "dana@example.org")])
        session.subject = "Offsite follow-up"
        let editor = try #require(w.editors.first)
        let first = "Thanks for joining today, it was good to see everyone."
        editor.insertText(first + "\nI will send the notes and the budget draft by Friday.",
                          replacementRange: editor.selectedRange())
        try await until { session.plainText.contains("Friday") }
        w.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: (first as NSString).length))
        try await sweepShoot(w.window, screen: "composer-ai-selection-before-panel", theme: theme)

        let panel = try #require(center.togglePanel(session))
        #expect(panel.scope == .selection)
        try await until { session.aiPanel === panel }
        try await sweepShoot(w.window, screen: "composer-ai-docked-open", theme: theme)
        panel.instruction = "Make it warmer"
        panel.generate()
        try await until { panel.phase == .done && panel.canApply }
        try await sweepShoot(w.window, screen: "composer-ai-docked-suggestion", theme: theme)

        panel.replace()
        try await until { session.aiPanel == nil }
        try await sweepShoot(w.window, screen: "composer-ai-docked-after-accept", theme: theme)
    }
}
