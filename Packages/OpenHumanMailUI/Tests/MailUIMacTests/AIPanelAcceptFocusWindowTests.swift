import AppKit
import MailFeatures
@testable import MailUI
import OpenHumanAI
import OpenHumanAITesting
import Testing
@testable import MailUIMac

/// The ⌘J panel shows "Accept ↵" once the AI has written its suggestion, so Return must reach it: the field keeps the
/// keyboard while the model works and gets it back when the suggestion is ready.
@MainActor
@Suite(.serialized) struct AIPanelAcceptFocusWindowTests {
    static func written(_ name: String) async throws -> (OneSuggestionStage, ComposerTextView, AIComposerModel) {
        // Why: a real model takes a while, and while it writes the panel shows "One moment…" instead of the field
        let slow = ScriptedProvider(displayName: "Apple on-device model") { request, _ in
            let response = FakeAIProvider.cannedScript(request)
            guard request.task == .rewrite, case .text(let text, _, _) = response else { return response }
            return .text(text, chunkSize: 4, delay: .milliseconds(60))
        }
        let stage = try await OneSuggestionStage.make(busy: false, frameName: "dev.openhuman.tests.ai-accept-\(name)",
                                                      provider: slow)
        do {
            try await stage.open()
            #expect(stage.router.perform(.reply))
            let body = try await stage.body()
            let composer = try await stage.w.inlineComposer()
            try await until { body.window?.firstResponder === body }
            body.insertText("thx c u fri", replacementRange: NSRange(location: NSNotFound, length: 0))
            let center = try #require(stage.center)
            let panel = try #require(center.togglePanel(composer.session))
            try await until { Self.fieldHasFocus(stage, composer: composer, body: body) }
            panel.instruction = "Make it friendlier"
            Self.press(stage, characters: "\r", keyCode: 36)
            try await until { panel.phase == .working }
            stage.w.window.contentView?.layoutSubtreeIfNeeded()
            try await until { panel.phase == .done }
            return (stage, body, panel)
        } catch {
            stage.close()
            throw error
        }
    }

    static func fieldHasFocus(_ stage: OneSuggestionStage, composer: NSView, body: ComposerTextView) -> Bool {
        stage.w.window.contentView?.layoutSubtreeIfNeeded()
        guard let responder = stage.w.window.firstResponder as? NSView, responder !== body else { return false }
        return responder.isDescendant(of: composer)
    }

    static func press(_ stage: OneSuggestionStage, characters: String, keyCode: UInt16) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 100,
                                           windowNumber: stage.w.window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode) else { return }
        if stage.w.content.keyRouter.route(event) != nil { stage.w.window.sendEvent(event) }
    }

    @Test func returnAcceptsTheSuggestionOnceItIsWritten() async throws {
        let (stage, body, panel) = try await Self.written("return")
        defer { stage.close() }
        let composer = try await stage.w.inlineComposer()
        try await until { Self.fieldHasFocus(stage, composer: composer, body: body) }
        #expect(panel.canApply)
        Self.press(stage, characters: "\r", keyCode: 36)
        try await until { composer.session.aiPanel == nil }
        #expect(body.string == "Rewritten: thx c u fri")
        try await until { body.window?.firstResponder === body }
    }

    @Test func escapeDismissesTheSuggestionAndKeepsTheDraft() async throws {
        let (stage, body, _) = try await Self.written("escape")
        defer { stage.close() }
        let composer = try await stage.w.inlineComposer()
        try await until { Self.fieldHasFocus(stage, composer: composer, body: body) }
        Self.press(stage, characters: "\u{1b}", keyCode: 53)
        try await until { composer.session.aiPanel == nil }
        #expect(body.string == "thx c u fri")
        try await until { body.window?.firstResponder === body }
    }

    @Test func typingAfterTheSuggestionEditsTheInstruction() async throws {
        let (stage, body, panel) = try await Self.written("typing")
        defer { stage.close() }
        let composer = try await stage.w.inlineComposer()
        try await until { Self.fieldHasFocus(stage, composer: composer, body: body) }
        let field = try #require(stage.w.window.firstResponder as? NSTextView)
        field.insertText("shorter", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await until { panel.editInstruction == "shorter" }
        #expect(panel.instruction == "Make it friendlier")
        #expect(Self.fieldHasFocus(stage, composer: composer, body: body))
        #expect(body.string == "thx c u fri")
    }
}
