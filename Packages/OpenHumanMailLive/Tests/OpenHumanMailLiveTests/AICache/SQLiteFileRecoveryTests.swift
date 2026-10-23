import Foundation
import OpenHumanAI
import OpenHumanCore
import SQLite3
import Testing
@testable import OpenHumanMailLive

@Suite struct SQLiteFileRecoveryTests {
    struct FakeOpenError: Error { let status: Int32 }

    static let now = Date(timeIntervalSince1970: 1_797_200_000)

    static func status(_ error: any Error) -> Int32? { (error as? FakeOpenError)?.status }

    static func fileWithContents(_ dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rules.sqlite")
        try Data("kept".utf8).write(to: url)
        return url
    }

    static func names(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    @Test(arguments: [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_IOERR, SQLITE_IOERR | (1 << 8), SQLITE_PERM, SQLITE_CANTOPEN,
                      SQLITE_FULL, SQLITE_READONLY, SQLITE_ERROR])
    func anOpenErrorThatIsNotDamageLeavesTheFileInPlace(_ code: Int32) throws {
        let scratch = TemporaryDirectory("oh-sqlite-recovery", isDirectory: true)
        let dir = scratch.url
        defer { withExtendedLifetime(scratch) {} }
        let url = try Self.fileWithContents(dir)
        var attempts = 0
        #expect(throws: FakeOpenError.self) {
            try SQLiteFileRecovery.open(url, now: Self.now, status: Self.status) { _ -> Int in
                attempts += 1
                throw FakeOpenError(status: code)
            }
        }
        #expect(attempts == 1)
        #expect(try Self.names(dir) == ["rules.sqlite"])
        #expect(try Data(contentsOf: url) == Data("kept".utf8))
    }

    @Test func anErrorWithoutAnSQLiteStatusLeavesTheFileInPlace() throws {
        let scratch = TemporaryDirectory("oh-sqlite-recovery", isDirectory: true)
        let dir = scratch.url
        defer { withExtendedLifetime(scratch) {} }
        let url = try Self.fileWithContents(dir)
        #expect(throws: CocoaError.self) {
            try SQLiteFileRecovery.open(url, now: Self.now, status: Self.status) { _ -> Int in
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        #expect(try Self.names(dir) == ["rules.sqlite"])
    }

    @Test(arguments: [SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_CORRUPT | (1 << 8)])
    func aDamagedFileIsSetAsideAndOpenedAgain(_ code: Int32) throws {
        let scratch = TemporaryDirectory("oh-sqlite-recovery", isDirectory: true)
        let dir = scratch.url
        defer { withExtendedLifetime(scratch) {} }
        let url = try Self.fileWithContents(dir)
        var attempts = 0
        let opened = try SQLiteFileRecovery.open(url, now: Self.now, status: Self.status) { _ -> Int in
            attempts += 1
            if attempts == 1 { throw FakeOpenError(status: code) }
            return attempts
        }
        #expect(opened == 2)
        #expect(try Self.names(dir) == ["rules.damaged-1797200000.sqlite"])
        let aside = dir.appendingPathComponent("rules.damaged-1797200000.sqlite")
        #expect(try Data(contentsOf: aside) == Data("kept".utf8))
    }

    @Test func aHealthyFileChecksOutAndGarbageReportsNotADatabase() throws {
        let scratch = TemporaryDirectory("oh-sqlite-recovery", isDirectory: true)
        let dir = scratch.url
        defer { withExtendedLifetime(scratch) {} }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let healthy = dir.appendingPathComponent("healthy.sqlite")
        let garbage = dir.appendingPathComponent("garbage.sqlite")
        try Data("not a database".utf8).write(to: garbage)
        for (url, expected) in [(healthy, SQLITE_OK), (garbage, SQLITE_NOTADB)] {
            var handle: OpaquePointer?
            #expect(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
            defer { sqlite3_close_v2(handle) }
            #expect(SQLiteFileRecovery.quickCheck(try #require(handle)) == expected)
        }
    }

    @Test func aRulesFileLockedByAnotherConnectionIsNotSetAside() async throws {
        let scratch = TemporaryDirectory("oh-sqlite-recovery", isDirectory: true)
        let dir = scratch.url
        defer { withExtendedLifetime(scratch) {} }
        let url = dir.appendingPathComponent(SQLiteRulesStore.fileName)
        let shipped = ClassificationConfig.shipped
        do {
            let store = try SQLiteRulesStore(url: url)
            _ = try await store.append(origin: "default", bodyJSON: try shipped.json(), digest: shipped.digest, note: nil,
                                       createdAt: Self.now, historyLimit: 3)
        }
        var other: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &other, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(other, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        #expect(throws: (any Error).self) { try SQLiteRulesStore(url: url) }
        sqlite3_exec(other, "ROLLBACK", nil, nil, nil)
        sqlite3_close_v2(other)
        #expect(try Self.names(dir) == [SQLiteRulesStore.fileName])
        let reopened = try SQLiteRulesStore(url: url)
        #expect(try await reopened.head()?.version == 1)
    }
}
