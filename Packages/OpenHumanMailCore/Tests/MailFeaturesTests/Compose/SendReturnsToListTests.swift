import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct SendReturnsToListTests {
    private func reply(_ f: ComposeFixture, _ text: String = "On it") async throws -> (ThreadKey, ComposeSession) {
        await f.loaded()
        let thread = try #require(f.router.list?.cursor)
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        session.updateBody(doc(text))
        #expect(f.router.mode == .reader && f.router.reader?.thread == thread)
        return (thread, session)
    }

    private func shownToast(_ f: ComposeFixture, _ message: String) throws -> Toast {
        try #require(f.env.notices.toasts.first { $0.message.hasPrefix(message) })
    }

    @Test func theLandingRule() {
        let a = ThreadKey(account: ComposeFixture.work, rowID: 1, gmailThreadID: GmailThreadID("a"))
        typealias M = ComposeManager
        #expect(M.landing(placement: .window, showing: a, inList: true) == .stays)
        #expect(M.landing(placement: .modal, showing: nil, inList: false) == .stays)
        #expect(M.landing(placement: .docked(a), showing: nil, inList: false) == .stays)
        #expect(M.landing(placement: .docked(a), showing: a, inList: true) == .list(row: a))
        #expect(M.landing(placement: .modal, showing: a, inList: true) == .list(row: a))
        #expect(M.landing(placement: .docked(a), showing: a, inList: false) == .list(row: nil))
    }

    @Test func aSentReplyReturnsToTheListOnItsConversationAndUndoBringsItBack() async throws {
        let f = ComposeFixture()
        try await f.store.set(AppSettings.sendAndMarkDone, false)
        let (thread, session) = try await reply(f)
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        #expect(f.router.mode == .list && f.router.reader == nil, "never a blank screen: the list shows")
        #expect(f.router.list?.cursor == thread)
        #expect(f.compose.windowSession == nil)

        #expect(await f.run(.undo))
        await soon { f.compose.windowSession === session }
        #expect(f.router.mode == .reader && f.router.reader?.thread == thread, "the conversation comes back with it")
        #expect(f.compose.isShown(session))
        #expect(f.store.sentMessages.isEmpty)
        #expect(f.compose.sending.isEmpty && f.env.status.sendingLine == nil)
    }

    @Test func sendAndMarkDoneLandsOnTheNextRowAtOnce() async throws {
        let f = ComposeFixture()
        let (thread, session) = try await reply(f)
        let state = try #require(f.router.active)
        let next = try #require(state.neighbor(of: thread))
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        await soon { f.router.list?.index(of: thread) == nil }
        #expect(state.mode == .list && f.router.list?.cursor == next)
        f.heldGate.release()
        f.store.completeHeldSends()
    }

    @Test func aNewMessageFromTheListStaysOnTheList() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let cursor = f.router.list?.cursor
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.subject = "Plan"
        session.updateBody(doc("Hello"))
        #expect(await f.run(.send, in: session))
        await f.toast("Sending to ")
        #expect(f.router.mode == .list && f.router.list?.cursor == cursor)
    }

    @Test func aReplyOpenedFromOutsideTheListLandsWhereTheUserLeftIt() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let anchor = try #require(f.router.list?.cursor)
        let all = try await f.store.threadPage(.system(.allMail), account: ComposeFixture.work, after: nil, limit: 1_000).rows
        let outside = try #require(all.first { f.router.list?.index(of: $0.id) == nil })
        f.router.open(outside.id)
        await soon { f.router.reader?.state == .loaded }
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        session.updateBody(doc("Thanks"))
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        #expect(f.router.mode == .list && f.router.list?.cursor == anchor)
    }

    @Test func aScheduledReplyReturnsToTheListWithViewUndoAndEdit() async throws {
        let f = ComposeFixture()
        let (thread, session) = try await reply(f, "Tomorrow")
        #expect(await f.run(.sendLater, in: session))
        #expect(try #require(f.timePicker).chooseNumber(1))
        await f.compose.settle()
        await f.toast("Scheduled for ")
        #expect(f.router.mode == .list && f.router.list?.cursor == thread)
        let toast = try shownToast(f, "Scheduled for ")
        #expect(toast.actionTitle == "Undo" && toast.secondaryActionTitle == "View")
        await f.env.notices.activateSecondary(toast.id)
        let shown = try #require(f.compose.shownSending)
        #expect(shown.id == session.id && shown.offersUndo && shown.offersEdit && !shown.offersRetry)
        guard case .scheduled = shown.state else {
            Issue.record("scheduled: \(shown.state)")
            return
        }
        #expect(f.compose.sendingStatus(shown, now: fixedNow).hasPrefix("Scheduled for "))
        #expect(f.env.status.sendingLine == nil, "a send-later is not on its way yet")

        await f.compose.undoSending(shown.id)
        await soon { f.compose.windowSession === session }
        #expect(f.router.reader?.thread == thread && f.compose.shownSending == nil && f.compose.sending.isEmpty)
        #expect(f.recorder.calls.contains("cancelScheduledSend"))
    }

    @Test func theViewFollowsQueuedSendingSentWithTheToastsAndTheStatusLine() async throws {
        let f = ComposeFixture()
        let (_, session) = try await reply(f)
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        let undoToast = try shownToast(f, "Reply sent.")
        #expect(undoToast.actionTitle == "Undo" && undoToast.shortcut == "⌘Z" && undoToast.secondaryActionTitle == "View")
        #expect(undoToast.holdsWindow, "the undo-time rule is the toast's: it holds the whole window")
        #expect(f.env.status.sendingLine == "Sending 1 message…")

        await f.env.notices.activateSecondary(undoToast.id)
        var shown = try #require(f.compose.shownSending)
        #expect(shown.id == session.id && shown.step == .queued && shown.offersUndo)
        #expect(shown.to == session.to.tokens && shown.text == "On it" && shown.mode == .reply)
        #expect(shown.secondsLeft(now: fixedNow) > 0)
        #expect(f.compose.sendingStatus(shown, now: fixedNow).hasPrefix("Sending in "))
        #expect(f.env.undo?.canUndo == true, "⌘Z still undoes after View took the toast away")

        f.heldGate.release()
        await soon { f.compose.shownSending?.step == .sending }
        shown = try #require(f.compose.shownSending)
        #expect(!shown.offersUndo)
        #expect(["Sending…", "Queued. Sends when you're back online."].contains(f.compose.sendingStatus(shown, now: fixedNow)))
        #expect(f.env.status.sendingLine == "Sending 1 message…")

        f.store.completeHeldSends()
        await soon { f.compose.shownSending?.state == .sent }
        await f.toast("Sent.")
        let sentToast = try shownToast(f, "Sent.")
        #expect(sentToast.actionTitle == "View")
        #expect(f.env.status.sendingLine == nil)
        shown = try #require(f.compose.shownSending)
        #expect(shown.step == .sent && shown.offersShowInSent && !shown.offersUndo)

        f.compose.showSendingInSent(shown.id)
        #expect(f.compose.shownSending == nil && f.router.location == .system(.sent))
        await soon { f.router.reader?.thread == shown.thread }
        #expect(f.recorder.calls.filter { $0 == "send" }.count == 1)
    }

    @Test func undoInTheViewIsTheSendsOwnUndo() async throws {
        let f = ComposeFixture()
        let (thread, session) = try await reply(f)
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        #expect(f.compose.showSending())
        await f.compose.undoSending(session.id)
        await soon { f.compose.windowSession === session }
        #expect(f.compose.shownSending == nil && f.compose.sending.isEmpty && f.store.sentMessages.isEmpty)
        #expect(f.router.reader?.thread == thread)
        #expect(!f.env.notices.toasts.contains { $0.message.hasPrefix("Reply sent.") })
    }

    @Test func theSendingViewNeverShowsUndoOnceTheWindowClosed() async throws {
        let f = ComposeFixture()
        let (_, session) = try await reply(f)
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        f.heldGate.release()
        await soon { f.compose.sending.first?.step == .sending }
        #expect(f.compose.sending.first?.offersUndo == false, "the view offers no Undo once the window closed")
        await f.compose.undoSending(session.id)
        #expect(f.compose.windowSession == nil)
        f.store.completeHeldSends()
        await soon { f.compose.sending.first?.state == .sent }
        #expect(f.store.sentMessages.count == 1)
    }

    @Test func aFailedSendOffersRetryThroughTheComposerAndEdit() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.subject = "Numbers"
        session.updateBody(doc("Attached below"))
        await soon { session.saveState == .saved && session.draftKey != nil }
        let key = try #require(session.draftKey)
        f.compose.close(session)
        await f.compose.settle()
        f.compose.addSending(session, draft: key, state: .failed)
        #expect(f.compose.showSending(session.id))
        let shown = try #require(f.compose.shownSending)
        #expect(shown.offersRetry && shown.offersEdit && !shown.offersUndo && shown.step == nil)
        #expect(f.compose.sendingStatus(shown, now: fixedNow) == "Couldn't send. Saved as draft.")

        f.compose.retrySending(shown.id)
        await f.toast("Sending to ")
        #expect(f.recorder.calls.filter { $0 == "send" }.count == 1)
        let again = try #require(f.compose.sending.last)
        #expect(again.draft == key && again.step == .queued && again.id != session.id)
        #expect(!f.compose.sending.contains { $0.id == session.id })

        #expect(await f.run(.undo))
        await soon { f.compose.windowSession?.draftKey == key }
        f.heldGate.release()
        if let open = f.compose.windowSession { f.compose.close(open) }
        await f.compose.settle()
        f.compose.addSending(session, draft: key, state: .failed)
        f.compose.editSending(session.id)
        await soon { f.compose.windowSession?.draftKey == key }
        #expect(f.compose.shownSending == nil && !f.compose.sending.contains { $0.id == session.id })
    }

    @Test func thePaletteEntryShowsTheNewestAndIsHiddenWithNothingToShow() async throws {
        let f = ComposeFixture()
        let (_, session) = try await reply(f)
        #expect(f.env.actions.availability(.showSending, host: f.router) == .hidden)
        #expect(ActionCatalog.descriptor(.showSending)?.title == "Show sending message")
        #expect(ActionCatalog.descriptor(.showSending)?.changesMail == false, "it only shows")
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        #expect(f.env.actions.availability(.showSending, host: f.router) == .enabled)
        #expect(await f.run(.showSending))
        #expect(f.compose.shownSending?.id == session.id)
        f.compose.closeSendingView()
        f.env.status.showSending?()
        #expect(f.compose.shownSending?.id == session.id)
        #expect(await f.run(.compose))
        #expect(f.compose.shownSending == nil)
    }
}
