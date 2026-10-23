import Foundation
import OpenHumanAI
import SQLite3

actor SQLiteAIResultCache: AIResultCache {
    enum CacheError: Error { case open(Int32), prepare(Int32) }

    static let fileName = "ai-cache.sqlite"
    static let defaultCapacity = 5_000
    private static let schemaVersion: Int32 = 1

    private var db: OpaquePointer?
    private let capacity: Int
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL, capacity: Int = SQLiteAIResultCache.defaultCapacity, now: @escaping @Sendable () -> Date = { Date() })
        throws {
        self.capacity = max(1, capacity)
        self.now = now
        db = try SQLiteFileRecovery.open(url, status: Self.openStatus, Self.open)
    }

    isolated deinit {
        sqlite3_close_v2(db)
    }

    private static func openStatus(_ error: any Error) -> Int32? {
        guard case .open(let status)? = error as? CacheError else { return nil }
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
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            throw CacheError.open(status)
        }
        sqlite3_busy_timeout(handle, 2_000)
        let setup = """
            CREATE TABLE IF NOT EXISTS results (
                digest TEXT PRIMARY KEY NOT NULL,
                thread_key TEXT,
                value BLOB NOT NULL,
                expires_at REAL,
                created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS results_thread ON results(thread_key);
            CREATE INDEX IF NOT EXISTS results_created ON results(created_at);
            PRAGMA user_version = \(schemaVersion);
            PRAGMA secure_delete = ON;
            """
        let check = SQLiteFileRecovery.quickCheck(handle)
        guard check == SQLITE_OK,
              sqlite3_exec(handle, setup, nil, nil, nil) == SQLITE_OK else {
            let code = check == SQLITE_OK ? sqlite3_errcode(handle) : check
            sqlite3_close_v2(handle)
            throw CacheError.open(code)
        }
        return handle
    }

    func get(_ key: AICacheKey) async -> CachedAIResult? {
        guard let statement = prepare("SELECT value, expires_at FROM results WHERE digest = ?") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(key.digest, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(statement, 1) != SQLITE_NULL, sqlite3_column_double(statement, 1) <= now().timeIntervalSince1970 {
            delete(digest: key.digest)
            return nil
        }
        guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return try? decoder.decode(CachedAIResult.self, from: data)
    }

    func put(_ key: AICacheKey, _ value: CachedAIResult, ttl: Duration?) async {
        guard let data = try? encoder.encode(value),
              let statement = prepare("""
                  INSERT OR REPLACE INTO results (digest, thread_key, value, expires_at, created_at) VALUES (?, ?, ?, ?, ?)
                  """) else { return }
        defer { sqlite3_finalize(statement) }
        let created = now().timeIntervalSince1970
        bind(key.digest, at: 1, in: statement)
        if let thread = key.threadKey { bind(thread, at: 2, in: statement) } else { sqlite3_bind_null(statement, 2) }
        _ = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 3, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
        if let ttl { sqlite3_bind_double(statement, 4, created + Self.seconds(ttl)) } else { sqlite3_bind_null(statement, 4) }
        sqlite3_bind_double(statement, 5, created)
        guard sqlite3_step(statement) == SQLITE_DONE else { return }
        trim()
    }

    func invalidate(threadKey: String) async {
        guard let statement = prepare("DELETE FROM results WHERE thread_key = ?") else { return }
        defer { sqlite3_finalize(statement) }
        bind(threadKey, at: 1, in: statement)
        sqlite3_step(statement)
    }

    func removeAll() async {
        sqlite3_exec(db, "DELETE FROM results;", nil, nil, nil)
    }

    var count: Int {
        guard let statement = prepare("SELECT COUNT(*) FROM results") else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    var secureDelete: Int {
        guard let statement = prepare("PRAGMA secure_delete") else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    private func trim() {
        guard count > capacity, let statement = prepare("""
            DELETE FROM results WHERE digest IN (SELECT digest FROM results ORDER BY created_at ASC LIMIT ?)
            """) else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(count - capacity))
        sqlite3_step(statement)
    }

    private func delete(digest: String) {
        guard let statement = prepare("DELETE FROM results WHERE digest = ?") else { return }
        defer { sqlite3_finalize(statement) }
        bind(digest, at: 1, in: statement)
        sqlite3_step(statement)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        return statement
    }

    private func bind(_ text: String, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

private var SQLITE_TRANSIENT: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
