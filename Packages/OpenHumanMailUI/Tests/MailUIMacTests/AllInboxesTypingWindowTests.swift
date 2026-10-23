import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct AllInboxesTypingWindowTests {
    static let frameName = "dev.openhuman.tests.all-inboxes-typing"

    private func make() async throws -> InlineReplyWindow {
        let environment = AppEnvironment.fake(
            corpus: .rich(threadCount: 40, now: Date(timeIntervalSince1970: 1_791_000_000)),
            options: .init(remoteAck: .immediate), notices: NoticeCenter(autoExpire: false))
        return try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true,
                                                exclusive: true, environment: environment)
    }

    private func wait(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        do {
            try await until(condition)
        } catch {
            Issue.record("timed out waiting for \(what)")
            throw error
        }
    }

    private func open(in w: InlineReplyWindow) async throws -> (AllInboxesModel, NSTextField) {
        try await wait("both accounts") { w.router.accounts.count == 2 }
        #expect(w.router.goToAllInboxes())
        let model = try #require(w.router.unifiedInbox)
        try await wait("All Inboxes to load with a cursor") {
            !model.isLoading && !model.rows.isEmpty && model.cursor != nil
        }
        try await wait("the All Inboxes search field") { searchField(in: w) != nil }
        try await wait("the All Inboxes field to take the keys") {
            guard let field = searchField(in: w) else { return false }
            if hasTheKeys(field, in: w) { return true }
            w.window.makeFirstResponder(field)
            return false
        }
        let field = try #require(searchField(in: w))
        return (model, field)
    }

    /// The All Inboxes field: the one editable field drawn over the mail column, outside the AppKit list and reader.
    private func searchField(in w: InlineReplyWindow) -> NSTextField? {
        guard let root = w.window.contentView else { return nil }
        let fields = subviews(of: NSTextField.self, in: root).filter {
            $0.isEditable && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && !$0.isDescendant(of: w.content.view)
        }
        if let labelled = fields.first(where: { $0.accessibilityLabel() == "Search All Inboxes" }) { return labelled }
        return fields.count == 1 ? fields.first : nil
    }

    private func hasTheKeys(_ field: NSTextField, in w: InlineReplyWindow) -> Bool {
        OverlayFocusKeeper.control(of: w.window.firstResponder) === field
    }

    private func type(_ text: String, into field: NSTextField, in w: InlineReplyWindow) throws {
        for character in text {
            #expect(try !typingKey(String(character), in: w), "the router passes every typed key on")
            #expect(hasTheKeys(field, in: w))
        }
    }

    @Test func lettersOnlyFilterTheInboxes() async throws {
        let w = try await make()
        defer { w.close() }
        let (model, field) = try await open(in: w)
        let cursor = model.cursor
        let rows = model.rows.map(\.id)
        try type("jessie lake", into: field, in: w)
        try await wait("the typed filter") { model.query == "jessie lake" }
        await w.environment.actions.lastTask?.value
        #expect(hasTheKeys(field, in: w))
        #expect(model.cursor == cursor || model.rows.contains { $0.id == model.cursor }
                || (model.cursor == nil && model.rows.isEmpty))
        #expect(model.rows.allSatisfy { rows.contains($0.id) })
        #expect(w.environment.undo?.canUndo != true)
        #expect(!w.environment.notices.toasts.contains { $0.message == "Marked done" || $0.actionTitle == "Undo" })
        #expect(!w.environment.overlays.isShowing)
        #expect(w.router.unifiedInbox != nil)
        model.setQuery("")
        #expect(model.rows.map(\.id) == rows, "filtering changed no mail")
    }

    @Test func returnHandsTheKeysToTheListAndItsShortcutsStillWork() async throws {
        let w = try await make()
        defer { w.close() }
        let (model, field) = try await open(in: w)
        let word = try #require(model.rows.first?.thread.subject.lowercased()
            .split(whereSeparator: { !$0.isLetter }).first.map(String.init))
        try type(word, into: field, in: w)
        try await wait("the filter “\(word)”") { model.query == word && !model.rows.isEmpty }
        #expect(try !typingKey("\r", in: w), "Return reaches the field's submit handler")
        try await wait("Return to take the keys from the field") { !hasTheKeys(field, in: w) }
        #expect(w.router.unifiedInbox != nil)
        #expect(w.router.reader == nil)
        #expect(w.environment.undo?.canUndo != true)

        // Clear the filter with the model so the list has room to move its cursor.
        model.setQuery("")
        try await wait("the unfiltered rows") { model.rows.count >= 2 }
        model.setCursor(model.rows[0].id)
        let next = model.rows[1].id
        _ = try typingKey("j", in: w)
        try await wait("J to move the cursor in the list") { model.cursor == next }
        _ = try typingKey("e", in: w)
        try await wait("E to mark the cursor row done") {
            w.environment.undo?.canUndo == true || !model.rows.contains { $0.id == next }
        }
        #expect(w.router.unifiedInbox != nil)
    }
}
