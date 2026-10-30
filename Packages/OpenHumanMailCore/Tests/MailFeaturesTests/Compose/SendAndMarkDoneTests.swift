import Foundation
import MailActions
import MailFakes
import MailModel
import MailRender
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct SendAndMarkDoneTests {
    private func reply(_ f: ComposeFixture, markDone: Bool) async throws -> (ThreadKey, ComposeSession) {
        if markDone { try await f.store.set(AppSettings.sendAndMarkDone, true) }
        await f.loaded()
        let thread = try #require(f.router.list?.cursor)
        #expect(await inInbox(f, thread))
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        session.updateBody(doc("On it"))
        return (thread, session)
    }

    private func inInbox(_ f: ComposeFixture, _ thread: ThreadKey) async -> Bool {
        let page = try? await f.store.threadPage(.system(.inbox), account: thread.account, after: nil, limit: 1_000)
        return page?.rows.contains { $0.id == thread } ?? false
    }

    @Test func theSettingIsOnByDefault() {
        #expect(AppSettings.sendAndMarkDone.defaultValue == true)
    }

    @Test func aSentReplyArchivesAtOnceAndReturnsToTheListOnTheNextRow() async throws {
        let f = ComposeFixture()
        let (thread, session) = try await reply(f, markDone: false)
        let state = try #require(f.router.active)
        let next = try #require(state.neighbor(of: thread))
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        await eventuallyAsync { !(await inInbox(f, thread)) }
        #expect(state.mode == .list && state.reader == nil, "the reader closed")
        await eventually(timeout: .seconds(15)) { state.list?.cursor == next }
        #expect(f.toasts.contains { $0.hasPrefix("Reply sent.") }, "the sending toast with Undo stays up for the window")
        f.heldGate.release()
        f.store.completeHeldSends()
        await f.posted("Sent.")
        #expect(!(await inInbox(f, thread)), "the archive stays once the send went out")
        await eventuallyAsync { await pendingSendDone(f).isEmpty }
    }

    private func pendingSendDone(_ f: ComposeFixture) async -> [PendingSendDone] {
        (try? await f.store.get(ComposeSettings.pendingSendDone)) ?? []
    }

    @Test func undoingTheSendRestoresTheConversationAndTheOpenDraft() async throws {
        let f = ComposeFixture()
        let (thread, session) = try await reply(f, markDone: false)
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        await eventuallyAsync { !(await inInbox(f, thread)) }
        #expect(await f.run(.undo))
        await soon { f.compose.windowSession === session && f.compose.outgoing.isEmpty }
        await eventuallyAsync { await inInbox(f, thread) }
        let state = try #require(f.router.active)
        #expect(state.mode == .reader && state.reader?.thread == thread, "the conversation is open under the composer")
        #expect(f.env.undo?.stack.isEmpty == true, "no stale Marked done entry is left")
        await eventuallyAsync { await pendingSendDone(f).isEmpty }
    }

    @Test func aFailedSendRestoresTheConversation() async throws {
        let f = ComposeFixture()
        let (thread, session) = try await reply(f, markDone: false)
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        await eventuallyAsync { !(await inInbox(f, thread)) }
        let token = try #require(f.compose.held.values.first?.token)
        f.heldGate.release()
        await soon { f.compose.held.isEmpty }
        #expect(try await f.store.cancelSend(token))
        await f.toast("Couldn't send.")
        await eventuallyAsync { await inInbox(f, thread) }
        await eventuallyAsync { await pendingSendDone(f).isEmpty }
    }

    @Test func withTheSettingOffASentReplyLeavesTheConversationInTheInbox() async throws {
        let f = ComposeFixture()
        try await f.store.set(AppSettings.sendAndMarkDone, false)
        let (thread, session) = try await reply(f, markDone: false)
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        f.heldGate.release()
        f.store.completeHeldSends()
        await f.posted("Sent.")
        #expect(await inInbox(f, thread))
        #expect(!f.postedToasts.contains { $0.hasPrefix("Marked done") })
        #expect(f.router.active?.mode == .list)
    }

    @Test func aNewMessageArchivesNothing() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let before = f.router.list?.cursor
        #expect(await f.run(.compose))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        session.to.text = "dana@acme.example,"
        session.subject = "Plan"
        session.updateBody(doc("Hello"))
        #expect(await f.run(.send, in: session))
        await f.toast("Sending to")
        f.heldGate.release()
        f.store.completeHeldSends()
        await f.posted("Sent.")
        #expect(!f.postedToasts.contains { $0.hasPrefix("Marked done") })
        if let before { #expect(await inInbox(f, before)) }
        #expect(await pendingSendDone(f).isEmpty)
    }

    @Test func aReplySentFromTheSentLocationArchivesNothing() async throws {
        let f = ComposeFixture()
        await f.loaded()
        f.router.go(to: .system(.sent))
        await eventually(timeout: .seconds(15)) { f.router.list?.state == .loaded && f.router.list?.cursor != nil }
        let thread = try #require(f.router.list?.cursor)
        let before = await inInbox(f, thread)
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        session.to.text = "dana@acme.example,"
        session.updateBody(doc("On it"))
        #expect(!f.compose.archivesOnSend(session))
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        f.heldGate.release()
        f.store.completeHeldSends()
        await f.posted("Sent.")
        #expect(!f.postedToasts.contains { $0.hasPrefix("Marked done") })
        #expect(await inInbox(f, thread) == before, "its Inbox membership is untouched")
    }

    @Test(arguments: [MailLocation.system(.sent), .system(.drafts), .system(.trash), .system(.spam), .system(.scheduled),
                      .system(.snoozed), .reviewQueue(nil)])
    func archivingDoesNotApplyIn(_ location: MailLocation) {
        #expect(!ComposeManager.archives(from: location))
    }

    @Test(arguments: [MailLocation.system(.inbox), .splitOther, .system(.starred), .system(.allMail), .search("from:a")])
    func archivingAppliesIn(_ location: MailLocation) {
        #expect(ComposeManager.archives(from: location))
    }

    @Test func aForwardArchivesLikeAReply() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let thread = try #require(f.router.list?.cursor)
        #expect(await f.run(.forward))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        session.to.text = "dana@acme.example,"
        #expect(session.mode == .forward && f.compose.archivesOnSend(session))
        #expect(await f.run(.send, in: session))
        await f.toast("Sending to")
        await eventuallyAsync { !(await inInbox(f, thread)) }
        f.heldGate.release()
        f.store.completeHeldSends()
    }

    @Test func theRightAccountIsArchived() async throws {
        let f = ComposeFixture()
        await f.loaded()
        #expect(f.router.switchAccount(position: 2))
        await eventually(timeout: .seconds(15)) { f.router.active?.id == AccountID(2) && f.router.list?.cursor != nil }
        let thread = try #require(f.router.list?.cursor)
        #expect(thread.account == AccountID(2))
        let work = try #require(try await f.store.threadPage(.system(.inbox), account: AccountID(1), after: nil, limit: 1_000).rows.count)
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        session.updateBody(doc("On it"))
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        await eventuallyAsync { !(await inInbox(f, thread)) }
        let after = try await f.store.threadPage(.system(.inbox), account: AccountID(1), after: nil, limit: 1_000).rows.count
        #expect(after == work, "the other account's Inbox is untouched")
        f.heldGate.release()
        f.store.completeHeldSends()
    }

    @Test func aReminderSetWithTheSendSurvivesTheArchive() async throws {
        let f = ComposeFixture()
        let (thread, session) = try await reply(f, markDone: false)
        session.pendingReminder = ComposeSession.PendingReminder(dueAt: Date().addingTimeInterval(5 * 86_400), kind: .ifNoReply)
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        await eventuallyAsync { !(await inInbox(f, thread)) }
        f.heldGate.release()
        f.store.completeHeldSends()
        await f.posted("Sent.", "Reminder set for")
        // The reminder toast precedes the store mutation; join the action before reading it.
        let reminder = try #require(f.env.actions.threadActions?.lastTask)
        await reminder.value
        let items = try await f.store.threadPage(.system(.reminders), account: thread.account, after: nil, limit: 1_000).rows
        #expect(items.contains { $0.id == thread })
        #expect(!(await inInbox(f, thread)))
    }

    @Test func aTooLateUndoStillReportsTheSendAndKeepsTheArchive() async throws {
        let f = ComposeFixture()
        let (thread, session) = try await reply(f, markDone: false)
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        await eventuallyAsync { !(await inInbox(f, thread)) }
        f.store.completeHeldSends()
        #expect(await f.run(.undo))
        await f.posted("Sent.")
        #expect(!(await inInbox(f, thread)))
        #expect(f.compose.windowSession !== session)
        f.heldGate.release()
    }

    @Test func aFailedSendOffersSendAgain() async throws {
        let f = ComposeFixture()
        let (_, session) = try await reply(f, markDone: false)
        f.store.failNextCommand()
        _ = await f.run(.send, in: session)
        await eventually(timeout: .seconds(15)) { session.notice != nil }
        #expect(session.notice?.kind == .error)
        #expect(session.notice?.offersSendAgain == true)
        #expect(!ComposeSession.Notice(.info, "Its attachments are already in this reply.").offersSendAgain)
    }

    @Test func aReplyToAConversationAlreadyOutOfTheInboxPushesNoEntryAndRestoresNothing() async throws {
        let f = ComposeFixture()
        let (thread, session) = try await reply(f, markDone: false)
        _ = try await f.store.apply(.markDone([thread]))
        let entries = f.env.undo?.stack.count ?? 0
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        #expect(f.env.undo?.stack.count == entries + 1, "only the send's own entry")
        await eventuallyAsync { await pendingSendDone(f).isEmpty }
        let token = try #require(f.compose.held.values.first?.token)
        f.heldGate.release()
        await soon { f.compose.held.isEmpty }
        #expect(try await f.store.cancelSend(token))
        await f.toast("Couldn't send.")
        #expect(!(await inInbox(f, thread)))
    }

    private func relaunch(_ f: ComposeFixture) async -> AppEnvironment {
        let env = AppEnvironment(data: f.store, commands: f.store, accounts: f.store, settings: f.store, isFake: true)
        env.router.start()
        await eventually(timeout: .seconds(15)) { env.router.active != nil }
        env.compose.restoreOpenDrafts()
        return env
    }

    @Test func aReplySentJustBeforeQuittingStaysArchivedAfterTheRelaunch() async throws {
        let f = ComposeFixture()
        let (thread, session) = try await reply(f, markDone: false)
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        await eventuallyAsync { !(await inInbox(f, thread)) }
        await f.compose.prepareForQuit()
        f.heldGate.release()
        await f.compose.settle()
        #expect(await pendingSendDone(f).map(\.thread) == [thread])

        _ = await relaunch(f)
        f.store.completeHeldSends()
        await eventuallyAsync { await pendingSendDone(f).isEmpty }
        #expect(!(await inInbox(f, thread)))
    }

    @Test(arguments: [true, false]) func afterACrashOnlyASendThatGoesOutStaysArchived(goesOut: Bool) async throws {
        let f = ComposeFixture()
        let (thread, session) = try await reply(f, markDone: false)
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        await eventuallyAsync { !(await inInbox(f, thread)) }
        let token = try #require(f.compose.held.values.first?.token)
        f.compose.held.removeAll()
        f.heldGate.release()

        let env2 = await relaunch(f)
        if goesOut {
            f.store.completeHeldSends()
            await eventuallyAsync { await pendingSendDone(f).isEmpty }
            #expect(!(await inInbox(f, thread)))
        } else {
            #expect(try await f.store.cancelSend(token))
            await eventuallyAsync { await pendingSendDone(f).isEmpty }
            await env2.compose.settle()
            await eventuallyAsync { await inInbox(f, thread) }
        }
    }

    @Test func aDraftSurvivesAKillMidCompose() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oh-crash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = ComposeFixture()
        await f.loaded()
        let nav = FileNavigationStore(directory: dir, scope: "fake")
        let env1 = AppEnvironment(data: f.store, commands: f.store, accounts: f.store, settings: f.store,
                                  isFake: true, navigationStore: nav)
        env1.router.start()
        await eventually(timeout: .seconds(15)) { env1.router.active != nil }
        env1.compose.recovery = FileDraftRecovery(directory: dir)
        let session = try #require(env1.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.subject = "Plan"
        session.updateBody(RichTextDocument(blocks: [.list(ordered: false, items: [[.paragraph([.text("one", [.bold])])]])]))
        await soon { session.saveState == .saved && session.draftKey != nil }
        let key = try #require(session.draftKey)
        let document = session.document
        await soon { env1.router.openDraftIDs == [key.rawValue] }
        env1.router.persist()
        #expect(nav.load()?.openDraftIDs == [key.rawValue])

        let env2 = AppEnvironment(data: f.store, commands: f.store, accounts: f.store, settings: f.store,
                                  isFake: true, navigationStore: FileNavigationStore(directory: dir, scope: "fake"))
        env2.router.start()
        await eventually(timeout: .seconds(15)) { env2.router.active != nil }
        env2.compose.recovery = FileDraftRecovery(directory: dir)
        env2.compose.restoreOpenDrafts()
        await soon { env2.compose.windowSession != nil }
        let restored = try #require(env2.compose.windowSession)
        #expect(restored.draftKey == key)
        #expect(restored.document == document, "the editor state comes back from draft.json")
        #expect(restored.to.tokens.map(\.email) == ["dana@acme.example"] && restored.subject == "Plan")
    }
}
