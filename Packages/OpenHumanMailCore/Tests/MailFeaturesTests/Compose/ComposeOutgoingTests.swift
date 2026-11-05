import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct ComposeOutgoingTests {
    private func reply(_ f: ComposeFixture, _ text: String) async throws -> (ThreadKey, ComposeSession) {
        await f.loaded()
        let thread = try #require(f.router.list?.cursor)
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        session.updateBody(doc(text))
        return (thread, session)
    }

    private func messages(_ f: ComposeFixture, _ thread: ThreadKey) async -> [MessageKey] {
        do { for try await detail in f.store.threadDetail(thread) { return detail?.messages.map(\.id) ?? [] } } catch {}
        return []
    }

    @Test func aSentReplyIsOutgoingInItsConversationUntilItsCopyIsThere() async throws {
        let f = ComposeFixture()
        let (thread, session) = try await reply(f, "On it")
        let before = await messages(f, thread)
        #expect(await f.run(.send, in: session))
        await soon { f.compose.outgoing.count == 1 }
        let entry = try #require(f.compose.outgoing.first)
        #expect(entry.id == session.id && entry.thread == thread && entry.mode == .reply && entry.state == .undoable)
        #expect(entry.text == "On it" && entry.to == session.to.tokens && entry.from.email == session.from.email)
        #expect(entry.earlierMessages == Set(before), "the conversation's messages when it was sent")
        #expect(f.compose.outgoingMessages(in: thread, shown: before).map(\.id) == [session.id])
        await f.toast("Reply sent.")
        let toast = try #require(f.env.notices.toasts.first { $0.message == "Reply sent." })
        #expect(toast.actionTitle == "Undo" && toast.shortcut == "⌘Z")
        let shown = try #require(toast.expiresAt).timeIntervalSince(toast.postedAt)
        #expect(shown > 9 && shown <= 10.5, "\(shown)")

        #expect(await f.run(.undo))
        await soon { f.compose.windowSession === session && f.compose.outgoing.isEmpty }
        #expect(f.store.sentMessages.isEmpty)

        #expect(await f.run(.send, in: session))
        await soon { f.compose.outgoing.first?.state == .undoable }
        f.heldGate.release()
        await soon { f.compose.outgoing.first?.state == .sending }
        #expect(f.compose.outgoingMessages(in: thread, shown: before).count == 1, "still shown while it goes")
        f.store.completeHeldSends()
        await soon { f.compose.outgoing.first?.state == .sent }
        await f.toast("Sent.")
        let after = await messages(f, thread)
        #expect(after.count == before.count + 1)
        #expect(f.compose.outgoingMessages(in: thread, shown: after).isEmpty, "its copy replaces it")
        #expect(f.compose.outgoingMessages(in: thread, shown: before).count == 1, "until then it stays")
        #expect(f.recorder.calls.filter { $0 == "send" }.count == 2 && f.store.sentMessages.count == 1)
    }

    @Test func aNewMessageIsNeverOutgoingInAConversationAndKeepsItsSendingToast() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.subject = "Plan"
        session.updateBody(doc("Hello"))
        #expect(await f.run(.send, in: session))
        await f.toast("Sending to ")
        #expect(f.compose.outgoing.isEmpty)
        #expect(f.compose.remindButton(for: session)?.isEnabled == true, "a new message has Remind me too (UX review #11)")
    }

    private func reminder(_ f: ComposeFixture, _ thread: ThreadKey) async -> ReminderItem? {
        do {
            for try await items in f.store.reminders(ComposeFixture.work) { return items.first { $0.thread == thread } }
        } catch {}
        return nil
    }

    @Test func remindMeIsKeptWithTheReplyAndSetOnlyOnceTheSendCommits() async throws {
        let f = ComposeFixture()
        let (thread, session) = try await reply(f, "Will check")
        let before = await reminder(f, thread)
        let button = try #require(f.compose.remindButton(for: session))
        #expect(button.isEnabled && button.help.hasPrefix("Remind me"))
        #expect(f.compose.remind(from: session))
        let picker = try #require(f.timePicker)
        #expect(picker.kind == .remind && picker.targets == [thread])
        #expect(picker.onlyIfNoReply, "a reminder set while writing is a follow-up")
        #expect(picker.chooseNumber(1))
        let pending = try #require(session.pendingReminder)
        #expect(pending.kind == .ifNoReply)
        #expect(f.compose.remindTitle(session).hasPrefix("Remind me ") && f.compose.remindTitle(session).hasSuffix("if no reply"))
        #expect(await reminder(f, thread) == before, "nothing is set while the reply is a draft")

        #expect(await f.run(.send, in: session))
        #expect(await f.run(.undo))
        await soon { f.compose.windowSession === session }
        #expect(session.pendingReminder == pending)
        #expect(await reminder(f, thread) == before)
        #expect(!f.postedToasts.contains { $0.hasPrefix("Reminder set for") })

        #expect(await f.run(.send, in: session))
        f.heldGate.release()
        await soon { f.compose.outgoing.first?.state == .sending }
        f.store.completeHeldSends()
        await f.posted("Sent.", "Reminder set for")
        #expect(session.pendingReminder == nil)
        // Why: the undo toast is posted as the command starts; the store has the reminder only once it finishes
        await eventuallyAsync { await reminder(f, thread) != before }
        let stored = try #require(await reminder(f, thread))
        #expect(stored.kind == .ifNoReply)
    }

    @Test func aDoubledSendKeyStartsOneSendAndAnOverlayTakesTheComposersKeys() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.subject = "Proposal"
        session.updateBody(doc("Here it is"))
        #expect(f.compose.ownsShortcutKeys(session))
        await f.run(.commandPalette)
        #expect(!f.compose.ownsShortcutKeys(session), "the palette is in front")
        f.env.overlays.overlay = .none
        #expect(f.compose.ownsShortcutKeys(session))
        #expect(f.compose.perform(.send, in: session, source: .keyboard))
        #expect(f.compose.perform(.send, in: session, source: .keyboard), "the doubled press is absorbed")
        f.heldGate.release()
        await soon { f.compose.sending.first { $0.id == session.id }?.state == .sending }
        f.store.completeHeldSends()
        await soon { f.store.sentMessages.count == 1 }
        #expect(session.notice == nil, "no stale error from a second send")
    }

    @Test func aNewMessagesReminderGoesToTheConversationItsSendStarted() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.subject = "Proposal"
        session.updateBody(doc("Here it is"))
        #expect(f.compose.remind(from: session))
        let picker = try #require(f.timePicker)
        #expect(picker.kind == .remind && picker.targets.isEmpty, "no conversation yet")
        picker.onlyIfNoReply = false
        #expect(picker.chooseNumber(2))
        #expect(session.pendingReminder?.kind == .always)
        #expect(await f.run(.send, in: session))
        f.heldGate.release()
        await soon { f.compose.sending.first { $0.id == session.id }?.state == .sending }
        f.store.completeHeldSends()
        await f.posted("Sent.", "Reminder set for")
        let sent = try #require(f.store.sentMessages.last)
        // Why: the undo toast is posted as the command starts; the store has the reminder only once it finishes
        await eventuallyAsync { await reminder(f, sent.thread) != nil }
        let stored = try #require(await reminder(f, sent.thread))
        #expect(stored.kind == .always)
    }

    @Test func aDiscardedDraftLeavesNoReminder() async throws {
        let f = ComposeFixture()
        let (thread, session) = try await reply(f, "Never mind")
        let before = await reminder(f, thread)
        #expect(f.compose.remind(from: session))
        #expect(try #require(f.timePicker).chooseNumber(1))
        #expect(session.pendingReminder != nil)
        session.clearPendingReminder()
        #expect(session.pendingReminder == nil && f.compose.remindTitle(session) == "Remind me")
        #expect(f.compose.remind(from: session))
        #expect(try #require(f.timePicker).chooseNumber(1))
        await soon { session.saveState == .saved }
        #expect(await f.run(.discardDraft, in: session))
        f.discardGate.release()
        await soon { f.recorder.calls.contains("discardDraft") }
        await f.compose.settle()
        #expect(await reminder(f, thread) == before, "a discarded draft's reminder is never set")
        #expect(!f.toasts.contains { $0.hasPrefix("Reminder set for") })
    }
}
