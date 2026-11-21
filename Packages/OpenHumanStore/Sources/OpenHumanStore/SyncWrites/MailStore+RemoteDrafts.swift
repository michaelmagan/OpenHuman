import Foundation
import GRDB
import OpenHumanCore

extension MailStore {
    private static let originHeader = "X-OpenHuman-Origin"

    public func reconcileRemoteDrafts(_ drafts: [RemoteDraftUpsert], account: AccountID, complete: Bool) throws {
        let discarded = try write { db -> [String] in
            try requireAccount(account, in: db)
            let a = account.rawValue
            let now = nowMillis()
            let context = try AggregationContext.load(account: a, in: db)
            let agentKey = context.keyByName[OHGmailLabels.agent]
            let creationInFlight = try Self.draftCreationInFlight(account: a, in: db)
            var tids = Set<Int64>()
            var discarded: [String] = []
            var seen = Set<String>()

            for remote in drafts {
                seen.insert(remote.gmailDraftID.rawValue)
                let messageLabels = try Self.messageLabelKeys(account: a, gmailMessageID: remote.gmailMessageID.rawValue, in: db)
                let names = context.names(of: messageLabels)
                let hasAgentMarker = DraftRowCodec.header(Self.originHeader, in: remote.extraHeaders) != nil
                    || (agentKey.map { messageLabels.contains($0) } ?? false)
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT * FROM drafts WHERE account_id = ? AND gmail_draft_id = ?
                    """, arguments: [a, remote.gmailDraftID.rawValue]) else {
                    if creationInFlight { continue }
                    tids.insert(try insertRemoteDraft(remote, account: account, labelNames: names,
                                                      agentLabel: agentKey.map { messageLabels.contains($0) } ?? false,
                                                      now: now, in: db))
                    continue
                }
                let uuid: String = row["draft_uuid"]
                guard let state = DraftState(rawValue: row["state"]), [.editing, .scheduled, .failed].contains(state)
                else { continue }
                let dirty = (row["local_version"] as Int) > (row["synced_version"] as Int)
                let changed = (row["gmail_message_id"] as String?) != remote.gmailMessageID.rawValue
                if let tid: Int64 = row["tid"] { tids.insert(tid) }

                if dirty {
                    guard changed, try !Self.upsertInFlight(draft: uuid, in: db) else { continue }
                    let conflict = DraftRowCodec.RemoteConflict(content: remote.content, extraHeaders: remote.extraHeaders,
                                                                gmailMessageID: remote.gmailMessageID.rawValue)
                    let json = DraftRowCodec.conflict(conflict)
                    if json != (row["remote_conflict_json"] as String?) {
                        try db.execute(sql: "UPDATE drafts SET remote_conflict_json = ?, updated_at = ? WHERE draft_uuid = ?",
                                       arguments: [json, now, uuid])
                    }
                    continue
                }

                // Why: our own upload has replaced the Gmail message but is not recorded yet; the next refresh decides
                if changed, try Self.upsertInFlight(draft: uuid, in: db) { continue }
                var sets: [(String, DatabaseValue)] = []
                if changed {
                    let tid = try threadRow(account: account, thread: remote.gmailThreadID, now: now, in: db)
                    tids.insert(tid)
                    let schedule = try ScheduleDerivation.deriveScheduledSend(.init(
                        isDirty: false,
                        current: .init(state: state, sendAt: row["send_at"], lastError: row["last_error"]),
                        header: DraftRowCodec.header(OHGmailLabels.sendAtHeader, in: remote.extraHeaders),
                        labelNames: names, remoteChanged: true))
                    sets += Self.contentColumns(remote.content) + [
                        ("gmail_message_id", remote.gmailMessageID.rawValue.databaseValue),
                        ("gmail_thread_id", remote.gmailThreadID.rawValue.databaseValue),
                        ("tid", tid.databaseValue),
                        ("extra_headers_json", DraftRowCodec.headers(remote.extraHeaders).databaseValue),
                        ("remote_conflict_json", DatabaseValue.null),
                        ("state", schedule.state.rawValue.databaseValue),
                        ("send_at", schedule.sendAt.databaseValue),
                        ("last_error", schedule.lastError.databaseValue),
                    ]
                }
                if (row["review_state"] as String) == DraftReviewState.pending.rawValue && !hasAgentMarker {
                    sets.append(("review_state", DraftReviewState.approved.rawValue.databaseValue))
                }
                var changes = sets.filter { (row[$0.0] as DatabaseValue) != $0.1 }
                guard !changes.isEmpty else { continue }
                // Why: an open composer and a saver holding the old version must see that the content was replaced
                let contentNames = Set(Self.contentColumns(remote.content).map(\.0))
                if changes.contains(where: { contentNames.contains($0.0) }) {
                    let version = (row["local_version"] as Int) + 1
                    changes += [("local_version", version.databaseValue), ("synced_version", version.databaseValue)]
                }
                var args = StatementArguments(changes.map(\.1))
                args += [now, uuid]
                try db.execute(sql: "UPDATE drafts SET \(changes.map { "\($0.0) = ?" }.joined(separator: ", ")), updated_at = ? WHERE draft_uuid = ?",
                               arguments: args)
            }

            if complete {
                for row in try Row.fetchAll(db, sql: """
                    SELECT draft_uuid, gmail_draft_id, tid, local_version, synced_version FROM drafts
                    WHERE account_id = ? AND gmail_draft_id IS NOT NULL AND state IN ('editing', 'scheduled', 'failed')
                    """, arguments: [a]) where !seen.contains(row["gmail_draft_id"]) {
                    let uuid: String = row["draft_uuid"]
                    if let tid: Int64 = row["tid"] { tids.insert(tid) }
                    if (row["local_version"] as Int) > (row["synced_version"] as Int) {
                        try db.execute(sql: """
                            UPDATE drafts SET gmail_draft_id = NULL, gmail_message_id = NULL, updated_at = ? WHERE draft_uuid = ?
                            """, arguments: [now, uuid])
                    } else {
                        try db.execute(sql: "UPDATE drafts SET state = 'discarded', updated_at = ? WHERE draft_uuid = ?",
                                       arguments: [now, uuid])
                        discarded.append(uuid)
                    }
                }
            }
            try ThreadAggregator.refresh(tids: tids, in: db)
            return discarded
        }
        if bumpsChangeFeed {
            for uuid in discarded where !uuid.isEmpty && !uuid.contains("/") && !uuid.contains("..") {
                try? FileManager.default.removeItem(at: location.draftsDirectory.appendingPathComponent(uuid, isDirectory: true))
            }
        }
    }

    private func insertRemoteDraft(_ remote: RemoteDraftUpsert, account: AccountID, labelNames: [String],
                                   agentLabel: Bool, now: Int64, in db: Database) throws -> Int64 {
        let a = account.rawValue
        let tid = try threadRow(account: account, thread: remote.gmailThreadID, now: now, in: db)
        let originHeader = DraftRowCodec.header(Self.originHeader, in: remote.extraHeaders)?
            .trimmingCharacters(in: .whitespaces).lowercased()
        let origin: DraftOrigin = originHeader == "agent" ? .agent : (originHeader == "cli" ? .cli : .user)
        let review: DraftReviewState = (origin != .user || agentLabel) ? .pending : .none
        let inReplyTo = DraftRowCodec.header("In-Reply-To", in: remote.extraHeaders)
            .map(AttachmentRows.stripBrackets).flatMap { $0.isEmpty ? nil : $0 }
        let replyTo = try inReplyTo.flatMap {
            try String.fetchOne(db, sql: """
                SELECT gmail_message_id FROM messages WHERE account_id = ? AND rfc822_message_id = ? ORDER BY internal_date DESC LIMIT 1
                """, arguments: [a, $0])
        }
        let schedule = try ScheduleDerivation.deriveScheduledSend(.init(
            isDirty: false, current: .init(state: .editing, sendAt: nil, lastError: nil),
            header: DraftRowCodec.header(OHGmailLabels.sendAtHeader, in: remote.extraHeaders), labelNames: labelNames))
        let columns: [(String, DatabaseValue)] = [
            ("draft_uuid", UUID().uuidString.databaseValue), ("account_id", a.databaseValue),
            ("gmail_draft_id", remote.gmailDraftID.rawValue.databaseValue),
            ("gmail_message_id", remote.gmailMessageID.rawValue.databaseValue), ("tid", tid.databaseValue),
            ("gmail_thread_id", remote.gmailThreadID.rawValue.databaseValue),
            ("compose_mode", (inReplyTo == nil ? ComposeMode.new : .reply).rawValue.databaseValue),
            ("reply_to_gmail_message_id", replyTo.databaseValue),
            ("extra_headers_json", DraftRowCodec.headers(remote.extraHeaders).databaseValue),
            ("origin", origin.rawValue.databaseValue), ("review_state", review.rawValue.databaseValue),
            ("state", schedule.state.rawValue.databaseValue), ("send_at", schedule.sendAt.databaseValue),
            ("last_error", schedule.lastError.databaseValue),
            ("local_version", 1.databaseValue), ("synced_version", 1.databaseValue),
            ("agent_snapshot_json", (origin == .user ? nil : DraftRowCodec.content(remote.content)).databaseValue),
            ("created_at", now.databaseValue), ("updated_at", now.databaseValue),
        ] + Self.contentColumns(remote.content)
        try db.execute(sql: """
            INSERT INTO drafts (\(columns.map(\.0).joined(separator: ", ")))
            VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))
            """, arguments: StatementArguments(columns.map(\.1)))
        return tid
    }

    static func contentColumns(_ c: DraftContent) -> [(String, DatabaseValue)] {
        [
            ("from_email", c.from?.email.databaseValue ?? .null),
            ("to_json", DraftRowCodec.addresses(c.to).databaseValue),
            ("cc_json", DraftRowCodec.addresses(c.cc).databaseValue),
            ("bcc_json", DraftRowCodec.addresses(c.bcc).databaseValue),
            ("subject", c.subject.databaseValue),
            ("body_html", c.bodyHTML.databaseValue),
            ("body_text", c.bodyText.databaseValue),
            ("attachments_json", DraftRowCodec.attachments(c.attachments).databaseValue),
        ]
    }

    private static func messageLabelKeys(account: Int64, gmailMessageID: String, in db: Database) throws -> Set<String> {
        Labels.split(try String.fetchOne(db, sql: """
            SELECT label_ids FROM messages WHERE account_id = ? AND gmail_message_id = ?
            """, arguments: [account, gmailMessageID]) ?? "")
    }

    private static func draftCreationInFlight(account: Int64, in db: Database) throws -> Bool {
        for row in try Row.fetchAll(db, sql: """
            SELECT payload_json FROM pending_operations
            WHERE account_id = ? AND kind = 'upsert_draft' AND status = 'in_flight'
            """, arguments: [account]) {
            guard case let .upsertDraft(draftID, _) = try OperationPayloadCodec.decode(kind: .upsertDraft,
                                                                                      json: row["payload_json"]) else { continue }
            if try Int.fetchOne(db, sql: "SELECT 1 FROM drafts WHERE draft_uuid = ? AND gmail_draft_id IS NULL",
                                arguments: [draftID.rawValue]) != nil { return true }
        }
        return false
    }

    private static func upsertInFlight(draft uuid: String, in db: Database) throws -> Bool {
        for row in try Row.fetchAll(db, sql: """
            SELECT payload_json FROM pending_operations WHERE kind = 'upsert_draft' AND status = 'in_flight'
            """) {
            if case let .upsertDraft(draftID, _) = try OperationPayloadCodec.decode(kind: .upsertDraft, json: row["payload_json"]),
               draftID.rawValue == uuid { return true }
        }
        return false
    }
}
