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

@MainActor
enum CalendarEditorProbe {
    static let patience: Duration = testBackstop

    static func anchor(_ identifier: String, in root: NSView) -> CompletionAnchorView? {
        subviews(of: CompletionAnchorView.self, in: root).first { $0.listIdentifier == identifier && $0.window != nil }
    }

    // The anchor sits behind the field it serves, so the field is the text field over the anchor's centre
    static func field(for identifier: String, in root: NSView) -> NSTextField? {
        root.layoutSubtreeIfNeeded()
        guard let anchor = anchor(identifier, in: root) else { return nil }
        let frame = anchor.convert(anchor.bounds, to: nil)
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        return subviews(of: NSTextField.self, in: root).first { field in
            field.isEditable && field.window != nil && field.convert(field.bounds, to: nil).contains(centre)
        }
    }

    static func waitForField(_ identifier: String, in root: NSView) async throws -> NSTextField {
        try await until(timeout: patience) { field(for: identifier, in: root) != nil }
        return try #require(field(for: identifier, in: root))
    }

    static func type(_ text: String, into field: NSTextField, in window: NSWindow) async throws {
        if OverlayFocusKeeper.control(of: window.firstResponder) !== field { window.makeFirstResponder(field) }
        try await until(timeout: patience) { OverlayFocusKeeper.control(of: window.firstResponder) === field }
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    static func panel(of window: NSWindow) -> CompletionPanelWindow? {
        (window.childWindows ?? []).compactMap { $0 as? CompletionPanelWindow }.first
    }

    static func shownPanel(of window: NSWindow) async throws -> CompletionPanelWindow {
        try await until(timeout: patience) { panel(of: window)?.list?.isShowing == true }
        return try #require(panel(of: window))
    }

    static func textEditors(in root: NSView) -> [NSTextView] {
        subviews(of: NSTextView.self, in: root).filter { !$0.isFieldEditor && $0.isEditable && $0.window != nil }
    }

    static func typeLines(_ lines: [String], into text: NSTextView, in window: NSWindow) async throws {
        window.makeFirstResponder(text)
        try await until(timeout: patience) { window.firstResponder === text }
        for (index, line) in lines.enumerated() {
            if index > 0 { text.insertNewline(nil) }
            text.insertText(line, replacementRange: text.selectedRange())
        }
    }

    // In the hosting view's own coordinates, so a window that changes size does not read as a move
    static func frames(of views: [NSView], in root: NSView) -> [NSRect] {
        root.layoutSubtreeIfNeeded()
        return views.map { $0.convert($0.bounds, to: root) }
    }

    static func settledFrames(of views: [NSView], in root: NSView) async throws -> [NSRect] {
        var last = frames(of: views, in: root)
        try await until(timeout: patience) {
            try? await Task.sleep(for: .milliseconds(50)) // flake-ok: the sampling interval inside until(), not a wait for a result
            let now = frames(of: views, in: root)
            let same = now == last
            last = now
            return same
        }
        return last
    }

    static func contactPrefix(_ sidebar: CalendarSidebarModel) async throws -> String {
        let top = try #require(await sidebar.guestSuggestions("").first, "the synthetic corpus has contacts")
        return String(top.email.prefix(2))
    }
}

@MainActor @Observable
final class CalendarFormBox {
    var form: CalendarEventForm
    init(_ form: CalendarEventForm) { self.form = form }
}

private struct CalendarFormHost: View {
    let box: CalendarFormBox
    let suggest: (@Sendable (String) async -> [EmailAddress])?

    var body: some View {
        CalendarEventFormView(form: Binding(get: { box.form }, set: { box.form = $0 }), rights: .all,
                              timeZone: TimeZone(identifier: "UTC") ?? .gmt, idPrefix: "test.form", meetLink: nil,
                              suggestGuests: suggest)
            .padding(20)
            .frame(width: 420)
    }
}

@MainActor
@Suite(.serialized)
struct CalendarEditorPolishTests {
    nonisolated static let people: [EmailAddress] = [
        EmailAddress(name: "Dana Ruiz", email: "dana@example.com"),
        EmailAddress(name: "Dan Okafor", email: "dan.okafor@example.org"),
        EmailAddress(name: "Daniela Costa", email: "daniela@example.net"),
        EmailAddress(name: "Dariusz Nowak", email: "dariusz@example.com"),
        EmailAddress(name: "Dave Lin", email: "dave.lin@example.org"),
        EmailAddress(name: "Dawn Price", email: "dawn@example.net"),
        EmailAddress(name: "Sam Rivera", email: "sam@example.org"),
    ]

    nonisolated static func suggest(_ prefix: String) -> [EmailAddress] {
        let needle = prefix.lowercased()
        return people.filter { person in
            let tokens = [person.email.lowercased()] + (person.name?.lowercased().split(separator: " ").map(String.init) ?? [])
            return tokens.contains { $0.hasPrefix(needle) }
        }
    }

    let start = Date(timeIntervalSince1970: 1_791_000_000)

    func form(notes: String = "") -> CalendarEventForm {
        CalendarEventForm(title: "Planning", start: start, end: start.addingTimeInterval(1_800), timeZone: "UTC",
                          notes: notes)
    }

    func host(_ box: CalendarFormBox, theme: ResolvedTheme = .light) -> (NSWindow, NSHostingView<AnyView>) {
        let root = CalendarFormHost(box: box, suggest: { prefix in CalendarEditorPolishTests.suggest(prefix) })
            .environment(\.theme, theme)
            .background(theme.bgWindow.color)
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 460, height: 1000), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    @Test func theRemindersMenuSummarisesAndTogglesEachReminder() {
        #expect(CalendarReminderMenu.title(.calendarDefault) == "Calendar default")
        #expect(CalendarReminderMenu.title(.custom([])) == "None")
        let ten = CalendarReminder(minutesBefore: 10)
        let day = CalendarReminder(method: .email, minutesBefore: 1_440)
        #expect(CalendarReminderMenu.title(.custom([ten])) == "10 minutes before")
        #expect(CalendarReminderMenu.title(.custom([day, ten])) == "10 minutes before, +1")

        let fromDefault = CalendarReminderMenu.toggling(ten, in: .calendarDefault)
        #expect(fromDefault == .custom([ten]))
        #expect(CalendarReminderMenu.toggling(ten, in: fromDefault) == .custom([]))

        let items = CalendarReminderMenu.items(.custom([ten, day]))
        #expect(items.map(\.reminder.minutesBefore) == [0, 5, 10, 30, 60, 1_440, 1_440], "the presets and the email reminder")
        #expect(items.filter(\.isOn).map(\.reminder) == [ten, day])
        #expect(items.first { $0.reminder == day }?.title == "Email, 1 day before")
        #expect(items.allSatisfy { $0.isEnabled })

        let five = [0, 5, 10, 30, 60].map { CalendarReminder(minutesBefore: $0) }
        let full = CalendarReminderMenu.items(.custom(five))
        #expect(full.filter { !$0.isEnabled }.map(\.reminder.minutesBefore) == [1_440], "five is the most Google keeps")
        #expect(CalendarReminderMenu.toggling(CalendarReminder(minutesBefore: 1_440), in: .custom(five)) == .custom(five))
        #expect(CalendarReminderMenu.items(.calendarDefault).allSatisfy { !$0.isOn })
    }

    @Test func theColourMenuOffersTheCalendarsColourThenElevenColours() {
        let choices = CalendarColourMenu.choices(including: nil)
        #expect(choices.count == 12)
        #expect(choices.first == .some(nil))
        #expect(CalendarColourMenu.choices(including: "4") == choices)
        #expect(CalendarColourMenu.choices(including: "12").last == "12", "a colour set elsewhere stays choosable")
        #expect(CalendarColourMenu.title(nil) == "Calendar colour")
        #expect(CalendarColourMenu.title("3") == "Colour 3")
        let theme = ResolvedTheme.light
        #expect(CalendarColourMenu.ink(nil, theme: theme) == nil)
        #expect(CalendarColourMenu.ink("3", theme: theme) == CalendarPalette.ink(3, tokens: theme.tokens))
        let swatch = CalendarColourMenu.swatch(CalendarColourMenu.ink("3", theme: theme), ring: theme.textTertiary)
        #expect(swatch.size == NSSize(width: 14, height: 14))
        #expect(!swatch.isTemplate, "menus keep the swatch's colour")
    }

    @Test func theNotesAreaRestsAtOneLineAndOpensToThree() {
        #expect(CalendarTextAreaModifier.minimumLines(text: "", focused: false) == 1)
        #expect(CalendarTextAreaModifier.minimumLines(text: "", focused: true) == 3)
        #expect(CalendarTextAreaModifier.minimumLines(text: "Agenda", focused: false) == 3)
        #expect(CalendarTextAreaModifier.maxLines == 10)
    }

    func notesHeight(_ text: String, focused: Bool = true) -> CGFloat {
        let area = TextEditor(text: .constant(text))
            .calendarTextArea(text: text, prompt: "Add agenda or notes", focused: focused)
            .frame(width: 320)
        return NSHostingView(rootView: area).fittingSize.height
    }

    @Test func theNotesAreaGrowsWithItsLinesUpToTenThenScrolls() {
        func lines(_ count: Int) -> String { (1...count).map { "Point \($0)" }.joined(separator: "\n") }
        let resting = notesHeight("", focused: false)
        let open = notesHeight("", focused: true)
        let four = notesHeight(lines(4))
        let ten = notesHeight(lines(CalendarTextAreaModifier.maxLines))
        let twenty = notesHeight(lines(20))
        #expect(open > resting, "focus opens the area")
        #expect(four > open, "four lines need more than the three it opens to")
        #expect(ten > four, "the area grew with the text")
        #expect(twenty == ten, "it stops at ten lines and the rest scrolls")
        let chrome: CGFloat = 10
        #expect(ten <= CalendarTextAreaModifier.lineHeight * CGFloat(CalendarTextAreaModifier.maxLines + 1) + chrome,
                "about ten lines, plus the field's own padding")
    }

    @Test func theSuggestionPanelHangsUnderTheFieldOrAboveItNearTheBottom() {
        let room = CompletionPanel.shadowRoom
        let size = CompletionPanel.size(fieldWidth: 300, rows: 3)
        #expect(size.width == 300 + 2 * room)
        #expect(size.height == CompletionListMetrics.height(rows: 3) + 2 * room)
        #expect(CompletionPanel.size(fieldWidth: 120, rows: 3).width == CompletionListMetrics.minWidth + 2 * room)
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let field = NSRect(x: 100, y: 600, width: 300, height: 24)
        let below = CompletionPanel.origin(for: size, below: field, within: screen)
        #expect(below.x == field.minX - room)
        #expect(below.y + size.height - room == field.minY - CompletionPanel.gap, "the list's top edge is just under the field")
        let low = NSRect(x: 100, y: 40, width: 300, height: 24)
        let above = CompletionPanel.origin(for: size, below: low, within: screen)
        #expect(above.y + room == low.maxY + CompletionPanel.gap, "no room below: the list opens above")
        let right = NSRect(x: 1300, y: 600, width: 300, height: 24)
        #expect(CompletionPanel.origin(for: size, below: right, within: screen).x + size.width - room <= screen.maxX)
    }

    // The arrow and Escape keys reach the list through completionKeys; CompletionListModelTests covers its answers,
    // so this drives the model directly and keeps to what needs a window: the panel, the layout and Return
    @Test func guestSuggestionsFloatOverTheEditorAndLeaveItsLayoutAlone() async throws {
        let patience = CalendarEditorProbe.patience
        let box = CalendarFormBox(form())
        let (window, hosting) = host(box)
        defer {
            window.orderOut(nil)
            window.close()
        }
        let guests = try await CalendarEditorProbe.waitForField("calendar.guestSuggestions", in: hosting)
        let others = subviews(of: NSTextField.self, in: hosting).filter { $0 !== guests }
        let frames = try await CalendarEditorProbe.settledFrames(of: others, in: hosting)
        let size = hosting.fittingSize

        try await CalendarEditorProbe.type("da", into: guests, in: window)
        let panel = try await CalendarEditorProbe.shownPanel(of: window)
        let list = try #require(panel.list)
        #expect(list.items.count == 6)
        #expect(panel.parent === window, "the list is a child panel, not part of the form")
        #expect(hosting.fittingSize == size, "the list floats; the editor keeps its height")
        #expect(CalendarEditorProbe.frames(of: others, in: hosting) == frames, "no other field moved")
        let field = window.convertToScreen(guests.convert(guests.bounds, to: nil))
        #expect(panel.frame.maxY - CompletionPanel.shadowRoom <= field.minY, "the list hangs under the field")
        #expect(panel.frame.height == CompletionPanel.size(fieldWidth: field.width, rows: 6).height)

        #expect(list.handle(.down) == .moved && list.cursor == 1)
        #expect(list.handle(.escape) == .dismissed)
        try await until(timeout: patience) { CalendarEditorProbe.panel(of: window) == nil }
        #expect(OverlayFocusKeeper.control(of: window.firstResponder) === guests, "Escape closed only the list")

        try await CalendarEditorProbe.type("dan", into: guests, in: window)
        _ = try await CalendarEditorProbe.shownPanel(of: window)
        #expect(list.selected?.email == "dana@example.com", "typing on starts again at the top row")
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertNewline(nil)
        try await until(timeout: patience) { box.form.guests.count == 1 }
        #expect(box.form.guests.first?.email == "dana@example.com", "Return added the highlighted person")
        try await until(timeout: patience) { CalendarEditorProbe.panel(of: window) == nil }

        try await CalendarEditorProbe.type("dan", into: guests, in: window)
        let again = try await CalendarEditorProbe.shownPanel(of: window)
        #expect(again.list?.items.contains { $0.email == "dana@example.com" } == false, "a guest already added is not offered")
    }

    @Test func returnInTheNotesStartsANewLineAndTheAreaOpens() async throws {
        let patience = CalendarEditorProbe.patience
        let box = CalendarFormBox(form())
        let (window, hosting) = host(box)
        defer {
            window.orderOut(nil)
            window.close()
        }
        try await until(timeout: patience) {
            hosting.layoutSubtreeIfNeeded()
            return CalendarEditorProbe.textEditors(in: hosting).count == 1
        }
        let notes = try #require(CalendarEditorProbe.textEditors(in: hosting).first)
        let resting = notes.enclosingScrollView?.frame.height ?? notes.frame.height
        try await CalendarEditorProbe.typeLines(["Agenda", "Budget", "Next steps", "Owners"], into: notes, in: window)
        try await until(timeout: patience) { box.form.notes == "Agenda\nBudget\nNext steps\nOwners" }
        try await until(timeout: patience) {
            hosting.layoutSubtreeIfNeeded()
            return (notes.enclosingScrollView?.frame.height ?? 0) > resting * 2
        }
    }

    @Test func theMeetFieldSuggestsPeopleAndReturnOpensTheEventWithThem() async throws {
        let (environment, now) = CalendarWindowSweep.environment()
        let model = try #require(environment.calendarWindow)
        let sidebar = try #require(environment.calendarSidebar)
        model.now = { now }
        sidebar.now = { now }
        await model.open(.week, source: .keyboard)
        let patience = CalendarEditorProbe.patience
        try await until(timeout: patience) { model.state == .loaded }
        let prefix = try await CalendarEditorProbe.contactPrefix(sidebar)
        let expected = try #require(await sidebar.guestSuggestions(prefix).first)

        let theme = ResolvedTheme.light
        let hosting = NSHostingView(rootView: AnyView(CalendarRightPanel(model: model, router: environment.router)
            .environment(\.theme, theme).frame(height: 760)))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 320, height: 760), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        let meet = try await CalendarEditorProbe.waitForField("calendar.window.meetSuggestions", in: hosting)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        try await CalendarEditorProbe.type(prefix, into: meet, in: window)
        let panel = try await CalendarEditorProbe.shownPanel(of: window)
        #expect(panel.list?.selected == expected)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize == size, "the list floats over the sidebar")

        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertNewline(nil)
        try await until(timeout: patience) {
            sidebar.draft?.attendees.contains { $0.email.lowercased() == expected.email.lowercased() } == true
        }
        try await until(timeout: patience) { CalendarEditorProbe.panel(of: window) == nil }
        sidebar.cancelDraft()
        await model.close()
    }
}
