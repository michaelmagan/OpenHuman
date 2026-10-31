import Foundation
import MailModel
import OpenHumanCore
import Synchronization

public struct FakeSchedulerReport: Sendable, Hashable {
    public var woken: [ThreadKey] = []
    public var sent: [DraftKey] = []
    public var firedReminders: [String] = []
    public var satisfiedReminders: [String] = []
    public var cancelledReminders: [String] = []
}

extension FakeMailStore {
    public func acknowledgeRemote() {
        let now = self.now
        mutate { $0.acknowledge(nil, now: now) }
    }

    public func failRemote(code: String = "server_503") {
        let now = self.now
        mutate { s in for id in s.operations.keys.sorted() { s.fail(id, code: code, now: now) } }
    }

    public func failNextRemoteOperations(_ count: Int = 1, code: String = "server_503") {
        mutate { $0.failNextRemote += Array(repeating: code, count: count) }
    }

    public func failNextCommand(_ error: MailPortError = .unavailable("injected failure")) {
        mutate { $0.failNextCommand = error }
    }

    public func beginRemoteAttempts() {
        mutate { s in for (id, op) in s.operations where op.status == .pending { s.operations[id]?.attempts = 1 } }
    }

    public var pendingOperationCount: Int {
        state.withLock { $0.operations.values.count { $0.status == .pending } }
    }

    public func serverLabels(of message: MessageKey) -> Set<GmailLabelID> {
        state.withLock { s in
            guard let key = s.messageIndex[message] else { return [] }
            return s.threads[key]?.messages.first { $0.summary.id == message }?.labels ?? []
        }
    }

    public func labelNames(of thread: ThreadKey) -> Set<String> {
        state.withLock { s in
            guard let t = s.threads[thread], let account = s.accounts[thread.account] else { return [] }
            var names = Set<String>()
            for view in s.views(t) where FakeAggregator.isVisible(view.labels) {
                for id in view.labels { names.insert(account.label(id)?.name ?? id.rawValue) }
            }
            return names
        }
    }

    public func isGmailImportant(_ thread: ThreadKey) -> Bool? {
        state.withLock { s in
            guard let t = s.threads[thread] else { return nil }
            return FakeAggregator.scope(s.views(t)).contains { $0.labels.contains(FakeLabels.important) }
        }
    }

    public func isInTrash(_ thread: ThreadKey) -> Bool {
        state.withLock { s in
            guard let t = s.threads[thread] else { return false }
            return s.views(t).contains { $0.labels.contains(FakeLabels.trash) }
        }
    }

    public func isVisible(_ thread: ThreadKey) -> Bool {
        state.withLock { s in
            guard let t = s.threads[thread] else { return false }
            return s.views(t).contains { FakeAggregator.isVisible($0.labels) }
        }
    }

    public func setOffline(_ offline: Bool) {
        let now = self.now
        let pending = mutate { s -> [Int64] in
            s.offline = offline
            s.offlineSince = offline ? now : nil
            guard !offline else { return [] }
            let ids = s.operations.values.filter { $0.status == .pending }.map(\.id)
            if options.remoteAck == .immediate { s.acknowledge(ids, now: now) }
            return ids
        }
        scheduleAcknowledgement(pending)
    }

    public func expireAuth(_ account: AccountID) {
        mutate { s in
            guard let state = s.accounts[account] else { return }
            s.accounts[account]?.account = Self.with(state.account, health: .needsSignIn)
        }
    }

    public func setConnectivity(_ connectivity: ConnectivityState, for account: AccountID) {
        mutate { $0.accounts[account]?.connectivity = connectivity }
    }

    public func setSyncProgress(_ line: String?, for account: AccountID) {
        mutate { $0.syncLines[account] = line }
    }

    public func setOAuthClient(_ status: OAuthClientStatus) {
        mutate { $0.oauthClient = status }
    }

    public func enqueueSignIn(_ outcomes: FakeSignInOutcome...) {
        mutate { $0.signInOutcomes += outcomes }
    }

    public func setSearchIncomplete(_ reasons: [SearchIncompleteness], account: AccountID) {
        mutate { $0.searchIncomplete[account] = reasons.isEmpty ? nil : reasons }
    }

    public func setGmailOnlyResults(_ threads: [ThreadKey], account: AccountID) {
        mutate { $0.gmailOnly[account] = threads }
    }

    public func setRelatedSearchMatches(_ on: Bool) {
        mutate {
            $0.relatedSearchMatches = on
            $0.smartSearch = on ? .ready : .off
        }
    }

    public func setSmartSearchStatus(_ status: SmartSearchStatus) {
        mutate { $0.smartSearch = status }
    }

    public func failNextGmailSearch() {
        mutate { $0.failNextGmailSearch = true }
    }

    public var gmailSearchCount: Int { state.withLock { $0.gmailSearchCount } }

    public func completeHeldSends() {
        let now = self.now
        mutate { s in for id in s.held.keys.sorted() { _ = s.completeHeld(id, now: now, byOtherInstall: false) } }
    }

    /// The draft's held send fails when it completes: the draft stays, marked failed with `error`.
    public func failDelivery(of draft: DraftKey, error: String = "server_503") {
        mutate { $0.failingDeliveries[draft] = error }
    }

    public var heldSendCount: Int { state.withLock { $0.held.count } }

    public var sentMessages: [FakeSentMessage] { state.withLock { $0.sent } }

    public var unsubscribeRequests: [MessageKey] { state.withLock { $0.unsubscribeRequests } }

    public func simulateOtherInstallWake(_ key: ThreadKey) {
        let now = self.now
        mutate { s in
            let current = s.snoozeLabels(key)
            var remove = Set(current.stamps.keys).union(current.malformed)
            if let marker = s.accounts[key.account]?.label(named: OHGmailLabels.snoozed)?.labelID { remove.insert(marker) }
            s.editServerLabels(key, add: [FakeLabels.inbox], remove: remove)
            s.threads[key]?.boostAt = now
            s.threads[key]?.reminderReturnAt = nil
        }
    }

    public func simulateOtherInstallSnooze(_ key: ThreadKey, until: Date, keepExisting: Bool = false) {
        mutate { s in
            let marker = s.ensureLabel(OHGmailLabels.snoozed, account: key.account)
            let stamp = s.ensureLabel(ScheduleLabel(kind: .snoozed, due: until).name, account: key.account)
            var remove: Set<GmailLabelID> = [FakeLabels.inbox]
            if !keepExisting { remove.formUnion(s.snoozeLabels(key).stamps.keys) }
            s.editServerLabels(key, add: [marker, stamp], remove: remove.subtracting([stamp]))
        }
    }

    public func setDraftSendStamp(_ draft: DraftKey, stamp: String?) {
        mutate { s in
            s.drafts[draft]?.sendStamp = stamp
            s.drafts[draft]?.status = stamp == nil ? .editing : .scheduled
            if let thread = s.drafts[draft]?.thread { s.invalidate([thread]) }
        }
    }

    public func simulateOtherInstallSend(_ draft: DraftKey) {
        let now = self.now
        mutate { _ = $0.deliverDraft(draft, now: now, byOtherInstall: true) }
    }

    @discardableResult
    public func deliverMessage(account: AccountID, to thread: ThreadKey? = nil, from: EmailAddress,
                               subject: String = "New message", text: String = "Hello from the fake.",
                               unread: Bool = true, at date: Date? = nil,
                               recipients: [EmailAddress]? = nil, cc: [EmailAddress] = [],
                               important: Bool = false, unsubscribe: UnsubscribeInfo? = nil) -> MessageKey {
        let at = date ?? now
        return mutate { s in
            let key = MessageKey(account: account, rowID: s.nextMessageRow, gmailMessageID: GmailMessageID("fake-m\(s.nextMessageRow)"))
            s.nextMessageRow += 1
            let me = s.accounts[account]?.account
            let summary = MessageSummary(id: key, from: from,
                                         to: recipients ?? me.map { [EmailAddress(name: $0.displayName, email: $0.email)] } ?? [],
                                         cc: cc, bcc: [], date: at, snippet: FakeCorpus.snippet(text), isUnread: unread,
                                         attachments: [])
            var labels: Set<GmailLabelID> = [FakeLabels.inbox]
            if unread { labels.insert(FakeLabels.unread) }
            if important { labels.insert(FakeLabels.important) }
            let message = FakeMessage(summary: summary, labels: labels, body: MessageContent(html: nil, text: text),
                                      unsubscribe: unsubscribe, isFromMe: false)
            let threadKey: ThreadKey
            if let thread, s.threads[thread] != nil {
                threadKey = thread
                s.threads[thread]?.messages.append(message)
            } else {
                threadKey = ThreadKey(account: account, rowID: s.nextThreadRow, gmailThreadID: GmailThreadID("fake-t\(s.nextThreadRow)"))
                s.nextThreadRow += 1
                s.threads[threadKey] = FakeThread(key: threadKey, subject: subject, messages: [message])
                s.threadOrder[account, default: []].insert(threadKey, at: 0)
            }
            s.messageIndex[key] = threadKey
            s.invalidate([threadKey])
            return key
        }
    }

    @discardableResult
    public func agentCreatesDraft(account: AccountID, replyTo: MessageKey? = nil, fields: DraftFields,
                                  note: String? = nil) -> DraftKey {
        let now = self.now
        return mutate { s in
            let id = s.ids.nextDraft()
            let thread = replyTo.flatMap { s.messageIndex[$0] }
            s.drafts[id] = FakeDraft(id: id, account: account, thread: thread, mode: replyTo == nil ? .new : .reply,
                                     replyTo: replyTo?.gmailMessageID, fields: fields, source: .agent, review: .pending,
                                     status: .editing, version: 1, syncedVersion: 0, hasRemoteConflict: false,
                                     agentNote: note, agentSnapshot: fields, updatedAt: now, agentVersion: 1)
            if let thread {
                s.draftsByThread[thread, default: []].insert(id)
                s.invalidate([thread])
            }
            return id
        }
    }

    public func agentUpdatesDraft(_ key: DraftKey, fields: DraftFields, note: String? = nil) {
        let now = self.now
        mutate { s in
            guard var draft = s.drafts[key] else { return }
            let userEdited = draft.version != (draft.agentVersion ?? draft.version)
            draft.agentSnapshot = fields
            draft.agentNote = note ?? draft.agentNote
            draft.review = .pending
            if userEdited {
                draft.hasRemoteConflict = true
            } else {
                draft.fields = fields
                draft.version += 1
                draft.agentVersion = draft.version
            }
            draft.updatedAt = now
            s.drafts[key] = draft
            if let thread = draft.thread { s.invalidate([thread]) }
        }
    }

    @discardableResult
    public func runSchedulers(now: Date) -> FakeSchedulerReport {
        let report = mutate { s -> (FakeSchedulerReport, [Int64]) in
            var report = FakeSchedulerReport()
            var operations: [Int64] = []
            if s.setting(AppSettings.schedulerSnooze) {
                for keys in s.threadOrder.values {
                    for key in keys {
                        guard let d = s.derived(key), case .until(let wake, _) = d.snooze else { continue }
                        if d.inInbox {
                            let current = s.snoozeLabels(key)
                            var remove = Set(current.stamps.keys).union(current.malformed)
                            if let marker = s.accounts[key.account]?.label(named: OHGmailLabels.snoozed)?.labelID { remove.insert(marker) }
                            operations += s.labelEdit("clearSnooze", [key], .visible, add: [], remove: remove)
                        } else if wake <= now {
                            operations += s.unsnooze([key], now: now).0
                            report.woken.append(key)
                        }
                    }
                }
            }
            if s.setting(AppSettings.schedulerSendLater) {
                let due = s.drafts.values.filter { draft in
                    let summary = draft.summary
                    return summary.status == .scheduled && (summary.sendAt ?? .distantFuture) <= now && summary.canBeScheduled
                }.map(\.id).sorted { $0.rawValue < $1.rawValue }
                for id in due where s.deliverDraft(id, now: now, byOtherInstall: false) { report.sent.append(id) }
            }
            if s.setting(AppSettings.schedulerReminders) {
                for reminder in s.reminders.values.sorted(by: { $0.dueAt < $1.dueAt }) where reminder.dueAt <= now {
                    let key = reminder.thread
                    guard let thread = s.threads[key], let d = s.derived(key) else { continue }
                    s.reminders.removeValue(forKey: key)
                    s.invalidate([key])
                    let views = s.views(thread)
                    let anchorIndex = reminder.anchor.flatMap { a in views.firstIndex { $0.summary.id == a } } ?? (views.count - 1)
                    let replied = views.dropFirst(anchorIndex + 1).contains { !$0.isFromMe && FakeAggregator.isVisible($0.labels) }
                    if reminder.kind == .ifNoReply, replied {
                        report.satisfiedReminders.append(reminder.id)
                    } else if !d.hasVisible {
                        report.cancelledReminders.append(reminder.id)
                    } else {
                        report.firedReminders.append(reminder.id)
                        if d.snooze == nil {
                            operations += s.labelEdit("fireReminder", [key], .visible, add: [FakeLabels.inbox], remove: [])
                            s.threads[key]?.boostAt = now
                            s.threads[key]?.reminderReturnAt = now
                        }
                    }
                }
            }
            if options.remoteAck == .immediate { s.acknowledge(operations, now: now) }
            return (report, operations)
        }
        scheduleAcknowledgement(report.1)
        return report.0
    }

    public func removeThreads(_ keys: Set<ThreadKey>) {
        mutate { s in
            for key in keys {
                for message in s.threads.removeValue(forKey: key)?.messages ?? [] {
                    s.messageIndex.removeValue(forKey: message.summary.id)
                }
                s.threadOrder[key.account]?.removeAll { $0 == key }
                s.reminders.removeValue(forKey: key)
                for draft in s.draftsByThread.removeValue(forKey: key) ?? [] { s.drafts.removeValue(forKey: draft) }
                s.derived.removeValue(forKey: key)
            }
        }
    }

    public func insertAtTop(_ thread: FakeCorpus.Thread) {
        mutate { s in
            let key = thread.row.id
            var messages: [FakeMessage] = []
            for summary in thread.allMessages {
                messages.append(FakeMessage(summary: summary, labels: Set(thread.labels[summary.id] ?? []),
                                            bodySpec: thread.bodySpecs[summary.id],
                                            unsubscribe: thread.unsubscribe[summary.id],
                                            listID: thread.listIDs[summary.id],
                                            isFromMe: thread.fromMe.contains(summary.id)))
                s.messageIndex[summary.id] = key
                s.nextMessageRow = max(s.nextMessageRow, summary.id.rowID + 1)
            }
            s.threads[key] = FakeThread(key: key, subject: thread.detail.subject, messages: messages)
            s.threadOrder[key.account, default: []].removeAll { $0 == key }
            s.threadOrder[key.account, default: []].insert(key, at: 0)
            s.nextThreadRow = max(s.nextThreadRow, key.rowID + 1)
            s.derived.removeValue(forKey: key)
        }
    }

    public var threadCount: Int { state.withLock { $0.threads.count } }
}

extension State {
    mutating func editServerLabels(_ key: ThreadKey, add: Set<GmailLabelID>, remove: Set<GmailLabelID>) {
        guard let thread = threads[key] else { return }
        let edit = FakeOperation.Edit(add: add, remove: remove)
        for (index, message) in thread.messages.enumerated() where FakeAggregator.isVisible(message.labels) {
            threads[key]?.messages[index].labels = edit.applied(to: message.labels)
        }
        invalidate([key])
    }
}

public final class FakeClock: Sendable {
    private let current: Mutex<Date>

    public init(_ start: Date) {
        current = Mutex(start)
    }

    public var now: Date { current.withLock { $0 } }

    public func advance(by interval: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(interval) }
    }

    public func set(_ date: Date) {
        current.withLock { $0 = date }
    }
}
