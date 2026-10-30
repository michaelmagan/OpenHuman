import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
enum ComposerSuggestionProbe {
    static func identifier(_ kind: RecipientFieldModel.Kind) -> String { "compose.recipientSuggestions.\(kind.rawValue)" }

    // The anchor spans the chips and the typing field of one row, so the row's field is the one inside it
    static func field(_ kind: RecipientFieldModel.Kind, in root: NSView) -> NSTextField? {
        root.layoutSubtreeIfNeeded()
        guard let anchor = CalendarEditorProbe.anchor(identifier(kind), in: root) else { return nil }
        let frame = anchor.convert(anchor.bounds, to: nil)
        return subviews(of: NSTextField.self, in: root).first { field in
            field.isEditable && field.window != nil && field.convert(field.bounds, to: nil).intersects(frame)
        }
    }

    static func waitForField(_ kind: RecipientFieldModel.Kind, in root: NSView) async throws -> NSTextField {
        try await until(timeout: CalendarEditorProbe.patience) { field(kind, in: root) != nil }
        return try #require(field(kind, in: root))
    }

    static func contactPrefix(_ environment: AppEnvironment, _ session: ComposeSession) async throws -> String {
        let found = try await environment.data.contactSuggestions(session.account.id, prefix: "",
                                                                  limit: RecipientFieldModel.maxSuggestions)
        let top = try #require(found.first, "the synthetic corpus has contacts")
        return String(top.email.prefix(2))
    }
}

@MainActor
@Suite(.serialized)
struct ComposerFloatingPartsTests {
    @Test func recipientSuggestionsFloatOverTheCardAndNothingUnderTheFieldMoves() async throws {
        let patience = CalendarEditorProbe.patience
        let w = try await InlineReplyWindow.make(frameName: "dev.openhuman.tests.recipient-float")
        defer { w.close() }
        let compose = w.environment.compose
        #expect(w.router.perform(.compose))
        try await until(timeout: patience) { compose.windowSession?.placement == .modal }
        let session = try #require(compose.windowSession)
        await session.settle()
        let root = try #require(w.window.contentView)
        let field = try await ComposerSuggestionProbe.waitForField(.to, in: root)
        let body = try #require(w.editors.first)
        let before = try await CalendarEditorProbe.settledFrames(of: [body], in: root)
        let prefix = try await ComposerSuggestionProbe.contactPrefix(w.environment, session)

        try await CalendarEditorProbe.type(prefix, into: field, in: w.window)
        let panel = try await CalendarEditorProbe.shownPanel(of: w.window)
        #expect(panel.parent === w.window, "the list is a child panel, not part of the card")
        #expect(panel.list?.items == session.to.suggestions)
        #expect(CalendarEditorProbe.frames(of: [body], in: root) == before, "From, Subject and the body stay where they were")
        let row = try #require(CalendarEditorProbe.anchor(ComposerSuggestionProbe.identifier(.to), in: root))
        let rowOnScreen = w.window.convertToScreen(row.convert(row.bounds, to: nil))
        #expect(panel.frame.maxY - CompletionPanel.shadowRoom <= rowOnScreen.minY, "the list hangs under the row")
        #expect(abs(panel.frame.minX + CompletionPanel.shadowRoom - rowOnScreen.minX) < 1, "aligned with the chips")

        if session.to.suggestions.count > 1 {
            session.to.moveSuggestion(by: 1)
            try await until(timeout: patience) { panel.list?.cursor == 1 }
            panel.list?.select(0)
            try await until(timeout: patience) { session.to.suggestionCursor == 0 }
        }
        session.to.dismissSuggestions()
        try await until(timeout: patience) { CalendarEditorProbe.panel(of: w.window)?.isVisible != true }
        #expect(session.isOpen && session.to.text == prefix, "Escape closed only the list")

        // Different text, so the field reports an edit and looks people up again
        let shorter = String(prefix.prefix(1))
        try await CalendarEditorProbe.type(shorter, into: field, in: w.window)
        let again = try await CalendarEditorProbe.shownPanel(of: w.window)
        let chosen = try #require(again.list?.selected)
        let editor = try #require(w.window.firstResponder as? NSTextView)
        editor.insertNewline(nil)
        try await until(timeout: patience) { session.to.tokens.contains(chosen) }
        try await until(timeout: patience) { CalendarEditorProbe.panel(of: w.window)?.isVisible != true }
    }

    @Test func theAITipShowsOnAnEmptyDraftAndHidesOnlyWhileThePanelIsOpen() async throws {
        let patience = CalendarEditorProbe.patience
        let center = AICenter.make(registry: ProviderRegistry(providers: [ScriptedProvider()]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore(
                                       AISettings(draftReplies: .onDeviceAuto))))
        let w = try await InlineReplyWindow.make(frameName: "dev.openhuman.tests.ai-tip", ai: center)
        defer { w.close() }
        let compose = w.environment.compose
        #expect(w.router.perform(.compose))
        try await until(timeout: patience) { compose.windowSession?.placement == .modal }
        let session = try #require(compose.windowSession)
        await session.settle()
        try await until(timeout: patience) { !w.editors.isEmpty }
        let body = try #require(w.editors.first)
        let tip = ComposerEditor.placeholder(for: .new)
        try await until(timeout: patience) { body.placeholder == tip }
        #expect(session.to.tokens.isEmpty && session.subject.isEmpty, "a blank new message still shows the tip")
        let panel = try #require(center.togglePanel(session))
        try await until(timeout: patience) { session.aiPanel === panel && body.placeholder.isEmpty }
        panel.close()
        try await until(timeout: patience) { session.aiPanel == nil && body.placeholder == tip }
    }
}
