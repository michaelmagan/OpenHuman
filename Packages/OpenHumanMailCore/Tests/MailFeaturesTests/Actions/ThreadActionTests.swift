import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct ThreadActionTests {
    @Test func starAndReadToggleWithUndo() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        let key = try #require(f.router.list?.cursor)
        let starred = try #require(f.router.list?.row(for: key)).isStarred
        #expect(await f.run(.toggleStar))
        await f.toast(starred ? "Unstarred" : "Starred")
        await eventually { f.router.list?.row(for: key)?.isStarred == !starred }
        #expect(await f.run(.undo))
        await eventually { f.router.list?.row(for: key)?.isStarred == starred }

        let unread = try #require(f.router.list?.row(for: key)).isUnread
        #expect(await f.run(.toggleRead))
        await f.toast(unread ? "Marked read" : "Marked unread")
        await eventually { f.router.list?.row(for: key)?.isUnread == !unread }
        #expect(await f.run(.redo) == false, "a new action cleared the redo stack")
    }

    @Test func spamTrashAndMoveToInboxFromTrash() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        let first = try #require(f.router.list?.cursor)
        #expect(await f.run(.spam))
        await f.toast("Marked as spam")
        await f.loaded(9)
        let second = try #require(f.router.list?.cursor)
        #expect(second != first, "the next row takes the cursor")
        #expect(await f.run(.trash))
        await f.toast("Moved to Trash")
        await f.loaded(8)

        #expect(f.registry.availability(.moveToInbox, host: f.router) == .hidden)
        f.router.go(to: .system(.trash))
        await eventually { f.router.list?.location == .system(.trash) && f.router.list?.row(for: second) != nil }
        f.router.list?.setCursor(second)
        #expect(f.router.actionContext().location == .system(.trash))
        #expect(await f.run(.moveToInbox))
        await f.toast("Moved to Inbox")
        await eventually { f.router.list?.row(for: second) == nil }
        #expect(f.store.labelNames(of: second).contains { $0.uppercased() == "INBOX" })
    }

    @Test func undoCoversQueuedAndAppliedChanges() async throws {
        let queued = ActionFixture(options: .init(remoteAck: .manual))
        await queued.loaded(10)
        #expect(await queued.run(.markDone))
        await queued.loaded(9)
        #expect(queued.store.pendingOperationCount > 0)
        #expect(await queued.run(.undo))
        await queued.loaded(10)
        #expect(queued.store.pendingOperationCount == 0, "cancelled before reaching Gmail")

        let applied = ActionFixture(options: .init(remoteAck: .immediate))
        await applied.loaded(10)
        let target = try #require(applied.router.list?.cursor)
        #expect(await applied.run(.markDone))
        await applied.loaded(9)
        #expect(await applied.run(.undo))
        await applied.loaded(10)
        await eventually { applied.router.list?.cursor == target }
        #expect(await applied.run(.redo))
        await applied.loaded(9)
    }

    @Test func multiSelectIsOneBatchEntry() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        let rows = f.rows.map(\.id)
        #expect(await f.run(.toggleCheck))
        #expect(await f.run(.extendSelectionDown))
        #expect(await f.run(.extendSelectionDown))
        let state = try #require(f.router.active)
        #expect(state.selection.checked == Set(rows[0...2]))
        #expect(f.router.actionContext().selection == Array(rows[0...2]))
        #expect(f.registry.availability(.clearChecks, host: f.router) == .enabled)

        #expect(await f.run(.markDone))
        await f.toast("Marked 3 conversations done")
        await f.loaded(7)
        #expect(state.selection.checked.isEmpty, "the action consumed the checks")
        #expect(f.env.undo?.stack.count == 1, "one entry for the batch")
        #expect(await f.run(.undo))
        await f.loaded(10)

        #expect(await f.run(.checkAll))
        #expect(state.selection.checked.count == 10)
        #expect(await f.run(.clearChecks))
        #expect(state.selection.checked.isEmpty)
        #expect(await f.run(.clearChecks) == false, "Esc passes on when nothing is checked")
    }

    @Test(arguments: BatchAction.allCases)
    func everyBatchActionIsOneEntryAndOneUndoRestoresTheBatch(_ action: BatchAction) async throws {
        let f = ActionFixture(corpus: .rich(threadCount: 60, now: fixedNow), options: .init(remoteAck: .manual))
        await f.loaded()
        let state = try #require(f.router.active)
        await eventually { state.labels.contains { $0.displayName == "Clients" } }
        let clients = try #require(state.labels.first { $0.displayName == "Clients" })
        #expect(await f.run(.checkAll))
        let batch = f.router.actionContext().selection
        #expect(batch.count == f.rows.count && batch.count > 3)
        let before = Dictionary(uniqueKeysWithValues: batch.map { ($0, f.store.labelNames(of: $0)) })
        let handler = try #require(f.registry.threadActions)
        switch action {
        case .markDone: #expect(await f.run(.markDone))
        case .trash: #expect(await f.run(.trash))
        case .spam: #expect(await f.run(.spam))
        case .star: #expect(await f.run(.toggleStar))
        case .read: #expect(await f.run(.toggleRead))
        case .label: await handler.setLabels(batch, add: [clients], remove: [], host: f.router)?.value
        case .move: await handler.move(batch, to: clients, host: f.router)?.value
        case .snooze: await handler.snooze(batch, until: fixedNow.addingTimeInterval(86_400), host: f.router)?.value
        case .createLabel:
            await handler.createLabel(named: "Synthetic batch", account: AccountID(1), applyTo: batch, host: f.router)?.value
        }
        await eventually { f.env.undo?.stack.count == 1 }
        let entry = try #require(f.env.undo?.stack.last)
        #expect(Set(entry.threads).isSubset(of: Set(batch)) && !entry.threads.isEmpty, "\(action)")
        let toast = try #require(f.env.notices.toasts.first { $0.style == .undo })
        #expect(toast.actionTitle == "Undo" && toast.shortcut == "⌘Z", "\(action)")
        #expect(f.store.pendingOperationCount > 0)
        #expect(await f.run(.undo))
        await eventually { batch.allSatisfy { f.store.labelNames(of: $0) == before[$0] } }
        #expect(f.store.pendingOperationCount == 0, "\(action): cancelled before reaching Gmail")
        #expect(f.env.undo?.stack.isEmpty == true)
    }

    enum BatchAction: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case markDone, trash, spam, star, read, label, move, snooze, createLabel
        var testDescription: String { rawValue }
    }

    @Test func aBatchUndoAfterGmailHasItRestoresEachConversation() async throws {
        let f = ActionFixture(options: .init(remoteAck: .immediate))
        await f.loaded(10)
        let rows = f.rows.map(\.id)
        for key in rows.prefix(2) where f.router.list?.row(for: key)?.isStarred != true {
            f.router.list?.setCursor(key)
            #expect(await f.run(.toggleStar))
            await eventually { f.router.list?.row(for: key)?.isStarred == true }
        }
        if let last = rows.last, f.router.list?.row(for: last)?.isStarred == true {
            f.router.list?.setCursor(last)
            #expect(await f.run(.toggleStar))
            await eventually { f.router.list?.row(for: last)?.isStarred == false }
        }
        let starred = Set(rows.filter { f.router.list?.row(for: $0)?.isStarred == true })
        #expect(starred.count >= 2 && starred.count < rows.count)
        let before = Dictionary(uniqueKeysWithValues: rows.map { ($0, f.store.labelNames(of: $0)) })
        #expect(await f.run(.checkAll))
        #expect(await f.run(.toggleStar))
        let changing = rows.count - starred.count
        await f.toast(changing == 1 ? "Starred" : "Starred \(changing) conversations")
        await eventually { rows.allSatisfy { f.router.list?.row(for: $0)?.isStarred == true } }
        #expect(await f.run(.undo))
        await eventually { rows.allSatisfy { f.store.labelNames(of: $0) == before[$0] } }
        #expect(starred.allSatisfy { f.router.list?.row(for: $0)?.isStarred == true }, "stars from before stay")

        #expect(await f.run(.checkAll))
        #expect(await f.run(.markDone))
        await f.toast("Marked 10 conversations done")
        await f.loaded(0)
        #expect(await f.run(.undo))
        await f.loaded(10)
        #expect(Set(f.rows.map(\.id)) == Set(rows))
    }

    @Test func doneAndNextInAConversation() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        let rows = f.rows.map(\.id)
        f.router.open(rows[3])
        #expect(f.router.actionContext().scope == .reader)
        #expect(f.router.actionContext().selection == [rows[3]])
        #expect(await f.run(.spam))
        #expect(f.router.reader?.thread == rows[4], "spam in a conversation opens the next (older) one")
        #expect(await f.run(.markDone))
        #expect(f.router.reader?.thread == rows[5])
        #expect(await f.run(.toggleStar))
        #expect(f.router.reader?.thread == rows[5], "a star keeps the conversation open")
        let last = try #require(f.rows.last?.id)
        let before = f.rows[f.rows.count - 2].id
        f.router.open(last)
        #expect(await f.run(.trash))
        #expect(f.router.reader?.thread == before)
    }

    @Test func pickersArePresentationsAndCallBackWithUndo() async throws {
        let f = ActionFixture(corpus: .rich(threadCount: 60, now: fixedNow))
        await f.loaded()
        let state = try #require(f.router.active)
        await eventually { state.labels.contains { $0.displayName == "Clients" } }
        let clients = try #require(state.labels.first { $0.displayName == "Clients" })
        let key = try #require(f.router.list?.cursor)
        let before = f.store.labelNames(of: key)
        #expect(inInbox(f, key) && !before.contains("Clients"))

        #expect(await f.run(.label))
        guard case .labelPicker(let targets, let mode)? = f.presenter.shown.last else {
            Issue.record("no label picker")
            return
        }
        #expect(targets == [key] && mode == .label)
        await f.registry.threadActions?.setLabels([key], add: [clients], remove: [], host: f.router)?.value
        await f.toast("Labeled Clients")
        #expect(f.store.labelNames(of: key) == before.union(["Clients"]))
        #expect(await f.run(.undo))
        #expect(f.store.labelNames(of: key) == before)

        #expect(await f.run(.move))
        #expect(f.presenter.lastKind == .labelPicker)
        await f.registry.threadActions?.move([key], to: clients, host: f.router)?.value
        await f.toast("Moved to Clients")
        await eventually { f.router.list?.row(for: key) == nil }
        #expect(await f.run(.undo))
        await eventually { f.router.list?.row(for: key) != nil }

        f.router.list?.setCursor(key)
        #expect(await f.run(.snooze))
        #expect(f.presenter.lastKind == .snoozePicker)
        let until = fixedNow.addingTimeInterval(3 * 86_400)
        f.registry.threadActions?.timeZone = TimeZone(identifier: "UTC")!
        f.registry.threadActions?.locale = Locale(identifier: "en_US_POSIX")
        await f.registry.threadActions?.snooze([key], until: until, host: f.router)?.value
        await eventually { f.env.notices.toasts.contains { $0.message.hasPrefix("Snoozed until ") } }
        await eventually { f.router.list?.row(for: key) == nil }
        #expect(await f.run(.undo))
        await eventually { f.router.list?.row(for: key) != nil }

        f.router.list?.setCursor(key)
        #expect(await f.run(.remind))
        guard case .remindPicker(let thread)? = f.presenter.shown.last else {
            Issue.record("no remind picker")
            return
        }
        #expect(thread == key)
        await f.registry.threadActions?.remind(key, at: until, kind: .ifNoReply, host: f.router)?.value
        await eventually { f.env.notices.toasts.contains { $0.message.hasSuffix("if no reply") } }
        await eventually { f.router.list?.row(for: key)?.reminderAt != nil }
        #expect(f.registry.availability(.clearReminder, host: f.router) == .enabled)
        #expect(await f.run(.clearReminder))
        await f.toast("Reminder cleared")
        await eventually { f.router.list?.row(for: key)?.reminderAt == nil }
    }

    @Test func withoutAPresenterPickerActionsAreHidden() async throws {
        let f = ActionFixture(presenter: false)
        await f.loaded(10)
        for id in [ActionID.label, .move, .snooze, .remind, .createLabel, .shortcutHelp, .search, .compose, .reply] {
            #expect(f.registry.availability(id, host: f.router) == .hidden, "\(id)")
            #expect(await f.run(id) == false, "\(id): the key passes on")
        }
        #expect(f.registry.availability(.commandPalette, host: f.router) == .enabled, "the palette model always opens")
    }

    @Test func composeRoutesOnlyAskTheComposerToOpen() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        let key = try #require(f.router.list?.cursor)
        #expect(await f.run(.reply))
        guard case .compose(.reply(let thread))? = f.presenter.shown.last else {
            Issue.record("no reply request")
            return
        }
        #expect(thread == key)
        #expect(await f.run(.compose))
        #expect(await f.run(.forward))
        #expect(f.store.sentMessages.isEmpty && f.store.heldSendCount == 0, "nothing sends")
        #expect(f.registry.handler(for: .send) == nil && f.registry.handler(for: .reviewSend) is ReviewActionHandler)
        let composer = ActionContext(scope: .composer, canUndo: false)
        #expect(f.registry.availability(.send, host: f.router, context: composer) == .hidden)
    }

    func newsletter(_ f: ActionFixture, index: Int) async throws -> ThreadKey {
        let key = ThreadKey(account: AccountID(1), rowID: Int64(index + 1), gmailThreadID: GmailThreadID("fake-t\(index + 1)"))
        f.router.open(key)
        await eventually { f.router.reader?.messages.isEmpty == false }
        return key
    }

    static let lettersSender = "letters@weekly.example"

    func letters(_ f: ActionFixture) async throws -> (thread: ThreadKey, older: ThreadKey, message: MessageKey) {
        let from = EmailAddress(name: "Weekly Letters", email: Self.lettersSender)
        f.store.deliverMessage(account: AccountID(1), from: from, subject: "Letters 1", unread: false,
                               at: fixedNow.addingTimeInterval(60), unsubscribe: .oneClick(host: "weekly.example"))
        let message = f.store.deliverMessage(account: AccountID(1), from: from, subject: "Letters 2", unread: false,
                                             at: fixedNow.addingTimeInterval(120),
                                             unsubscribe: .oneClick(host: "weekly.example"))
        await untilObserved { f.rows.count == 12 && f.rows.prefix(2).map(\.subject) == ["Letters 2", "Letters 1"] }
        let thread = f.rows[0].id, older = f.rows[1].id
        f.router.open(thread)
        await untilObserved { f.router.reader?.messages.last?.id == message }
        return (thread, older, message)
    }

    func heldWindow(_ f: ActionFixture) throws -> (ThreadActionHandler, TestGate) {
        let handler = try #require(f.registry.threadActions)
        let window = TestGate()
        handler.unsubscribeWindow = .seconds(3_600)
        handler.sleep = { _ in await window.wait() }
        return (handler, window)
    }

    func endWindow(_ handler: ThreadActionHandler, _ window: TestGate) async {
        let held = handler.heldUnsubscribeTasks
        window.release()
        for task in held { await task.value }
    }

    func inTrash(_ f: ActionFixture, _ key: ThreadKey) -> Bool {
        f.store.isInTrash(key)
    }

    func inInbox(_ f: ActionFixture, _ key: ThreadKey) -> Bool {
        f.store.labelNames(of: key).contains { $0.uppercased() == "INBOX" }
    }

    func archived(_ f: ActionFixture, _ key: ThreadKey) -> Bool {
        f.store.isVisible(key) && !inInbox(f, key)
    }

    @Test func oneClickUnsubscribeMovesOnAtOnceAndSendsOnlyAfterItsUndoWindow() async throws {
        let f = ActionFixture()
        let (handler, window) = try heldWindow(f)
        let (thread, older, message) = try await letters(f)
        let domain = try #require(f.router.actionContext().senderDomain)
        #expect(await f.run(.unsubscribe))
        #expect(f.router.list?.row(for: thread) == nil, "hidden before the window ends")
        #expect(f.router.reader?.thread == older, "the reader moved on")
        #expect(archived(f, thread) && !inTrash(f, thread), "marked done on this Mac")
        let toast = try #require(f.env.notices.toasts.first { $0.message == "Unsubscribing from \(domain)…" })
        #expect(toast.style == .undo && toast.actionTitle == "Undo" && toast.shortcut == "⌘Z")
        #expect(!f.presenter.shown.contains { $0.kind == .compose || $0.kind == .openURL }, "nothing else opens")
        #expect(f.store.unsubscribeRequests.isEmpty && handler.heldUnsubscribeCount == 1, "nothing goes out in the window")
        await endWindow(handler, window)
        #expect(f.store.unsubscribeRequests == [message])
        let offer = try #require(f.env.notices.toasts.first { $0.message.hasPrefix("Unsubscribe request sent.") })
        #expect(offer.message.contains("2 conversations"))
        #expect(offer.actionTitle == "Archive all 1" && offer.secondaryActionTitle == "Move 2 to Trash")
        await f.env.notices.activate(offer.id)
        #expect(f.router.list?.row(for: older) == nil)
        #expect(archived(f, older))
    }

    @Test func undoInsideTheWindowCancelsTheRequestAndBringsTheConversationBack() async throws {
        let f = ActionFixture()
        let (handler, window) = try heldWindow(f)
        let (thread, older, _) = try await letters(f)
        #expect(await f.run(.unsubscribeAndTrash))
        #expect(f.router.list?.row(for: thread) == nil && f.router.reader?.thread == older)
        #expect(inTrash(f, thread), "trashed at once, not after the request")
        #expect(!inTrash(f, older), "the rest of the sender's mail waits for the request")
        let held = handler.heldUnsubscribeTasks
        #expect(await f.run(.undo))
        #expect(f.toastMessages.contains("Unsubscribe canceled. Nothing was sent."))
        #expect(!inTrash(f, thread))
        #expect(f.router.reader?.thread == thread, "the conversation is open again")
        window.release()
        for task in held { await task.value }
        #expect(f.store.unsubscribeRequests.isEmpty && handler.heldUnsubscribeCount == 0)
        #expect(inInbox(f, older) && !inTrash(f, older))
    }

    @Test func unsubscribeAndTrashTrashesThisOneAtOnceAndTheRestAfterTheRequest() async throws {
        let f = ActionFixture()
        let (handler, window) = try heldWindow(f)
        let (thread, older, message) = try await letters(f)
        #expect(f.registry.availability(.unsubscribeAndTrash, host: f.router).isEnabled)
        #expect(await f.run(.unsubscribeAndTrash))
        #expect(inTrash(f, thread) && !inTrash(f, older))
        await endWindow(handler, window)
        #expect(f.store.unsubscribeRequests == [message])
        #expect(inTrash(f, older))
        #expect(f.rows.allSatisfy { row in !row.participants.contains { $0.email == Self.lettersSender } },
                "no inbox row from the sender is left")
        #expect(await f.run(.undo))
        #expect(!inTrash(f, older), "one undo restores the swept batch")
        #expect(inInbox(f, older))
    }

    @Test func aFailedUnsubscribeRequestPutsTheConversationBack() async throws {
        let f = ActionFixture()
        let (handler, window) = try heldWindow(f)
        let (thread, older, _) = try await letters(f)
        #expect(await f.run(.unsubscribe))
        #expect(f.router.reader?.thread == older && archived(f, thread))
        f.store.failNextCommand()
        await endWindow(handler, window)
        #expect(f.store.unsubscribeRequests.isEmpty)
        #expect(f.toastMessages.contains("Couldn't send the unsubscribe request"))
        #expect(!f.toastMessages.contains { $0.hasPrefix("Unsubscribing from") })
        #expect(inInbox(f, thread), "back in the Inbox")
        #expect(f.router.reader?.thread == thread, "and open again")
        await untilObserved { f.rows.contains { $0.id == thread } }
    }

    @Test func aFailedWriteReopensTheConversationTheReaderMovedOffFrom() async throws {
        let f = ActionFixture()
        await untilObserved { f.router.list?.state == .loaded && f.rows.count == 10 }
        let rows = f.rows.map(\.id)
        _ = try await f.store.apply(.markRead([rows[3], rows[4]]))
        await untilObserved { f.rows.count == 10 && !f.rows[3].isUnread && !f.rows[4].isUnread }
        f.router.open(rows[3])
        f.store.failNextCommand()
        #expect(f.registry.perform(.trash, source: .keyboard, host: f.router))
        #expect(f.router.reader?.thread == rows[4], "the reader moved on at once")
        await f.registry.lastTask?.value
        #expect(f.toastMessages.contains("Couldn't move 1 conversation to Trash"))
        #expect(f.router.reader?.thread == rows[3], "the failed write brought the conversation back")
        #expect(f.router.list?.optimisticKeys.isEmpty == true)
        await untilObserved { f.rows.contains { $0.id == rows[3] } }
    }

    @Test func anArchiveTheWritePortRefusesComesBackWithARetryAndNoUndoEntry() async throws {
        let f = ActionFixture()
        await untilObserved { f.router.list?.state == .loaded && f.rows.count == 10 }
        let target = try #require(f.router.list?.cursor)
        f.store.failNextCommand(.unavailable("Gmail can't be reached"))
        #expect(await f.run(.markDone))
        let message = "Couldn't mark 1 conversation done"
        let toast = try #require(f.env.notices.toasts.first { $0.message == message })
        #expect(toast.style == .error && toast.actionTitle == "Retry")
        #expect(f.env.undo?.stack.isEmpty == true, "nothing to undo for a change that didn't happen")
        #expect(f.router.list?.optimisticKeys.isEmpty == true)
        #expect(f.store.pendingOperationCount == 0)
        await untilObserved { f.rows.contains { $0.id == target } }
    }

    @Test func cleanupOfferTrashesEverythingFromTheSenderWithOneUndoEntry() async throws {
        let f = ActionFixture()
        let (handler, window) = try heldWindow(f)
        let (thread, older, _) = try await letters(f)
        #expect(await f.run(.unsubscribe))
        await endWindow(handler, window)
        let offer = try #require(f.env.notices.toasts.first { $0.message.hasPrefix("Unsubscribe request sent.") })
        #expect(offer.message.contains("2 conversations from this sender"))
        #expect(offer.secondaryActionTitle == "Move 2 to Trash")
        let before = f.env.undo?.stack.count ?? 0
        await f.env.notices.activateSecondary(offer.id)
        #expect((f.env.undo?.stack.count ?? 0) == before + 1, "one batch, one undo entry")
        #expect(inTrash(f, thread) && inTrash(f, older))
        #expect(await f.run(.undo))
        #expect(!inTrash(f, thread) && !inTrash(f, older))
    }

    @Test func theCleanupOfferWithNothingLeftInTheInboxOffersOnlyTrash() async throws {
        let f = ActionFixture()
        let (handler, window) = try heldWindow(f)
        let (thread, older, _) = try await letters(f)
        _ = try await f.store.apply(.markDone([older]))
        #expect(await f.run(.unsubscribe))
        await endWindow(handler, window)
        let offer = try #require(f.env.notices.toasts.first { $0.message.hasPrefix("Unsubscribe request sent.") })
        #expect(offer.actionTitle == "Move 2 to Trash" && offer.secondaryActionTitle == nil)
        await f.env.notices.activate(offer.id)
        #expect(inTrash(f, thread) && inTrash(f, older))
    }

    @Test func cleanupOfferKeepAndSwitchOff() async throws {
        let f = ActionFixture()
        let (handler, window) = try heldWindow(f)
        let (thread, older, _) = try await letters(f)
        #expect(await f.run(.unsubscribe))
        await endWindow(handler, window)
        let offer = try #require(f.env.notices.toasts.first { $0.message.hasPrefix("Unsubscribe request sent.") })
        f.env.notices.dismiss(offer.id)
        #expect(!inTrash(f, thread) && archived(f, thread), "Keep leaves the unsubscribed conversation done")
        #expect(inInbox(f, older) && !inTrash(f, older), "Keep leaves the rest of the sender's mail alone")

        let g = ActionFixture()
        let (other, gate) = try heldWindow(g)
        g.env.system.preferences.unsubscribeCleanupOffer = false
        _ = try await letters(g)
        #expect(await g.run(.unsubscribe))
        await endWindow(other, gate)
        let plain = try #require(g.env.notices.toasts.first { $0.message == "Unsubscribe request sent" })
        #expect(plain.secondaryActionTitle == nil && plain.actionTitle == nil)
    }

    @Test func cleanupPreferenceDefaultsOnAndWordingCounts() {
        #expect(SystemPreferences(defaults: ScopedDefaults("openhuman.test.unsub-cleanup")).unsubscribeCleanupOffer)
        #expect(ThreadActionHandler.cleanupMessage(count: 1, capped: false, hasAddress: true).contains("1 conversation from"))
        #expect(ThreadActionHandler.cleanupMessage(count: 3, capped: false, hasAddress: true).contains("3 conversations"))
        #expect(ThreadActionHandler.cleanupMessage(count: 500, capped: true, hasAddress: true).contains("500+"))
    }

    @Test func undoInsideTheUnsubscribeWindowSendsNothing() async throws {
        let f = ActionFixture(corpus: .rich(threadCount: 60, now: fixedNow))
        await f.loaded()
        let handler = try #require(f.registry.threadActions)
        let woke = Counter()
        handler.sleep = { _ in
            defer { woke.increment() }
            try await Task.sleep(for: .seconds(3_600))
        }
        _ = try await newsletter(f, index: 5)
        #expect(await f.run(.unsubscribe))
        await eventually { handler.heldUnsubscribeCount == 1 }
        #expect(await f.run(.undo))
        await f.toast("Unsubscribe canceled. Nothing was sent.")
        await eventually { woke.value == 1 }
        #expect(handler.heldUnsubscribeCount == 0 && f.store.unsubscribeRequests.isEmpty)
        #expect(f.env.undo?.stack.contains { String(localized: $0.title).hasPrefix("Unsubscribing") } == false)
    }

    @Test func mailtoAndLinkUnsubscribeNeverSendOrFetch() async throws {
        let f = ActionFixture(corpus: .rich(threadCount: 60, now: fixedNow))
        await f.loaded()
        _ = try await newsletter(f, index: 6)
        #expect(await f.run(.unsubscribe))
        await eventually { f.presenter.lastKind == .compose }
        guard case .compose(.mailto(let address, _))? = f.presenter.shown.last else {
            Issue.record("no prefilled composer")
            return
        }
        #expect(address.email == "unsubscribe@news.example")
        #expect(f.store.sentMessages.isEmpty && f.store.unsubscribeRequests.isEmpty)

        _ = try await newsletter(f, index: 7)
        #expect(await f.run(.unsubscribe))
        let offer = try #require(await firstToast(f, "This sender's unsubscribe is a web page"))
        #expect(offer.actionTitle == "Open unsubscribe page" && offer.secondaryActionTitle == "Cancel")
        #expect(f.presenter.lastKind != .openURL, "nothing opened before the choice")
        await f.env.notices.activate(offer.id)
        await eventually { f.presenter.lastKind == .openURL }
        guard case .openURL(let url)? = f.presenter.shown.last else {
            Issue.record("no browser request")
            return
        }
        #expect(url.absoluteString == "https://news.example/preferences")
        #expect(f.store.unsubscribeRequests.isEmpty, "Mail itself fetched and sent nothing")
    }

    @Test func unsubscribeNeedsAnOpenConversation() async throws {
        let f = ActionFixture(corpus: .rich(threadCount: 60, now: fixedNow))
        await f.loaded()
        #expect(f.registry.availability(.unsubscribe, host: f.router) == .disabled(.other("Open the conversation first")))
        _ = try await newsletter(f, index: 5)
        #expect(f.registry.availability(.unsubscribe, host: f.router).isEnabled)
    }
}

@MainActor
private func firstToast(_ f: ActionFixture, _ message: String) async -> Toast? {
    await eventually { f.env.notices.toasts.contains { $0.message == message } }
    return f.env.notices.toasts.first { $0.message == message }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
