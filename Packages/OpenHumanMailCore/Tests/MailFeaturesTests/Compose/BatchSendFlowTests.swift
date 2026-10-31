import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct BatchSendFlowTests {
    static let home = AccountID(2)

    /// Conversations with no draft, scheduled send or reminder yet, each with the message a reply answers.
    private func freshThreads(_ f: ComposeFixture, account: AccountID = ComposeFixture.work,
                              count: Int) async throws -> [(thread: ThreadKey, message: MessageKey)] {
        let rows = try await f.store.threadPage(.system(.allMail), account: account, after: nil, limit: 1_000).rows
        var found: [(thread: ThreadKey, message: MessageKey)] = []
        for row in rows where row.draftCount == 0 && row.scheduledSendAt == nil && row.reminderAt == nil {
            guard let detail = await ComposeManager.first(f.store.threadDetail(row.id)) ?? nil,
                  let last = detail.messages.last else { continue }
            found.append((row.id, last.id))
            if found.count == count { break }
        }
        try #require(found.count == count)
        return found
    }

    private func makeDraft(_ f: ComposeFixture, _ target: (thread: ThreadKey, message: MessageKey),
                           to: String = "someone@else.example", subject: String) async throws -> DraftSummary {
        let content = DraftFields(to: [EmailAddress(name: nil, email: to)], subject: subject,
                                  bodyHTML: "<p>Here are the notes from today.</p>",
                                  bodyText: "Here are the notes from today.")
        let (key, _) = try await f.store.createDraft(DraftInput(account: target.thread.account, mode: .reply,
                                                                replyTo: target.message, content: content))
        return try #require(await f.draftRow(key))
    }

    private func drafts(_ f: ComposeFixture, count: Int, account: AccountID = ComposeFixture.work) async throws -> [DraftSummary] {
        var made: [DraftSummary] = []
        for (index, target) in try await freshThreads(f, account: account, count: count).enumerated() {
            made.append(try await makeDraft(f, target, subject: "Batch \(account.rawValue)-\(index + 1)"))
        }
        return made
    }

    private func reminder(_ f: ComposeFixture, _ thread: ThreadKey) async -> ReminderItem? {
        do {
            for try await items in f.store.reminders(thread.account) { return items.first { $0.thread == thread } }
        } catch {}
        return nil
    }

    private func pendingReminders(_ f: ComposeFixture) async -> [PendingSendReminder] {
        (try? await f.store.get(ComposeSettings.pendingSendReminders)) ?? []
    }

    private func letThemGo(_ f: ComposeFixture) async {
        f.heldGate.release()
        f.store.completeHeldSends()
        await f.compose.settle()
    }

    private func sent(_ f: ComposeFixture) -> [DraftKey] { f.store.sentMessages.map(\.draft) }

    @Test func validDraftsGoTogetherUnderOneUndoEntry() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let made = try await drafts(f, count: 3)
        let entriesBefore = f.env.undo?.stack.count ?? 0
        let start = await f.compose.sendBatch(made, reminders: nil)
        #expect(start.queued == made.map(\.id) && start.failed.isEmpty && start.batch != nil)
        #expect(f.store.heldSendCount == 3 && f.compose.heldSendCount == 3 && f.compose.hasQuitWork)
        #expect((f.env.undo?.stack.count ?? 0) == entriesBefore + 1, "one entry for the whole batch")
        #expect(f.env.undo?.stack.last.map { String(localized: $0.title) } == "Sending 3 drafts…")
        #expect(f.compose.sending.filter { made.map(\.id).contains($0.draft) }.count == 3)
        #expect(f.env.status.sendingLine == "Sending 3 drafts…", "the same word as the Undo toast")
        #expect(sent(f).isEmpty, "nothing leaves during the undo window")

        await letThemGo(f)
        #expect(Set(sent(f)) == Set(made.map(\.id)))
        await f.posted("Sending 3 drafts…", "Sent 3 drafts.")
        #expect(f.compose.heldSendCount == 0 && f.compose.lastBatchFailures.isEmpty)
        #expect(!f.toasts.contains { $0.hasPrefix("Sending ") }, "the Undo toast goes once the batch is out")
    }

    @Test func oneUndoBringsTheWholeBatchBack() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let made = try await drafts(f, count: 3)
        await f.compose.sendBatch(made, reminders: nil)
        await f.env.undo?.undoLast()
        for draft in made { #expect(await f.draftRow(draft.id)?.status == .editing) }
        #expect(f.store.heldSendCount == 0 && f.compose.heldSendCount == 0)
        #expect(!f.compose.sending.contains { made.map(\.id).contains($0.draft) })
        await f.posted("Not sent. The 3 drafts are back in Drafts.")

        await letThemGo(f)
        #expect(sent(f).isEmpty)
        #expect(!f.postedToasts.contains { $0.hasPrefix("Sent ") })
    }

    @Test func aTransportFailureStaysInDraftsAndCanBeRetried() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let made = try await drafts(f, count: 3)
        let failing = made[1].id
        f.store.failDelivery(of: failing)
        await f.compose.sendBatch(made, reminders: nil)
        await letThemGo(f)
        #expect(Set(sent(f)) == [made[0].id, made[2].id])
        #expect(await f.draftRow(failing)?.status == .failed, "the draft that failed is still there")
        await f.posted("2 of 3 sent. “Batch 1-2” is still in Drafts.")
        #expect(!f.toasts.contains { $0.hasPrefix("Sending ") }, "no Undo next to the result")
        #expect(f.env.undo?.stack.contains { String(localized: $0.title) == "Sending 3 drafts…" } == false)
        #expect(f.compose.lastBatchFailures == [failing])
        #expect(f.compose.sending.first { $0.draft == failing }?.state == .failed)

        await f.compose.retryBatch([failing], reminders: nil)
        f.store.completeHeldSends()
        await f.compose.settle()
        #expect(sent(f).last == failing)
        await f.posted("Sent 1 draft.")
    }

    @Test func aDraftThatCannotStartIsReportedAndTheRestGo() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let made = try await drafts(f, count: 3)
        f.recorder.failSend(of: made[0].id, with: .unavailable("injected failure"))
        let start = await f.compose.sendBatch(made, reminders: nil)
        #expect(start.failed == [made[0].id] && start.queued == [made[1].id, made[2].id])
        #expect(f.env.undo?.stack.last.map { String(localized: $0.title) } == "Sending 2 drafts…")
        #expect(await f.draftRow(made[0].id)?.status == .editing)
        await letThemGo(f)
        #expect(Set(sent(f)) == [made[1].id, made[2].id])
        await f.posted("2 of 3 sent. “Batch 1-1” is still in Drafts.")
        #expect(f.compose.lastBatchFailures == [made[0].id])
    }

    @Test func aFailedDraftWithALongSubjectIsCountedNotNamed() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let targets = try await freshThreads(f, count: 3)
        var made: [DraftSummary] = []
        for (index, target) in targets.enumerated() {
            made.append(try await makeDraft(f, target, subject: "Thursday project notes \(index + 1): agenda and next steps"))
        }
        f.store.failDelivery(of: made[2].id)
        await f.compose.sendBatch(made, reminders: nil)
        await letThemGo(f)
        await f.posted("2 of 3 sent. 1 is still in Drafts.")
    }

    @Test func draftsFromTwoAccountsEachGoFromTheirOwnAccount() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let work = try await drafts(f, count: 2)
        let home = try await drafts(f, count: 1, account: Self.home)
        await f.compose.sendBatch([work[0], home[0], work[1]], reminders: nil)
        #expect(f.recorder.calls.filter { $0 == "send" }.count == 3)
        await letThemGo(f)
        let messages = f.store.sentMessages
        #expect(messages.map(\.draft) == [work[0].id, work[1].id, home[0].id], "grouped by account")
        #expect(messages.map(\.account) == [ComposeFixture.work, ComposeFixture.work, Self.home])
        await f.posted("Sent 3 drafts.")
    }

    @Test func withRemindersOnEachConversationGetsAnIfNoReplyReminder() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let made = try await drafts(f, count: 2)
        let rule = SentMailReminderRule(enabled: true)
        await f.compose.sendBatch(made, reminders: rule)
        let pending = await pendingReminders(f)
        #expect(pending.count == 2, "kept across a relaunch until the sends go out")
        let threads = try made.map { try #require($0.thread) }
        for thread in threads { #expect(await reminder(f, thread) == nil) }
        await letThemGo(f)
        for thread in threads { await eventuallyAsync { await reminder(f, thread)?.kind == .ifNoReply } }
        await eventuallyAsync { await pendingReminders(f).isEmpty }
        #expect((try? await f.store.get(AppSettings.autoRemindExternal)) == false, "the setting isn't touched")
    }

    @Test func withRemindersOffForTheBatchNoneAreSetAndTheSettingStaysOn() async throws {
        let f = ComposeFixture()
        try await f.store.set(AppSettings.autoRemindExternal, true)
        await f.loaded()
        let made = try await drafts(f, count: 2)
        await f.compose.sendBatch(made, reminders: nil)
        #expect(await pendingReminders(f).isEmpty)
        await letThemGo(f)
        await f.posted("Sent 2 drafts.")
        for thread in try made.map({ try #require($0.thread) }) { #expect(await reminder(f, thread) == nil) }
        #expect(!f.postedToasts.contains { $0.hasPrefix("Reminder set for") })
        #expect((try? await f.store.get(AppSettings.autoRemindExternal)) == true)
    }

    @Test func fromTheDraftsListTheConfirmationSendsWhatCanGoAndKeepsTheRestChecked() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let made = try await drafts(f, count: 3)
        let scheduledAt = fixedNow.addingTimeInterval(86_400)
        try await f.store.scheduleSend(made[2].id, at: scheduledAt)
        f.router.go(to: .system(.drafts))
        await eventually(timeout: .seconds(15)) {
            f.router.active?.location == .system(.drafts) && f.router.list?.state == .loaded
        }
        let state = try #require(f.router.active)
        let threads = try made.map { try #require($0.thread) }
        for thread in threads { state.selection.toggle(thread) }
        let hints = HintBarModel(router: f.router)
        #expect(hints.hints.first?.action == .sendDrafts && hints.hints.first?.title == "Send 3 drafts",
                "the hint bar shows ⌘↵ while drafts are checked")

        #expect(await f.run(.sendDrafts))
        guard case .batchSend(let model) = f.env.overlays.overlay else {
            Issue.record("the confirmation isn't shown")
            return
        }
        #expect(model.count == 2 && model.title == "Send 2 drafts?")
        #expect(model.summary == "To someone@else.example. 1 won't be sent.")
        #expect(model.plan.skipped.map(\.reason) == [.scheduled(scheduledAt)])
        #expect(model.skippedTitle == "Staying in Drafts (1)")
        let hold = AppSettings.undoSendHold((try? await f.store.get(AppSettings.undoSendSeconds)) ?? 10)
        #expect(model.undoNote == "You can undo the whole batch for \(hold) seconds after sending.")
        #expect(!model.remindersOn, "the reminder setting is off by default")

        await model.confirm()?.value
        #expect(!f.env.overlays.isShowing)
        #expect(state.selection.checked == [threads[2]], "the skipped draft stays checked")
        #expect(f.store.heldSendCount == 2)
        await letThemGo(f)
        #expect(Set(sent(f)) == [made[0].id, made[1].id])
        let kept = await f.draftRow(made[2].id)
        #expect(kept?.status == .scheduled && kept?.sendAt == scheduledAt, "the scheduled draft keeps its schedule")
    }

    @Test func quittingDuringTheUndoWindowSendsTheBatch() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let made = try await drafts(f, count: 2)
        await f.compose.sendBatch(made, reminders: nil)
        #expect(f.compose.heldSendCount == 2)
        await f.compose.prepareForQuit()
        #expect(Set(sent(f)) == Set(made.map(\.id)) && f.compose.heldSendCount == 0)
        f.heldGate.release()
        await f.compose.settle()
        await f.posted("Sent 2 drafts.")
    }
}
