import Foundation
import MailActions
import MailModel
import OpenHumanCore

/// Checked drafts sent together from the Drafts list: one undo entry holds every send in the batch, each draft goes
/// out from its own account through the held-send window, and one notice reports what went out and what stayed.
struct BatchSend {
    enum Kind: Equatable {
        /// Checked drafts from the Drafts list. Reminders off is the person's choice, so the AI catch-up skips them
        case checked
        /// One scheduled draft sent before its time. Undo puts its schedule back
        case scheduledNow(at: Date, condition: SendLaterCondition)
    }

    enum State: Equatable {
        case held
        case sending
        case cancelled
        case sent
        case failed(String?)
        case gone
    }

    struct Item {
        let id: UUID
        let draft: DraftSummary
        let token: SendToken
        var reminder: PendingSendReminder?
        var state: State = .held
    }

    struct Failure: Equatable {
        let draft: DraftSummary
        let detail: String?
    }

    var kind: Kind = .checked
    var items: [Item] = []
    var failedAtStart: [Failure] = []
    var reminders: SentMailReminderRule?
    var undoEntry: UndoCoordinator.Entry.ID?

    var isSettled: Bool {
        items.allSatisfy { $0.state != .held && $0.state != .sending }
    }

    var failures: [Failure] {
        failedAtStart + items.compactMap { item in
            if case .failed(let detail) = item.state { Failure(draft: item.draft, detail: detail) } else { nil }
        }
    }

    var sentCount: Int { items.count { $0.state == .sent } }
}

/// How a large batch is spread out: past `threshold` drafts, each chunk of `chunkSize` is held `pause` longer than the
/// one before, so the send queue and the provider's rate limits get a few at a time. The batch keeps one undo entry,
/// which ends with the first chunk's window.
public struct BatchSendPacing: Sendable, Equatable {
    public var threshold: Int
    public var chunkSize: Int
    public var pause: Duration

    public init(threshold: Int = 25, chunkSize: Int = 10, pause: Duration = .seconds(5)) {
        self.threshold = threshold
        self.chunkSize = chunkSize
        self.pause = pause
    }

    /// The extra hold for the draft queued at `index` in a batch of `count`.
    public func extraHold(at index: Int, of count: Int) -> Duration {
        guard count > threshold, chunkSize > 0, index > 0 else { return .zero }
        return pause * (index / chunkSize)
    }
}

/// The question asked before a scheduled draft goes out ahead of its time.
public struct ScheduledSendNowQuestion: Sendable, Equatable {
    public var subject: String
    public var recipients: String
    public var scheduledFor: String

    public init(subject: String, recipients: String, scheduledFor: String) {
        self.subject = subject
        self.recipients = recipients
        self.scheduledFor = scheduledFor
    }

    public var title: String { String(localized: "Send now?") }

    public var message: String {
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return subject.isEmpty
            ? String(localized: "The draft to \(recipients) is scheduled for \(scheduledFor). It will be sent now instead.")
            : String(localized: "“\(subject)” to \(recipients) is scheduled for \(scheduledFor). It will be sent now instead.")
    }

    public var confirmTitle: String { String(localized: "Send Now") }
}

/// What came back from starting a batch. Sends are still in their undo window when this is returned.
public struct BatchSendStart: Sendable, Equatable {
    public var batch: UUID?
    public var queued: [DraftKey]
    public var failed: [DraftKey]
}

extension ComposeManager {
    func batchSendAction(threads: [ThreadKey]) -> ActionPerformance {
        guard canSend else {
            let title = environment.actions.descriptor(.sendDrafts)?.title ?? String(localized: "Send drafts")
            environment.actions.refuse(.sendDrafts, .unavailable(title))
            return .done
        }
        guard !threads.isEmpty else { return .notHandled }
        return .started(Task { [weak self] in _ = await self?.presentBatchSend(threads: threads) })
    }

    /// Reads the checked rows' drafts, works out which can go and which stay, and shows the confirmation.
    @discardableResult
    public func presentBatchSend(threads: [ThreadKey]) async -> BatchSendModel? {
        guard canSend, !threads.isEmpty else { return nil }
        var drafts: [DraftSummary] = []
        var accounts: [AccountID] = []
        for thread in threads where !accounts.contains(thread.account) { accounts.append(thread.account) }
        for account in accounts {
            drafts += await Self.first(environment.data.drafts(account, review: false)) ?? []
        }
        let open = Set(sessions.filter(\.isOpen).compactMap(\.draftKey))
        let plan = BatchSendPlan.make(rows: threads, drafts: drafts, openInComposer: open)
        let rule = await SentMailReminderRule.load(from: environment.settings)
        let undoSeconds = AppSettings.undoSendHold(await Self.read(environment.settings, AppSettings.undoSendSeconds) ?? 10)
        let state = environment.router.active
        let names = Dictionary(environment.router.accounts.map { ($0.id, $0.account.alias ?? $0.account.email) },
                               uniquingKeysWith: { first, _ in first })
        let model = BatchSendModel(plan: plan, remindersOn: rule.enabled, reminderDays: rule.days,
                                   undoSeconds: undoSeconds, accountNames: names,
                                   formatDate: { [weak self] in self?.formatSendAt($0) ?? $0.formatted() }) {
            [weak self, weak state] plan, remindersOn in
            guard let self else { return nil }
            self.environment.overlays.dismiss()
            if let state {
                let checked = Set(threads)
                state.selection.restoreChecked(plan.skipped.compactMap(\.thread).filter(checked.contains))
            }
            var batchRule = rule
            batchRule.enabled = true
            let reminders = remindersOn ? batchRule : nil
            let drafts = plan.ready.map(\.draft)
            let task = Task { [weak self] in _ = await self?.sendBatch(drafts, reminders: reminders) }
            self.track(task)
            return task
        }
        environment.overlays.presentBatchSend(model)
        return model
    }

    /// Sends each draft through the held-send window, grouped by account in the order given. `reminders` is the rule
    /// for this batch's "remind me if no reply" reminders, or nil for none; the stored setting is not changed.
    @discardableResult
    public func sendBatch(_ drafts: [DraftSummary], reminders: SentMailReminderRule?) async -> BatchSendStart {
        await startBatch(drafts, reminders: reminders, kind: .checked)
    }

    @discardableResult
    func startBatch(_ drafts: [DraftSummary], reminders: SentMailReminderRule?, kind: BatchSend.Kind) async -> BatchSendStart {
        var start = BatchSendStart(batch: nil, queued: [], failed: [])
        guard canSend, let commands = environment.commands, !drafts.isEmpty else { return start }
        let seconds = AppSettings.undoSendHold(await Self.read(environment.settings, AppSettings.undoSendSeconds) ?? 10)
        undoSendSeconds = seconds
        var batch = BatchSend(kind: kind, reminders: reminders)
        let ordered = Self.byAccount(drafts)
        for draft in ordered {
            do {
                let hold = Duration.seconds(seconds) + batchPacing.extraHold(at: batch.items.count, of: ordered.count)
                let token = try await commands.send(draft.id, undoWindow: hold)
                var item = BatchSend.Item(id: UUID(), draft: draft, token: token)
                if let reminders { item.reminder = rememberBatchReminder(draft, rule: reminders) }
                let until = Date().addingTimeInterval(token.sendAfter.timeIntervalSince(timing.now()))
                addSending(sendingMessage(item, state: .queued(until: until)))
                batch.items.append(item)
                start.queued.append(draft.id)
            } catch {
                batch.failedAtStart.append(BatchSend.Failure(draft: draft, detail: (error as? MailPortError)?.description))
                start.failed.append(draft.id)
            }
        }
        let id = UUID()
        guard !batch.items.isEmpty else {
            report(batch)
            return start
        }
        start.batch = id
        batches[id] = batch
        let count = batch.items.count
        let earliest = batch.items.map(\.token.sendAfter).min() ?? timing.now()
        let expiresAt = Date().addingTimeInterval(earliest.timeIntervalSince(timing.now()))
        let title: LocalizedStringResource
        if case .scheduledNow = kind, let only = batch.items.first {
            let fields = only.draft.fields
            title = "Sending to \(Self.recipientSummary(fields.to + fields.cc + fields.bcc))…"
        } else {
            title = count == 1 ? "Sending 1 draft…" : "Sending \(count) drafts…"
        }
        if let entry = push(title, .sendBatch(batch: id), expiresAt: expiresAt) {
            batches[id]?.undoEntry = entry
            for item in batch.items { sendingUndoEntries[item.id] = entry }
        }
        updateSendingLine()
        for item in batch.items { track(watchBatchItem(id, item: item)) }
        // Why: every reminder intent is stored before the batch is reported started, so all survive a relaunch
        if batch.items.contains(where: { $0.reminder != nil }) { await sendReminderUpdate?.value }
        return start
    }

    func sendScheduledNowAction(in thread: ThreadKey) -> ActionPerformance {
        guard canSend else {
            let title = environment.actions.descriptor(.sendScheduledNow)?.title ?? String(localized: "Send now")
            environment.actions.refuse(.sendScheduledNow, .unavailable(title))
            return .done
        }
        return .started(Task { [weak self] in _ = await self?.sendScheduledNow(in: thread) })
    }

    /// Sends the conversation's scheduled draft now instead of at its time, once the person confirms. It goes through
    /// the held-send window like any send, and Undo puts the schedule back. Nil when nothing was sent.
    @discardableResult
    public func sendScheduledNow(in thread: ThreadKey) async -> BatchSendStart? {
        guard canSend, let commands = environment.commands else { return nil }
        guard let row = await scheduledDraft(in: thread), let at = row.sendAt else {
            nothingScheduled()
            return nil
        }
        let open = Set(sessions.filter(\.isOpen).compactMap(\.draftKey))
        if let reason = BatchSendPlan.contentReason(row, openInComposer: open) {
            let text = BatchSendModel.text(for: reason) { [weak self] in self?.formatSendAt($0) ?? $0.formatted() }
            environment.notices.post(String(localized: "Not sent: \(text)."), style: .info, duration: NoticeCenter.infoDuration)
            return nil
        }
        let condition = row.sendCondition
        let fields = row.fields
        let when = formatSendAt(at) + (condition == .ifNoReply ? Self.ifNoReplySuffix : "")
        let question = ScheduledSendNowQuestion(subject: fields.subject,
                                                recipients: Self.recipientSummary(fields.to + fields.cc + fields.bcc),
                                                scheduledFor: when)
        guard await environment.system.platform.confirmSendScheduledNow(question) else { return nil }
        // Why: the schedule may have changed or gone out while the question was up
        guard let current = await Self.first(environment.data.draft(row.id)) ?? nil, current.status == .scheduled,
              current.sendAt == at else {
            nothingScheduled()
            return nil
        }
        do {
            try await commands.cancelScheduledSend(row.id)
        } catch {
            let detail = (error as? MailPortError)?.description ?? String(localized: "Try again.")
            environment.notices.post(String(localized: "Couldn't send it now. \(detail)"), style: .error)
            return nil
        }
        forgetSending(draft: row.id)
        let unscheduled = await Self.first(environment.data.draft(row.id)) ?? nil
        let start = await startBatch([unscheduled ?? current], reminders: nil,
                                     kind: .scheduledNow(at: at, condition: condition))
        guard start.batch == nil else { return start }
        guard at.timeIntervalSince(timing.now()) >= Self.restoreLead else {
            environment.notices.post(String(localized: "Couldn't send it now. Its scheduled time has passed, so it's back in Drafts."),
                                     style: .error)
            return start
        }
        do {
            try await restoreSchedule(draft: row.id, at: at, condition: condition)
            environment.notices.post(String(localized: "Couldn't send it now, so it stays scheduled for \(when)."),
                                     style: .error)
        } catch {
            environment.notices.post(String(localized: "Couldn't send it now. It's back in Drafts without its schedule."),
                                     style: .error)
        }
        return start
    }

    static func byAccount(_ drafts: [DraftSummary]) -> [DraftSummary] {
        var order: [AccountID] = []
        for draft in drafts where !order.contains(draft.account) { order.append(draft.account) }
        return order.flatMap { account in drafts.filter { $0.account == account } }
    }

    private func sendingMessage(_ item: BatchSend.Item, state: SendingMessage.State) -> SendingMessage {
        let fields = item.draft.fields
        let account = environment.router.accounts.first { $0.id == item.draft.account }?.account
        let from = fields.from ?? EmailAddress(name: account?.displayName, email: account?.email ?? "")
        return SendingMessage(id: item.id, draft: item.draft.id, account: item.draft.account, thread: item.draft.thread,
                              mode: item.draft.mode, from: from, to: fields.to, cc: fields.cc, bcc: fields.bcc,
                              subject: fields.subject, text: BatchSendPlan.plainText(fields),
                              attachmentNames: fields.attachments.map(\.filename), date: timing.now(), state: state)
    }

    private func rememberBatchReminder(_ draft: DraftSummary, rule: SentMailReminderRule) -> PendingSendReminder? {
        guard rule.scope == .externalRecipients,
              let account = environment.router.accounts.first(where: { $0.id == draft.account })?.account else { return nil }
        let fields = draft.fields
        guard let due = rule.dueDate(sentAt: timing.now(), recipients: (fields.to + fields.cc + fields.bcc).map(\.email),
                                     myAddresses: account.myAddresses, calendar: calendar) else { return nil }
        let intent = PendingSendReminder(draft: draft.id, thread: draft.thread, dueAt: due, kind: .ifNoReply)
        sendReminderDrafts.insert(draft.id)
        updatePendingSendReminders { list in list.filter { $0.draft != draft.id } + [intent] }
        return intent
    }

    private func watchBatchItem(_ batch: UUID, item: BatchSend.Item) -> Task<Void, Never> {
        let timing = self.timing
        let token = item.token
        return Task { [weak self] in
            let wait = token.sendAfter.timeIntervalSince(timing.now())
            if wait > 0 { try? await timing.sleep(.milliseconds(Int(wait * 1000))) }
            // Why: quitting sends held items at once and marks them sending; they are still followed to the end
            guard let self, let state = self.batchItem(batch, item.id)?.state, state == .held || state == .sending
            else { return }
            self.setBatchItem(batch, item.id, .sending)
            self.setSending(item.id, .sending)
            self.dropBatchUndoOncePast(batch)
            await self.followBatchItem(batch, item: item)
        }
    }

    private func followBatchItem(_ batch: UUID, item: BatchSend.Item) async {
        do {
            for try await row in environment.data.draft(item.draft.id) {
                guard batchItem(batch, item.id)?.state == .sending else { return }
                switch row?.status {
                case nil, .sent?:
                    await batchItemSent(batch, item: item)
                    return
                case .sending?:
                    continue
                case .failed?, .editing?:
                    finishBatchItem(batch, item, .failed(row?.lastError))
                    return
                case .scheduled?, .discarded?:
                    finishBatchItem(batch, item, .gone)
                    return
                }
            }
        } catch {}
    }

    private func batchItemSent(_ batch: UUID, item: BatchSend.Item) async {
        let rule = batches[batch]?.reminders
        let kind = batches[batch]?.kind
        finishBatchItem(batch, item, .sent)
        guard let rule else {
            if kind == .checked { await noteNoReminderWanted(item) }
            return
        }
        if let intent = item.reminder {
            await applySendReminder(intent)
        } else if rule.scope == .needsFollowUp,
                  let account = environment.router.accounts.first(where: { $0.id == item.draft.account })?.account {
            let fields = item.draft.fields
            let followUps = environment.followUps
            followUps.calendar = calendar
            await followUps.sendCommitted(draft: item.draft.id, account: account,
                                          recipients: (fields.to + fields.cc + fields.bcc).map(\.email),
                                          subject: fields.subject, text: BatchSendPlan.plainText(fields),
                                          thread: item.draft.thread, rule: rule, sentAt: timing.now())
        }
    }

    private func noteNoReminderWanted(_ item: BatchSend.Item) async {
        var conversation = item.draft.thread
        if conversation == nil { conversation = try? await environment.data.sentConversation(item.draft.id) }
        guard let thread = conversation else { return }
        await environment.followUps.noteNoReminderWanted(thread, sentAt: timing.now())
    }

    private func finishBatchItem(_ batch: UUID, _ item: BatchSend.Item, _ state: BatchSend.State) {
        setBatchItem(batch, item.id, state)
        switch state {
        case .sent:
            recovery.remove(item.draft.id)
            setSending(item.id, .sent)
        case .failed:
            forgetSendReminder(item.draft.id)
            setSending(item.id, .failed)
        case .gone, .cancelled:
            forgetSendReminder(item.draft.id)
            removeSending(item.id)
        case .held, .sending:
            break
        }
        settleBatch(batch)
    }

    private func batchItem(_ batch: UUID, _ id: UUID) -> BatchSend.Item? {
        batches[batch]?.items.first { $0.id == id }
    }

    private func setBatchItem(_ batch: UUID, _ id: UUID, _ state: BatchSend.State) {
        guard let index = batches[batch]?.items.firstIndex(where: { $0.id == id }) else { return }
        batches[batch]?.items[index].state = state
    }

    private func settleBatch(_ id: UUID) {
        guard let batch = batches[id], batch.isSettled else { return }
        dropBatchUndo(batch)
        batches[id] = nil
        report(batch)
    }

    /// Once no draft in the batch can be held back any more, its Undo toast goes, even if the pointer is keeping it.
    private func dropBatchUndoOncePast(_ id: UUID) {
        guard let batch = batches[id], !batch.items.contains(where: { $0.state == .held }) else { return }
        dropBatchUndo(batch)
        batches[id]?.undoEntry = nil
    }

    private func dropBatchUndo(_ batch: BatchSend) {
        guard let entry = batch.undoEntry else { return }
        environment.undo?.discard(entry)
    }

    private func report(_ batch: BatchSend) {
        // Why: a send-now that never started is reported by sendScheduledNow once the schedule is back
        if case .scheduledNow = batch.kind, batch.items.isEmpty { return }
        let sent = batch.sentCount
        let failures = batch.failures
        guard !failures.isEmpty else {
            guard sent > 0 else { return }
            let text: String
            if case .scheduledNow = batch.kind {
                text = String(localized: "Sent.")
            } else {
                text = sent == 1 ? String(localized: "Sent 1 draft.") : String(localized: "Sent \(sent) drafts.")
            }
            environment.notices.post(text, style: .info, duration: environment.notices.timing.brief)
            return
        }
        let failed = failures.count
        let total = sent + failed
        let message: String
        if sent > 0 {
            if failed == 1, let name = Self.noticeName(failures[0].draft) {
                message = String(localized: "\(sent) of \(total) sent. “\(name)” is still in Drafts.")
            } else {
                message = failed == 1 ? String(localized: "\(sent) of \(total) sent. 1 is still in Drafts.")
                                      : String(localized: "\(sent) of \(total) sent. \(failed) are still in Drafts.")
            }
        } else if failed == 1 {
            let detail = failures[0].detail.map { " " + $0 } ?? ""
            message = String(localized: "Couldn't send the draft.\(detail) It stays in Drafts.")
        } else {
            message = String(localized: "Couldn't send \(failed) drafts. They stay in Drafts.")
        }
        let keys = failures.map(\.draft.id)
        let reminders = batch.reminders
        let kind = batch.kind
        let account = failures[0].draft.account
        let show = NoticeCenter.Choice(String(localized: "Show Drafts")) { [weak self] in self?.showDrafts(account) }
        lastBatchFailures = keys
        environment.notices.post(message, style: .error, actionTitle: String(localized: "Retry"), duration: nil,
                                 secondary: show) { [weak self] in
            await self?.retryBatch(keys, reminders: reminders, kind: kind)
        }
    }

    /// The longest subject the one-line result notice can name next to its Retry and Show Drafts buttons.
    static let noticeNameLimit = 24

    /// A failed draft's subject for the result notice, or nil when it is empty or too long to fit.
    static func noticeName(_ draft: DraftSummary) -> String? {
        let subject = draft.fields.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return subject.isEmpty || subject.count > noticeNameLimit ? nil : subject
    }

    private func showDrafts(_ account: AccountID) {
        let router = environment.router
        if router.activeAccountID != account { router.switchAccount(to: account) }
        router.go(to: .system(.drafts))
    }

    /// Sends the drafts that failed again, after checking them as the confirmation did. Drafts that can't go now are
    /// reported and left alone.
    public func retryBatch(_ keys: [DraftKey], reminders: SentMailReminderRule?) async {
        await retryBatch(keys, reminders: reminders, kind: .checked)
    }

    func retryBatch(_ keys: [DraftKey], reminders: SentMailReminderRule?, kind: BatchSend.Kind) async {
        var rows: [DraftSummary] = []
        let failed = Set(keys)
        for key in keys {
            guard let row = await Self.first(environment.data.draft(key)) ?? nil else { continue }
            rows.append(row)
        }
        let open = Set(sessions.filter(\.isOpen).compactMap(\.draftKey))
        let ready = rows.filter { failed.contains($0.id) && BatchSendPlan.skipReason($0, openInComposer: open) == nil }
        let left = keys.count - ready.count
        if left > 0 {
            let text = left == 1 ? String(localized: "1 draft can't be sent as it is. Open it in Drafts to fix it.")
                                 : String(localized: "\(left) drafts can't be sent as they are. Open them in Drafts to fix them.")
            environment.notices.post(text, style: .info, duration: NoticeCenter.infoDuration)
        }
        guard !ready.isEmpty else { return }
        for key in ready.map(\.id) { forgetSending(draft: key) }
        await startBatch(ready, reminders: reminders, kind: kind)
    }

    func undoBatch(_ id: UUID) async throws {
        guard let commands = environment.commands, let batch = batches[id] else { return }
        var cancelled = 0
        var late = 0
        var failure: (any Error)?
        for item in batch.items {
            guard batchItem(id, item.id)?.state == .held else {
                if batchItem(id, item.id)?.state == .sending { late += 1 }
                continue
            }
            do {
                if try await commands.cancelSend(item.token) {
                    cancelled += 1
                    finishBatchItem(id, item, .cancelled)
                } else {
                    late += 1
                }
            } catch {
                failure = error
            }
        }
        if let failure, batches[id]?.items.contains(where: { $0.state == .held }) == true { throw failure }
        if case .scheduledNow(let at, let condition) = batch.kind, cancelled > 0 {
            await putScheduleBack(batch.items[0].draft.id, at: at, condition: condition)
            return
        }
        if late > 0 {
            let text = late == 1 ? String(localized: "Too late to undo 1 draft: it's already on its way.")
                                 : String(localized: "Too late to undo \(late) drafts: they're already on their way.")
            environment.notices.post(text, style: .info, duration: NoticeCenter.infoDuration)
        } else if cancelled > 0 {
            let text = cancelled == 1 ? String(localized: "Not sent. The draft is back in Drafts.")
                                      : String(localized: "Not sent. The \(cancelled) drafts are back in Drafts.")
            environment.notices.post(text, style: .info, duration: NoticeCenter.infoDuration)
        }
    }

    private func putScheduleBack(_ draft: DraftKey, at date: Date, condition: SendLaterCondition) async {
        guard date.timeIntervalSince(timing.now()) >= Self.restoreLead else {
            environment.notices.post(String(localized: "Not sent. Its scheduled time has passed, so it's back in Drafts."),
                                     style: .info, duration: NoticeCenter.infoDuration)
            return
        }
        do {
            try await restoreSchedule(draft: draft, at: date, condition: condition)
        } catch {
            let detail = (error as? MailPortError)?.description ?? String(localized: "Try again.")
            environment.notices.post(String(localized: "Not sent, and the schedule couldn't be put back. \(detail) It's in Drafts."),
                                     style: .error)
            return
        }
        let when = formatSendAt(date) + (condition == .ifNoReply ? Self.ifNoReplySuffix : "")
        environment.notices.post(String(localized: "Not sent. It's scheduled for \(when) again."), style: .info,
                                 duration: NoticeCenter.infoDuration)
    }

    var heldBatchSendCount: Int {
        batches.values.reduce(0) { total, batch in total + batch.items.count { $0.state == .held } }
    }

    func releaseHeldBatches() async {
        let commands = environment.commands
        for (id, batch) in batches {
            for item in batch.items where batchItem(id, item.id)?.state == .held {
                setBatchItem(id, item.id, .sending)
                _ = try? await commands?.sendNow(item.token)
            }
        }
    }
}
