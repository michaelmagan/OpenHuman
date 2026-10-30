import Foundation
import GRDB
import OpenHumanCore

enum SendMutations {
    static let maxUndoWindowMillis: Int64 = 86_400_000

    static func holdMillis(_ undoWindow: Duration) -> Int64 {
        min(max(0, MailStore.windowMillis(undoWindow)), maxUndoWindowMillis)
    }

    static func send(_ id: DraftID, undoWindow: Duration, origin: OperationOrigin, in db: Database) throws -> SendReceipt {
        guard origin == .app || origin == .scheduler else {
            throw StoreError.conflict("only the app's send action or the send-later scheduler can send (origin \(origin.rawValue))")
        }
        let row = try DraftRow.load(id, in: db)
        try MailStore.requireWritableAccount(AccountID(row.account), in: db)
        switch row.state {
        case .sending: throw StoreError.conflict("draft \(id.rawValue) is already being sent")
        case .sent: throw StoreError.conflict("draft \(id.rawValue) was already sent")
        case .discarded: throw StoreError.conflict("draft \(id.rawValue) was discarded")
        case .editing, .scheduled, .failed: break
        }
        if try liveSendOp(for: row.uuid, in: db) != nil {
            throw StoreError.conflict("draft \(id.rawValue) already has a send queued")
        }
        if origin == .scheduler {
            guard row.state == .scheduled, !row.isDirty, row.gmailDraftID != nil else {
                throw StoreError.conflict("draft \(id.rawValue) is not a synced scheduled draft")
            }
            guard row.origin == .user || row.review == .approved else {
                throw StoreError.conflict("draft \(id.rawValue) needs review before it can send")
            }
        }
        let now = nowMillis()
        let sendAfter = now + holdMillis(undoWindow)
        var upsert: Int64?
        if row.isDirty || row.gmailDraftID == nil {
            upsert = try DraftMutations.enqueueUpsert(row, origin: origin, in: db)
        }
        let send = try OpWriter.insert(account: row.account, payload: .sendDraft(draftID: id), origin: origin,
                                       coalesceKey: nil, dependsOn: upsert, notBefore: sendAfter, in: db)
        let review = origin == .app && row.review == .pending ? DraftReviewState.approved : row.review
        try db.execute(sql: """
            UPDATE drafts SET state = 'sending', last_error = NULL, review_state = ?, updated_at = ? WHERE draft_uuid = ?
            """, arguments: [review.rawValue, now, row.uuid])
        if let tid = row.tid { try ThreadAggregator.refresh(tids: [tid], in: db) }
        return SendReceipt(draftID: id, upsertOperationID: upsert.map { OperationID(rawValue: $0) },
                           sendOperationID: OperationID(rawValue: send), sendAfter: MailStore.storeDate(millis: sendAfter))
    }

    // Cancelling the scheduler's own send also drops the schedule, so the next aggregation cannot schedule it again
    static func cancelSend(_ receipt: SendReceipt, in db: Database) throws -> Bool {
        let op = try Row.fetchOne(db, sql: "SELECT origin, claimed_at, not_before FROM pending_operations WHERE op_id = ?",
                                  arguments: [receipt.sendOperationID.rawValue])
        let origin: String? = op?["origin"]
        let interrupted = (op?["claimed_at"] as Int64?) == nil && (op?["not_before"] as Int64? ?? .max) < nowMillis() - 3_600_000
        try db.execute(sql: """
            UPDATE pending_operations SET status = 'cancelled', claimed_by = NULL, updated_at = ?
            WHERE op_id = ? AND kind = 'send_draft' AND status = 'pending' AND attempts = 0
            """, arguments: [nowMillis(), receipt.sendOperationID.rawValue])
        guard db.changesCount == 1 else { return false }
        let row = try DraftRow.load(receipt.draftID, in: db)
        guard row.state == .sending else { return true }
        if origin == OperationOrigin.scheduler.rawValue,
           DraftRowCodec.header(OHGmailLabels.sendAtHeader, in: row.headers) != nil {
            _ = try DraftMutations.bump(row, sets: DraftMutations.unschedule(row), in: db)
            _ = try DraftMutations.enqueueUpsert(try DraftRow.load(receipt.draftID, in: db), origin: .app, in: db)
        } else {
            try db.execute(sql: "UPDATE drafts SET state = 'editing', last_error = ?, updated_at = ? WHERE draft_uuid = ?",
                           arguments: [interrupted ? "send was interrupted" : nil, nowMillis(), row.uuid])
            if let tid = row.tid { try ThreadAggregator.refresh(tids: [tid], in: db) }
        }
        return true
    }

    static func sendNow(_ receipt: SendReceipt, in db: Database) throws -> Bool {
        try db.execute(sql: """
            UPDATE pending_operations SET not_before = MIN(not_before, ?), updated_at = ?
            WHERE op_id = ? AND kind = 'send_draft' AND status = 'pending'
            """, arguments: [nowMillis(), nowMillis(), receipt.sendOperationID.rawValue])
        return db.changesCount == 1
    }

    // The floored minute must be after now, or the draft would be sent at once with no undo window
    static func schedule(_ id: DraftID, at: Date, onlyIfNoReply: Bool = false, now: Int64 = nowMillis(),
                         in db: Database) throws {
        let row = try DraftRow.load(id, in: db)
        try MailStore.requireWritableAccount(AccountID(row.account), in: db)
        try DraftMutations.requireEditable(row)
        guard row.origin == .user || row.review == .approved else {
            throw StoreError.conflict("draft \(id.rawValue) needs review before it can be scheduled")
        }
        if onlyIfNoReply, row.tid == nil { throw StoreError.conflict("only a reply can wait for no reply") }
        let label = ScheduleLabel(kind: .scheduled, due: at)
        let stamp = ScheduleStamp.format(label.due)
        let due = MailStore.storeMillis(label.due)
        guard due > now else { throw StoreError.conflict("the scheduled time has passed") }
        let condition = DraftRowCodec.header(OHGmailLabels.sendAtConditionHeader, in: row.headers)
        let hasCondition = condition != nil
        if row.state == .scheduled, row.sendAt == due,
           DraftRowCodec.header(OHGmailLabels.sendAtHeader, in: row.headers) == stamp, hasCondition == onlyIfNoReply { return }
        if try LabelIndex.load(account: row.account, in: db).keyByName[label.name] == nil {
            try SnoozeMutations.checkBudget(account: row.account, in: db)
        }
        var headers = DraftMutations.withoutSendAt(row.headers)
        headers[OHGmailLabels.sendAtHeader] = stamp
        if onlyIfNoReply, row.state == .scheduled, let condition {
            headers[OHGmailLabels.sendAtConditionHeader] = condition
        } else if onlyIfNoReply, let tid = row.tid {
            let newest = try String.fetchOne(db, sql: """
                SELECT gmail_message_id FROM messages WHERE tid = ? AND is_draft = 0 AND in_trash = 0 AND in_spam = 0
                ORDER BY internal_date DESC, mid DESC LIMIT 1
                """, arguments: [tid])
            headers[OHGmailLabels.sendAtConditionHeader] = SendAtCondition(anchor: newest.map { GmailMessageID($0) }).headerValue
        }
        _ = try DraftMutations.bump(row, sets: [
            ("state", DraftState.scheduled.rawValue.databaseValue), ("send_at", due.databaseValue),
            ("last_error", DatabaseValue.null), ("extra_headers_json", DraftRowCodec.headers(headers).databaseValue),
        ], in: db)
        _ = try DraftMutations.enqueueUpsert(try DraftRow.load(id, in: db), origin: .app, in: db)
    }

    static func cancelSchedule(_ id: DraftID, in db: Database) throws {
        let row = try DraftRow.load(id, in: db)
        let hasHeader = DraftRowCodec.header(OHGmailLabels.sendAtHeader, in: row.headers) != nil
        guard row.state == .scheduled || (row.state == .failed && (hasHeader || row.sendAt != nil)) else { return }
        _ = try DraftMutations.bump(row, sets: DraftMutations.unschedule(row), in: db)
        _ = try DraftMutations.enqueueUpsert(try DraftRow.load(id, in: db), origin: .app, in: db)
    }

    static func liveSendOp(for uuid: String, in db: Database) throws -> Int64? {
        for r in try Row.fetchAll(db, sql: """
            SELECT op_id, payload_json FROM pending_operations
            WHERE kind = 'send_draft' AND status IN ('pending', 'in_flight') ORDER BY op_id
            """) {
            if case let .sendDraft(draft) = try OperationPayloadCodec.decode(kind: .sendDraft, json: r["payload_json"]),
               draft.rawValue == uuid { return r["op_id"] }
        }
        return nil
    }
}

extension MailStore {
    public func send(_ id: DraftID, undoWindow: Duration, origin: OperationOrigin) throws -> SendReceipt {
        try write { db in try SendMutations.send(id, undoWindow: undoWindow, origin: origin, in: db) }
    }

    public func cancelSend(_ receipt: SendReceipt) throws -> Bool {
        try write { db in try SendMutations.cancelSend(receipt, in: db) }
    }

    public func sendNow(_ receipt: SendReceipt) throws -> Bool {
        try write { db in try SendMutations.sendNow(receipt, in: db) }
    }

    public func scheduleSend(_ id: DraftID, at: Date) throws {
        try write { db in try SendMutations.schedule(id, at: at, in: db) }
    }

    public func scheduleSend(_ id: DraftID, at: Date, onlyIfNoReply: Bool) throws {
        try write { db in try SendMutations.schedule(id, at: at, onlyIfNoReply: onlyIfNoReply, in: db) }
    }

    public func scheduledSendHasReply(_ draft: DraftListItem) throws -> Bool? {
        guard let value = DraftRowCodec.header(OHGmailLabels.sendAtConditionHeader, in: draft.extraHeaders) else { return false }
        guard let condition = SendAtCondition(headerValue: value) else { return nil }
        guard let thread = draft.thread else { return false }
        return try read { db in
            try Self.hasReply(tid: thread.rowID.rawValue, account: thread.accountID.rawValue,
                              anchor: condition.anchor?.rawValue, in: db)
        }
    }

    public func cancelScheduledSend(_ id: DraftID) throws {
        try write { db in try SendMutations.cancelSchedule(id, in: db) }
    }
}
