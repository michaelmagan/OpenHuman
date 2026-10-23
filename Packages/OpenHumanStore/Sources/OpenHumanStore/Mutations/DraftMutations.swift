import Foundation
import GRDB
import OpenHumanCore

struct DraftRow {
    var uuid: String
    var account: Int64
    var tid: Int64?
    var gmailDraftID: String?
    var gmailMessageID: String?
    var origin: DraftOrigin
    var review: DraftReviewState
    var state: DraftState
    var sendAt: Int64?
    var localVersion: Int
    var syncedVersion: Int
    var headers: [String: String]
    var content: DraftContent
    var agentSnapshot: DraftContent?
    var conflict: DraftRowCodec.RemoteConflict?
    var lastError: String?

    var isDirty: Bool { localVersion > syncedVersion }
    var opOrigin: OperationOrigin {
        switch origin {
        case .user: return .app
        case .agent: return .agent
        case .cli: return .cli
        }
    }

    static func load(_ id: DraftID, in db: Database) throws -> DraftRow {
        guard let r = try Row.fetchOne(db, sql: "SELECT * FROM drafts WHERE draft_uuid = ?", arguments: [id.rawValue]) else {
            throw StoreError.notFound("draft \(id.rawValue)")
        }
        return DraftRow(r)
    }

    init(_ r: Row) {
        uuid = r["draft_uuid"]
        account = r["account_id"]
        tid = r["tid"]
        gmailDraftID = r["gmail_draft_id"]
        gmailMessageID = r["gmail_message_id"]
        origin = DraftOrigin(rawValue: r["origin"]) ?? .user
        review = DraftReviewState(rawValue: r["review_state"]) ?? .none
        state = DraftState(rawValue: r["state"]) ?? .editing
        sendAt = r["send_at"]
        localVersion = r["local_version"]
        syncedVersion = r["synced_version"]
        headers = DraftRowCodec.decodeHeaders(r["extra_headers_json"])
        content = DraftContent(from: (r["from_email"] as String?).map { EmailAddress(email: $0) },
                               to: DraftRowCodec.decodeAddresses(r["to_json"]), cc: DraftRowCodec.decodeAddresses(r["cc_json"]),
                               bcc: DraftRowCodec.decodeAddresses(r["bcc_json"]), subject: r["subject"],
                               bodyHTML: r["body_html"], bodyText: r["body_text"],
                               attachments: DraftRowCodec.decodeAttachments(r["attachments_json"]))
        agentSnapshot = (r["agent_snapshot_json"] as String?).flatMap {
            try? JSONDecoder().decode(DraftContent.self, from: Data($0.utf8))
        }
        conflict = DraftRowCodec.decodeConflict(r["remote_conflict_json"])
        lastError = r["last_error"]
    }

    static func normalized(_ c: DraftContent) -> DraftContent {
        var c = c
        c.from = c.from.map { EmailAddress(email: $0.email) }
        return c
    }
}

enum DraftMutations {
    static let originHeader = "X-OpenHuman-Origin"
    static let agentNoteLimit = 500

    static func create(account: AccountID, mode: ComposeMode, replyTo: GmailMessageID?, content: DraftContent,
                       origin: DraftOrigin, reviewState: DraftReviewState, agentNote: String?,
                       extraHeaders: [String: String], in db: Database) throws -> DraftID {
        try MailStore.requireWritableAccount(account, in: db)
        let a = account.rawValue
        var tid: Int64?, gmailThreadID: String?
        if let replyTo {
            let row = try Row.fetchOne(db, sql: """
                SELECT m.tid, t.gmail_thread_id FROM messages m JOIN threads t ON t.tid = m.tid
                WHERE m.account_id = ? AND m.gmail_message_id = ?
                """, arguments: [a, replyTo.rawValue])
            if mode == .reply || mode == .replyAll {
                guard let row else { throw StoreError.notFound("message \(replyTo.rawValue)") }
                tid = row["tid"]; gmailThreadID = row["gmail_thread_id"]
            }
        }
        let uuid = UUID().uuidString
        let now = nowMillis()
        let byAgent = origin != .user
        let columns: [(String, DatabaseValue)] = [
            ("draft_uuid", uuid.databaseValue), ("account_id", a.databaseValue), ("tid", tid.databaseValue),
            ("gmail_thread_id", gmailThreadID.databaseValue), ("compose_mode", mode.rawValue.databaseValue),
            ("reply_to_gmail_message_id", replyTo?.rawValue.databaseValue ?? .null),
            ("extra_headers_json", DraftRowCodec.headers(extraHeaders).databaseValue),
            ("origin", origin.rawValue.databaseValue), ("review_state", reviewState.rawValue.databaseValue),
            ("state", DraftState.editing.rawValue.databaseValue),
            ("local_version", 1.databaseValue), ("synced_version", 0.databaseValue),
            ("agent_note", (byAgent ? agentNote.map(capNote) : nil).databaseValue),
            ("agent_snapshot_json", (byAgent ? DraftRowCodec.content(content) : nil).databaseValue),
            ("created_at", now.databaseValue), ("updated_at", now.databaseValue),
        ] + MailStore.contentColumns(content)
        try db.execute(sql: """
            INSERT INTO drafts (\(columns.map(\.0).joined(separator: ", ")))
            VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))
            """, arguments: StatementArguments(columns.map(\.1)))
        if let tid { try ThreadAggregator.refresh(tids: [tid], in: db) }
        return DraftID(uuid)
    }

    static func update(_ id: DraftID, content: DraftContent, expectedVersion: Int?, in db: Database) throws -> Int {
        let row = try DraftRow.load(id, in: db)
        try requireEditable(row)
        if let expectedVersion, expectedVersion != row.localVersion {
            throw StoreError.conflict("draft \(id.rawValue) is at version \(row.localVersion), not \(expectedVersion)")
        }
        // Why: a save that repeats the stored content keeps the version, so it uploads nothing and starts no sync
        if row.state != .failed, DraftRow.normalized(content) == DraftRow.normalized(row.content) { return row.localVersion }
        var sets = MailStore.contentColumns(content)
        if row.state == .failed { sets += unschedule(row) }
        return try bump(row, sets: sets, in: db)
    }

    static func updateAgent(_ id: DraftID, content: DraftContent, agentNote: String?, in db: Database) throws -> Int {
        let row = try DraftRow.load(id, in: db)
        guard row.origin != .user else { throw StoreError.conflict("draft \(id.rawValue) is the user's, not an agent's") }
        try requireEditable(row)
        let userEdited = row.agentSnapshot.map { DraftRow.normalized($0) != DraftRow.normalized(row.content) } ?? false
        var sets: [(String, DatabaseValue)] = [
            ("agent_snapshot_json", DraftRowCodec.content(content).databaseValue),
            ("review_state", DraftReviewState.pending.rawValue.databaseValue),
        ]
        if let agentNote { sets.append(("agent_note", capNote(agentNote).databaseValue)) }
        if userEdited {
            let conflict = DraftRowCodec.RemoteConflict(content: content, extraHeaders: row.headers, gmailMessageID: "")
            sets.append(("remote_conflict_json", DraftRowCodec.conflict(conflict).databaseValue))
        } else {
            sets += MailStore.contentColumns(content)
        }
        if row.state == .scheduled || row.state == .failed { sets += unschedule(row) }
        return try bump(row, sets: sets, in: db)
    }

    static func saveRemotely(_ id: DraftID, in db: Database) throws -> OperationID {
        let row = try DraftRow.load(id, in: db)
        try requireEditable(row)
        return OperationID(rawValue: try enqueueUpsert(row, origin: row.opOrigin, in: db))
    }

    static func enqueueUpsert(_ row: DraftRow, origin: OperationOrigin, in db: Database) throws -> Int64 {
        let payload = OperationPayload.upsertDraft(draftID: DraftID(row.uuid), version: row.localVersion)
        for r in try Row.fetchAll(db, sql: """
            SELECT op_id, payload_json FROM pending_operations
            WHERE account_id = ? AND kind = 'upsert_draft' AND status = 'pending' AND attempts = 0 ORDER BY op_id DESC
            """, arguments: [row.account]) {
            guard case let .upsertDraft(draft, _) = try OperationPayloadCodec.decode(kind: .upsertDraft, json: r["payload_json"]),
                  draft.rawValue == row.uuid else { continue }
            let op: Int64 = r["op_id"]
            try db.execute(sql: "UPDATE pending_operations SET payload_json = ?, updated_at = ? WHERE op_id = ?",
                           arguments: [OperationPayloadCodec.encode(payload), nowMillis(), op])
            return op
        }
        return try OpWriter.insert(account: row.account, payload: payload, origin: origin, coalesceKey: nil, in: db)
    }

    static func discard(_ id: DraftID, in db: Database) throws -> (op: OperationID?, uuid: String?) {
        let row = try DraftRow.load(id, in: db)
        switch row.state {
        case .sending: throw StoreError.conflict("draft \(id.rawValue) is being sent; cancel the send first")
        case .sent, .discarded: return (nil, nil)
        case .editing, .scheduled, .failed: break
        }
        try db.execute(sql: "UPDATE drafts SET state = 'discarded', updated_at = ? WHERE draft_uuid = ?",
                       arguments: [nowMillis(), row.uuid])
        try cancelPendingUpserts(of: row, in: db)
        var op: OperationID?
        if let gmailDraftID = row.gmailDraftID {
            op = OperationID(rawValue: try OpWriter.insert(
                account: row.account, payload: .deleteDraft(draftID: id, gmailDraftID: GmailDraftID(gmailDraftID)),
                origin: row.opOrigin, coalesceKey: nil, in: db))
        }
        if let tid = row.tid { try ThreadAggregator.refresh(tids: [tid], in: db) }
        return (op, row.uuid)
    }

    static func setReviewState(_ id: DraftID, _ state: DraftReviewState, in db: Database) throws {
        let row = try DraftRow.load(id, in: db)
        guard row.review != state else { return }
        try db.execute(sql: "UPDATE drafts SET review_state = ?, updated_at = ? WHERE draft_uuid = ?",
                       arguments: [state.rawValue, nowMillis(), row.uuid])
        guard state == .approved || state == .rejected, [.editing, .scheduled, .failed].contains(row.state) else { return }
        if let message = row.gmailMessageID,
           let agentKey = try LabelIndex.load(account: row.account, in: db).keyByName[OHGmailLabels.agent] {
            let target = try Row.fetchOne(db, sql: """
                SELECT mid, tid, label_ids FROM messages WHERE account_id = ? AND gmail_message_id = ?
                """, arguments: [row.account, message]).map {
                OpTarget(mid: $0["mid"], tid: $0["tid"], gmailID: message, labels: Labels.split($0["label_ids"]))
            }
            _ = try OpWriter.modifyLabels(account: row.account, targets: target.map { [$0] } ?? [],
                                          extraIDs: target == nil ? [message] : [], add: [], remove: [agentKey],
                                          origin: .app, in: db)
            if let target {
                try LabelOverlay.recompute(mids: [target.mid], in: db)
                try ThreadAggregator.refresh(tids: [target.tid], in: db)
            }
        }
        if row.gmailDraftID != nil || state == .approved { _ = try enqueueUpsert(row, origin: .app, in: db) }
    }

    static func resolveConflict(_ id: DraftID, keep: DraftConflictChoice, in db: Database) throws {
        let row = try DraftRow.load(id, in: db)
        guard let conflict = row.conflict else { return }
        try requireEditable(row)
        var sets: [(String, DatabaseValue)] = [("remote_conflict_json", .null)]
        switch keep {
        case .keepLocal:
            _ = try bump(row, sets: sets, in: db)
        case .takeRemote where conflict.gmailMessageID.isEmpty:
            sets += MailStore.contentColumns(conflict.content)
            _ = try bump(row, sets: sets, in: db)
        case .takeRemote:
            sets += MailStore.contentColumns(conflict.content) + [
                ("extra_headers_json", DraftRowCodec.headers(conflict.extraHeaders).databaseValue),
                ("gmail_message_id", conflict.gmailMessageID.databaseValue),
                ("synced_version", (row.localVersion + 1).databaseValue),
            ]
            try cancelPendingUpserts(of: row, in: db)
            _ = try bump(row, sets: sets, in: db)
        }
    }

    static func requireEditable(_ row: DraftRow) throws {
        switch row.state {
        case .sending: throw StoreError.conflict("draft \(row.uuid) is being sent")
        case .sent: throw StoreError.conflict("draft \(row.uuid) was sent")
        case .discarded: throw StoreError.conflict("draft \(row.uuid) was discarded")
        case .editing, .scheduled, .failed: break
        }
    }

    static func bump(_ row: DraftRow, sets: [(String, DatabaseValue)], in db: Database) throws -> Int {
        let version = row.localVersion + 1
        var columns = sets.filter { $0.0 != "local_version" && $0.0 != "updated_at" }
        columns += [("local_version", version.databaseValue), ("updated_at", nowMillis().databaseValue)]
        try db.execute(sql: "UPDATE drafts SET \(columns.map { "\($0.0) = ?" }.joined(separator: ", ")) WHERE draft_uuid = ?",
                       arguments: StatementArguments(columns.map(\.1) + [row.uuid.databaseValue]))
        if let tid = row.tid { try ThreadAggregator.refresh(tids: [tid], in: db) }
        return version
    }

    static func unschedule(_ row: DraftRow) -> [(String, DatabaseValue)] {
        [("state", DraftState.editing.rawValue.databaseValue), ("send_at", DatabaseValue.null),
         ("last_error", DatabaseValue.null),
         ("extra_headers_json", DraftRowCodec.headers(withoutSendAt(row.headers)).databaseValue)]
    }

    static func withoutSendAt(_ headers: [String: String]) -> [String: String] {
        let names: Set<String> = [OHGmailLabels.sendAtHeader.lowercased(), OHGmailLabels.sendAtConditionHeader.lowercased()]
        return headers.filter { !names.contains($0.key.lowercased()) }
    }

    static func cancelPendingUpserts(of row: DraftRow, in db: Database) throws {
        for r in try Row.fetchAll(db, sql: """
            SELECT op_id, payload_json FROM pending_operations
            WHERE account_id = ? AND kind = 'upsert_draft' AND status = 'pending' AND attempts = 0
            """, arguments: [row.account]) {
            guard case let .upsertDraft(draft, _) = try OperationPayloadCodec.decode(kind: .upsertDraft, json: r["payload_json"]),
                  draft.rawValue == row.uuid else { continue }
            let dependents = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM pending_operations WHERE depends_on = ? AND status IN ('pending', 'in_flight')
                """, arguments: [r["op_id"] as Int64]) ?? 0
            guard dependents == 0 else { continue }
            try db.execute(sql: """
                UPDATE pending_operations SET status = 'cancelled', last_error_code = 'superseded', updated_at = ?
                WHERE op_id = ?
                """, arguments: [nowMillis(), r["op_id"] as Int64])
        }
    }

    static func capNote(_ note: String) -> String {
        guard note.unicodeScalars.count > agentNoteLimit else { return note }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: note.unicodeScalars.prefix(agentNoteLimit))
        return String(scalars)
    }
}

extension MailStore {
    public func createDraft(account: AccountID, mode: ComposeMode, replyTo: GmailMessageID?, content: DraftContent,
                            origin: DraftOrigin, reviewState: DraftReviewState, agentNote: String?,
                            extraHeaders: [String: String]) throws -> DraftID {
        try write { db in
            try DraftMutations.create(account: account, mode: mode, replyTo: replyTo, content: content, origin: origin,
                                      reviewState: reviewState, agentNote: agentNote, extraHeaders: extraHeaders, in: db)
        }
    }

    public func updateAgentDraft(_ id: DraftID, content: DraftContent, agentNote: String?) throws -> Int {
        try write { db in try DraftMutations.updateAgent(id, content: content, agentNote: agentNote, in: db) }
    }

    public func updateDraft(_ id: DraftID, content: DraftContent, expectedVersion: Int?) throws -> Int {
        try write { db in try DraftMutations.update(id, content: content, expectedVersion: expectedVersion, in: db) }
    }

    public func saveDraftRemotely(_ id: DraftID) throws -> OperationID {
        try write { db in try DraftMutations.saveRemotely(id, in: db) }
    }

    public func discardDraft(_ id: DraftID) throws -> OperationID? {
        let result = try write { db in try DraftMutations.discard(id, in: db) }
        if let uuid = result.uuid { removeDraftDirectory(uuid) }
        return result.op
    }

    public func setReviewState(_ id: DraftID, _ state: DraftReviewState) throws {
        try write { db in try DraftMutations.setReviewState(id, state, in: db) }
    }

    public func resolveDraftConflict(_ id: DraftID, keep: DraftConflictChoice) throws {
        try write { db in try DraftMutations.resolveConflict(id, keep: keep, in: db) }
    }

    func removeDraftDirectory(_ uuid: String) {
        try? deleteDraftDirectory(uuid)
    }

    func deleteDraftDirectory(_ uuid: String) throws {
        guard bumpsChangeFeed, !uuid.isEmpty, !uuid.contains("/"), !uuid.contains("..") else { return }
        try Self.removeIfPresent(location.draftsDirectory.appendingPathComponent(uuid, isDirectory: true))
    }

    static func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {}
    }
}
