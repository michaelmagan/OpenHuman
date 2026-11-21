import Foundation
import GRDB
import OpenHumanCore

extension MailStore: MailMutating {
    public func apply(_ action: MailAction, origin: OperationOrigin) throws -> ActionReceipt {
        try write { db in try Self.apply(action, origin: origin, in: db) }
    }

    public func undo(_ receipt: ActionReceipt, origin: OperationOrigin) throws -> ActionReceipt? {
        try write { db in try Self.undo(receipt, origin: origin, in: db) }
    }

    public func dismissFailedOperation(_ id: OperationID) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM pending_operations WHERE op_id = ? AND status = 'failed'",
                           arguments: [id.rawValue])
        }
    }
}

extension MailStore {
    static func apply(_ action: MailAction, origin: OperationOrigin, in db: Database) throws -> ActionReceipt {
        switch action {
        case let .archive(refs):
            return try ThreadActions.labels(refs, add: [], remove: ["INBOX"], scope: .visible, origin: origin,
                                            undo: .moveToInbox(refs), in: db)
        case let .moveToInbox(refs):
            return try ThreadActions.labels(refs, add: ["INBOX"], remove: [], scope: .visible, origin: origin,
                                            undo: .archive(refs), in: db)
        case let .trash(refs):
            return try ThreadActions.trash(refs, untrash: false, origin: origin, in: db)
        case let .untrash(refs):
            return try ThreadActions.trash(refs, untrash: true, origin: origin, in: db)
        case let .markRead(refs):
            return try ThreadActions.labels(refs, add: [], remove: ["UNREAD"], scope: .visibleElseNonDraft, origin: origin,
                                            undo: .markUnread(refs), in: db)
        case let .markUnread(refs):
            return try ThreadActions.labels(refs, add: ["UNREAD"], remove: [], scope: .visibleElseNonDraft, origin: origin,
                                            undo: .markRead(refs), in: db)
        case let .star(refs):
            return try ThreadActions.labels(refs, add: ["STARRED"], remove: [], scope: .latest, origin: origin,
                                            undo: .unstar(refs), in: db)
        case let .unstar(refs):
            return try ThreadActions.labels(refs, add: [], remove: ["STARRED"], scope: .starred, origin: origin,
                                            undo: .star(refs), in: db)
        case let .markSpam(refs):
            return try ThreadActions.labels(refs, add: ["SPAM"], remove: ["INBOX"], scope: .visible, origin: origin,
                                            undo: .markNotSpam(refs), in: db)
        case let .markNotSpam(refs):
            return try ThreadActions.labels(refs, add: ["INBOX"], remove: ["SPAM"], scope: .spam, origin: origin,
                                            undo: .markSpam(refs), in: db)
        case let .modifyLabels(refs, add, remove):
            return try ThreadActions.modifyLabels(refs, add: add, remove: remove, origin: origin, in: db)
        case let .modifyMessageLabels(account, ids, add, remove):
            return try ThreadActions.modifyMessageLabels(account, ids, add: add, remove: remove, origin: origin, in: db)
        case let .snooze(refs, until):
            return try SnoozeMutations.snooze(refs, until: until, origin: origin, in: db)
        case let .unsnooze(refs):
            return try SnoozeMutations.unsnooze(refs, origin: origin, in: db)
        case let .clearSnooze(refs):
            return try SnoozeMutations.unsnooze(refs, toInbox: false, origin: origin, in: db)
        case let .setReminder(ref, dueAt, condition):
            return try ReminderMutations.set(ref, dueAt: dueAt, condition: condition, in: db)
        case let .cancelReminder(ref):
            return try ReminderMutations.cancel(ref, in: db)
        case let .createLabel(account, name, applyTo):
            return try LabelCreation.create(account: account, name: name, applyTo: applyTo, origin: origin, in: db)
        }
    }

    static func inverse(_ action: MailAction) -> MailAction? {
        switch action {
        case let .archive(refs): return .moveToInbox(refs)
        case let .moveToInbox(refs): return .archive(refs)
        case let .trash(refs): return .untrash(refs)
        case let .untrash(refs): return .trash(refs)
        case let .markRead(refs): return .markUnread(refs)
        case let .markUnread(refs): return .markRead(refs)
        case let .star(refs): return .unstar(refs)
        case let .unstar(refs): return .star(refs)
        case let .markSpam(refs): return .markNotSpam(refs)
        case let .markNotSpam(refs): return .markSpam(refs)
        case let .modifyLabels(refs, add, remove): return .modifyLabels(refs, add: remove, remove: add)
        case let .modifyMessageLabels(account, ids, add, remove):
            return .modifyMessageLabels(account, ids, add: remove, remove: add)
        case .snooze, .unsnooze, .clearSnooze, .setReminder, .cancelReminder, .createLabel:
            return nil
        }
    }

    static func undo(_ receipt: ActionReceipt, origin: OperationOrigin, in db: Database) throws -> ActionReceipt? {
        guard let inverse = receipt.undo else { return nil }
        if receipt.operationIDs.isEmpty { return try apply(inverse, origin: origin, in: db) }
        if try ruleMutedSince(receipt, undo: inverse, in: db) { return try apply(inverse, origin: origin, in: db) }

        var needsInverse = false
        var cancelled: [OperationPayload] = []
        var mids = Set<Int64>(), tids = Set<Int64>()
        var creates: [(id: Int64, payload: OperationPayload)] = []
        let now = nowMillis()
        for id in receipt.operationIDs.map(\.rawValue) {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT kind, status, attempts, payload_json FROM pending_operations WHERE op_id = ?
                """, arguments: [id]) else {
                needsInverse = true
                continue
            }
            guard let kind = OperationKind(rawValue: row["kind"]) else { continue }
            let payload = try OperationPayloadCodec.decode(kind: kind, json: row["payload_json"])
            if kind == .createLabel { creates.append((id, payload)); continue }
            let attempts: Int = row["attempts"]
            switch OperationStatus(rawValue: row["status"]) {
            case .pending where attempts == 0:
                let linked = try linkedMessages(op: id, in: db)
                try db.execute(sql: """
                    UPDATE pending_operations SET status = 'cancelled', updated_at = ?
                    WHERE op_id = ? AND status = 'pending' AND attempts = 0
                    """, arguments: [now, id])
                guard db.changesCount == 1 else { needsInverse = true; continue }
                try db.execute(sql: "DELETE FROM pending_op_messages WHERE op_id = ?", arguments: [id])
                for r in linked { mids.insert(r.mid); tids.insert(r.tid) }
                cancelled.append(payload)
            case .pending, .inFlight, .succeeded:
                needsInverse = true
            case .failed, .cancelled, nil:
                break
            }
        }
        for create in creates.reversed() {
            guard try cancelUnneededCreateLabel(create.id, in: db) else { continue }
            cancelled.append(create.payload)
        }
        try LabelOverlay.recompute(mids: mids, in: db)
        try ThreadAggregator.refresh(tids: tids, in: db)

        if needsInverse { return try apply(receipt.exactUndo ?? inverse, origin: origin, in: db) }
        guard !cancelled.isEmpty else { return nil }
        return ActionReceipt(operationIDs: [], undo: try redo(of: inverse, cancelled: cancelled, in: db))
    }

    static func ruleMutedSince(_ receipt: ActionReceipt, undo: MailAction, in db: Database) throws -> Bool {
        guard case let .modifyLabels(refs, _, remove) = undo, let account = refs.first?.accountID else { return false }
        let index = try LabelIndex.load(account: account.rawValue, in: db)
        guard let muted = remove.lazy.compactMap({ index.resolve($0.rawValue) })
            .first(where: { index.name(of: $0) == OHGmailLabels.muted }) else { return false }
        var targeted = Set<String>()
        for id in receipt.operationIDs.map(\.rawValue) {
            guard let row = try Row.fetchOne(db, sql: "SELECT kind, payload_json FROM pending_operations WHERE op_id = ?",
                                             arguments: [id]),
                  let kind = OperationKind(rawValue: row["kind"]) else { return false }
            if case let .modifyLabels(ids, _, _, _) = try OperationPayloadCodec.decode(kind: kind, json: row["payload_json"]) {
                targeted.formUnion(ids.map(\.rawValue))
            }
        }
        let tids = refs.filter { $0.accountID == account }.map(\.rowID.rawValue)
        let marks = Array(repeating: "?", count: tids.count).joined(separator: ", ")
        let rows = try Row.fetchAll(db, sql: """
            SELECT gmail_message_id, label_ids FROM messages
            WHERE tid IN (\(marks)) AND is_draft = 0 AND in_trash = 0 AND in_spam = 0
            """, arguments: StatementArguments(tids))
        return rows.contains { row in
            !targeted.contains(row["gmail_message_id"] as String) && Labels.split(row["label_ids"]).contains(muted)
        }
    }

    static func cancelUnneededCreateLabel(_ id: Int64, in db: Database) throws -> Bool {
        let dependents = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM pending_operations WHERE depends_on = ? AND status IN ('pending', 'in_flight')
            """, arguments: [id]) ?? 0
        guard dependents == 0 else { return false }
        try db.execute(sql: """
            UPDATE pending_operations SET status = 'cancelled', updated_at = ?
            WHERE op_id = ? AND status = 'pending' AND attempts = 0
            """, arguments: [nowMillis(), id])
        return db.changesCount == 1
    }

    static func redo(of undo: MailAction, cancelled: [OperationPayload], in db: Database) throws -> MailAction? {
        switch undo {
        case let .unsnooze(refs):
            return try snoozeStamp(in: cancelled, account: refs.first?.accountID, in: db).map { .snooze(refs, until: $0.due) }
        case let .snooze(refs, _):
            if let stamp = try snoozeStamp(in: cancelled, account: refs.first?.accountID, in: db) {
                return .snooze(refs, until: stamp.due)
            }
            let woke = cancelled.contains { payload in
                if case let .modifyLabels(_, add, _, _) = payload { return add.contains(GmailLabelID("INBOX")) }
                return false
            }
            return woke ? .unsnooze(refs) : .clearSnooze(refs)
        case let .modifyLabels(refs, add, remove) where add.isEmpty && remove.count == 1:
            let name = remove[0].rawValue
            let createdByName = cancelled.contains { payload in
                switch payload {
                case let .createLabel(n): return n == name
                case let .modifyLabels(_, _, _, names): return names.contains(name)
                default: return false
                }
            }
            if createdByName, let account = refs.first?.accountID { return .createLabel(account, name: name, applyTo: refs) }
            return inverse(undo)
        default:
            return inverse(undo)
        }
    }

    static func snoozeStamp(in payloads: [OperationPayload], account: AccountID?, in db: Database) throws -> ScheduleLabel? {
        guard let account else { return nil }
        let index = try LabelIndex.load(account: account.rawValue, in: db)
        for payload in payloads {
            guard case let .modifyLabels(_, add, _, names) = payload else { continue }
            for name in add.compactMap({ index.name(of: $0.rawValue) }) + names {
                if case let .schedule(label) = ScheduleLabel.parse(name), label.kind == .snoozed { return label }
            }
        }
        return nil
    }

    static func linkedMessages(op: Int64, in db: Database) throws -> [(mid: Int64, tid: Int64)] {
        try Row.fetchAll(db, sql: """
            SELECT m.mid, m.tid FROM pending_op_messages pom JOIN messages m ON m.mid = pom.mid WHERE pom.op_id = ?
            """, arguments: [op]).map { ($0["mid"], $0["tid"]) }
    }
}
