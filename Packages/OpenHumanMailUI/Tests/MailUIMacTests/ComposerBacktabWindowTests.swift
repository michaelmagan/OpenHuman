import AppKit
import MailActions
import MailUI
import SwiftUI
import Testing
@testable import MailUIMac

/// ⇥ goes from the To field to the body, so ⇧⇥ in the body goes back to the field before it.
@MainActor
@Suite(.serialized)
struct ComposerBacktabWindowTests {
    @Test func shiftTabInTheBodyGoesBackToTheFieldBeforeIt() async throws {
        let w = try await InlineReplyWindow.make(frameName: "dev.openhuman.tests.composer-backtab", exclusive: true)
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        try await until { subviews(of: ComposerTextView.self, in: composer).first != nil }
        let body = try #require(subviews(of: ComposerTextView.self, in: composer).first)
        #expect(w.window.makeFirstResponder(body))

        body.insertBacktab(nil)

        let field = try #require(w.window.firstResponder as? NSTextView, "a field has the keys")
        #expect(field !== body)
        #expect(field.isFieldEditor, "the field before the body, not the body")
        let owner = try #require(field.delegate as? NSView)
        #expect(owner.isDescendant(of: composer), "a field of this composer")
        #expect(body.string.contains("\t") == false)
    }
}
