import AppKit
import MailActions
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
@Suite(.serialized)
struct ComposerNativeWindowTests {
    // smartSearch off: its async read would move the header at a moment no test controls
    static let flags = FeatureFlags.atLaunch.with(.smartSearch, false)

    private func reply(in w: InlineReplyWindow) async throws -> (InlineComposerView, ComposerTextView) {
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        try await until(timeout: CalendarEditorProbe.patience) {
            subviews(of: ComposerTextView.self, in: composer).first != nil
        }
        return (composer, try #require(subviews(of: ComposerTextView.self, in: composer).first))
    }

    @Test func anAtMentionListFloatsUnderTheBodyAndTheCardKeepsItsSize() async throws {
        let patience = CalendarEditorProbe.patience
        let w = try await InlineReplyWindow.make(frameName: "dev.openhuman.tests.composer-native-mention",
                                                 featureFlags: Self.flags)
        defer { w.close() }
        let (composer, editor) = try await reply(in: w)
        let root = try #require(w.window.contentView)
        let session = composer.session
        let prefix = try await ComposerSuggestionProbe.contactPrefix(w.environment, session)
        try await CalendarEditorProbe.typeLines(["Thanks "], into: editor, in: w.window)
        let before = try await CalendarEditorProbe.settledFrames(of: [composer, editor], in: root)

        editor.insertText("@" + prefix, replacementRange: editor.selectedRange())
        try await until(timeout: patience) { session.mentionPicker?.rows.isEmpty == false }
        let panel = try await CalendarEditorProbe.shownPanel(of: w.window)
        #expect(panel.parent === w.window, "the list is a child panel, not part of the card")
        #expect(panel.list?.items == session.mentionPicker?.rows.map(\.address))
        #expect(CalendarEditorProbe.anchor("composer.mention", in: root) != nil)
        #expect(CalendarEditorProbe.frames(of: [composer, editor], in: root) == before,
                "the card keeps its height and the body its place while the list is open")

        session.dismissMention()
        try await until(timeout: patience) { CalendarEditorProbe.panel(of: w.window)?.isVisible != true }
        #expect(session.isOpen && editor.string.contains("@" + prefix), "Escape closed only the list")
    }

    @Test func aNoticeFloatsAboveTheSendBarAndNothingMoves() async throws {
        let w = try await InlineReplyWindow.make(frameName: "dev.openhuman.tests.composer-native-notice",
                                                 featureFlags: Self.flags)
        defer { w.close() }
        let (composer, editor) = try await reply(in: w)
        let root = try #require(w.window.contentView)
        let session = composer.session
        let before = try await CalendarEditorProbe.settledFrames(of: [composer, editor], in: root)

        session.notice = ComposeSession.Notice(.error, "Couldn't send. The connection dropped; your draft is kept.",
                                               offersSendAgain: true)
        let shown = try await CalendarEditorProbe.settledFrames(of: [composer, editor], in: root)
        #expect(shown == before, "the notice floats; the card, the text and the Send bar stay where they were")

        session.notice = nil
        let gone = try await CalendarEditorProbe.settledFrames(of: [composer, editor], in: root)
        #expect(gone == before)
    }

    @Test func fromIsABorderlessPopUpAndItsReasonStaysOnTheRow() async throws {
        let w = try await InlineReplyWindow.make(frameName: "dev.openhuman.tests.composer-native-from",
                                                 featureFlags: Self.flags)
        defer { w.close() }
        let (composer, editor) = try await reply(in: w)
        let root = try #require(w.window.contentView)
        let session = composer.session
        try #require(session.offersFromPicker, "the synthetic work account has a second address")
        try await until(timeout: CalendarEditorProbe.patience) {
            subviews(of: NSPopUpButton.self, in: composer).contains { $0.accessibilityIdentifier() == "composer.from" }
        }
        let popUp = try #require(subviews(of: NSPopUpButton.self, in: composer)
            .first { $0.accessibilityIdentifier() == "composer.from" })
        #expect(!popUp.isBordered, "no bezel in the header row")
        #expect(popUp.accessibilityLabel() == "From")
        #expect(popUp.numberOfItems == session.fromChoices.count)

        let alias = try #require(session.fromChoices.first { $0 != session.from })
        let before = try await CalendarEditorProbe.settledFrames(of: [editor], in: root)
        session.chooseFrom(alias)
        try await until(timeout: CalendarEditorProbe.patience) { session.showsFromReason }
        let after = try await CalendarEditorProbe.settledFrames(of: [editor], in: root)
        #expect(after == before, "the reason sits beside the address, so the body keeps its place")
        try await until(timeout: CalendarEditorProbe.patience) { popUp.titleOfSelectedItem == alias.display }
    }
}
