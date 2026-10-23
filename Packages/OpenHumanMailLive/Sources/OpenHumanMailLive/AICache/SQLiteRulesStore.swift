import Foundation
import MailModel
import OpenHumanCore
import SQLite3

actor SQLiteRulesStore: ClassificationRulesStoring {
    enum StoreError: Error { case open(Int32), write }

    static let fileName = "rules.sqlite"
    private static let schemaVersion: Int32 = 1

    private var db: OpaquePointer?

    init(url: URL) throws {
        db = try SQLiteFileRecovery.open(url, status: Self.openStatus, Self.open)
    }

    isolated deinit {
        sqlite3_close_v2(db)
    }

    private static func openStatus(_ error: any Error) -> Int32? {
        guard case .open(let status)? = error as? StoreError else { return nil }
        return status
    }

    private static func open(_ url: URL) throws -> OpaquePointer? {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            _ = manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            throw StoreError.open(status)
        }
        sqlite3_busy_timeout(handle, 2_000)
        let setup = """
            CREATE TABLE IF NOT EXISTS rule_set_versions (
                version INTEGER PRIMARY KEY,
                origin TEXT NOT NULL CHECK (origin IN ('default','edit','revert','import','app_update','suggestion')),
                body_json TEXT NOT NULL,
                digest TEXT NOT NULL,
                note TEXT,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS rule_set_head (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS examples (
                example_id TEXT PRIMARY KEY,
                account_id INTEGER, thread_id TEXT, latest_message_id TEXT,
                created_at REAL NOT NULL,
                source TEXT NOT NULL,
                feature TEXT NOT NULL,
                expected TEXT NOT NULL,
                rejected_json TEXT, was TEXT,
                decision_id INTEGER, rule_id TEXT, prompt_id TEXT, prompt_version INTEGER, prompt_digest TEXT, model_id TEXT,
                sender TEXT, sender_domain TEXT, list_id TEXT,
                features_json TEXT NOT NULL,
                scope TEXT, created_rule_id TEXT,
                text_json TEXT
            );
            CREATE INDEX IF NOT EXISTS examples_by_thread ON examples (account_id, thread_id);
            CREATE INDEX IF NOT EXISTS examples_by_time ON examples (created_at);
            PRAGMA secure_delete = ON;
            PRAGMA user_version = \(schemaVersion);
            """
        let check = SQLiteFileRecovery.quickCheck(handle)
        guard check == SQLITE_OK,
              sqlite3_exec(handle, setup, nil, nil, nil) == SQLITE_OK else {
            let code = check == SQLITE_OK ? sqlite3_errcode(handle) : check
            sqlite3_close_v2(handle)
            throw StoreError.open(code)
        }
        return handle
    }

    var userVersion: Int32 {
        guard let statement = prepare("PRAGMA user_version", []) else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    }


    func head() async throws -> RuleSetVersion? {
        versionRows("""
            SELECT v.version, v.origin, v.body_json, v.digest, v.note, v.created_at FROM rule_set_versions v
            JOIN rule_set_head h ON h.version = v.version WHERE h.id = 1
            """, []).first
    }

    func versions(limit: Int) async throws -> [RuleSetVersion] {
        versionRows("SELECT version, origin, body_json, digest, note, created_at FROM rule_set_versions "
                     + "ORDER BY version DESC LIMIT ?", [.int(Int64(max(0, limit)))])
    }

    func version(_ number: Int) async throws -> RuleSetVersion? {
        versionRows("SELECT version, origin, body_json, digest, note, created_at FROM rule_set_versions WHERE version = ?",
                    [.int(Int64(number))]).first
    }

    func append(origin: String, bodyJSON: String, digest: String, note: String?, createdAt: Date,
                historyLimit: Int) async throws -> Int {
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        let next = (scalar("SELECT MAX(version) FROM rule_set_versions") ?? 0) + 1
        let ok = run("""
            INSERT INTO rule_set_versions (version, origin, body_json, digest, note, created_at) VALUES (?, ?, ?, ?, ?, ?)
            """, [.int(Int64(next)), .text(origin), .text(bodyJSON), .text(digest), note.map(Value.text) ?? .null,
                  .real(createdAt.timeIntervalSince1970)])
            && run("INSERT OR REPLACE INTO rule_set_head (id, version) VALUES (1, ?)", [.int(Int64(next))])
            && run("DELETE FROM rule_set_versions WHERE version <= ?", [.int(next - Int64(max(1, historyLimit)))])
        guard ok else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw StoreError.write
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return Int(next)
    }


    func examples(limit: Int) async throws -> [LabelledExample] {
        guard let statement = prepare("""
            SELECT example_id, account_id, thread_id, latest_message_id, created_at, source, feature, expected,
                   rejected_json, was, decision_id, rule_id, model_id, sender, sender_domain, list_id, features_json, scope,
                   created_rule_id, text_json
            FROM examples ORDER BY created_at DESC, example_id DESC LIMIT ?
            """, [.int(Int64(max(0, limit)))]) else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [LabelledExample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String? {
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil
                    : sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            func int(_ column: Int32) -> Int64? {
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
            }
            guard let id = text(0), let source = text(5), let feature = text(6), let expected = text(7) else { continue }
            let rejected = text(8).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
            let account: AccountID? = int(1).map { AccountID($0) }
            let thread: GmailThreadID? = text(2).map { GmailThreadID($0) }
            let latest: GmailMessageID? = text(3).map { GmailMessageID($0) }
            out.append(LabelledExample(
                id: id, account: account, thread: thread, latestMessage: latest,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)), source: source,
                feature: feature, expected: expected, rejected: rejected, was: text(9), decisionID: int(10),
                ruleID: text(11), modelID: text(12), sender: text(13), senderDomain: text(14), listID: text(15),
                featuresJSON: text(16) ?? "{}", scope: text(17), createdRuleID: text(18), textJSON: text(19)))
        }
        return out
    }

    func addExample(_ e: LabelledExample, maxRows: Int) async throws {
        func text(_ value: String?) -> Value { value.map(Value.text) ?? .null }
        let rejected = e.rejected.isEmpty ? nil
            : (try? JSONEncoder().encode(e.rejected)).map { String(decoding: $0, as: UTF8.self) }
        let account: Value = e.account.map { Value.int($0.rawValue) } ?? .null
        let decision: Value = e.decisionID.map { Value.int($0) } ?? .null
        let values: [Value] = [.text(e.id), account, text(e.thread?.rawValue), text(e.latestMessage?.rawValue),
                               .real(e.createdAt.timeIntervalSince1970), .text(e.source), .text(e.feature),
                               .text(e.expected), text(rejected), text(e.was), decision, text(e.ruleID), text(e.modelID),
                               text(e.sender), text(e.senderDomain), text(e.listID), .text(e.featuresJSON), text(e.scope),
                               text(e.createdRuleID), text(e.textJSON)]
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        let ok = run("""
            INSERT OR REPLACE INTO examples
                (example_id, account_id, thread_id, latest_message_id, created_at, source, feature, expected, rejected_json,
                 was, decision_id, rule_id, model_id, sender, sender_domain, list_id, features_json, scope, created_rule_id,
                 text_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, values)
            && run("""
                DELETE FROM examples WHERE example_id NOT IN
                    (SELECT example_id FROM examples ORDER BY created_at DESC, example_id DESC LIMIT ?)
                """, [.int(Int64(max(0, maxRows)))])
        sqlite3_exec(db, ok ? "COMMIT" : "ROLLBACK", nil, nil, nil)
        if !ok { throw StoreError.write }
    }

    func deleteExample(id: String) async throws {
        run("DELETE FROM examples WHERE example_id = ?", [.text(id)])
    }

    func removeAllExamples() async throws {
        sqlite3_exec(db, "DELETE FROM examples;", nil, nil, nil)
    }

    var exampleTextDump: [String] {
        guard let statement = prepare("SELECT * FROM examples", []) else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            for column in 0..<sqlite3_column_count(statement) where sqlite3_column_type(statement, column) == SQLITE_TEXT {
                if let value = sqlite3_column_text(statement, column) { out.append(String(cString: value)) }
            }
        }
        return out
    }


    private enum Value { case int(Int64), real(Double), text(String), null }

    private func versionRows(_ sql: String, _ arguments: [Value]) -> [RuleSetVersion] {
        guard let statement = prepare(sql, arguments) else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [RuleSetVersion] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String? {
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil
                    : sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            guard let origin = text(1), let body = text(2), let digest = text(3) else { continue }
            out.append(RuleSetVersion(version: Int(sqlite3_column_int64(statement, 0)), origin: origin, bodyJSON: body,
                                      digest: digest, note: text(4),
                                      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))))
        }
        return out
    }

    private func scalar(_ sql: String) -> Int64? {
        guard let statement = prepare(sql, []) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    @discardableResult
    private func run(_ sql: String, _ arguments: [Value]) -> Bool {
        guard let statement = prepare(sql, arguments) else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func prepare(_ sql: String, _ arguments: [Value]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        for (offset, value) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, rulesTransient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
}

private var rulesTransient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
