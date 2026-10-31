import Foundation
import MailActions
import MailModel
import OpenHumanCore

/// Checked drafts sent together from the Drafts list: one undo entry holds every send in the batch, each draft goes
/// out from its own account through the held-send window, and one notice reports what went out and what stayed.
struct BatchSend {
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

    var items: [Item] = []
    var failedAtStart: [Failure] = []
    var reminders: SentMailReminderRule?

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
        let state = environment.router.active
        let names = Dictionary(environment.router.accounts.map { ($0.id, $0.account.alias ?? $0.account.email) },
                               uniquingKeysWith: { first, _ in first })
        let model = BatchSendModel(plan: plan, remindersOn: rule.enabled, reminderDays: rule.days, accountNames: names,
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
        var start = BatchSendStart(batch: nil, queued: [], failed: [])
        guard canSend, let commands = environment.commands, !drafts.isEmpty else { return start }
        let seconds = AppSettings.undoSendHold(await Self.read(environment.settings, AppSettings.undoSendSeconds) ?? 10)
        undoSendSeconds = seconds
        var batch = BatchSend(reminders: reminders)
        for draft in Self.byAccount(drafts) {
            do {
                let token = try await commands.send(draft.id, undoWindow: .seconds(seconds))
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
        let title: LocalizedStringResource = count == 1 ? "Sending 1 draft…" : "Sending \(count) drafts…"
        if let entry = push(title, .sendBatch(batch: id), expiresAt: expiresAt) {
            for item in batch.items { sendingUndoEntries[item.id] = entry }
        }
        for item in batch.items { track(watchBatchItem(id, item: item)) }
        // Why: every reminder intent is stored before the batch is reported started, so all survive a relaunch
        if batch.items.contains(where: { $0.reminder != nil }) { await sendReminderUpdate?.value }
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
        finishBatchItem(batch, item, .sent)
        guard let rule else { return }
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
        batches[id] = nil
        report(batch)
    }

    private func report(_ batch: BatchSend) {
        let sent = batch.sentCount
        let failures = batch.failures
        guard !failures.isEmpty else {
            guard sent > 0 else { return }
            environment.notices.post(sent == 1 ? String(localized: "Sent 1 draft.") : String(localized: "Sent \(sent) drafts."),
                                     style: .info, duration: environment.notices.timing.brief)
            return
        }
        let failed = failures.count
        let message: String
        if sent > 0 {
            message = failed == 1
                ? String(localized: "Sent \(sent) of \(sent + failed). 1 couldn't be sent and stays in Drafts.")
                : String(localized: "Sent \(sent) of \(sent + failed). \(failed) couldn't be sent and stay in Drafts.")
        } else if failed == 1 {
            let detail = failures[0].detail.map { " " + $0 } ?? ""
            message = String(localized: "Couldn't send the draft.\(detail) It stays in Drafts.")
        } else {
            message = String(localized: "Couldn't send \(failed) drafts. They stay in Drafts.")
        }
        let keys = failures.map(\.draft.id)
        let reminders = batch.reminders
        let account = failures[0].draft.account
        let show = NoticeCenter.Choice(String(localized: "Show Drafts")) { [weak self] in self?.showDrafts(account) }
        lastBatchFailures = keys
        environment.notices.post(message, style: .error, actionTitle: String(localized: "Retry"), duration: nil,
                                 secondary: show) { [weak self] in
            await self?.retryBatch(keys, reminders: reminders)
        }
    }

    private func showDrafts(_ account: AccountID) {
        let router = environment.router
        if router.activeAccountID != account { router.switchAccount(to: account) }
        router.go(to: .system(.drafts))
    }

    /// Sends the drafts that failed again, after checking them as the confirmation did. Drafts that can't go now are
    /// reported and left alone.
    public func retryBatch(_ keys: [DraftKey], reminders: SentMailReminderRule?) async {
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
        await sendBatch(ready, reminders: reminders)
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
        if late > 0 {
            let text = late == 1 ? String(localized: "Too late to undo 1 message: it's already on its way.")
                                 : String(localized: "Too late to undo \(late) messages: they're already on their way.")
            environment.notices.post(text, style: .info, duration: NoticeCenter.infoDuration)
        } else if cancelled > 0 {
            let text = cancelled == 1 ? String(localized: "Not sent. The draft is back in Drafts.")
                                      : String(localized: "Not sent. The \(cancelled) drafts are back in Drafts.")
            environment.notices.post(text, style: .info, duration: NoticeCenter.infoDuration)
        }
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
