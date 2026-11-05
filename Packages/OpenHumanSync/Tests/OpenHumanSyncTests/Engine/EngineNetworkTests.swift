import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct EngineNetworkTests {
    @Test func onDemandViewsThreadsDraftsBodiesAndRemoteSearch() async throws {
        let h = try await EngineHarness()
        let label = await h.gmail.addUserLabel("Projects")
        let filed = await h.gmail.deliver(subject: "Filed away", body: "Synthetic filed body.", labels: [label])
        let other = await h.gmail.deliver(subject: "Elsewhere", body: "Synthetic body.", labels: [])
        let remote = try await h.gmail.createDraft(rawRFC822: rawDraft(subject: "Synthetic draft"), threadID: nil)
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        try await engine.ensureViewLoaded(.label(h.account, GmailLabelID(label)))
        #expect(try h.store.thread(account: h.account, gmailThreadID: GmailThreadID(filed.threadID)) != nil)
        let ref = try #require(try await engine.fetchThread(account: h.account, gmailThreadID: GmailThreadID(other.threadID)))
        #expect(ref.gmailThreadID.rawValue == other.threadID)
        #expect(try await engine.fetchDraft(account: h.account, gmailDraftID: GmailDraftID(remote.id)) != nil)

        try await engine.ensureBodies(thread: ref.rowID)
        let message = try #require(try h.store.message(account: h.account, gmailMessageID: GmailMessageID(other.messageID)))
        #expect(try h.store.body(message.id) != nil)
        #expect(try await engine.ensureBody(account: h.account, gmailMessageID: GmailMessageID(other.messageID)))
        try await engine.ensureBody(message: message.id)

        let found = try await engine.remoteSearch("label:Projects", account: h.account, maxResults: 10)
        #expect(found.map(\.gmailThreadID.rawValue) == [filed.threadID])
        let reports = try await engine.syncNow(nil, reason: "test")
        #expect(reports.count == 1 && reports.first?.error == nil)
        await engine.stop()
    }

    @Test func connectivityFollowsRunsReachabilityAndReauth() async throws {
        let h = try await EngineHarness()
        let system = TestSystemEvents()
        let engine = h.engine(systemEvents: system)
        let states = engine.observeConnectivity()
        var iterator = states.makeAsyncIterator()
        #expect(await iterator.next() == [:])
        await engine.start()
        try await h.waitForSyncs(engine)
        let last = try h.store.syncStatus(account: h.account).lastSuccessAt
        try await eventually("online after the first run") {
            engine.connectivity.current[h.account] == .online(syncing: false, lastSyncAt: last)
        }

        system.send(.networkReachable(false))
        try await eventually("offline") {
            if case .offline(since: h.clock.now)? = engine.connectivity.current[h.account] { return true }
            return false
        }
        _ = try await engine.syncNow(h.account, reason: "test")
        #expect(engine.connectivity.current[h.account] == .offline(since: h.clock.now),
                "a run that finishes while the network is down leaves the account offline")
        let drainer = try #require(await engine.drainer(for: h.account))
        let passes = await drainer.passes
        system.send(.networkReachable(true))
        try await eventually("drainer poked") { await drainer.passes > passes }
        try await h.waitForSyncs(engine, 3)
        try await eventually("online again") {
            if case .online(syncing: false, _)? = engine.connectivity.current[h.account] { return true }
            return false
        }

        await h.gmail.failNext(.listHistory, with: .rateLimited(retryAfter: .seconds(120)))
        _ = try? await engine.syncNow(h.account, reason: "test")
        #expect(engine.connectivity.current[h.account] == .rateLimited(until: h.clock.now.addingTimeInterval(120)))

        let events = EngineEvents(engine)
        await h.gmail.failNext(.listHistory, with: .reauthRequired)
        _ = try? await engine.syncNow(h.account, reason: "test")
        #expect(engine.connectivity.current[h.account] == .needsReauth)
        try await eventually("reauth event") {
            events.all.contains { if case .accountNeedsReauth(h.account) = $0 { return true } else { return false } }
        }
        #expect(try h.store.accounts().first?.status == .needsReauth)
        await engine.stop()
    }

    @Test func wakeForegroundRequestsAndForeignOpsMoveThePoll() async throws {
        let h = try await EngineHarness()
        let system = TestSystemEvents()
        let engine = h.engine(systemEvents: system)
        await engine.start()
        try await h.waitForSyncs(engine)

        system.send(.didWake)
        try await h.waitForSyncs(engine, 2)
        try h.store.setSetting(SettingKey<Int?>.syncRequestAt, 1, scope: .global)
        try await h.waitForSyncs(engine, 3)

        let runtime = try #require(await engine.runtime(for: h.account))
        try await eventually("poll armed") { await runtime.nextPollAt == h.clock.now.addingTimeInterval(60) }
        system.send(.didResignActive)
        try await eventually("in the background") { await !runtime.active }
        h.clock.advance(by: .seconds(60))
        try await h.waitForSyncs(engine, 4)
        try await eventually("next poll in 180 s") { await runtime.nextPollAt == h.clock.now.addingTimeInterval(180) }
        system.send(.didBecomeActive)
        try await h.waitForSyncs(engine, 5)
        try await eventually("next poll in 60 s") { await runtime.nextPollAt == h.clock.now.addingTimeInterval(60) }

        let cli = h.engine(role: .localClient, factory: .some(nil))
        let receipt = try await cli.perform(.archive([try h.ref(h.threads[0])]), origin: .cli)
        try await eventually("the app's drainer claimed the CLI's op") {
            try h.store.operation(receipt.operationIDs[0])?.status == .failed
        }
        #expect(try h.store.operation(receipt.operationIDs[0])?.lastErrorCode == "not_applied_outside_app")
        #expect(await h.serverLabels(ofThread: h.threads[0]).contains("INBOX"))
        await engine.stop()
    }

    @Test func aSyncRunsThreeSecondsAfterEveryAppliedOp() async throws {
        let h = try await EngineHarness(threads: 4)
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        h.clock.advance(by: .seconds(60))
        try await h.waitForSyncs(engine, 2)
        let runtime = try #require(await engine.runtime(for: h.account))

        func expectSyncAfter(_ kind: OperationKind, _ act: () async throws -> Void) async throws {
            let before = Set(try h.ops().map(\.id))
            try await act()
            try await eventually("\(kind.rawValue) applied") {
                let new = try h.ops().filter { !before.contains($0.id) }
                return new.contains { $0.kind == kind } && new.allSatisfy { $0.status == .succeeded }
            }
            let due = h.clock.now.addingTimeInterval(3)
            try await eventually("\(kind.rawValue): sync armed 3 s later") { await runtime.syncSoonAt == due }
            let runs = await runtime.completedRuns
            h.clock.advance(to: due)
            try await eventually("\(kind.rawValue): synced") {
                let ran = await runtime.completedRuns > runs
                let idle = await runtime.nextPollAt != nil
                return ran && idle
            }
        }

        try await expectSyncAfter(.modifyLabels) { _ = try await engine.perform(.archive([try h.ref(h.threads[0])]), origin: .app) }
        try await expectSyncAfter(.trash) { _ = try await engine.perform(.trash([try h.ref(h.threads[1])]), origin: .app) }
        let draft = try await engine.newDraft(account: h.account, mode: .new, replyTo: nil, origin: .user,
                                              initial: DraftContent(to: [EmailAddress(email: "bob@example.invalid")], cc: [],
                                                                    bcc: [], subject: "Synthetic draft",
                                                                    bodyHTML: "<p>Synthetic body.</p>", attachments: []))
        try await expectSyncAfter(.upsertDraft) { try await engine.flushDraft(draft.id) }
        try await expectSyncAfter(.deleteDraft) { try await engine.discardDraft(draft.id) }
        let remote = try await h.gmail.createDraft(rawRFC822: rawDraft(subject: "Synthetic send"), threadID: nil)
        let clean = try #require(try await engine.fetchDraft(account: h.account, gmailDraftID: GmailDraftID(remote.id)))
        try await expectSyncAfter(.sendDraft) {
            let receipt = try await engine.send(clean, authorization: .userConfirmed, undoWindow: .zero)
            h.advancePast(receipt)
        }
        try await expectSyncAfter(.createLabel) {
            _ = try await engine.createLabel(account: h.account, name: "Synthetic", applyTo: [try h.ref(h.threads[2])])
        }
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        await engine.stop()
    }

    @Test func aLateSyncSoonForOpsAppliedTogetherKeepsTheDueSync() async throws {
        let h = try await EngineHarness()
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let runtime = try #require(await engine.runtime(for: h.account))
        let applied = h.clock.now
        let due = applied.addingTimeInterval(3)
        await runtime.syncSoon(after: applied)
        #expect(await runtime.syncSoonAt == due)
        let runs = await runtime.completedRuns
        h.clock.advance(to: due)
        await runtime.syncSoon(after: applied)
        #expect((await runtime.syncSoonAt ?? due) == due)
        try await eventually("synced at the first deadline") {
            let ran = await runtime.completedRuns > runs
            let idle = await runtime.nextPollAt != nil
            return ran && idle
        }
        await engine.stop()
    }
}

@Suite struct EngineQuotaTests {
    @Test func theBackfillPaceIsHalfTheClientsBudgetAndTheHorizonsComeFromSettings() async throws {
        let h = try await EngineHarness()
        try h.store.setSetting(.bodyHorizonDays, 30, scope: .global)
        try h.store.setSetting(.metadataHorizonDays, 365, scope: .global)
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let runtime = try #require(await engine.runtime(for: h.account))
        let settings = await runtime.syncer.settings
        #expect(settings.backfillUnitsPerMinute == engineGmailConfig.unitsPerMinute / 2)
        #expect(settings.bodyHorizon == .seconds(30 * 86_400))
        #expect(settings.metadataHorizon == .seconds(365 * 86_400))
        #expect(GmailClientConfig(userAgent: "x").unitsPerMinute / 2 == 3_000)
        await engine.stop()
    }
}
