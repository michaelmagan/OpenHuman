import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
@testable import MailUI
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct SearchPillWindowTests {
    static let frameName = "dev.openhuman.tests.search-pills"
    static let start = NSRange(location: 0, length: 0)

    enum Key {
        static let backspace = ("\u{7F}", UInt16(51))
        static let forwardDelete = ("\u{F728}", UInt16(117))
        static let left = ("\u{F702}", UInt16(123))
        static let right = ("\u{F703}", UInt16(124))
        static let escape = ("\u{1B}", UInt16(53))
        static let selectAll = ("a", UInt16(0))
    }

    private func wait(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        do {
            try await until(condition)
        } catch {
            Issue.record("timed out waiting for \(what)")
            throw error
        }
    }

    /// Sends a key the way the window gets it: the key router first, then the field editor. True when the router took it.
    @discardableResult
    private func press(_ key: (String, UInt16), modifiers: NSEvent.ModifierFlags = [], in w: InlineReplyWindow) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 100,
                                     windowNumber: w.window.windowNumber, context: nil, characters: key.0,
                                     charactersIgnoringModifiers: key.0, isARepeat: false, keyCode: key.1)!
        guard w.content.keyRouter.route(event) != nil else { return true }
        w.window.sendEvent(event)
        return false
    }

    /// Opens search on `text`, waits for its pills and leaves the caret at the start of the text after them.
    private func open(_ text: String, in w: InlineReplyWindow) async throws -> (NSTextField, NSTextView) {
        let model = w.environment.overlays.search
        model.text = text
        #expect(w.router.perform(.search))
        try await wait("the search field") { model.isOpen && w.content.searchField(in: w.window) != nil }
        let field = try #require(w.content.searchField(in: w.window))
        try await wait("the field to take the keys") { OverlayFocusKeeper.control(of: w.window.firstResponder) === field }
        let rest = SearchQueryTokens.split(text).rest
        try await wait("the pills") {
            w.window.contentView?.layoutSubtreeIfNeeded()
            w.window.displayIfNeeded()
            return field.stringValue == rest
        }
        let editor = try #require(w.window.firstResponder as? NSTextView)
        #expect(editor.delegate === field)
        editor.setSelectedRange(Self.start)
        return (field, editor)
    }

    private func hasTheKeys(_ field: NSTextField, in w: InlineReplyWindow) -> Bool {
        OverlayFocusKeeper.control(of: w.window.firstResponder) === field
    }

    @Test func backspaceSelectsThePillThenRemovesItRerunsTheSearchAndUndoBringsItBack() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let model = w.environment.overlays.search
        let query = "subject:re from:nobody@example.com "
        let (field, editor) = try await open(query, in: w)
        #expect(field.stringValue.isEmpty, "both operators are pills")
        try await wait("the search for both pills") { model.shownQuery == "subject:re from:nobody@example.com" }

        #expect(press(Key.backspace, in: w), "⌫ with nothing before the caret is the pills'")
        #expect(model.selectedPills == [1], "the first ⌫ selects the from: pill")
        #expect(model.text == query, "and removes nothing yet")
        #expect(press(Key.backspace, in: w))
        #expect(model.text == "subject:re ", "the second ⌫ removes it")
        #expect(model.selectedPills.isEmpty)
        #expect(hasTheKeys(field, in: w), "the field keeps the keys")
        try await wait("the results without it") {
            model.shownQuery == "subject:re" && w.router.list?.state == .loaded && w.router.list?.rows.isEmpty == false
        }
        #expect(hasTheKeys(field, in: w))
        #expect(w.environment.undo?.canUndo != true, "no mail was changed")

        let undo = try #require(editor.undoManager)
        undo.undo()
        #expect(model.text == query, "Undo puts the pill back")
        try await wait("the search for both pills again") { model.shownQuery == "subject:re from:nobody@example.com" }
    }

    @Test func arrowsWalkAcrossThePillsAndForwardDeleteRemovesTheOneAfterTheCaret() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let model = w.environment.overlays.search
        let (field, editor) = try await open("subject:re in:anywhere budget", in: w)
        #expect(field.stringValue == "budget")

        #expect(press(Key.left, in: w))
        #expect(model.selectedPills == [1], "← at the start of the text selects the pill before it")
        #expect(press(Key.left, in: w))
        #expect(model.selectedPills == [0])
        #expect(press(Key.left, in: w))
        #expect(model.selectedPills == [0], "the first pill is the end")
        #expect(press(Key.right, in: w))
        #expect(model.selectedPills == [1])
        #expect(press(Key.right, in: w))
        #expect(model.selectedPills.isEmpty && editor.selectedRange() == Self.start, "→ goes back to the text")
        #expect(!press(Key.right, in: w), "→ in the text is the text's")
        #expect(editor.selectedRange() == NSRange(location: 1, length: 0))

        editor.setSelectedRange(Self.start)
        #expect(press(Key.left, in: w))
        #expect(press(Key.left, in: w))
        #expect(model.selectedPills == [0])
        #expect(press(Key.forwardDelete, in: w))
        #expect(model.text == "in:anywhere budget", "⌦ removes the selected pill")
        #expect(field.stringValue == "budget", "the text after the pills stays")
        #expect(hasTheKeys(field, in: w))
    }

    @Test func selectAllThenBackspaceClearsThePillsAndTheText() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let model = w.environment.overlays.search
        let query = "subject:re has:attachment budget"
        let (field, editor) = try await open(query, in: w)

        #expect(press(Key.selectAll, modifiers: .command, in: w))
        #expect(model.selectedPills == [0, 1], "⌘A takes the pills")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 6), "and the text")
        #expect(press(Key.backspace, in: w))
        #expect(model.text.isEmpty)
        #expect(field.stringValue.isEmpty)
        #expect(hasTheKeys(field, in: w))

        try #require(editor.undoManager).undo()
        #expect(model.text == query, "Undo puts everything back")
    }

    @Test func escapeLetsGoOfTheSelectionAndKeepsThePills() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let model = w.environment.overlays.search
        let (field, _) = try await open("subject:re ", in: w)

        #expect(press(Key.backspace, in: w))
        #expect(model.selectedPills == [0])
        #expect(press(Key.escape, in: w), "Esc with a pill selected is the pills'")
        #expect(model.selectedPills.isEmpty, "it lets go of the pill")
        #expect(model.text == "subject:re ", "and keeps it")
        #expect(model.isOpen)
        #expect(hasTheKeys(field, in: w))
        #expect(!press(Key.escape, in: w), "with nothing selected Esc goes on to the field")
    }

    @Test func manyPillsGiveWayAndTheTypedTextStaysInView() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let query = "from:dana subject:\"q4 budget\" -label:Receipts in:anywhere has:attachment larger:5M e"
        let (field, _) = try await open(query, in: w)
        #expect(field.stringValue == "e")
        w.window.contentView?.layoutSubtreeIfNeeded()
        w.window.displayIfNeeded()
        let window = try #require(field.window)
        let shown = field.convert(field.bounds, to: nil)
        #expect(shown.minX >= 0 && shown.maxX <= window.frame.width, "the text is inside the window: \(shown)")
        #expect(shown.width >= SearchFieldView.minTextWidth - 8, "with room for the caret and what is typed: \(shown)")
    }

    @Test func aClickedPillTakesTheKeysAndBackspaceRemovesIt() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let model = w.environment.overlays.search
        let (field, _) = try await open("subject:re in:anywhere budget", in: w)
        try await wait("the results") { model.shownQuery == "subject:re in:anywhere budget" }
        #expect(model.focusResults())
        try await wait("the results to take the keys") {
            if w.window.firstResponder === w.content.tableView { return true }
            // With no results ↓ leaves the keys in the field; a click in the list still takes them
            if let list = w.router.list, list.state != .loading, list.rows.isEmpty {
                w.window.makeFirstResponder(w.content.tableView)
            } else {
                _ = model.focusResults()
            }
            return false
        }

        SearchPills.select(0, in: model)
        #expect(model.selectedPills == [0])
        try await wait("the field to take the keys at the pills") {
            hasTheKeys(field, in: w) && (w.window.firstResponder as? NSTextView)?.selectedRange() == Self.start
        }
        #expect(press(Key.backspace, in: w))
        #expect(model.text == "in:anywhere budget", "⌫ removes the clicked pill")
        #expect(field.stringValue == "budget")
    }

    @Test func thePillsRemoveControlTakesItOutKeepsTheKeysAndUndoes() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let model = w.environment.overlays.search
        let query = "subject:re from:nobody@example.com "
        let (field, editor) = try await open(query, in: w)
        try await wait("the search for both pills") { model.shownQuery == "subject:re from:nobody@example.com" }

        SearchPills.remove(1, from: model, undoManager: editor.undoManager)
        #expect(model.text == "subject:re ")
        try await wait("the results without it") {
            model.shownQuery == "subject:re" && w.router.list?.state == .loaded && w.router.list?.rows.isEmpty == false
        }
        try await wait("the field to keep the keys") { hasTheKeys(field, in: w) }

        try #require(editor.undoManager).undo()
        #expect(model.text == query, "Undo puts the pill back")
    }
}
