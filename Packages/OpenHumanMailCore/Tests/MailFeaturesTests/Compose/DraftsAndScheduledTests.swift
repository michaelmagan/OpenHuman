import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct DraftsAndScheduledTests {
    private func drafts(_ f: ComposeFixture) async -> [DraftSummary] {
        do { for try await rows in f.store.drafts(ComposeFixture.work, review: false) { return rows } } catch {}
        return []
    }

    private func show(_ f: ComposeFixture, _ location: MailLocation) async {
        f.router.go(to: location)
        await soon { f.router.location == location && f.router.list?.state == .loaded && f.router.list?.cursor != nil }
    }

    private func scheduledRow(_ f: ComposeFixture) async throws -> (ThreadKey, DraftSummary) {
        await show(f, .system(.scheduled))
        let thread = try #require(f.router.list?.cursor)
        let draft = try #require(await drafts(f).first { $0.thread == thread && $0.status == .scheduled })
        return (thread, draft)
    }

    @Test func enterOnADraftsRowResumesItsDraftUnderItsConversationAndEditsSaveIntoIt() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let own = try #require(await drafts(f).first { $0.source == .user && $0.status == .editing && $0.mode == .reply })
        let thread = try #require(own.thread)
        await show(f, .system(.drafts))
        f.router.list?.setCursor(thread)
        #expect(f.router.list?.cursor == thread)
        #expect(await f.run(.openThread))
        await soon { f.compose.windowSession?.draftKey == own.id }
        let session = try #require(f.compose.windowSession)
        #expect(session.placement == .docked(thread), "a reply docks under its conversation, as r does")
        #expect(f.router.mode == .reader && f.router.reader?.thread == thread)
        #expect(f.router.location == .system(.drafts), "Esc goes back to Drafts")
        #expect(session.mode == .reply && session.to.tokens.map(\.email) == own.fields.to.map(\.email))
        #expect(!f.recorder.calls.contains("createDraft"), "the stored draft, not a second one")

        session.updateBody(doc("Edited after resuming"))
        await soon { f.recorder.calls.contains("updateDraft") && session.saveState == .saved }
        #expect(try #require(await f.draftRow(own.id)).fields.bodyHTML.contains("Edited after resuming"))

        f.compose.close(session)
        await f.compose.settle()
        #expect(await f.draftRow(own.id) != nil && f.recorder.calls.contains("flushDraft"))
        #expect(!f.recorder.calls.contains("discardDraft") && !f.recorder.calls.contains("send"))
    }

    @Test func aStoredReplyDraftReopenedAndClosedWithoutTypingIsKept() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let own = try #require(await drafts(f).first { $0.source == .user && $0.status == .editing && $0.mode == .reply })
        let session = try #require(await f.compose.openDraft(own.id).value)
        await session.settle()
        #expect(!session.hasUserEdits)
        f.compose.close(session)
        await f.compose.settle()
        #expect(!f.recorder.calls.contains("discardDraft"), "only a skeleton this composer created is dropped on close")
        #expect(await f.draftRow(own.id) != nil)

        let scheduled = try #require(await drafts(f).first { $0.status == .scheduled && $0.thread != nil })
        let again = try #require(await f.compose.openDraft(scheduled.id).value)
        await again.settle()
        f.compose.close(again)
        await f.compose.settle()
        #expect(await f.draftRow(scheduled.id)?.status == .scheduled)
        #expect(!f.recorder.calls.contains("discardDraft"))
    }

    @Test func enterOnAScheduledRowOpensItsScheduledDraftWithSendsAt() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let (_, scheduled) = try await scheduledRow(f)
        #expect(await f.run(.openThread))
        await soon { f.compose.windowSession?.draftKey == scheduled.id }
        let session = try #require(f.compose.windowSession)
        #expect(session.sendAt == scheduled.sendAt && session.draftStatus == .scheduled)
        #expect(f.env.actions.availability(.cancelSendLater, host: session) == .enabled, "the chip's Cancel")
        #expect(f.env.actions.availability(.sendLater, host: session) == .enabled, "the chip's Reschedule")
        #expect(!f.recorder.calls.contains("scheduleSend") && !f.recorder.calls.contains("cancelScheduledSend"))
    }

    @Test func openDraftShowsWhereTheRowHasADraftAndBringsItUpInTheConversation() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let own = try #require(await drafts(f).first { $0.source == .user && $0.status == .editing && $0.mode == .reply })
        let thread = try #require(own.thread)
        f.router.go(to: .system(.allMail))
        await soon { f.router.list?.state == .loaded && f.router.list?.index(of: thread) != nil }
        let plain = try #require(f.router.list?.rows.first { $0.draftCount == 0 && $0.scheduledSendAt == nil })
        f.router.list?.setCursor(plain.id)
        #expect(f.env.actions.availability(.openDraft, host: f.router) == .hidden)
        #expect(f.env.actions.availability(.cancelScheduledSend, host: f.router) == .hidden)
        #expect(f.env.actions.availability(.rescheduleSend, host: f.router) == .hidden)
        f.router.list?.setCursor(thread)
        #expect(f.env.actions.availability(.openDraft, host: f.router) == .enabled)

        #expect(await f.run(.openThread))
        #expect(f.router.reader?.thread == thread && f.compose.windowSession == nil)
        let context = ReaderActions.context(host: f.router, thread: thread, lastMessage: nil)
        let offered = ReaderActions.offeredThreadActions(registry: f.env.actions, host: f.router, context: context).map(\.id)
        #expect(offered.contains(.openDraft) && offered.contains(.remind))
        #expect(ReaderActions.symbol(for: .openDraft) == "pencil")
        #expect(await f.run(.openDraft))
        await soon { f.compose.windowSession?.draftKey == own.id }
        #expect(f.compose.windowSession?.placement == .docked(thread))
    }

    @Test func cancelFromAScheduledRowGoesBackToADraftWithUndo() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let (thread, scheduled) = try await scheduledRow(f)
        let at = try #require(scheduled.sendAt)
        #expect(f.env.actions.availability(.cancelScheduledSend, host: f.router) == .enabled)
        #expect(f.env.actions.availability(.rescheduleSend, host: f.router) == .enabled)
        #expect(await f.run(.cancelScheduledSend))
        await f.toast("Send later canceled")
        #expect(f.recorder.calls.contains("cancelScheduledSend") && !f.recorder.calls.contains("send"))
        let canceled = try #require(await f.draftRow(scheduled.id))
        #expect(canceled.status == .editing && canceled.sendAt == nil)
        await soon { f.router.list?.index(of: thread) == nil }

        #expect(await f.run(.undo))
        #expect(f.recorder.calls.contains("scheduleSend"))
        #expect(await f.draftRow(scheduled.id)?.sendAt == at)
        await soon { f.router.list?.index(of: thread) != nil }
    }

    @Test func rescheduleFromARowTakesAFutureTimeOnlyAndUndoesToTheEarlierOne() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let (thread, scheduled) = try await scheduledRow(f)
        let before = try #require(scheduled.sendAt)
        #expect(await f.run(.rescheduleSend))
        let picker = try #require(f.timePicker)
        #expect(picker.kind == .sendLater && picker.targets == [thread])
        #expect(picker.chooseNumber(1))
        await f.compose.settle()
        let moved = ScheduleStamp.floorToMinute(fixedNow.addingTimeInterval(3_600))
        #expect(await f.draftRow(scheduled.id)?.sendAt == moved)
        await f.toast("Rescheduled for ")
        #expect(!f.recorder.calls.contains("send") && !f.recorder.calls.contains("sendNow"), "moving a send never sends")

        let schedules = f.recorder.calls.filter { $0 == "scheduleSend" }.count
        await f.compose.reschedule(scheduled.id, at: fixedNow.addingTimeInterval(30), previous: moved, thread: thread)
        await f.toast("Pick a time at least a minute from now")
        #expect(f.recorder.calls.filter { $0 == "scheduleSend" }.count == schedules)
        #expect(await f.draftRow(scheduled.id)?.sendAt == moved)

        #expect(await f.run(.undo))
        #expect(await f.draftRow(scheduled.id)?.sendAt == before)
    }

    @Test func rescheduleFromARowKeepsOnlyIfNoReplyAndUndoRestoresIt() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let (thread, original) = try await scheduledRow(f)
        let before = try #require(original.sendAt)
        try await f.store.scheduleSend(original.id, at: before, condition: .ifNoReply)
        let scheduled = try #require(await f.draftRow(original.id))
        #expect(scheduled.sendCondition == .ifNoReply)
        #expect(await f.run(.rescheduleSend))
        let picker = try #require(f.timePicker)
        #expect(picker.targets == [thread] && picker.onlyIfNoReply, "the card starts from the current condition")
        #expect(picker.chooseNumber(1))
        await f.compose.settle()
        let moved = ScheduleStamp.floorToMinute(fixedNow.addingTimeInterval(3_600))
        #expect(await f.draftRow(scheduled.id)?.sendAt == moved)
        #expect(f.store.sendCondition(scheduled.id) == .ifNoReply)
        #expect(f.recorder.calls.contains("scheduleSend:ifNoReply"))
        await f.toast("Rescheduled for ")
        #expect(f.toasts.contains { $0.hasPrefix("Rescheduled for ") && $0.contains(" if no reply") })

        #expect(await f.run(.undo))
        #expect(await f.draftRow(scheduled.id)?.sendAt == before)
        #expect(f.store.sendCondition(scheduled.id) == .ifNoReply, "undo puts back the earlier time and condition")

        await f.compose.reschedule(scheduled.id, at: fixedNow.addingTimeInterval(7_200), condition: .always,
                                   previous: before, previousCondition: .ifNoReply, thread: thread)
        #expect(f.store.sendCondition(scheduled.id) == .always, "turning the box off is an explicit choice")
    }

    @Test func undoingACanceledIfNoReplySendRestoresTheCondition() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let (_, original) = try await scheduledRow(f)
        let at = try #require(original.sendAt)
        try await f.store.scheduleSend(original.id, at: at, condition: .ifNoReply)
        #expect(await f.draftRow(original.id)?.sendCondition == .ifNoReply)
        #expect(await f.run(.cancelScheduledSend))
        await f.toast("Send later canceled")
        #expect(f.store.sendCondition(original.id) == nil)
        #expect(await f.run(.undo))
        #expect(await f.draftRow(original.id)?.sendAt == at)
        #expect(f.store.sendCondition(original.id) == .ifNoReply)
    }

    @Test func theComposerRefusesASendLaterTimeLessThanAMinuteAhead() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.updateBody(doc("Soon"))
        await f.compose.schedule(session, at: fixedNow.addingTimeInterval(20))
        #expect(session.notice?.text == "Pick a time at least a minute from now.")
        #expect(!f.recorder.calls.contains("scheduleSend") && f.compose.windowSession === session)
    }

    @Test func withConfirmEverySendOnTheMoveOpensTheDraftWhereTheCardAsks() async throws {
        let f = ComposeFixture(isLiveAccount: true)
        await f.loaded()
        try await f.store.set(SendSettings.confirmEverySend, true)
        let (_, scheduled) = try await scheduledRow(f)
        #expect(await f.run(.rescheduleSend))
        await soon { f.compose.windowSession?.draftKey == scheduled.id }
        #expect(f.timePicker == nil && !f.recorder.calls.contains("scheduleSend"))
        await f.toast("Confirm before sending is on")
    }

    @Test func withTheSendLaterModuleOffTheRowActionsAreGone() async throws {
        let f = ComposeFixture(flags: FeatureFlags().with(.sendLater, false))
        await f.loaded()
        #expect(!f.env.actions.contains(.cancelScheduledSend) && !f.env.actions.contains(.rescheduleSend))
        #expect(f.env.actions.contains(.openDraft), "opening a draft is the composer's own (core)")
    }

    @Test func aReplysReminderIsSetWhenItIsScheduled() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let thread = try #require(f.router.list?.cursor)
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        session.updateBody(doc("Later, with a nudge"))
        #expect(f.compose.remind(from: session))
        #expect(try #require(f.timePicker).chooseNumber(1))
        #expect(session.pendingReminder != nil)
        await f.compose.schedule(session, at: fixedNow.addingTimeInterval(7_200))
        #expect(f.recorder.calls.contains("scheduleSend"))
        await soon { f.toasts.contains { $0.hasPrefix("Reminder set for") } }
        var reminder: ReminderItem?
        do {
            for try await items in f.store.reminders(ComposeFixture.work) {
                reminder = items.first { $0.thread == thread }
                break
            }
        } catch {}
        #expect(reminder?.kind == .ifNoReply)
    }
}
