import Foundation
import OpenHumanAI
import SQLite3

actor SQLitePromptStore: PromptOverrideStore {
    enum StoreError: Error { case open(Int32), write(Int32) }

    static let fileName = "prompts.sqlite"
    private static let schemaVersion: Int32 = 1

    private var db: OpaquePointer?
    nonisolated let activeAtOpen: [String: PromptRevision]

    init(url: URL) throws {
        let handle = try SQLiteFileRecovery.open(url, status: Self.openStatus, Self.open)
        activeAtOpen = Self.active(handle)
        db = handle
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
            CREATE TABLE IF NOT EXISTS prompt_overrides (
                prompt_id TEXT PRIMARY KEY,
                active_rev INTEGER,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS prompt_revisions (
                prompt_id TEXT NOT NULL,
                rev INTEGER NOT NULL,
                base_version INTEGER NOT NULL,
                body TEXT NOT NULL,
                digest TEXT NOT NULL,
                origin TEXT NOT NULL CHECK (origin IN ('edit','revert','import','reset')),
                note TEXT,
                created_at REAL NOT NULL,
                PRIMARY KEY (prompt_id, rev)
            );
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


    func activeRevisions() async throws -> [String: PromptRevision] { Self.active(db) }

    private static func active(_ db: OpaquePointer?) -> [String: PromptRevision] {
        let rows = revisions(db, """
            SELECT \(columns) FROM prompt_revisions r
            JOIN prompt_overrides o ON o.prompt_id = r.prompt_id AND o.active_rev = r.rev
            """, [])
        return Dictionary(rows.map { ($0.promptID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func history(of promptID: String) async throws -> [PromptRevision] {
        revisions("SELECT \(Self.columns) FROM prompt_revisions r WHERE r.prompt_id = ? ORDER BY r.rev DESC",
                  [.text(promptID)])
    }

    func revisionCounts() async throws -> [String: Int] {
        guard let statement = prepare("SELECT prompt_id, COUNT(*) FROM prompt_revisions GROUP BY prompt_id", []) else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }
        var out: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = sqlite3_column_text(statement, 0) { out[String(cString: id)] = Int(sqlite3_column_int64(statement, 1)) }
        }
        return out
    }

    func addRevision(promptID: String, baseVersion: Int, body: String, origin: PromptRevision.Origin, note: String?,
                     at date: Date) async throws -> PromptRevision {
        try exec("BEGIN IMMEDIATE")
        do {
            let next = maxRevision(promptID) + 1
            let revision = PromptRevision(promptID: promptID, revision: next, baseVersion: baseVersion, body: body,
                                          origin: origin, note: note, createdAt: date)
            try write("""
                INSERT INTO prompt_revisions (prompt_id, rev, base_version, body, digest, origin, note, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(promptID), .int(Int64(next)), .int(Int64(baseVersion)), .text(body), .text(revision.digest),
                      .text(origin.rawValue), note.map(Value.text) ?? .null, .real(date.timeIntervalSince1970)])
            try setActiveRow(promptID, revision: next, at: date)
            try exec("COMMIT")
            return revision
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func setActive(promptID: String, revision: Int?, at date: Date) async throws {
        if let revision {
            let known = revisions("SELECT \(Self.columns) FROM prompt_revisions r WHERE r.prompt_id = ? AND r.rev = ?",
                                  [.text(promptID), .int(Int64(revision))])
            guard !known.isEmpty else { throw PromptOverrideStoreError.unknownRevision(promptID, revision) }
        }
        try setActiveRow(promptID, revision: revision, at: date)
    }


    private enum Value { case int(Int64), real(Double), text(String), null }

    private static let columns = "r.prompt_id, r.rev, r.base_version, r.body, r.digest, r.origin, r.note, r.created_at"

    private func setActiveRow(_ promptID: String, revision: Int?, at date: Date) throws {
        try write("""
            INSERT INTO prompt_overrides (prompt_id, active_rev, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(prompt_id) DO UPDATE SET active_rev = excluded.active_rev, updated_at = excluded.updated_at
            """, [.text(promptID), revision.map { .int(Int64($0)) } ?? .null, .real(date.timeIntervalSince1970)])
    }

    private func maxRevision(_ promptID: String) -> Int {
        guard let statement = prepare("SELECT MAX(rev) FROM prompt_revisions WHERE prompt_id = ?", [.text(promptID)]) else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    private func revisions(_ sql: String, _ arguments: [Value]) -> [PromptRevision] {
        Self.revisions(db, sql, arguments)
    }

    private static func revisions(_ db: OpaquePointer?, _ sql: String, _ arguments: [Value]) -> [PromptRevision] {
        guard let statement = prepare(db, sql, arguments) else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [PromptRevision] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String? {
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil
                    : sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            guard let id = text(0), let body = text(3), let digest = text(4),
                  let origin = text(5).flatMap(PromptRevision.Origin.init(rawValue:)) else { continue }
            out.append(PromptRevision(
                promptID: id, revision: Int(sqlite3_column_int64(statement, 1)),
                baseVersion: Int(sqlite3_column_int64(statement, 2)), body: body, origin: origin, note: text(6),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)), digest: digest))
        }
        return out
    }

    private func exec(_ sql: String) throws {
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw StoreError.write(status) }
    }

    private func write(_ sql: String, _ arguments: [Value]) throws {
        guard let statement = prepare(sql, arguments) else { throw StoreError.write(sqlite3_errcode(db)) }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw StoreError.write(status) }
    }

    private func prepare(_ sql: String, _ arguments: [Value]) -> OpaquePointer? { Self.prepare(db, sql, arguments) }

    private static func prepare(_ db: OpaquePointer?, _ sql: String, _ arguments: [Value]) -> OpaquePointer? {
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
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, promptStoreTransient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
}

private var promptStoreTransient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
