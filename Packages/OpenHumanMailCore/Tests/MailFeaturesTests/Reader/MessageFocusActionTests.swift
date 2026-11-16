import Foundation
import MailActions
import MailFakes
import MailModel
import MailRender
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct MessageFocusActionTests {
    private func open(_ f: ComposeFixture) async throws -> (ReaderModel, [MessageSummary]) {
        await f.loaded()
        let (thread, messages) = try await ComposeReplyTargetTests.conversation(f)
        f.router.open(thread)
        await soon { f.router.reader?.state == .loaded }
        return (try #require(f.router.reader), messages)
    }

    @Test func theMessageKeysAreActionsOfTheOpenConversation() async throws {
        let f = ComposeFixture()
        let (reader, messages) = try await open(f)
        let newest = try #require(messages.last?.id)
        let middle = messages[messages.count - 2].id
        let registry = f.env.actions
        #expect(reader.focusedMessage == newest && f.router.actionContext().focusedMessage == newest)
        #expect(registry.availability(.previousMessage, host: f.router) == .enabled)
        #expect(registry.availability(.nextMessage, host: f.router) == .disabled(.other("This is the newest message")))
        #expect(!(await f.run(.nextMessage)), "disabled at the newest: the key passes on (↓ scrolls)")
        for id in [ActionID.toggleMessage, .expandAllMessages, .toggleQuotedText] {
            #expect(registry.availability(id, host: f.router) == .enabled, "\(id)")
        }

        #expect(await f.run(.previousMessage))
        #expect(reader.focusedMessage == middle && reader.replyTarget == middle && reader.focusScrollRequest == 1)
        #expect(f.router.actionContext().focusedMessage == middle, "the reply target follows the keys")
        #expect(registry.availability(.nextMessage, host: f.router) == .enabled)
        #expect(await f.run(.nextMessage))
        #expect(reader.focusedMessage == newest && reader.focusScrollRequest == 2)
        #expect(await f.run(.expandAllMessages))
        #expect(reader.messages.filter { !$0.isExpanded }.isEmpty)
        #expect(await f.run(.toggleMessage))
        #expect(reader.message(newest)?.isExpanded == false, "o collapses the focused message")

        #expect(await f.run(.backToList))
        for id in ReaderMessageActionHandler.ids {
            #expect(registry.availability(id, host: f.router) == .hidden, "\(id) in the list")
        }
        #expect(registry.descriptor(.nextMessage)?.scopes == [.reader])
    }

    @Test func returnOpensTheSelectedMessageFirstAndRepliesOnceItIsOpen() async throws {
        let f = ComposeFixture()
        let (reader, messages) = try await open(f)
        let middle = messages[messages.count - 2].id
        #expect(await f.run(.previousMessage))
        if reader.message(middle)?.isExpanded == true { #expect(await f.run(.toggleMessage)) }
        #expect(reader.focusedMessage == middle && reader.message(middle)?.isExpanded == false)
        #expect(f.env.actions.availability(.openMessageOrReply, host: f.router) == .enabled)

        #expect(await f.run(.openMessageOrReply))
        #expect(reader.message(middle)?.isExpanded == true, "↵ on a closed message opens it")
        #expect(f.compose.windowSession == nil, "and starts no reply")

        #expect(await f.run(.openMessageOrReply))
        let reply = try #require(f.compose.windowSession)
        await reply.settle()
        #expect(reply.mode == (ActionCatalog.returnRepliesAll ? .replyAll : .reply), "↵ on an open message replies")
        #expect(reply.replyTo == middle, "to the message the keys selected")
        #expect(f.env.actions.availability(.openMessageOrReply, host: f.router) == .hidden, "the composer has ↵ now")
    }

    @Test func aFocusedComposerKeepsTheArrowAndReturnKeys() async throws {
        let f = ComposeFixture()
        let (reader, messages) = try await open(f)
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        #expect(f.router.actionContext().scope == .composer)
        for id in ReaderMessageActionHandler.ids + [.reply, .replyAll] {
            #expect(f.env.actions.availability(id, host: f.router) == .hidden, "\(id) (its ↵ too) while typing a reply")
        }
        #expect(!(await f.run(.previousMessage)) && reader.focusedMessage == messages.last?.id)
        f.compose.dockedComposerHasFocus = { _ in false }
        session.focusHandled = session.focusRequest
        #expect(f.router.actionContext().scope == .reader)
        #expect(await f.run(.previousMessage))
        #expect(reader.focusedMessage == messages[messages.count - 2].id)
    }

    @Test func replyReplyAllAndForwardAnswerTheMessageTheKeysFocused() async throws {
        let f = ComposeFixture()
        let (reader, messages) = try await open(f)
        let middle = messages[messages.count - 2]
        #expect(await f.run(.previousMessage))
        #expect(reader.focusedMessage == middle.id)

        #expect(await f.run(.reply))
        let reply = try #require(f.compose.windowSession)
        await reply.settle()
        #expect(reply.mode == .reply && reply.replyTo == middle.id && reply.replyToGmailMessageID == middle.id.gmailMessageID)
        #expect(reply.to.tokens.map(\.email) == [try #require(middle.from?.email)], "To is the focused message's sender")
        let quote = QuotePreview(quotedText: reply.quotedText, quotedHTML: reply.quotedHTML)
        #expect(quote.header.contains(try #require(middle.from?.email)) && quote.header.hasSuffix("wrote:"))
        #expect(QuoteSplit.quoteBlockCount(reply.assembledFields().bodyHTML) == 1)

        f.compose.dockedComposerHasFocus = { _ in false }
        reply.focusHandled = reply.focusRequest
        #expect(await f.run(.forward))
        let forward = try #require(f.compose.windowSession)
        await forward.settle()
        #expect(forward !== reply && forward.mode == .forward && forward.replyTo == middle.id)
        #expect(forward.to.tokens.isEmpty, "a forward starts with no recipient")
        let middleSender = try #require(middle.from?.email)
        #expect(forward.quotedHTML.contains("From: ") && forward.quotedHTML.contains(middleSender),
                "the forwarded message is the focused one")

        forward.focusHandled = forward.focusRequest
        #expect(await f.run(.nextMessage))
        let newest = try #require(messages.last)
        #expect(await f.run(.replyAll))
        let all = try #require(f.compose.windowSession)
        await all.settle()
        #expect(all.mode == .replyAll && all.replyTo == newest.id)
        #expect(f.compose.sessions.count == 1, "one reply at a time in the conversation")
    }

    @Test func thePaletteAndTheShortcutSheetListTheMessageKeys() async throws {
        let f = ComposeFixture()
        _ = try await open(f)
        let palette = f.env.actions.palette
        palette.open(host: f.router)
        palette.query = "previous message"
        let row = try #require(palette.rows.first { $0.action == .previousMessage })
        #expect(row.keycaps == ["P"], "the palette shows the first key; the sheet shows both")
        palette.query = "next message"
        #expect(!palette.rows.contains { $0.action == .nextMessage }, "only what can run: the newest is focused")
        #expect(palette.perform(.previousMessage))
        #expect(f.router.reader?.focusScrollRequest == 1)
        palette.close()

        let sheet = ShortcutHelpModel(descriptors: f.env.actions.descriptors)
        let navigate = try #require(sheet.sections.first { $0.title == "Navigate" })
        let lines = Dictionary(uniqueKeysWithValues: navigate.lines.map { ($0.action, $0.keys) })
        #expect(lines[.nextMessage] == ["N", "↓"] && lines[.previousMessage] == ["P", "↑"])
        #expect(lines[.toggleMessage] == ["O"] && lines[.expandAllMessages] == ["⇧O"])
        #expect(lines[.toggleQuotedText] == ["."] && lines[.showImages] == ["⇧I"])
        let write = try #require(sheet.sections.first { $0.title == "Write" })
        let replies = Dictionary(uniqueKeysWithValues: write.lines.map { ($0.action, $0.keys) })
        let (replyKeys, replyAllKeys) = ActionCatalog.returnRepliesAll ? (["R", "⇧↵"], ["A"]) : (["R"], ["A", "⇧↵"])
        #expect(replies[.reply] == replyKeys && replies[.replyAll] == replyAllKeys)
        #expect(lines[.openMessageOrReply] == ["↵"], "↵ opens the selected message, then replies")
        #expect(replies[.forward] == ["F"])
        sheet.filter = "message"
        #expect(sheet.sections.flatMap(\.lines).map(\.action).contains(.nextMessage))
    }
}
