import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct DraftsRefreshTests {
    @Test func theAgentMarkerBecomesAPendingReviewAndApprovalOrDeletionElsewhereFollows() async throws {
        let h = try SyncHarness(onDisk: true, recording: true)
        let location = try #require(h.location)
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let recorder = try #require(h.recorder)
        await h.gmail.seedInbox(count: 3)
        let agent = try await h.gmail.createDraft(rawRFC822: rawDraft(subject: "Agent reply",
                                                                      headers: ["X-OpenHuman-Origin": "agent"]),
                                                  threadID: nil)
        let user = try await h.gmail.createDraft(rawRFC822: rawDraft(subject: "My draft"), threadID: nil)
        try await h.syncer.sync(reason: "launch")
        #expect(await h.syncer.runBackfill() == .complete)
        var rows = try draftRows(location)
        #expect(rows.contains(DraftRow(gmailDraftID: agent.id, origin: "agent", reviewState: "pending", state: "editing")))
        #expect(rows.contains(DraftRow(gmailDraftID: user.id, origin: "user", reviewState: "none", state: "editing")))
        #expect(recorder.calls(.getDraft).count == 2)

        recorder.reset()
        _ = try await h.gmail.updateDraft(id: agent.id, rawRFC822: rawDraft(subject: "Agent reply", body: "Edited."),
                                          threadID: nil)
        try await h.gmail.deleteDraft(id: user.id)
        try await h.syncer.sync(reason: "poll")
        rows = try draftRows(location)
        #expect(rows.contains(DraftRow(gmailDraftID: agent.id, origin: "agent", reviewState: "approved", state: "editing")))
        #expect(rows.contains(DraftRow(gmailDraftID: user.id, origin: "user", reviewState: "none", state: "discarded")))
        #expect(recorder.calls(.listDrafts).count == 1 && recorder.calls(.getDraft).count == 1)

        recorder.reset()
        await h.gmail.deliver(subject: "Plain mail")
        try await h.syncer.sync(reason: "poll")
        #expect(recorder.calls(.listDrafts).isEmpty)
        let log = try h.store.syncLog(account: h.account, limit: 10)
        #expect(log.contains { $0.kind == "drafts" && $0.outcome == "ok" })
    }

    @Test func aDraftThatCannotBeReadIsNeverDiscardedAndTheRefreshIsRetried() async throws {
        let h = try SyncHarness(onDisk: true)
        let location = try #require(h.location)
        defer { try? FileManager.default.removeItem(at: location.directory) }
        await h.gmail.seedInbox(count: 2)
        let first = try await h.gmail.createDraft(rawRFC822: rawDraft(subject: "First"), threadID: nil)
        try await h.syncer.sync(reason: "launch")
        try await h.syncer.refreshDrafts()
        #expect(try draftRows(location).map(\.gmailDraftID) == [first.id])

        let second = try await h.gmail.createDraft(rawRFC822: rawDraft(subject: "Second"), threadID: nil)
        _ = try await h.gmail.updateDraft(id: first.id, rawRFC822: rawDraft(subject: "First", body: "v2"), threadID: nil)
        await h.gmail.failNext(.getDraft, with: .server(status: 500, message: nil))
        let start = try h.status().historyID
        await #expect(throws: GmailError.server(status: 500, message: nil)) { try await h.syncer.sync(reason: "poll") }
        #expect(try draftRows(location).allSatisfy { $0.state == "editing" })
        #expect(try h.status().historyID == start)

        try await h.syncer.sync(reason: "poll")
        let rows = try draftRows(location)
        #expect(Set(rows.map(\.gmailDraftID)) == [first.id, second.id] && rows.allSatisfy { $0.state == "editing" })
    }

    @Test func aDraftFirstUploadedWhileTheListingIsReadIsNotDiscarded() async throws {
        let h = try await WriteHarness()
        let id = try h.newDraft()
        let op = try h.store.saveDraftRemotely(id)
        let store = h.store
        await h.gmail.afterNext(.listDrafts) { gmail in
            let remote = gmail.seedDraft()
            try? store.complete(op, outcome: .draftSaved(gmailDraftID: GmailDraftID(remote.draftID),
                                                         gmailMessageID: GmailMessageID(remote.messageID), version: 1))
        }
        try await h.syncer.refreshDrafts()
        var draft = try #require(try h.store.draft(id))
        #expect(draft.state == .editing && draft.gmailDraftID != nil)

        try await h.syncer.refreshDrafts()
        draft = try #require(try h.store.draft(id))
        #expect(draft.state == .editing && draft.gmailDraftID != nil)
        #expect(try h.store.drafts(account: h.account, states: [], limit: 10).count == 1)
    }

    @Test func aDraftEditedElsewhereReplacesTheCleanCopyAndMovesItsVersion() async throws {
        let h = try SyncHarness()
        await h.gmail.seedInbox(count: 2)
        let remote = try await h.gmail.createDraft(rawRFC822: rawDraft(subject: "Plan", body: "First."), threadID: nil)
        try await h.syncer.sync(reason: "launch")
        try await h.syncer.refreshDrafts()
        let before = try #require(try h.store.drafts(account: h.account, states: [.editing], limit: 10).first)
        #expect(before.gmailDraftID?.rawValue == remote.id && before.localVersion == 1 && !before.isDirty)

        _ = try await h.gmail.updateDraft(id: remote.id, rawRFC822: rawDraft(subject: "Plan", body: "Second."), threadID: nil)
        try await h.syncer.sync(reason: "poll")
        let after = try #require(try h.store.draft(before.id))
        #expect(((after.content.bodyText ?? "") + after.content.bodyHTML).contains("Second."))
        #expect(after.localVersion == 2 && !after.isDirty, "an open composer reloads on a newer version")
        #expect(throws: StoreError.self) {
            _ = try h.store.updateDraft(before.id, content: before.content, expectedVersion: before.localVersion)
        }

        try await h.syncer.refreshDrafts()
        #expect(try #require(try h.store.draft(before.id)).localVersion == 2, "nothing changed, so the version stays")
    }

    @Test func aDraftSavedAgainWhileTheListingIsReadKeepsItsNewerLocalCopy() async throws {
        let h = try await WriteHarness()
        let id = try h.newDraft()
        let first = try h.store.saveDraftRemotely(id)
        let seeded = await h.gmail.seedDraft()
        try h.store.complete(first, outcome: .draftSaved(gmailDraftID: GmailDraftID(seeded.draftID),
                                                         gmailMessageID: GmailMessageID(seeded.messageID), version: 1))
        try await h.syncer.refreshDrafts()
        let before = try #require(try h.store.draft(id))
        #expect(before.gmailMessageID?.rawValue == seeded.messageID)

        let again = try h.store.saveDraftRemotely(id)
        let store = h.store
        await h.gmail.afterNext(.listDrafts) { _ in
            try? store.complete(again, outcome: .draftSaved(gmailDraftID: GmailDraftID(seeded.draftID),
                                                            gmailMessageID: GmailMessageID("newer-upload"), version: 1))
        }
        try await h.syncer.refreshDrafts()
        let after = try #require(try h.store.draft(id))
        #expect(after.state == .editing && after.gmailMessageID?.rawValue == "newer-upload")
        #expect(after.content == before.content && after.localVersion == before.localVersion)
    }
}
