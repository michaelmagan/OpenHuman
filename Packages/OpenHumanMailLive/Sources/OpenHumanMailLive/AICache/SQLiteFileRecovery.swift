import Foundation
import SQLite3

/// Opening rules for the small SQLite files next to the mail store. A file is set aside and started again only when
/// SQLite reports the file itself as damaged; a busy lock, a permission or disk error leaves the file in place and
/// the open throws, so the caller falls back for this session without losing what the file holds.
enum SQLiteFileRecovery {
    static func isDamaged(_ status: Int32) -> Bool {
        let primary = status & 0xff
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    /// Runs `PRAGMA quick_check` and reads its answer. Returns `SQLITE_OK` when the file checks out, `SQLITE_CORRUPT`
    /// when the check reports a problem, and the SQLite error otherwise (for example `SQLITE_BUSY`).
    static func quickCheck(_ handle: OpaquePointer) -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return sqlite3_errcode(handle)
        }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else { return status == SQLITE_DONE ? SQLITE_OK : status }
        let answer = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        return answer == "ok" ? SQLITE_OK : SQLITE_CORRUPT
    }

    static func asideURL(for url: URL, at date: Date) -> URL {
        url.deletingPathExtension().appendingPathExtension("damaged-\(Int(date.timeIntervalSince1970)).sqlite")
    }

    /// Opens `url`; when the open fails with a damage status, moves the file aside and opens a fresh one.
    static func open<Handle>(_ url: URL, now: Date = Date(), status: (any Error) -> Int32?,
                             _ open: (URL) throws -> Handle) throws -> Handle {
        do {
            return try open(url)
        } catch {
            guard let code = status(error), isDamaged(code) else { throw error }
            try? FileManager.default.moveItem(at: url, to: asideURL(for: url, at: now))
            return try open(url)
        }
    }
}
