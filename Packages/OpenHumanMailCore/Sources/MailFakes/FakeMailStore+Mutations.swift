import Foundation
import MailModel
import OpenHumanCore

extension State {
    enum Selection { case visible, latestVisible, trashed, spam }

    mutating func perform(_ commands: [MailCommand], now: Date) throws -> FakeReceipt {
        var receipt = FakeReceipt(operations: [], undo: [], redo: commands)
        for command in commands {
            let (operations, undo) = try performOne(command, now: now)
            receipt.operations += operations
            receipt.undo.insert(contentsOf: undo, at: 0)
        }
        return receipt
    }

    private mutating func performOne(_ command: MailCommand, now: Date) throws -> ([Int64], [MailCommand]) {
        for key in command.threads where threads[key] == nil { throw MailPortError.notFound("thread") }
        func simple(_ select: Selection, add: [GmailLabelID] = [], remove: [GmailLabelID] = [],
                    keys: [ThreadKey], undo: MailCommand) -> ([Int64], [MailCommand]) {
            guard changes(keys, select, add: Set(add), remove: Set(remove)) else { return ([], []) }
            let ops = labelEdit(command.name, keys, select, add: Set(add), remove: Set(remove))
            return (ops, ops.isEmpty ? [] : [undo])
        }
        switch command {
        case .markDone(let keys):
            return simple(.visible, remove: [FakeLabels.inbox], keys: keys, undo: .moveToInbox(keys))
        case .moveToInbox(let keys):
            return simple(.visible, add: [FakeLabels.inbox], keys: keys, undo: .markDone(keys))
        case .trash(let keys):
            return simple(.visible, add: [FakeLabels.trash], remove: [FakeLabels.inbox, FakeLabels.spam], keys: keys,
                          undo: .untrash(keys))
        case .untrash(let keys):
            return simple(.trashed, remove: [FakeLabels.trash], keys: keys, undo: .trash(keys))
        case .markRead(let keys):
            return simple(.visible, remove: [FakeLabels.unread], keys: keys, undo: .markUnread(keys))
        case .markUnread(let keys):
            return simple(.visible, add: [FakeLabels.unread], keys: keys, undo: .markRead(keys))
        case .star(let keys):
            return simple(.latestVisible, add: [FakeLabels.starred], keys: keys, undo: .unstar(keys))
        case .unstar(let keys):
            return simple(.visible, remove: [FakeLabels.starred], keys: keys, undo: .star(keys))
        case .markSpam(let keys):
            return simple(.visible, add: [FakeLabels.spam], remove: [FakeLabels.inbox], keys: keys, undo: .markNotSpam(keys))
        case .markNotSpam(let keys):
            return simple(.spam, add: [FakeLabels.inbox], remove: [FakeLabels.spam], keys: keys, undo: .markSpam(keys))
        case .modifyLabels(let keys, let add, let remove):
            for key in keys {
                for id in add + remove where !Self.isGmailSystemLabel(id) {
                    guard let label = accounts[key.account]?.label(id) else { throw MailPortError.notFound("label") }
                    if ScheduleLabel.parse(label.name) != .notOurs { throw MailPortError.reservedLabel(label.name) }
                }
            }
            let removed = Set(remove)
            let lost = keys.filter { key in
                threads[key].map { chosen(views($0), .visible).contains { !$0.labels.isDisjoint(with: removed) } } ?? false
            }
            let kept = keys.filter { !lost.contains($0) }
            guard changes(keys, .visible, add: Set(add), remove: removed) else { return ([], []) }
            let ops = labelEdit(command.name, keys, .visible, add: Set(add), remove: removed)
            guard !ops.isEmpty else { return ([], []) }
            var undo: [MailCommand] = lost.isEmpty ? [] : [.modifyLabels(lost, add: remove, remove: add)]
            if !kept.isEmpty, !add.isEmpty { undo.append(.modifyLabels(kept, add: [], remove: add)) }
            return (ops, undo)
        case .snooze(let keys, let until):
            return try snooze(keys, until: until)
        case .unsnooze(let keys):
            return unsnooze(keys, now: now)
        case .clearSnooze(let keys):
            return unsnooze(keys, now: now, wake: false)
        case .setReminder(let key, let dueAt, let kind):
            let previous = reminders[key]
            reminders[key] = FakeReminder(id: ids.nextReminder(), thread: key, dueAt: dueAt, kind: kind,
                                          anchor: threads[key]?.messages.last?.summary.id)
            invalidate([key])
            return ([], [previous.map { .setReminder(key, dueAt: $0.dueAt, kind: $0.kind) } ?? .cancelReminder(key)])
        case .cancelReminder(let key):
            guard let previous = reminders.removeValue(forKey: key) else { return ([], []) }
            invalidate([key])
            return ([], [.setReminder(key, dueAt: previous.dueAt, kind: previous.kind)])
        }
    }

    func chosen(_ views: [FakeAggregator.MessageView], _ select: Selection) -> [FakeAggregator.MessageView] {
        let visible = views.filter { FakeAggregator.isVisible($0.labels) }
        return switch select {
        case .visible: visible
        case .latestVisible: visible.last.map { [$0] } ?? []
        case .trashed: views.filter { $0.labels.contains(FakeLabels.trash) }
        case .spam: views.filter { $0.labels.contains(FakeLabels.spam) }
        }
    }

    func changes(_ keys: [ThreadKey], _ select: Selection, add: Set<GmailLabelID>, remove: Set<GmailLabelID>) -> Bool {
        keys.contains { key in
            guard let thread = threads[key] else { return false }
            return chosen(views(thread), select).contains { !add.isSubset(of: $0.labels) || !remove.isDisjoint(with: $0.labels) }
        }
    }

    mutating func labelEdit(_ kind: String, _ keys: [ThreadKey], _ select: Selection, add: Set<GmailLabelID>,
                            remove: Set<GmailLabelID>) -> [Int64] {
        var byAccount: [AccountID: (threads: [ThreadKey], edits: [MessageKey: FakeOperation.Edit])] = [:]
        for key in keys {
            guard let thread = threads[key] else { continue }
            let chosen = self.chosen(views(thread), select)
            guard !chosen.isEmpty else { continue }
            var entry = byAccount[key.account] ?? ([], [:])
            entry.threads.append(key)
            for view in chosen { entry.edits[view.summary.id] = FakeOperation.Edit(add: add, remove: remove) }
            byAccount[key.account] = entry
        }
        return byAccount.keys.sorted().compactMap { account in
            guard let entry = byAccount[account] else { return nil }
            return enqueue(kind, account: account, threads: entry.threads, edits: entry.edits)
        }
    }

    mutating func enqueue(_ kind: String, account: AccountID, threads keys: [ThreadKey],
                          edits: [MessageKey: FakeOperation.Edit]) -> Int64? {
        guard !edits.isEmpty else { return nil }
        let id = nextOperation
        nextOperation += 1
        operations[id] = FakeOperation(id: id, account: account, kind: kind, threads: keys, edits: edits,
                                       status: .pending, attempts: 0)
        for message in edits.keys { pendingByMessage[message, default: []].append(id) }
        for key in keys { pendingByThread[key, default: []].insert(id) }
        invalidate(keys)
        return id
    }

    func snoozeLabels(_ key: ThreadKey) -> (stamps: [GmailLabelID: Date], malformed: Set<GmailLabelID>, marker: Bool) {
        guard let thread = threads[key], let account = accounts[key.account] else { return ([:], [], false) }
        var stamps: [GmailLabelID: Date] = [:]
        var malformed = Set<GmailLabelID>()
        var marker = false
        for view in views(thread) where FakeAggregator.isVisible(view.labels) {
            for id in view.labels where !Self.isGmailSystemLabel(id) {
                guard let name = account.label(id)?.name else { continue }
                switch ScheduleLabel.parse(name) {
                case .schedule(let label) where label.kind == .snoozed: stamps[id] = label.due
                case .marker(.snoozed): marker = true
                case .malformed(.snoozed): malformed.insert(id)
                default: break
                }
            }
        }
        return (stamps, malformed, marker)
    }

    mutating func snooze(_ keys: [ThreadKey], until: Date) throws -> ([Int64], [MailCommand]) {
        let due = ScheduleStamp.floorToMinute(until)
        let stampName = ScheduleLabel(kind: .snoozed, due: due).name
        var operations: [Int64] = []
        var undo: [MailCommand] = []
        for key in keys {
            guard let account = accounts[key.account], let thread = threads[key] else { continue }
            let visible = views(thread).filter { FakeAggregator.isVisible($0.labels) }
            guard !visible.isEmpty else { continue }
            if account.label(named: stampName) == nil,
               account.labels.count(where: { if case .schedule = ScheduleLabel.parse($0.name) { true } else { false } }) >= 8_000 {
                throw MailPortError.limitExceeded("labels")
            }
            let current = snoozeLabels(key)
            let marker = ensureLabel(OHGmailLabels.snoozed, account: key.account)
            let stamp = ensureLabel(stampName, account: key.account)
            let fresh = current.stamps.isEmpty && current.malformed.isEmpty && !current.marker
            if !fresh, Set(current.stamps.keys) == [stamp], current.malformed.isEmpty, current.marker { continue }
            let remove = fresh ? [FakeLabels.inbox] : Set(current.stamps.keys).union(current.malformed).subtracting([stamp])
            var edits: [MessageKey: FakeOperation.Edit] = [:]
            for view in visible { edits[view.summary.id] = FakeOperation.Edit(add: [marker, stamp], remove: remove) }
            if let id = enqueue("snooze", account: key.account, threads: [key], edits: edits) { operations.append(id) }
            if fresh {
                let inInbox = visible.contains { $0.labels.contains(FakeLabels.inbox) }
                undo.append(inInbox ? .unsnooze([key]) : .clearSnooze([key]))
            } else if let previous = current.stamps.values.min() {
                undo.append(.snooze([key], until: previous))
            }
        }
        return (operations, Array(undo.reversed()))
    }

    mutating func unsnooze(_ keys: [ThreadKey], now: Date, wake: Bool = true) -> ([Int64], [MailCommand]) {
        let markUnread = wake && setting(AppSettings.snoozeMarkUnread)
        var operations: [Int64] = []
        var undo: [MailCommand] = []
        for key in keys {
            guard let thread = threads[key] else { continue }
            let current = snoozeLabels(key)
            guard current.marker || !current.stamps.isEmpty || !current.malformed.isEmpty else { continue }
            var remove = Set(current.stamps.keys).union(current.malformed)
            if let marker = accounts[key.account]?.label(named: OHGmailLabels.snoozed)?.labelID { remove.insert(marker) }
            let visible = views(thread).filter { FakeAggregator.isVisible($0.labels) }
            var edits: [MessageKey: FakeOperation.Edit] = [:]
            for (index, view) in visible.enumerated() {
                var add: Set<GmailLabelID> = wake ? [FakeLabels.inbox] : []
                if markUnread, index == visible.count - 1 { add.insert(FakeLabels.unread) }
                edits[view.summary.id] = FakeOperation.Edit(add: add, remove: remove)
            }
            if let id = enqueue(wake ? "unsnooze" : "clearSnooze", account: key.account, threads: [key], edits: edits) {
                operations.append(id)
            }
            if wake {
                threads[key]?.boostAt = now
                threads[key]?.reminderReturnAt = nil
            }
            if let previous = current.stamps.values.min() { undo.append(.snooze([key], until: previous)) }
        }
        return (operations, Array(undo.reversed()))
    }

    mutating func ensureLabel(_ name: String, account: AccountID) -> GmailLabelID {
        if let existing = accounts[account]?.labels.first(where: { $0.name == name }) { return existing.labelID }
        let position = accounts[account]?.labels.count ?? 0
        let label = FakeLabels.user(name, account: account, position: position, ids: &ids)
        accounts[account]?.labels.append(label)
        return label.labelID
    }

    func setting<V>(_ key: AppSettingKey<V>) -> V {
        guard let data = settings[SettingSlot(name: key.name, scope: key.scope)],
              let value = try? JSONDecoder().decode(V.self, from: data) else { return key.defaultValue }
        return value
    }

    mutating func undo(_ receipt: FakeReceipt, now: Date) throws -> FakeReceipt? {
        var cancelled = 0
        var needsInverse = false
        for id in receipt.operations {
            guard let op = operations[id] else { needsInverse = true; continue }
            switch op.status {
            case .pending where op.attempts == 0:
                finish(id, as: .cancelled)
                cancelled += 1
            case .pending, .succeeded:
                needsInverse = true
            case .failed, .cancelled:
                break
            }
        }
        if needsInverse || receipt.operations.isEmpty {
            guard !receipt.undo.isEmpty else {
                return cancelled > 0 ? FakeReceipt(operations: [], undo: [], redo: []) : nil
            }
            return try perform(receipt.undo, now: now)
        }
        guard cancelled > 0 else { return nil }
        return FakeReceipt(operations: [], undo: receipt.redo, redo: receipt.undo)
    }

    func canReachGmail(_ account: AccountID) -> Bool {
        !offline && accounts[account]?.account.health == .active
    }

    mutating func acknowledge(_ ids: [Int64]?, now: Date) {
        for id in (ids ?? Array(operations.keys)).sorted() {
            guard let op = operations[id], op.status == .pending, canReachGmail(op.account) else { continue }
            if failNextRemote.isEmpty {
                finish(id, as: .succeeded)
            } else {
                fail(id, code: failNextRemote.removeFirst(), now: now)
            }
        }
    }

    mutating func fail(_ id: Int64, code: String, now: Date) {
        guard let op = operations[id], op.status == .pending else { return }
        finish(id, as: .failed)
        failures.insert(FailedOperationInfo(id: id, account: op.account, kind: op.kind, threads: op.threads,
                                            errorCode: code, failedAt: now), at: 0)
    }

    mutating func finish(_ id: Int64, as status: FakeOperation.Status) {
        guard var op = operations[id], op.status == .pending else { return }
        op.status = status
        operations[id] = op
        for (message, edit) in op.edits {
            pendingByMessage[message]?.removeAll { $0 == id }
            if pendingByMessage[message]?.isEmpty == true { pendingByMessage.removeValue(forKey: message) }
            guard status == .succeeded, let key = messageIndex[message],
                  let index = threads[key]?.messages.firstIndex(where: { $0.summary.id == message }) else { continue }
            let current = threads[key]?.messages[index].labels ?? []
            threads[key]?.messages[index].labels = edit.applied(to: current)
        }
        for key in op.threads {
            pendingByThread[key]?.remove(id)
            if pendingByThread[key]?.isEmpty == true { pendingByThread.removeValue(forKey: key) }
        }
        invalidate(op.threads)
    }

    mutating func nextGmailDraftID() -> GmailDraftID {
        defer { nextGmailDraft += 1 }
        return GmailDraftID("r-fake-store-\(nextGmailDraft)")
    }

    mutating func removeDraft(_ key: DraftKey) {
        guard let draft = drafts.removeValue(forKey: key) else { return }
        held = held.filter { $0.value.draft != key }
        if let thread = draft.thread {
            draftsByThread[thread]?.remove(key)
            invalidate([thread])
        }
    }

    mutating func completeHeld(_ id: Int64, now: Date, byOtherInstall: Bool) -> Bool {
        guard let held = held.removeValue(forKey: id) else { return false }
        if let error = failingDeliveries.removeValue(forKey: held.draft), var draft = drafts[held.draft] {
            draft.status = .failed
            draft.lastError = error
            draft.updatedAt = now
            drafts[held.draft] = draft
            if let thread = draft.thread { invalidate([thread]) }
            return false
        }
        return deliverDraft(held.draft, now: now, byOtherInstall: byOtherInstall)
    }

    mutating func deliverDraft(_ key: DraftKey, now: Date, byOtherInstall: Bool) -> Bool {
        guard let draft = drafts[key], let account = accounts[draft.account] else { return false }
        let fields = draft.fields
        let from = fields.from ?? EmailAddress(name: account.account.displayName, email: account.account.email)
        let messageKey = MessageKey(account: draft.account, rowID: nextMessageRow,
                                    gmailMessageID: GmailMessageID("fake-m\(nextMessageRow)"))
        nextMessageRow += 1
        let attachments = fields.attachments.enumerated().map { index, a in
            AttachmentInfo(id: a.sourceAttachmentID ?? (messageKey.rowID * 100 + Int64(index)), filename: a.filename,
                           mimeType: a.mimeType, size: a.size, contentID: a.contentID, isInline: a.isInline)
        }
        let text = fields.bodyText ?? fields.bodyHTML.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let summary = MessageSummary(id: messageKey, from: from, to: fields.to, cc: fields.cc, bcc: fields.bcc, date: now,
                                     snippet: FakeCorpus.snippet(text), isUnread: false, attachments: attachments)
        let message = FakeMessage(summary: summary, labels: [FakeLabels.sent],
                                  body: MessageContent(html: fields.bodyHTML.isEmpty ? nil : fields.bodyHTML, text: text),
                                  isFromMe: true)
        let threadKey: ThreadKey
        if let existing = draft.thread, threads[existing] != nil {
            threadKey = existing
            threads[existing]?.messages.append(message)
        } else {
            threadKey = ThreadKey(account: draft.account, rowID: nextThreadRow,
                                  gmailThreadID: GmailThreadID("fake-t\(nextThreadRow)"))
            nextThreadRow += 1
            threads[threadKey] = FakeThread(key: threadKey, subject: fields.subject, messages: [message])
            threadOrder[draft.account, default: []].insert(threadKey, at: 0)
        }
        messageIndex[messageKey] = threadKey
        removeDraft(key)
        sent.append(FakeSentMessage(draft: key, account: draft.account, thread: threadKey, to: fields.to,
                                    subject: fields.subject, byOtherInstall: byOtherInstall, from: from, cc: fields.cc,
                                    bcc: fields.bcc, bodyHTML: fields.bodyHTML, bodyText: fields.bodyText))
        invalidate([threadKey])
        return true
    }
}
