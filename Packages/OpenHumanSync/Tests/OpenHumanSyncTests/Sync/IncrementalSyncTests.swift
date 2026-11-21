import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Synchronization
import Testing
@testable import OpenHumanSync

@Suite struct IncrementalSyncTests {
    @Test func deltasAddArchiveReadDeleteAndUnknownLabels() async throws {
        let h = try SyncHarness()
        let threads = await h.gmail.seedInbox(count: 6)
        let (reply, _) = await h.gmail.deliver(subject: "Re", threadID: threads[5])
        try await h.syncer.sync(reason: "launch")
        #expect(try h.inbox().count == 6)

        await h.gmail.resetAccounting()
        let (newMessage, newThread) = await h.gmail.deliver(subject: "New", body: "Fresh body", html: "<p>Fresh body</p>")
        await h.gmail.simulateWebArchive(threadID: threads[0])
        await h.gmail.simulateWebRead(threadID: threads[1])
        let gone = await h.gmail.messageIDs(inThread: threads[2])[0]
        await h.gmail.deleteMessagePermanently(gone)
        await h.gmail.deleteMessagePermanently(reply)
        let label = await h.gmail.addUserLabel("Projects")
        let tagged = await h.gmail.messageIDs(inThread: threads[3])[0]
        await h.gmail.modifyLabels(messageID: tagged, add: [label])
        let (flash, _) = await h.gmail.deliver(subject: "Gone again")
        await h.gmail.deleteMessagePermanently(flash)

        let report = try await h.syncer.sync(reason: "poll")

        #expect(try h.inbox() == (try await h.serverInbox()))
        #expect(try h.inbox().first == newThread && !(try h.inbox()).contains(threads[0]))
        #expect(try h.thread(threads[1])?.thread.unreadCount == 0)
        #expect(try h.thread(threads[2]) == nil && (try h.message(gone)) == nil)
        #expect(try h.thread(threads[5])?.messages.map(\.gmailMessageID.rawValue) == [threads[5]])
        #expect(try h.thread(threads[3])?.labels.map(\.name) == ["Projects"])
        let fresh = try #require(try h.message(newMessage))
        #expect(fresh.bodyState == .stored)
        #expect(try h.store.body(fresh.id)?.html == "<p>Fresh body</p>")
        #expect(try h.message(flash) == nil)
        let historyCalls = await h.gmail.callCount(.listHistory), getCalls = await h.gmail.callCount(.getMessage)
        #expect(historyCalls == 1 && getCalls == 1)
        #expect(await h.gmail.callCount(.listLabels) == 1)
        #expect(try h.status().historyID == (await h.gmail.currentHistoryID))
        #expect(report.kind == "incremental" && report.added == 1 && report.deleted == 2)
    }

    @Test func aBigHistoryPageIsFetchedAndDeletedInChunks() async throws {
        let h = try SyncHarness(settings: SyncSettings(fetchChunk: 20), recording: true)
        let recorder = try #require(h.recorder)
        let seeded = await h.gmail.seedInbox(count: 45)
        try await h.syncer.sync(reason: "launch")
        recorder.reset()
        var fresh: [String] = []
        for index in 0..<45 { fresh.append(await h.gmail.deliver(subject: "Burst \(index)").0) }
        for thread in seeded { await h.gmail.deleteMessagePermanently(await h.gmail.messageIDs(inThread: thread)[0]) }
        let report = try await h.syncer.sync(reason: "poll")
        let sizes = recorder.calls(.getMessage).map(\.items)
        #expect(sizes == [20, 20, 5])
        #expect(report.added == 45 && report.deleted == 45)
        #expect(try h.inbox() == (try await h.serverInbox()))
        #expect(try fresh.allSatisfy { try h.message($0)?.bodyState == .stored })
        #expect(try h.status().historyID == (await h.gmail.currentHistoryID))
    }

    @Test func noChangesIsOneCheapCall() async throws {
        let h = try SyncHarness()
        await h.gmail.seedInbox(count: 3)
        try await h.syncer.sync(reason: "launch")
        await h.gmail.resetAccounting()
        let report = try await h.syncer.sync(reason: "poll")
        let log = await h.gmail.callLog, units = await h.gmail.unitsUsed
        #expect(log == [.listHistory] && units == 2)
        #expect(report.added == 0 && report.changed == 0 && report.deleted == 0 && report.units == 2)
    }

    @Test func labelDeltaForAnUnknownMessageFetchesIt() async throws {
        let h = try SyncHarness()
        let (old, oldThread) = await h.gmail.deliver(subject: "Archived long ago", labels: ["CATEGORY_UPDATES"])
        await h.gmail.seedInbox(count: 2)
        try await h.syncer.sync(reason: "launch")
        #expect(try h.message(old) == nil)
        await h.gmail.modifyLabels(messageID: old, add: ["INBOX"])
        try await h.syncer.sync(reason: "poll")
        #expect(try h.inbox().contains(oldThread))
        #expect(try h.message(old)?.bodyState == .stored)
    }

    @Test func labelChangesToAnAddedMessageThatIsAlreadyStoredAreApplied() async throws {
        let h = try SyncHarness()
        await h.gmail.seedInbox(count: 2)
        try await h.syncer.sync(reason: "launch")
        let (message, thread) = await h.gmail.deliver(subject: "Stored before the poll")
        let fetched = try await h.gmail.getMessage(id: message, format: .full, metadataHeaders: [], priority: .interactive)
        _ = try h.store.upsertMessages([try GmailMapper.messageUpsert(fetched, includeBody: true)], account: h.account,
                                       generation: try h.status().generation)
        #expect(try h.thread(thread)?.thread.unreadCount == 1)
        #expect(try h.inbox().contains(thread))

        await h.gmail.simulateWebRead(threadID: thread)
        await h.gmail.simulateWebArchive(threadID: thread)
        try await h.syncer.sync(reason: "poll")

        #expect(try h.thread(thread)?.thread.unreadCount == 0)
        #expect(!(try h.inbox().contains(thread)))
        #expect(try h.inbox() == (try await h.serverInbox()))
        #expect(try h.status().historyID == (await h.gmail.currentHistoryID))
    }

    @Test func aThreadFirstSeenThroughHistoryIsStoredWholeSoMarkDoneCoversIt() async throws {
        let (h, thread) = try await threadFirstSeenThroughHistory()
        #expect(try h.thread(thread)?.messages.count == 3)
        let ref = try #require(try h.store.thread(account: h.account, gmailThreadID: GmailThreadID(thread)))
        _ = try h.store.apply(.archive([ref]), origin: .app)
        _ = await OperationDrainer(account: h.account, store: h.store, api: h.gmail, clock: h.clock).drainOnce()
        for id in await h.gmail.messageIDs(inThread: thread) {
            #expect(await h.gmail.labelIDs(ofMessage: id)?.contains("INBOX") == false)
        }
        #expect(await h.syncer.runBackfill() == .complete)
        #expect(!(try h.inbox().contains(thread)))
    }

    @Test func aSnoozeOfAThreadFirstSeenThroughHistoryIsNotWokenByTheBackfill() async throws {
        let (h, thread) = try await threadFirstSeenThroughHistory()
        let ref = try #require(try h.store.thread(account: h.account, gmailThreadID: GmailThreadID(thread)))
        _ = try h.store.apply(.snooze([ref], until: testNow.addingTimeInterval(86_400)), origin: .app)
        let drainer = OperationDrainer(account: h.account, store: h.store, api: h.gmail, clock: h.clock)
        for _ in 0..<5 where !(try h.store.operations(account: h.account, statuses: [.pending], limit: 10)).isEmpty {
            _ = await drainer.drainOnce()
        }
        #expect(await h.syncer.runBackfill() == .complete)
        #expect(try h.store.dueItems(account: h.account, now: testNow).snoozesWokenByMail.isEmpty)
        #expect(!(try h.inbox().contains(thread)))
    }

    private func threadFirstSeenThroughHistory() async throws -> (SyncHarness, String) {
        let h = try SyncHarness()
        let old = testNow.addingTimeInterval(-400 * 86_400)
        let thread = await h.gmail.deliver(subject: "Old", date: old).threadID
        await h.gmail.deliver(subject: "Re: Old", threadID: thread, date: old.addingTimeInterval(3_600))
        await h.gmail.seedInbox(count: 60)
        try await h.syncer.sync(reason: "launch")
        #expect(try h.thread(thread) == nil)
        await h.gmail.deliver(subject: "Re: Old", threadID: thread)
        try await h.syncer.sync(reason: "poll")
        return (h, thread)
    }

    @Test func multiPageHistoryAdvancesOnlyAtTheEndAndReplaysIdempotently() async throws {
        let h = try SyncHarness(settings: SyncSettings(historyPageSize: 2))
        await h.gmail.seedInbox(count: 2)
        try await h.syncer.sync(reason: "launch")
        let start = try h.status().historyID
        var delivered: [String] = []
        for n in 0..<5 { delivered.append(await h.gmail.deliver(subject: "Burst \(n)").messageID) }
        await h.gmail.failNext(.getMessage, with: .server(status: 500, message: nil))
        await #expect(throws: GmailError.self) { try await h.syncer.sync(reason: "poll") }
        var status = try h.status()
        #expect(status.historyID == start && status.consecutiveFailures == 1)
        try await h.syncer.sync(reason: "poll")
        status = try h.status()
        #expect(status.historyID == (await h.gmail.currentHistoryID) && status.consecutiveFailures == 0)
        for id in delivered { #expect(try h.message(id) != nil) }
        #expect(try h.inbox().count == 7)
    }

    @Test func twentyConcurrentSyncRequestsCauseAtMostTwoRuns() async throws {
        let clock = TestClock(now: testNow)
        let h = try SyncHarness(clock: clock)
        await h.gmail.seedInbox(count: 2)
        try await h.syncer.sync(reason: "launch")
        await h.gmail.latency(.listHistory, .seconds(1))
        let runsBefore = await h.syncer.runCount
        let finished = Counter()
        let tasks = (0..<20).map { n in
            Task {
                defer { finished.increment() }
                return try await h.syncer.sync(reason: "request \(n)")
            }
        }
        try await eventually("first run blocked in history.list") { clock.sleeperCount == 1 }
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<120_000 where finished.current < 20 {
            if clock.sleeperCount > 0 { clock.advance(by: .seconds(1)) }
            try await Task.sleep(for: .milliseconds(1))
        }
        for t in tasks { _ = try await t.value }
        let runs = await h.syncer.runCount - runsBefore
        #expect(runs == 2)
    }
}

final class Counter: Sendable {
    private let value = Mutex(0)
    @discardableResult func increment() -> Int { value.withLock { $0 += 1; return $0 } }
    var current: Int { value.withLock { $0 } }
}
