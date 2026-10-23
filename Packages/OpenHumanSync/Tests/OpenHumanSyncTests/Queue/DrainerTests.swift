import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct DrainerTests {
    @Test func markDoneDrainsAsOneBatchModifyAndStaysDoneAfterSync() async throws {
        let h = try await WriteHarness(threads: 3)
        let (a, b) = (h.threads[0], h.threads[1])
        let first = try h.store.apply(.archive([try h.ref(a)]), origin: .app)
        let second = try h.store.apply(.archive([try h.ref(b)]), origin: .app)
        #expect(try h.inbox() == [h.threads[2]])
        #expect(await h.gmail.callCount(.batchModify) == 0)

        let report = await h.drainer(api: try h.client).drainOnce()
        #expect(report.claimed == 2 && report.succeeded == 2 && report.gmailCalls == 1)
        #expect(await h.gmail.callCount(.batchModify) == 1)
        #expect(h.wire.requests.filter { $0.method == "POST" && !$0.url.path().hasPrefix("/batch/") }.map { $0.url.path() } == ["/gmail/v1/users/me/messages/batchModify"])
        #expect(!(await h.serverLabels(ofThread: a)).contains("INBOX"))
        #expect(!(await h.serverLabels(ofThread: b)).contains("INBOX"))
        #expect(try h.store.operation(first.operationIDs[0])?.status == .succeeded)
        #expect(try h.store.operation(second.operationIDs[0])?.status == .succeeded)

        try await h.syncer.sync(reason: "poll")
        #expect(try h.inbox() == [h.threads[2]])
        #expect(try h.inbox() == (try await h.serverInbox()))
    }

    @Test func thirtyArchivesCoalesceIntoOneCall() async throws {
        let h = try await WriteHarness(threads: 30)
        for thread in h.threads { _ = try h.store.apply(.archive([try h.ref(thread)]), origin: .app) }
        let report = await h.drainer(api: h.gmail).drainOnce()
        #expect(report.claimed == 30 && report.succeeded == 30)
        #expect(await h.gmail.callCount(.batchModify) == 1)
        #expect(try await h.serverInbox().isEmpty)
    }

    @Test func undoBeforeTheDrainNeverReachesGmail() async throws {
        let h = try await WriteHarness()
        let receipt = try h.store.apply(.archive([try h.ref(h.threads[0])]), origin: .app)
        _ = try h.store.undo(receipt, origin: .app)
        let report = await h.drainer(api: h.gmail).drainOnce()
        #expect(report.claimed == 0)
        #expect(await h.gmail.callCount(.batchModify) == 0)
        #expect(Set(try h.inbox()) == Set(h.threads))
    }

    @Test func undoAfterTheDrainPutsTheThreadBackOnGmail() async throws {
        let h = try await WriteHarness()
        let thread = h.threads[0]
        let drainer = h.drainer(api: h.gmail)
        let receipt = try h.store.apply(.archive([try h.ref(thread)]), origin: .app)
        await drainer.drainOnce()
        #expect(!(await h.serverLabels(ofThread: thread)).contains("INBOX"))

        let undo = try #require(try h.store.undo(receipt, origin: .app))
        #expect(undo.operationIDs.count == 1)
        #expect(try h.inbox().contains(thread))
        await drainer.drainOnce()
        #expect(await h.gmail.callCount(.batchModify) == 2)
        #expect((await h.serverLabels(ofThread: thread)).contains("INBOX"))
        try await h.syncer.sync(reason: "poll")
        #expect(try h.inbox() == (try await h.serverInbox()))
    }

    @Test func undoWhileTheCallIsInFlightQueuesTheInverseAfterIt() async throws {
        let clock = TestClock(now: testNow)
        let h = try await WriteHarness(clock: clock)
        let thread = h.threads[0]
        await h.gmail.latency(.batchModify, .seconds(1))
        let drainer = h.drainer(api: h.gmail)
        let receipt = try h.store.apply(.archive([try h.ref(thread)]), origin: .app)
        let pass = Task { await drainer.drainOnce() }
        try await eventually("archive call in flight") { clock.sleeperCount == 1 }
        #expect(try h.store.operation(receipt.operationIDs[0])?.status == .inFlight)

        let undo = try #require(try h.store.undo(receipt, origin: .app))
        #expect(undo.operationIDs.count == 1)
        #expect(try h.inbox().contains(thread))
        clock.advance(by: .seconds(1))
        try await eventually("inverse call in flight") {
            let calls = await h.gmail.callCount(.batchModify)
            return clock.sleeperCount == 1 && calls == 2
        }
        #expect(try h.inbox().contains(thread))
        clock.advance(by: .seconds(1))
        let report = await pass.value
        #expect(report.succeeded == 2 && report.gmailCalls == 2)
        #expect(try h.store.operation(undo.operationIDs[0])?.status == .succeeded)
        #expect((await h.serverLabels(ofThread: thread)).contains("INBOX"))
        #expect(try h.inbox().contains(thread))
    }

    @Test func undoOfARetryingTrashMustWin() async throws {
        let h = try await WriteHarness()
        let t = h.threads[0]
        await h.gmail.failNext(.trashMessage, with: .server(status: 503, message: nil))
        let receipt = try h.store.apply(.trash([try h.ref(t)]), origin: .app)
        let drainer = h.drainer(api: h.gmail)
        #expect(await drainer.drainOnce().retried == 1)
        let undo = try #require(try h.store.undo(receipt, origin: .app))
        #expect(undo.operationIDs.count == 2)
        #expect(try h.inbox().contains(t))
        #expect(await drainer.drainOnce().claimed == 0)
        #expect(try h.inbox().contains(t))
        h.instant.advance(by: .seconds(5))
        #expect(await drainer.drainOnce().succeeded == 3)
        let writes = await h.gmail.callLog.filter { [.trashMessage, .untrashMessage, .batchModify].contains($0) }
        #expect(writes == [.trashMessage, .trashMessage, .untrashMessage, .batchModify])
        try await h.syncer.sync(reason: "poll")
        #expect(!(await h.serverLabels(ofThread: t)).contains("TRASH"))
        #expect(try h.inbox().contains(t))
        #expect(try h.inbox() == (try await h.serverInbox()))
    }

    @Test func moveToInboxAfterAnOfflineArchiveEndsInTheInbox() async throws {
        let h = try await WriteHarness()
        let t = h.threads[0]
        await h.gmail.failNext(.batchModify, with: .transport(.notConnected))
        _ = try h.store.apply(.archive([try h.ref(t)]), origin: .app)
        let drainer = h.drainer(api: h.gmail)
        #expect(await drainer.drainOnce().released == 1)
        _ = try h.store.apply(.moveToInbox([try h.ref(t)]), origin: .app)
        #expect(try h.inbox().contains(t))
        #expect(await drainer.drainOnce().claimed == 0)
        h.instant.advance(by: OperationDrainer.offlineRetry)
        #expect(await drainer.drainOnce().succeeded == 2)
        #expect((await h.serverLabels(ofThread: t)).contains("INBOX"))
        try await h.syncer.sync(reason: "poll")
        #expect(try h.inbox().contains(t))
        #expect(try h.inbox() == (try await h.serverInbox()))
    }

    @Test func offlineReleasesWithoutAnAttemptAndStaleSyncDoesNotFlicker() async throws {
        let h = try await WriteHarness()
        let thread = h.threads[0]
        let message = try #require(await h.gmail.messageIDs(inThread: thread).first)
        await h.gmail.failNext(.batchModify, with: .transport(.notConnected))
        let id = try h.store.apply(.archive([try h.ref(thread)]), origin: .app).operationIDs[0]
        let drainer = h.drainer(api: h.gmail)
        let report = await drainer.drainOnce()
        #expect(report.released == 1 && report.succeeded == 0)
        let op = try #require(try h.store.operation(id))
        #expect(op.status == .pending && op.attempts == 0)
        #expect(abs(op.nextRetryAt.timeIntervalSince(h.clock.now) - 30) < 0.01)
        #expect(!(try h.inbox().contains(thread)))

        await h.gmail.modifyLabels(messageID: message, add: ["STARRED"])
        try await h.syncer.sync(reason: "poll")
        #expect(!(try h.inbox().contains(thread)))
        #expect(try h.store.thread(try h.ref(thread))?.isStarred == true)

        #expect(await drainer.drainOnce().claimed == 0)
        (h.clock as! InstantClock).advance(by: .seconds(30))
        #expect(await drainer.drainOnce().succeeded == 1)
        #expect(!(await h.serverLabels(ofThread: thread)).contains("INBOX"))
        try await h.syncer.sync(reason: "poll")
        #expect(try h.inbox() == (try await h.serverInbox()))
    }

    @Test func serverErrorRetriesWithBackoffThenSucceeds() async throws {
        let h = try await WriteHarness()
        await h.gmail.failNext(.batchModify, with: .server(status: 503, message: nil))
        let id = try h.store.apply(.archive([try h.ref(h.threads[0])]), origin: .app).operationIDs[0]
        let drainer = h.drainer(api: h.gmail)
        #expect(await drainer.drainOnce().retried == 1)
        let op = try #require(try h.store.operation(id))
        #expect(op.status == .pending && op.attempts == 1 && op.lastErrorCode == "server")
        #expect(abs(op.nextRetryAt.timeIntervalSince(h.clock.now) - 5) < 0.01)
        #expect(!(try h.inbox().contains(h.threads[0])))
        (h.clock as! InstantClock).advance(by: .seconds(5))
        #expect(await drainer.drainOnce().succeeded == 1)
        #expect(try h.store.operation(id)?.status == .succeeded)
    }

    @Test func tenFailedAttemptsBecomePermanent() async throws {
        let h = try await WriteHarness()
        await h.gmail.failNext(.batchModify, with: .transport(.timedOut), count: 10)
        let id = try h.store.apply(.archive([try h.ref(h.threads[0])]), origin: .app).operationIDs[0]
        let events = EventLog()
        let drainer = h.drainer(api: h.gmail, events: events)
        var waits: [TimeInterval] = []
        for _ in 0..<10 {
            await drainer.drainOnce()
            guard let op = try h.store.operation(id), op.status == .pending else { break }
            waits.append(op.nextRetryAt.timeIntervalSince(h.clock.now).rounded())
            (h.clock as! InstantClock).advance(by: .seconds(600))
        }
        #expect(waits == [5, 10, 20, 40, 80, 160, 320, 600, 600])
        #expect(try h.store.operation(id)?.status == .failed)
        #expect(events.failedOperations.map(\.id) == [id])
        #expect(try h.inbox().contains(h.threads[0]))
    }

    @Test func permanentFailureRevertsAndReportsTheOperation() async throws {
        let h = try await WriteHarness()
        await h.gmail.failNext(.batchModify, with: .badRequest(reason: "invalidArgument", message: "Invalid label"))
        let id = try h.store.apply(.archive([try h.ref(h.threads[0])]), origin: .app).operationIDs[0]
        #expect(!(try h.inbox().contains(h.threads[0])))
        let events = EventLog()
        let report = await h.drainer(api: h.gmail, events: events).drainOnce()
        #expect(report.failed == 1)
        let op = try #require(try h.store.operation(id))
        #expect(op.status == .failed && op.lastErrorCode == "bad_request")
        #expect(events.failedOperations.map(\.id) == [id])
        #expect(try h.inbox().contains(h.threads[0]))
        #expect(try h.store.thread(try h.ref(h.threads[0]))?.hasPendingChanges == false)
    }

    @Test func rateLimitHonorsRetryAfter() async throws {
        let h = try await WriteHarness()
        await h.gmail.failNext(.batchModify, with: .rateLimited(retryAfter: .seconds(120)))
        let ids = try h.threads.prefix(2).map { try h.store.apply(.archive([try h.ref($0)]), origin: .app).operationIDs[0] }
        let report = await h.drainer(api: h.gmail).drainOnce()
        #expect(report.released == 2 && report.gmailCalls == 1)
        for id in ids {
            let op = try #require(try h.store.operation(id))
            #expect(op.attempts == 0 && abs(op.nextRetryAt.timeIntervalSince(h.clock.now) - 120) < 0.01)
        }
    }

    @Test func reauthPausesTheDrainerAndFlagsTheAccount() async throws {
        let h = try await WriteHarness()
        await h.gmail.failNext(.batchModify, with: .reauthRequired)
        let id = try h.store.apply(.archive([try h.ref(h.threads[0])]), origin: .app).operationIDs[0]
        let events = EventLog()
        let drainer = h.drainer(api: h.gmail, events: events)
        #expect(await drainer.drainOnce().released == 1)
        #expect(await drainer.state == .pausedNeedsReauth)
        #expect(try h.store.accounts().first?.status == .needsReauth)
        #expect(try h.store.operation(id)?.status == .pending)
        #expect(events.all.contains { if case .accountNeedsReauth(h.account) = $0 { return true } else { return false } })
    }

    @Test func missingIDsAreBisectedAwayAndTheRestApplied() async throws {
        let h = try await WriteHarness(threads: 6)
        await h.gmail.setBatchModifyRejectsMissingIDs(true)
        let refs = try h.threads.map(h.ref)
        let id = try h.store.apply(.archive(refs), origin: .app).operationIDs[0]
        let gone = try #require(await h.gmail.messageIDs(inThread: h.threads[4]).first)
        await h.gmail.deleteMessagePermanently(gone)
        let report = await h.drainer(api: h.gmail).drainOnce()
        #expect(report.succeeded == 1 && report.gmailCalls > 1)
        #expect(try h.store.operation(id)?.status == .succeeded)
        #expect(try await h.serverInbox().isEmpty)
    }

    @Test func aMissingIDInALargeBatchDropsOnlyThatID() async throws {
        let h = try await WriteHarness(threads: 130)
        #expect(await h.syncer.runBackfill() == .complete, "all 130 threads are in the store")
        await h.gmail.setBatchModifyRejectsMissingIDs(true)
        let refs = try h.threads.map(h.ref)
        let id = try h.store.apply(.archive(refs), origin: .app).operationIDs[0]
        let gone = try #require(await h.gmail.messageIDs(inThread: h.threads[77]).first)
        await h.gmail.deleteMessagePermanently(gone)
        let report = await h.drainer(api: h.gmail).drainOnce()
        #expect(report.succeeded == 1)
        #expect(report.gmailCalls <= 1 + 2 * 8, "calls=\(report.gmailCalls)")
        #expect(try h.store.operation(id)?.status == .succeeded)
        #expect(try await h.serverInbox().isEmpty, "every message that still exists is archived")
    }

    @Test func aGuardRefusalFailsPermanentlyAndIsNeverRetried() async throws {
        let h = try await WriteHarness()
        let id = try h.store.apply(.archive([try h.ref(h.threads[0])]), origin: .app).operationIDs[0]
        await h.gmail.failNext(.batchModify, with: .transport(.refusedByGuard("POST /gmail/v1/users/me/messages/batchModify")))
        let events = EventLog()
        let drainer = h.drainer(api: h.gmail, events: events)
        let report = await drainer.drainOnce()
        #expect(report.failed == 1)
        let op = try #require(try h.store.operation(id))
        #expect(op.status == .failed && op.lastErrorCode == "refused_by_guard")
        #expect(op.lastErrorMessage == "POST /gmail/v1/users/me/messages/batchModify")
        #expect(await h.serverLabels(ofThread: h.threads[0]).contains("INBOX"))
        #expect(try h.inbox().contains(h.threads[0]))
        #expect(events.failedOperations.count == 1)
        #expect(await drainer.drainOnce().claimed == 0)
        #expect(await h.gmail.callCount(.batchModify) == 1)
    }

    @Test func groupsJoinOnlyConsecutiveEqualKeys() {
        func op(_ id: Int64, _ key: String) -> OperationItem {
            OperationItem(id: OperationID(rawValue: id), accountID: AccountID(1), kind: .modifyLabels,
                          payload: .modifyLabels(ids: [], add: [], remove: [], addNames: []), status: .inFlight,
                          attempts: 0, notBefore: .distantPast, nextRetryAt: .distantPast, coalesceKey: key,
                          origin: .app, createdAt: .distantPast, updatedAt: .distantPast)
        }
        let groups = OperationDrainer.groups([op(1, "a"), op(2, "a"), op(3, "b"), op(4, "a")])
        #expect(groups.map { $0.map(\.id.rawValue) } == [[1, 2], [3], [4]])
    }
}
