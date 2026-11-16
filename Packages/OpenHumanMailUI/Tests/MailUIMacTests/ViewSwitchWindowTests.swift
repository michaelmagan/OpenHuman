import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
@testable import MailUI
import Testing
@testable import MailUIMac

/// 1 is Mail and 2 the Calendar, from every place in either; 2 in the Calendar goes back to where the mail was.
@MainActor
@Suite(.serialized) struct ViewSwitchWindowTests {
    static let frameName = "dev.openhuman.tests.view-switch"

    /// The key as the app delivers it: the key router first, then the first responder if the router passed it on.
    @discardableResult
    func press(_ digit: String, in w: InlineReplyWindow) -> Bool {
        let code: UInt16 = digit == "1" ? 18 : 19
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.window.windowNumber,
                                     context: nil, characters: digit, charactersIgnoringModifiers: digit,
                                     isARepeat: false, keyCode: code)!
        guard let passed = w.content.keyRouter.route(event) else { return true }
        w.window.firstResponder?.keyDown(with: passed)
        return false
    }

    func make() async throws -> (InlineReplyWindow, CalendarWindowModel) {
        let environment = AppEnvironment.fake(corpus: .small, options: .init(remoteAck: .immediate),
                                              featureFlags: FeatureFlags(), calendar: FakeCalendar(),
                                              notices: NoticeCenter(autoExpire: false))
        let calendar = try #require(environment.calendarWindow)
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true,
                                                environment: environment)
        return (w, calendar)
    }

    @Test func theKeysStayWithTheWindowWhileTheCalendarHidesTheMail() async throws {
        let (w, calendar) = try await make()
        defer { w.close() }
        #expect(w.content.keyRouter.isInstalled)
        #expect(press("2", in: w), "2 in the list is the Calendar's")
        try await until(timeout: .seconds(15)) { calendar.isOpen && w.content.view.isHidden }
        #expect(w.content.keyRouter.isInstalled, "hiding the mail for the Calendar keeps the key router")
        #expect(w.content.keyRouter.scopeStack == [.calendar, .global])
        #expect(press("1", in: w), "1 in the Calendar is Mail's")
        try await until(timeout: .seconds(15)) { !calendar.isOpen && !w.content.view.isHidden }
        #expect(w.content.keyRouter.isInstalled)
    }

    @Test func closingTheWindowWhileTheCalendarShowsStopsTheKeys() async throws {
        let (w, calendar) = try await make()
        defer { w.close() }
        #expect(press("2", in: w))
        try await until(timeout: .seconds(15)) { calendar.isOpen && w.content.view.isHidden }
        let keys = w.content.keyRouter
        #expect(keys.isInstalled)
        w.window.close()
        #expect(!keys.isInstalled, "a closed window's router routes no other window's keys")
    }

    @Test func twoTogglesBetweenTheMailAndTheCalendarAgainAndAgain() async throws {
        let (w, calendar) = try await make()
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        for round in 0..<3 {
            #expect(press("2", in: w), "2 in the conversation, round \(round)")
            try await until(timeout: .seconds(15)) { calendar.isOpen }
            #expect(press("2", in: w), "2 again in the Calendar, round \(round)")
            try await until(timeout: .seconds(15)) { !calendar.isOpen }
            #expect(w.router.mode == .reader && w.router.reader?.thread == thread, "back in the conversation")
        }
    }

    @Test func oneAndTwoWorkInTheCalendarWhenTheSidebarHasTheKeys() async throws {
        let (w, calendar) = try await make()
        defer { w.close() }
        let sidebar = try #require(w.content.sidebarTable())
        w.window.makeFirstResponder(sidebar)
        try await until(timeout: .seconds(15)) { w.router.sidebarHasKeys }
        #expect(press("2", in: w), "2 in the sidebar opens the Calendar")
        try await until(timeout: .seconds(15)) { calendar.isOpen }
        w.window.makeFirstResponder(sidebar)
        try await until(timeout: .seconds(15)) { w.content.sidebarHasTheKeys() }
        #expect(press("2", in: w), "2 in the sidebar while the Calendar shows goes back")
        try await until(timeout: .seconds(15)) { !calendar.isOpen }
        #expect(press("2", in: w))
        try await until(timeout: .seconds(15)) { calendar.isOpen }
        w.window.makeFirstResponder(sidebar)
        try await until(timeout: .seconds(15)) { w.content.sidebarHasTheKeys() }
        #expect(press("1", in: w), "1 in the sidebar while the Calendar shows is Mail")
        try await until(timeout: .seconds(15)) { !calendar.isOpen }
    }

    @Test func digitsTypedInTheCalendarsFieldsAreTextAndTheKeysComeBackWhenTheEventCloses() async throws {
        let (w, calendar) = try await make()
        defer { w.close() }
        #expect(press("2", in: w))
        try await until(timeout: .seconds(15)) { calendar.isOpen }
        await calendar.newEvent()
        var title: NSTextField?
        try await until(timeout: .seconds(15)) {
            title = CalendarNativeEditorTests.editableField(in: w.window.contentView!) { $0.placeholderString == "Add title" }
            return title != nil
        }
        let field = try #require(title)
        w.window.makeFirstResponder(field)
        try await until(timeout: .seconds(15)) { (w.window.firstResponder as? NSTextView)?.delegate === field }
        #expect(!press("2", in: w), "2 in the title field is the field's")
        #expect(!press("1", in: w), "so is 1")
        #expect(calendar.isOpen)
        await calendar.escape()
        try await until(timeout: .seconds(15)) { calendar.sidebar.draft == nil }
        try await until(timeout: .seconds(15)) {
            w.window.contentView?.layoutSubtreeIfNeeded()
            return field.window == nil || field.isHiddenOrHasHiddenAncestor
        }
        #expect(press("1", in: w), "with the event gone, 1 is Mail again")
        try await until(timeout: .seconds(15)) { !calendar.isOpen }
    }
}
