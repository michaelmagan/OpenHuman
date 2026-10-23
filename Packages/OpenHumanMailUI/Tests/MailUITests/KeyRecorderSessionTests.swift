#if os(macOS)
import AppKit
import MailActions
import MailFeatures
import Testing
@testable import MailUI

@MainActor
@Suite(.serialized) struct KeyRecorderSessionTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private func recording() -> (KeymapEditorModel, KeyRecorderSession) {
        let editor = KeymapEditorModel(registry: ActionRegistry(), store: InMemoryKeymapStore())
        editor.startRecording(.markDone)
        return (editor, KeyRecorderSession(editor: editor))
    }

    @Test func onlyKeysTypedInTheSettingsWindowAreRecorded() {
        let settings = window(), composer = window()
        defer { settings.close(); composer.close() }
        let (editor, session) = recording()
        session.start(in: settings)
        defer { session.stop() }
        #expect(session.takes(windowNumber: settings.windowNumber))
        #expect(!session.takes(windowNumber: composer.windowNumber), "typing in a composer is left to it")
        #expect(!session.takes(windowNumber: 0), "a key with no window is left alone")
        #expect(editor.recording == .markDone)
    }

    @Test func keysThatComposeTextAreLeftToTheField() throws {
        let settings = window()
        defer { settings.close() }
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        settings.contentView?.addSubview(field)
        #expect(settings.makeFirstResponder(field))
        let (_, session) = recording()
        session.start(in: settings)
        defer { session.stop() }
        field.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(field.hasMarkedText())
        #expect(!session.takes(windowNumber: settings.windowNumber), "an input method's keys reach the field")
        field.unmarkText()
        #expect(session.takes(windowNumber: settings.windowNumber))
    }

    @Test func recordingEndsWhenTheSettingsWindowIsNoLongerKey() {
        let settings = window()
        defer { settings.close() }
        let (editor, session) = recording()
        session.start(in: settings)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: settings)
        #expect(editor.recording == nil)
        #expect(!session.takes(windowNumber: settings.windowNumber), "nothing is recorded afterwards")
    }

    @Test func withoutAWindowNothingIsRecorded() {
        let other = window()
        defer { other.close() }
        let (editor, session) = recording()
        session.start(in: nil)
        defer { session.stop() }
        #expect(!session.takes(windowNumber: other.windowNumber))
        #expect(editor.recording == .markDone, "the row still offers Cancel")
    }
}
#endif
