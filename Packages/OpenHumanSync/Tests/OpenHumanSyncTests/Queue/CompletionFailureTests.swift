import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import SQLite3
import Testing
@testable import OpenHumanSync

/// Makes the store refuse to mark any operation as succeeded, from a second connection to the same file.
private struct RefuseCompletion {
    let path: String

    init(_ h: WriteHarness) throws {
        path = StoreLocation(directory: try #require(h.temporary).url).databaseURL.path
        try run("""
            CREATE TRIGGER test_refuse_completion BEFORE UPDATE OF status ON pending_operations
            WHEN NEW.status = 'succeeded' BEGIN SELECT RAISE(ABORT, 'test: completion refused'); END
            """)
    }

    func lift() throws { try run("DROP TRIGGER test_refuse_completion") }

    private func run(_ sql: String) throws {
        var handle: OpaquePointer?
        defer { sqlite3_close_v2(handle) }
        #expect(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        sqlite3_busy_timeout(handle, 5_000)
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK, "\(String(cString: sqlite3_errmsg(handle)))")
    }
}

@Suite struct CompletionFailureTests {
    @Test func aLabelChangeWhoseCompletionFailsIsRetriedAndOnlyThenReported() async throws {
        let h = try await WriteHarness(threads: 2, onDisk: true)
        let applied = Counter()
        let drainer = h.drainer(api: h.gmail, applied: applied)
        let id = try h.store.apply(.archive([try h.ref(h.threads[0])]), origin: .app).operationIDs[0]
        let refusal = try RefuseCompletion(h)

        let first = await drainer.drainOnce()
        #expect(first.succeeded == 0 && first.retried == 1, "\(first)")
        let waiting = try #require(try h.store.operation(id))
        #expect(waiting.status == .pending && waiting.lastErrorCode == "complete_failed" && waiting.attempts == 1)
        #expect(applied.current == 0, "nothing is reported applied before the store records it")
        #expect(await h.gmail.callCount(.batchModify) == 1)

        try refusal.lift()
        h.instant.advance(by: .seconds(OperationDrainer.backoff(attempts: 0).timeInterval + 1))
        let second = await drainer.drainOnce()
        #expect(second.succeeded == 1, "\(second)")
        #expect(try h.store.operation(id)?.status == .succeeded)
        #expect(applied.current == 1)
        #expect(!(await h.serverLabels(ofThread: h.threads[0])).contains("INBOX"))
        #expect(!(try h.inbox().contains(h.threads[0])))
    }

    @Test func aSendWhoseCompletionFailsIsNotSentAgainAndIsAnnouncedOnce() async throws {
        let h = try await WriteHarness(clock: sendClock(), onDisk: true)
        let events = EventLog()
        let drainer = h.drainer(api: h.gmail, events: events)
        let id = try h.newDraft()
        let receipt = try h.store.send(id, undoWindow: .seconds(10), origin: .app)
        await drainer.drainOnce()
        #expect(await h.gmail.callCount(.createDraft) == 1)
        let refusal = try RefuseCompletion(h)

        h.advancePast(receipt)
        let first = await drainer.drainOnce()
        #expect(first.succeeded == 0 && first.retried == 1, "\(first)")
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        #expect(events.sent.isEmpty, "no sent event before the store records the send")
        #expect(try h.draft(id).state == .sending)
        let waiting = try #require(try h.store.operations(account: h.account, statuses: [.pending], limit: 10)
            .first { $0.kind == .sendDraft })
        #expect(waiting.lastErrorCode == "complete_failed" && waiting.attempts == 1)

        try refusal.lift()
        h.instant.advance(by: .seconds(OperationDrainer.backoff(attempts: 0).timeInterval + 1))
        let second = await drainer.drainOnce()
        #expect(second.succeeded == 1, "\(second)")
        #expect(await h.gmail.callCount(.sendDraft) == 1, "the retry finds the sent copy and never sends again")
        #expect(try await h.sentOnGmail().count == 1)
        #expect(try h.draft(id).state == .sent)
        #expect(events.sent.map(\.0) == [id])
    }
}
