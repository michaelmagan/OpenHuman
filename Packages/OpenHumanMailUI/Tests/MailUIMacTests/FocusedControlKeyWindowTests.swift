import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
@testable import MailUI
import Testing
@testable import MailUIMac

/// A control the Tab loop focused inside a conversation answers ↵ itself; the conversation's keys (↵ replies) do not
/// reach past it.
@MainActor
@Suite(.serialized) struct FocusedControlKeyWindowTests {
    static let frameName = "dev.openhuman.tests.focused-control-keys"

    static func hasFile(_ message: MessageSummary) -> Bool {
        message.attachments.contains { $0.contentID == nil && InviteCenter.calendarPart(of: [$0]) == nil }
    }

    @Test func returnOnAFocusedAttachmentTileOpensItAndStartsNoReply() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, exclusive: true)
        defer { w.close() }
        let thread = try #require(FakeCorpus.small.threads.first { $0.detail.messages.contains(where: Self.hasFile) },
                                  "the small corpus has a conversation with a file")
        let model = try await w.open(thread.row.id)
        var opened: [URL] = []
        w.reader.openFile = { opened.append($0) }
        let message = try #require(model.messages.last { Self.hasFile($0.summary) }?.id)
        model.expandAll()
        try await until { w.reader.messageViews[message]?.attachmentsStrip != nil }
        w.window.contentView?.layoutSubtreeIfNeeded()
        let tile = try #require(w.reader.messageViews[message]?.attachmentsStrip?.tiles.first)
        #expect(w.window.makeFirstResponder(tile))
        let returnKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.window.windowNumber, context: nil, characters: "\r",
                                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        let passed = try #require(w.content.keyRouter.route(returnKey), "the key router leaves ↵ to the tile")
        w.window.firstResponder?.keyDown(with: passed)
        try await until(timeout: .seconds(15)) { !opened.isEmpty }
        #expect(w.environment.compose.sessions.isEmpty, "↵ on the tile opens the file, it does not reply")
    }
}
