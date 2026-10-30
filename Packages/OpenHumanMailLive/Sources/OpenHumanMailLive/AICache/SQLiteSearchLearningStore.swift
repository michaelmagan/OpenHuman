import Foundation
import OpenHumanCore
import OpenHumanStore
import SQLite3

struct SearchLearningEntry: Sendable, Hashable {
    let account: AccountID
    let thread: GmailThreadID
    let history: SearchClickHistory
}

protocol SearchLearningStoring: Sendable {
    var initialEntries: [SearchLearningEntry] { get }
    func put(_ entry: SearchLearningEntry) async
    func remove(_ entries: [(AccountID, GmailThreadID)]) async
    func removeAll() async
}

actor InMemorySearchLearningStore: SearchLearningStoring {
    nonisolated let initialEntries: [SearchLearningEntry]
    private var rows: [String: SearchLearningEntry] = [:]

    init(_ entries: [SearchLearningEntry] = []) {
        initialEntries = entries
        for entry in entries { rows["\(entry.account.rawValue)/\(entry.thread.rawValue)"] = entry }
    }

    func put(_ entry: SearchLearningEntry) { rows["\(entry.account.rawValue)/\(entry.thread.rawValue)"] = entry }
    func remove(_ entries: [(AccountID, GmailThreadID)]) {
        for (account, thread) in entries { rows["\(account.rawValue)/\(thread.rawValue)"] = nil }
    }
    func removeAll() { rows = [:] }
    var count: Int { rows.count }
}

actor SQLiteSearchLearningStore: SearchLearningStoring {
    enum StoreError: Error { case open(Int32) }

    static let fileName = "search-learning.sqlite"
    private static let schemaVersion: Int32 = 1

    nonisolated let initialEntries: [SearchLearningEntry]
    private var db: OpaquePointer?

    init(url: URL) throws {
        let handle = try SQLiteFileRecovery.open(url, status: Self.openStatus, Self.open)
        db = handle
        initialEntries = Self.readAll(handle)
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
            CREATE TABLE IF NOT EXISTS search_opens (
                account_id INTEGER NOT NULL,
                thread_id TEXT NOT NULL,
                score REAL NOT NULL,
                at REAL NOT NULL,
                PRIMARY KEY (account_id, thread_id)
            );
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

    private static func readAll(_ handle: OpaquePointer?) -> [SearchLearningEntry] {
        var statement: OpaquePointer?
        guard let handle, sqlite3_prepare_v2(handle, "SELECT account_id, thread_id, score, at FROM search_opens ORDER BY account_id, thread_id",
                                             -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }
        var out: [SearchLearningEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let thread = sqlite3_column_text(statement, 1) else { continue }
            out.append(SearchLearningEntry(
                account: AccountID(sqlite3_column_int64(statement, 0)), thread: GmailThreadID(String(cString: thread)),
                history: SearchClickHistory(score: sqlite3_column_double(statement, 2),
                                            at: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)))))
        }
        return out
    }

    func put(_ entry: SearchLearningEntry) {
        run("INSERT OR REPLACE INTO search_opens (account_id, thread_id, score, at) VALUES (?, ?, ?, ?)",
            [.int(entry.account.rawValue), .text(entry.thread.rawValue), .real(entry.history.score),
             .real(entry.history.at.timeIntervalSince1970)])
    }

    func remove(_ entries: [(AccountID, GmailThreadID)]) {
        guard !entries.isEmpty else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        for (account, thread) in entries {
            run("DELETE FROM search_opens WHERE account_id = ? AND thread_id = ?", [.int(account.rawValue), .text(thread.rawValue)])
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func removeAll() {
        sqlite3_exec(db, "DELETE FROM search_opens;", nil, nil, nil)
    }

    var count: Int { Self.readAll(db).count }

    var userVersion: Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    }

    private enum Value { case int(Int64), real(Double), text(String) }

    private func run(_ sql: String, _ arguments: [Value]) {
        var statement: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, searchLearningTransient)
            }
        }
        sqlite3_step(statement)
    }
}

private var searchLearningTransient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
