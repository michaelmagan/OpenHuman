import Foundation
import GRDB
import OpenHumanCore

extension MailStore: AccountStoring {
    public func addAccount(email: String, displayName: String?, scopes: [String]) throws -> AccountID {
        try write { db in
            let now = nowMillis()
            if let existing = try Int64.fetchOne(db, sql: "SELECT account_id FROM accounts WHERE email = ?",
                                                 arguments: [email]) {
                try db.execute(sql: """
                    UPDATE accounts SET granted_scopes = ?, status = 'active', updated_at = ?,
                           display_name = COALESCE(?, display_name) WHERE account_id = ?
                    """, arguments: [scopes.joined(separator: " "), now, displayName, existing])
                return AccountID(existing)
            }
            let position = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position) + 1, 0) FROM accounts")) ?? 0
            try db.execute(sql: """
                INSERT INTO accounts (email, display_name, position, granted_scopes, added_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [email, displayName, position, scopes.joined(separator: " "), now, now])
            let id = db.lastInsertedRowID
            let virtuals: [(String, String, Int, Int)] = [
                ("oh:allmail", "All Mail", 0, -1), ("oh:snoozed", "Snoozed", 1, 1),
                ("oh:scheduled", "Scheduled", 2, 1), ("oh:reminders", "Reminders", 3, 1),
                ("oh:waiting", "Waiting", 4, 1),
            ]
            for (key, name, pos, dir) in virtuals {
                try db.execute(sql: """
                    INSERT INTO labels (account_id, key, kind, name, display_name, position, sort_direction, updated_at)
                    VALUES (?, ?, 'virtual', ?, ?, ?, ?, ?)
                    """, arguments: [id, key, name, name, pos, dir, now])
            }
            try db.execute(sql: """
                INSERT INTO labels (account_id, key, kind, name, display_name, position, updated_at)
                VALUES (?, 'oh:split:other', 'split', 'Other', 'Other', 1000000, ?)
                """, arguments: [id, now])
            try db.execute(sql: "INSERT INTO sync_state (account_id, updated_at) VALUES (?, ?)", arguments: [id, now])
            try Self.seedDefaultSplits(db, account: id, now: now)
            return AccountID(id)
        }
    }

    public func setAccountStatus(_ id: AccountID, _ status: AccountStatus) throws {
        try write { db in
            try db.execute(sql: "UPDATE accounts SET status = ?, updated_at = ? WHERE account_id = ?",
                           arguments: [status.rawValue, nowMillis(), id.rawValue])
            if db.changesCount == 0 { throw StoreError.notFound("account \(id.rawValue)") }
        }
    }

    public func updateAccount(_ id: AccountID, alias: String?, color: String?, position: Int?,
                              displayName: String?) throws {
        try write { db in
            try db.execute(sql: """
                UPDATE accounts SET alias = COALESCE(?, alias), color = COALESCE(?, color),
                       position = COALESCE(?, position), display_name = COALESCE(?, display_name), updated_at = ?
                WHERE account_id = ?
                """, arguments: [alias, color, position, displayName, nowMillis(), id.rawValue])
            if db.changesCount == 0 { throw StoreError.notFound("account \(id.rawValue)") }
        }
    }

    public func setAccountAlias(_ id: AccountID, _ alias: String?) throws {
        try write { db in
            try db.execute(sql: "UPDATE accounts SET alias = ?, updated_at = ? WHERE account_id = ?",
                           arguments: [alias, nowMillis(), id.rawValue])
            if db.changesCount == 0 { throw StoreError.notFound("account \(id.rawValue)") }
        }
    }

    public func removeAccountData(_ id: AccountID, progress: (Double) -> Void) throws {
        try removeAccountData(id, chunk: Self.removalChunk, progress: progress)
    }

    func removeAccountData(_ id: AccountID, chunk: Int, progress: (Double) -> Void) throws {
        let total = try read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM threads WHERE account_id = ?", arguments: [id.rawValue]) ?? 0
        }
        let draftFolders = try write { db -> [String] in
            try db.execute(sql: "UPDATE accounts SET status = 'removing', updated_at = ? WHERE account_id = ?",
                           arguments: [nowMillis(), id.rawValue])
            if db.changesCount == 0 { throw StoreError.notFound("account \(id.rawValue)") }
            return try String.fetchAll(db, sql: "SELECT draft_uuid FROM drafts WHERE account_id = ?", arguments: [id.rawValue])
        }
        var deleted = 0
        while true {
            let n = try write { db -> Int in
                try db.execute(sql: """
                    DELETE FROM threads WHERE tid IN (SELECT tid FROM threads WHERE account_id = ? LIMIT ?)
                    """, arguments: [id.rawValue, chunk])
                return db.changesCount
            }
            if n == 0 { break }
            deleted += n
            progress(total == 0 ? 0 : min(0.99, Double(deleted) / Double(total)))
        }
        if bumpsChangeFeed {
            try Self.removeIfPresent(location.attachmentsDirectory.appendingPathComponent(String(id.rawValue), isDirectory: true))
        }
        for uuid in draftFolders { try deleteDraftDirectory(uuid) }
        try write { db in
            try db.execute(sql: "DELETE FROM accounts WHERE account_id = ?", arguments: [id.rawValue])
            try db.execute(sql: "DELETE FROM settings WHERE scope = ?", arguments: ["account:\(id.rawValue)"])
        }
        progress(1)
    }

    static let removalChunk = 1000

    private static func seedDefaultSplits(_ db: Database, account: Int64, now: Int64) throws {
        _ = try seedSplit(db, account: account, name: "Important", position: 0, rule: .isImportant, role: "important",
                          now: now)
        let calendar = try seedSplit(db, account: account, name: "Calendar", position: 1, rule: .isEvent,
                                     role: nil, now: now)
        let hidden = String(decoding: try JSONEncoder().encode([calendar]), as: UTF8.self)
        try db.execute(sql: "INSERT INTO settings (scope, key, value_json, updated_at) VALUES (?, ?, ?, ?)",
                       arguments: [scopeString(.account(AccountID(account))), SettingKey<[String]>.hideSplitWhenEmpty.name,
                                   hidden, now])
    }

    private static func seedSplit(_ db: Database, account: Int64, name: String, position: Int, rule: SplitRule,
                                  role: String?, now: Int64) throws -> String {
        let splitID = UUID().uuidString
        try db.execute(sql: """
            INSERT INTO labels (account_id, key, kind, name, display_name, position, updated_at)
            VALUES (?, ?, 'split', ?, ?, ?, ?)
            """, arguments: [account, "oh:split:" + splitID, name, name, position, now])
        let labelRid = db.lastInsertedRowID
        let ruleJSON = String(decoding: try JSONEncoder().encode(rule), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO splits (split_id, account_id, label_rid, name, position, rule_text, rule_json, enabled, role,
                                created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
            """, arguments: [splitID, account, labelRid, name, position, rule.canonicalText, ruleJSON, role, now, now])
        return splitID
    }
}
