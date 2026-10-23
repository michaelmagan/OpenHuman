import Foundation
import MailModel
import OpenHumanCore
import SQLite3

actor SQLiteAutoLabelStore: AutoLabelStoring, DecisionLogStoring {
    enum StoreError: Error { case open(Int32) }

    static let fileName = "classification.sqlite"
    private static let schemaVersion: Int32 = 3

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
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var file = url
        try? file.setResourceValues(excluded)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            throw StoreError.open(status)
        }
        sqlite3_busy_timeout(handle, 2_000)
        let setup = """
            CREATE TABLE IF NOT EXISTS auto_labels (
                account_id INTEGER NOT NULL,
                thread_id TEXT NOT NULL,
                latest_message_id TEXT NOT NULL,
                prompt_version INTEGER NOT NULL,
                model_id TEXT NOT NULL,
                category TEXT,
                source TEXT NOT NULL,
                classified_at REAL NOT NULL,
                rejected TEXT,
                written INTEGER NOT NULL DEFAULT 0,
                prompt_digest TEXT,
                rule_id TEXT,
                rule_set_version INTEGER,
                model_output TEXT,
                PRIMARY KEY (account_id, thread_id)
            );
            CREATE TABLE IF NOT EXISTS decisions (
                decision_id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id INTEGER NOT NULL,
                thread_id TEXT NOT NULL,
                latest_message_id TEXT NOT NULL,
                decided_at REAL NOT NULL,
                feature TEXT NOT NULL,
                decided_by TEXT NOT NULL,
                rule_id TEXT,
                rule_set_version INTEGER,
                prompt_id TEXT,
                prompt_version INTEGER,
                prompt_override_rev INTEGER,
                prompt_digest TEXT,
                provider_id TEXT,
                model_id TEXT,
                params_json TEXT,
                features_json TEXT NOT NULL,
                constraints_json TEXT,
                model_output TEXT,
                confidence REAL,
                output_label TEXT,
                applied_label TEXT,
                applied_state TEXT NOT NULL DEFAULT 'pending',
                trace_id TEXT,
                text_json TEXT
            );
            CREATE INDEX IF NOT EXISTS decisions_by_thread ON decisions (account_id, thread_id, decided_at DESC);
            CREATE INDEX IF NOT EXISTS decisions_by_time ON decisions (decided_at);
            CREATE INDEX IF NOT EXISTS decisions_by_rule ON decisions (rule_id, decided_at);
            PRAGMA secure_delete = ON;
            """
        let check = SQLiteFileRecovery.quickCheck(handle)
        guard check == SQLITE_OK,
              sqlite3_exec(handle, setup, nil, nil, nil) == SQLITE_OK,
              migrate(handle) else {
            let code = check == SQLITE_OK ? sqlite3_errcode(handle) : check
            sqlite3_close_v2(handle)
            throw StoreError.open(code)
        }
        return handle
    }

    private static func migrate(_ handle: OpaquePointer) -> Bool {
        var columns = Set<String>()
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, "PRAGMA table_info(auto_labels);", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
            }
        }
        sqlite3_finalize(statement)
        var sql = ""
        if !columns.contains("rejected") { sql += "ALTER TABLE auto_labels ADD COLUMN rejected TEXT;" }
        if !columns.contains("written") { sql += "ALTER TABLE auto_labels ADD COLUMN written INTEGER NOT NULL DEFAULT 0;" }
        for (name, type) in [("prompt_digest", "TEXT"), ("rule_id", "TEXT"), ("rule_set_version", "INTEGER"),
                             ("model_output", "TEXT")] where !columns.contains(name) {
            sql += "ALTER TABLE auto_labels ADD COLUMN \(name) \(type);"
        }
        sql += "PRAGMA user_version = \(schemaVersion);"
        return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    var userVersion: Int32 {
        guard let statement = prepare("PRAGMA user_version", []) else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    }

    func entries(account: AccountID) async throws -> [AutoLabelEntry] {
        rows("SELECT \(Self.columns) FROM auto_labels WHERE account_id = ? ORDER BY thread_id", [.int(account.rawValue)])
    }

    func entry(account: AccountID, thread: GmailThreadID) async throws -> AutoLabelEntry? {
        rows("SELECT \(Self.columns) FROM auto_labels WHERE account_id = ? AND thread_id = ?",
             [.int(account.rawValue), .text(thread.rawValue)]).first
    }

    func put(_ entries: [AutoLabelEntry]) async throws {
        guard !entries.isEmpty else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        for entry in entries {
            run("""
                INSERT OR REPLACE INTO auto_labels
                    (account_id, thread_id, latest_message_id, prompt_version, model_id, category, source, classified_at,
                     rejected, written, rule_id, rule_set_version, model_output)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.int(entry.account.rawValue), .text(entry.thread.rawValue), .text(entry.latestMessage.rawValue),
                      .int(Int64(entry.promptVersion)), .text(entry.modelID), entry.category.map(Value.text) ?? .null,
                      .text(entry.source.rawValue), .real(entry.classifiedAt.timeIntervalSince1970),
                      AutoLabelRejections.encode(entry.rejected).map(Value.text) ?? .null,
                      .int(entry.writtenToGmail ? 1 : 0), entry.ruleID.map(Value.text) ?? .null,
                      entry.ruleSetVersion.map { .int(Int64($0)) } ?? .null, entry.modelOutput.map(Value.text) ?? .null])
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func accountIDs() async throws -> [AccountID] {
        guard let statement = prepare("SELECT DISTINCT account_id FROM auto_labels ORDER BY account_id", []) else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [AccountID] = []
        while sqlite3_step(statement) == SQLITE_ROW { out.append(AccountID(sqlite3_column_int64(statement, 0))) }
        return out
    }

    func removeAll(account: AccountID) async throws {
        run("DELETE FROM auto_labels WHERE account_id = ?", [.int(account.rawValue)])
    }

    func removeAll() async throws {
        sqlite3_exec(db, "DELETE FROM auto_labels;", nil, nil, nil)
    }

    var count: Int {
        guard let statement = prepare("SELECT COUNT(*) FROM auto_labels", []) else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }


    func appendDecisions(_ new: [ClassificationDecision], now: Date, maxRows: Int, maxDays: Int) async throws {
        guard !new.isEmpty else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        for d in new {
            func text(_ value: String?) -> Value { value.map(Value.text) ?? .null }
            func int(_ value: Int?) -> Value { value.map { .int(Int64($0)) } ?? .null }
            run("""
                INSERT INTO decisions
                    (account_id, thread_id, latest_message_id, decided_at, feature, decided_by, rule_id, rule_set_version,
                     prompt_id, prompt_version, prompt_digest, provider_id, model_id, features_json, constraints_json,
                     model_output, output_label, applied_label, applied_state, text_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.int(d.account.rawValue), .text(d.thread.rawValue), .text(d.latestMessage.rawValue),
                      .real(d.decidedAt.timeIntervalSince1970), .text(d.feature), .text(d.decidedBy), text(d.ruleID),
                      int(d.ruleSetVersion), text(d.promptID), int(d.promptVersion), text(d.promptDigest),
                      text(d.providerID), text(d.modelID), .text(d.featuresJSON), text(d.constraintsJSON),
                      text(d.modelOutput), text(d.outputLabel), text(d.appliedLabel), .text(d.appliedState.rawValue),
                      text(d.textJSON)])
        }
        run("DELETE FROM decisions WHERE decided_at < ?", [.real(now.timeIntervalSince1970 - Double(maxDays) * 86_400)])
        run("""
            DELETE FROM decisions WHERE decision_id NOT IN
                (SELECT decision_id FROM decisions ORDER BY decided_at DESC, decision_id DESC LIMIT ?)
            """, [.int(Int64(max(0, maxRows)))])
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func decisions(limit: Int) async throws -> [ClassificationDecision] {
        decisionRows("SELECT \(Self.decisionColumns) FROM decisions ORDER BY decided_at DESC, decision_id DESC LIMIT ?",
                     [.int(Int64(max(0, limit)))])
    }

    func latestDecision(account: AccountID, thread: GmailThreadID) async throws -> ClassificationDecision? {
        decisionRows("""
            SELECT \(Self.decisionColumns) FROM decisions WHERE account_id = ? AND thread_id = ?
            ORDER BY decided_at DESC, decision_id DESC LIMIT 1
            """, [.int(account.rawValue), .text(thread.rawValue)]).first
    }

    func setApplied(account: AccountID, thread: GmailThreadID, latestMessage: GmailMessageID,
                    state: DecisionAppliedState, label: String?) async throws {
        run("""
            UPDATE decisions SET applied_state = ?, applied_label = ? WHERE decision_id =
                (SELECT decision_id FROM decisions WHERE account_id = ? AND thread_id = ? AND latest_message_id = ?
                 ORDER BY decided_at DESC, decision_id DESC LIMIT 1)
            """, [.text(state.rawValue), label.map(Value.text) ?? .null, .int(account.rawValue), .text(thread.rawValue),
                  .text(latestMessage.rawValue)])
    }

    func removeAllDecisions() async throws {
        sqlite3_exec(db, "DELETE FROM decisions;", nil, nil, nil)
    }

    func decisionCount() async throws -> Int {
        guard let statement = prepare("SELECT COUNT(*) FROM decisions", []) else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    var decisionTextDump: [String] {
        guard let statement = prepare("SELECT * FROM decisions", []) else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            for column in 0..<sqlite3_column_count(statement) where sqlite3_column_type(statement, column) == SQLITE_TEXT {
                if let value = sqlite3_column_text(statement, column) { out.append(String(cString: value)) }
            }
        }
        return out
    }

    private static let decisionColumns = "decision_id, account_id, thread_id, latest_message_id, decided_at, feature, "
        + "decided_by, rule_id, rule_set_version, prompt_id, prompt_version, prompt_digest, provider_id, model_id, "
        + "features_json, constraints_json, model_output, output_label, applied_label, applied_state, text_json"

    private func decisionRows(_ sql: String, _ arguments: [Value]) -> [ClassificationDecision] {
        guard let statement = prepare(sql, arguments) else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [ClassificationDecision] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String? {
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil
                    : sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            func int(_ column: Int32) -> Int? {
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
            }
            guard let thread = text(2), let latest = text(3), let feature = text(5), let by = text(6) else { continue }
            out.append(ClassificationDecision(
                id: sqlite3_column_int64(statement, 0), account: AccountID(sqlite3_column_int64(statement, 1)),
                thread: GmailThreadID(thread), latestMessage: GmailMessageID(latest),
                decidedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)), feature: feature,
                decidedBy: by, ruleID: text(7), ruleSetVersion: int(8), promptID: text(9), promptVersion: int(10),
                promptDigest: text(11), providerID: text(12), modelID: text(13), featuresJSON: text(14) ?? "{}",
                constraintsJSON: text(15), modelOutput: text(16), outputLabel: text(17), appliedLabel: text(18),
                appliedState: text(19).flatMap(DecisionAppliedState.init(rawValue:)) ?? .pending, textJSON: text(20)))
        }
        return out
    }

    private enum Value { case int(Int64), real(Double), text(String), null }

    private static let columns = "account_id, thread_id, latest_message_id, prompt_version, model_id, category, source, "
        + "classified_at, rejected, written, rule_id, rule_set_version, model_output"

    private func rows(_ sql: String, _ arguments: [Value]) -> [AutoLabelEntry] {
        guard let statement = prepare(sql, arguments) else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [AutoLabelEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String? {
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil
                    : sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            guard let thread = text(1), let latest = text(2), let model = text(4),
                  let source = text(6).flatMap(AutoLabelSource.init(rawValue:)) else { continue }
            out.append(AutoLabelEntry(
                account: AccountID(sqlite3_column_int64(statement, 0)), thread: GmailThreadID(thread),
                latestMessage: GmailMessageID(latest), promptVersion: Int(sqlite3_column_int64(statement, 3)),
                modelID: model, category: text(5), source: source,
                classifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                rejected: AutoLabelRejections.decode(text(8)), writtenToGmail: sqlite3_column_int64(statement, 9) != 0,
                modelOutput: text(12), ruleID: text(10),
                ruleSetVersion: sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 11))))
        }
        return out
    }

    private func run(_ sql: String, _ arguments: [Value]) {
        guard let statement = prepare(sql, arguments) else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_step(statement)
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
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, autoLabelTransient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
}

private var autoLabelTransient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
