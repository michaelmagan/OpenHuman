import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct RemoteDraftTests {
    private func setup() throws -> AggregationFixture {
        let f = try AggregationFixture()
        try f.labels([("L_agent", "OpenHuman/Agent")])
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX"]),
                      .fixture("dm1", thread: "t1", minutes: 2, labels: ["DRAFT"], from: "me@example.com")])
        return f
    }

    private func reconcile(_ f: AggregationFixture, _ drafts: [RemoteDraftUpsert], complete: Bool = true) throws {
        try f.store.reconcileRemoteDrafts(drafts, account: f.account, complete: complete)
    }

    private func makeDirty(_ f: AggregationFixture) throws {
        try f.mutate { db in try db.execute(sql: "UPDATE drafts SET local_version = local_version + 1, subject = 'local edit'") }
    }

    @Test func aNewRemoteDraftIsInsertedClean() throws {
        let f = try setup()
        try f.upsert([.fixture("x1", thread: "t1", minutes: 1, from: "bob@example.com")])
        try f.store.write { db in try db.execute(sql: "UPDATE messages SET rfc822_message_id = 'orig@x' WHERE gmail_message_id = 'x1'") }
        try reconcile(f, [f.remote("r1", message: "dm1", thread: "t1", subject: "Re: Hello",
                                   headers: ["In-Reply-To": "<orig@x>"])])
        let row = try #require(try f.draftRow(gmailDraftID: "r1"))
        #expect(row["origin"] as String == "user" && row["review_state"] as String == "none")
        #expect(row["state"] as String == "editing" && row["compose_mode"] as String == "reply")
        #expect(row["reply_to_gmail_message_id"] as String? == "x1")
        #expect(row["local_version"] as Int == 1 && row["synced_version"] as Int == 1)
        let t1 = try f.tid("t1")
        #expect(row["subject"] as String == "Re: Hello" && row["tid"] as Int64? == t1)
        #expect(DraftRowCodec.decodeAddresses(row["to_json"]) == [EmailAddress(name: "Bob", email: "bob@example.com")])
        #expect(DraftRowCodec.decodeHeaders(row["extra_headers_json"]) == ["In-Reply-To": "<orig@x>"])
        let before = try f.draftRows().map { $0["updated_at"] as Int64 }
        try reconcile(f, [f.remote("r1", message: "dm1", thread: "t1", subject: "Re: Hello", headers: ["In-Reply-To": "<orig@x>"])])
        #expect(try f.draftRows().map { $0["updated_at"] as Int64 } == before)
    }

    @Test func agentMarkersMakeAPendingReview() throws {
        let f = try setup()
        try reconcile(f, [f.remote("r1", message: "dm1", thread: "t1", headers: ["X-OpenHuman-Origin": "agent"])])
        var row = try #require(try f.draftRow(gmailDraftID: "r1"))
        #expect(row["origin"] as String == "agent" && row["review_state"] as String == "pending")
        #expect(row["agent_snapshot_json"] as String? != nil)
        let g = try setup()
        _ = try g.store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID("dm1"), historyID: HistoryID(5),
                                                     added: [GmailLabelID("L_agent")], removed: [])], account: g.account)
        try reconcile(g, [g.remote("r2", message: "dm1", thread: "t1")])
        row = try #require(try g.draftRow(gmailDraftID: "r2"))
        #expect(row["origin"] as String == "user" && row["review_state"] as String == "pending")
    }

    @Test func aCleanRowTakesAChangedRemoteAndApprovesWhenMarkersAreGone() throws {
        let f = try setup()
        try reconcile(f, [f.remote("r1", message: "dm1", thread: "t1", headers: ["X-OpenHuman-Origin": "cli"])])
        #expect(try f.draftRow(gmailDraftID: "r1")?["review_state"] as String? == "pending")
        try reconcile(f, [f.remote("r1", message: "dm2", thread: "t1", subject: "Edited elsewhere")])
        let row = try #require(try f.draftRow(gmailDraftID: "r1"))
        #expect(row["subject"] as String == "Edited elsewhere" && row["gmail_message_id"] as String? == "dm2")
        #expect(row["review_state"] as String == "approved" && row["origin"] as String == "cli")
        #expect(row["local_version"] as Int == row["synced_version"] as Int)
    }

    @Test func remoteContentInACleanRowIsANewVersion() throws {
        let f = try setup()
        try reconcile(f, [f.remote("r1", message: "dm1", thread: "t1", subject: "First")])
        let uuid = try #require(try f.draftRow(gmailDraftID: "r1"))["draft_uuid"] as String
        try reconcile(f, [f.remote("r1", message: "dm2", thread: "t1", subject: "Edited elsewhere")])
        var row = try #require(try f.draftRow(gmailDraftID: "r1"))
        #expect(row["subject"] as String == "Edited elsewhere")
        #expect(row["local_version"] as Int == 2 && row["synced_version"] as Int == 2)
        let stale = DraftContent(to: [], cc: [], bcc: [], subject: "Typed over the old text", bodyHTML: "", attachments: [])
        #expect(throws: StoreError.self) { _ = try f.store.updateDraft(DraftID(uuid), content: stale, expectedVersion: 1) }
        #expect(try f.draftRow(gmailDraftID: "r1")?["subject"] as String? == "Edited elsewhere")

        try reconcile(f, [f.remote("r1", message: "dm3", thread: "t1", subject: "Edited elsewhere")])
        row = try #require(try f.draftRow(gmailDraftID: "r1"))
        #expect(row["gmail_message_id"] as String? == "dm3")
        #expect(row["local_version"] as Int == 2 && row["synced_version"] as Int == 2, "the same content keeps the version")
    }

    @Test func aCleanRowIsNotReplacedWhileOurOwnSaveIsInFlight() throws {
        let f = try setup()
        try reconcile(f, [f.remote("r1", message: "dm1", thread: "t1", subject: "Ours")])
        let uuid = try #require(try f.draftRow(gmailDraftID: "r1"))["draft_uuid"] as String
        try f.store.write { db in
            try db.execute(sql: """
                INSERT INTO pending_operations (account_id, kind, payload_json, status, created_at, updated_at)
                VALUES (?, 'upsert_draft', ?, 'in_flight', 0, 0)
                """, arguments: [f.account.rawValue, OperationPayloadCodec.encode(.upsertDraft(draftID: DraftID(uuid), version: 1))])
        }
        try reconcile(f, [f.remote("r1", message: "dm-ours", thread: "t1", subject: "Read back")])
        var row = try #require(try f.draftRow(gmailDraftID: "r1"))
        #expect(row["subject"] as String == "Ours" && row["gmail_message_id"] as String? == "dm1")
        #expect(row["state"] as String == "editing" && row["local_version"] as Int == 1)

        try f.store.write { db in try db.execute(sql: "UPDATE pending_operations SET status = 'succeeded'") }
        try reconcile(f, [f.remote("r1", message: "dm-other", thread: "t1", subject: "Edited elsewhere")])
        row = try #require(try f.draftRow(gmailDraftID: "r1"))
        #expect(row["subject"] as String == "Edited elsewhere" && row["local_version"] as Int == 2)
    }

    @Test func aDirtyRowKeepsLocalAndStoresAConflictOnlyWhenRemoteChanged() throws {
        let f = try setup()
        try reconcile(f, [f.remote("r1", message: "dm1", thread: "t1")])
        try makeDirty(f)
        try reconcile(f, [f.remote("r1", message: "dm1", thread: "t1", subject: "ignored")])
        var row = try #require(try f.draftRow(gmailDraftID: "r1"))
        #expect(row["subject"] as String == "local edit" && row["remote_conflict_json"] as String? == nil)
        try reconcile(f, [f.remote("r1", message: "dm9", thread: "t1", subject: "Remote edit")])
        row = try #require(try f.draftRow(gmailDraftID: "r1"))
        #expect(row["subject"] as String == "local edit" && row["gmail_message_id"] as String? == "dm1")
        let conflict = try #require(DraftRowCodec.decodeConflict(row["remote_conflict_json"]))
        #expect(conflict.content.subject == "Remote edit" && conflict.gmailMessageID == "dm9")
    }

    @Test func ourOwnSaveInFlightIsNotAConflict() throws {
        let f = try setup()
        try reconcile(f, [f.remote("r1", message: "dm1", thread: "t1")])
        try makeDirty(f)
        let uuid = try #require(try f.draftRow(gmailDraftID: "r1"))["draft_uuid"] as String
        try f.store.write { db in
            try db.execute(sql: """
                INSERT INTO pending_operations (account_id, kind, payload_json, status, created_at, updated_at)
                VALUES (?, 'upsert_draft', ?, 'in_flight', 0, 0)
                """, arguments: [f.account.rawValue, OperationPayloadCodec.encode(.upsertDraft(draftID: DraftID(uuid), version: 2))])
        }
        try reconcile(f, [f.remote("r1", message: "dm-ours", thread: "t1")])
        #expect(try f.draftRow(gmailDraftID: "r1")?["remote_conflict_json"] as String? == nil)
    }

    @Test func missingRemoteDraftsDiscardCleanRowsAndDetachDirtyOnes() throws {
        let f = try setup()
        try reconcile(f, [f.remote("r1", message: "dm1", thread: "t1"), f.remote("r2", message: "dmx", thread: "t2")])
        #expect(try f.draftRows().count == 2)
        try f.mutate { db in
            try db.execute(sql: "UPDATE drafts SET local_version = 2, subject = 'keep me' WHERE gmail_draft_id = 'r2'")
        }
        try reconcile(f, [], complete: false)
        #expect(try f.draftRows().allSatisfy { ($0["state"] as String) == "editing" })
        try reconcile(f, [], complete: true)
        let rows = try f.draftRows()
        let clean = try #require(rows.first { ($0["gmail_message_id"] as String?) == "dm1" })
        #expect(clean["state"] as String == "discarded")
        let dirty = try #require(rows.first { ($0["subject"] as String) == "keep me" })
        #expect(dirty["state"] as String == "editing" && dirty["gmail_draft_id"] as String? == nil)
        #expect(try f.threadRow("t1")["draft_count"] as Int == 0)
    }

    @Test func sendLaterFollowsTheHeaderOfACleanRow() throws {
        let f = try setup()
        try reconcile(f, [f.remote("r1", message: "dm1", thread: "t1", headers: ["X-OpenHuman-Send-At": "20261012T0900Z"])])
        #expect(try f.draftRow(gmailDraftID: "r1")?["state"] as String? == "scheduled")
        try reconcile(f, [f.remote("r1", message: "dm2", thread: "t1", headers: ["X-OpenHuman-Send-At": "20261013T0900Z"])])
        #expect(try f.draftRow(gmailDraftID: "r1")?["send_at"] as Int64? == millis("20261013T0900Z"))
        try reconcile(f, [f.remote("r1", message: "dm3", thread: "t1")])
        #expect(try f.draftRow(gmailDraftID: "r1")?["state"] as String? == "editing")
        #expect(try f.view(.system(f.account, .scheduled)).isEmpty)
        #expect(try f.threadRow("t1")["scheduled_send_at"] as Int64? == nil)
    }

    @Test func unknownDraftsWaitWhileALocalCreationIsInFlight() throws {
        let f = try setup()
        try f.store.write { db in
            try db.execute(sql: """
                INSERT INTO drafts (draft_uuid, account_id, compose_mode, created_at, updated_at, local_version, synced_version)
                VALUES ('local-new', ?, 'new', 0, 0, 1, 0)
                """, arguments: [f.account.rawValue])
            try db.execute(sql: """
                INSERT INTO pending_operations (account_id, kind, payload_json, status, created_at, updated_at)
                VALUES (?, 'upsert_draft', ?, 'in_flight', 0, 0)
                """, arguments: [f.account.rawValue, OperationPayloadCodec.encode(.upsertDraft(draftID: DraftID("local-new"), version: 1))])
        }
        try reconcile(f, [f.remote("r-new", message: "dm-new", thread: "tn")])
        #expect(try f.draftRow(gmailDraftID: "r-new") == nil)
        try f.store.write { db in try db.execute(sql: "UPDATE pending_operations SET status = 'succeeded'") }
        try reconcile(f, [f.remote("r-new", message: "dm-new", thread: "tn")])
        #expect(try f.draftRow(gmailDraftID: "r-new") != nil)
    }
}
