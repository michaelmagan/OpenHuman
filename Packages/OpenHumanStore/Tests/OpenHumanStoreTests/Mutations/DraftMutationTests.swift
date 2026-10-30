import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct DraftMutationTests {
    @Test func aReplyDraftJoinsItsThreadAndANewOneHasNone() throws {
        let f = try MutationFixture()
        _ = try f.seed(1)
        let reply = try f.newDraft(replyTo: "m1")
        let row = try f.draftRow(reply)
        #expect(try row["tid"] as Int64? == f.ref("t1").rowID.rawValue && row["gmail_thread_id"] as String? == "t1")
        #expect(row["compose_mode"] as String == "reply" && row["reply_to_gmail_message_id"] as String? == "m1")
        #expect(row["local_version"] as Int == 1 && row["synced_version"] as Int == 0 && row["state"] as String == "editing")
        #expect(try f.store.thread(f.ref("t1"))?.draftCount == 1)
        let fresh = try f.newDraft()
        #expect(try f.draftRow(fresh)["tid"] as Int64? == nil)
        #expect(try f.ops().isEmpty)
        #expect(throws: StoreError.notFound("message nope")) {
            try f.store.createDraft(account: f.account, mode: .reply, replyTo: GmailMessageID("nope"),
                                    content: MutationFixture.content(), origin: .user, reviewState: .none, agentNote: nil,
                                    extraHeaders: [:])
        }
        let quoted = "<p>Thanks</p><div class=\"gmail_quote\" data-oh-quote=\"1\">On Mon, Bob wrote:</div>"
        _ = try f.store.updateDraft(reply, content: MutationFixture.content(body: quoted), expectedVersion: 1)
        #expect(try f.draftRow(reply)["body_html"] as String == quoted)
    }

    @Test func agentDraftsKeepASnapshotAndACappedNote() throws {
        let f = try MutationFixture()
        let note = String(repeating: "é", count: 600)
        let id = try f.newDraft(origin: .agent, review: .pending, note: note, headers: ["X-OpenHuman-Origin": "agent"])
        let row = try f.draftRow(id)
        #expect((row["agent_note"] as String).unicodeScalars.count == 500)
        let snapshot = try JSONDecoder().decode(DraftContent.self, from: Data((row["agent_snapshot_json"] as String).utf8))
        #expect(snapshot == MutationFixture.content() && row["review_state"] as String == "pending")
        #expect(DraftRowCodec.decodeHeaders(row["extra_headers_json"]) == ["X-OpenHuman-Origin": "agent"])
        let mine = try f.newDraft(note: "ignored")
        #expect(try f.draftRow(mine)["agent_note"] as String? == nil && f.draftRow(mine)["agent_snapshot_json"] as String? == nil)
    }

    @Test func updateDraftChecksTheVersion() throws {
        let f = try MutationFixture()
        let id = try f.newDraft()
        #expect(try f.store.updateDraft(id, content: MutationFixture.content("Two"), expectedVersion: 1) == 2)
        #expect(throws: StoreError.self) { try f.store.updateDraft(id, content: MutationFixture.content("Stale"), expectedVersion: 1) }
        #expect(try f.store.updateDraft(id, content: MutationFixture.content("Three"), expectedVersion: nil) == 3)
        #expect(try f.draftRow(id)["subject"] as String == "Three")
        #expect(throws: StoreError.notFound("draft nope")) {
            try f.store.updateDraft(DraftID("nope"), content: MutationFixture.content(), expectedVersion: nil)
        }
    }

    @Test func aSaveThatRepeatsTheStoredContentKeepsTheVersionAndWritesNothing() throws {
        let f = try MutationFixture()
        let id = try f.newDraft()
        #expect(try f.store.updateDraft(id, content: MutationFixture.content("Two"), expectedVersion: 1) == 2)
        let written = try f.draftRow(id)["updated_at"] as Int64
        #expect(try f.store.updateDraft(id, content: MutationFixture.content("Two"), expectedVersion: 2) == 2)
        #expect(try f.store.updateDraft(id, content: MutationFixture.content("Two"), expectedVersion: nil) == 2)
        let row = try f.draftRow(id)
        #expect(row["local_version"] as Int == 2 && row["updated_at"] as Int64 == written)
        #expect(throws: StoreError.self) { try f.store.updateDraft(id, content: MutationFixture.content("Two"), expectedVersion: 1) }
        #expect(try f.store.updateDraft(id, content: MutationFixture.content("Three"), expectedVersion: 2) == 3)
        #expect(try f.ops().isEmpty)
    }

    @Test func anUnchangedSaveStillReopensAFailedDraft() throws {
        let f = try MutationFixture()
        let id = try f.syncedDraft()
        let receipt = try f.store.send(id, undoWindow: .zero, origin: .app)
        _ = try f.claim()
        try f.store.fail(receipt.sendOperationID, code: "bad_request", message: "Invalid To header", retryAt: nil)
        #expect(try f.draftRow(id)["state"] as String == "failed")
        let content = try #require(try f.store.draft(id)).content
        let version = try f.draftRow(id)["local_version"] as Int
        #expect(try f.store.updateDraft(id, content: content, expectedVersion: nil) == version + 1)
        #expect(try f.draftRow(id)["state"] as String == "editing")
    }

    @Test func uploadsCoalesceUntilAttemptedAndANewerOneSupersedesAnOlderRetry() throws {
        let f = try MutationFixture()
        let id = try f.newDraft()
        let first = try f.store.saveDraftRemotely(id)
        _ = try f.store.updateDraft(id, content: MutationFixture.content("Two"), expectedVersion: nil)
        let second = try f.store.saveDraftRemotely(id)
        #expect(try first == second && f.op(first).payload == .upsertDraft(draftID: id, version: 2))
        #expect(try f.op(first).origin == .app)
        _ = try f.claim()
        try f.store.fail(first, code: "server", message: "503", retryAt: Date())
        _ = try f.store.updateDraft(id, content: MutationFixture.content("Three"), expectedVersion: nil)
        let third = try f.store.saveDraftRemotely(id)
        #expect(third != first)
        #expect(try f.claim().map(\.id) == [third])
        #expect(try f.op(first).status == .cancelled && f.op(first).lastErrorCode == "superseded")
    }

    @Test func draftSavedRecordsIdsAndNeverLowersTheSyncedVersion() throws {
        let f = try MutationFixture()
        let id = try f.newDraft()
        let op = try f.store.saveDraftRemotely(id)
        _ = try f.claim()
        _ = try f.store.updateDraft(id, content: MutationFixture.content("Typed meanwhile"), expectedVersion: nil)
        try f.store.complete(op, outcome: .draftSaved(gmailDraftID: GmailDraftID("r1"), gmailMessageID: GmailMessageID("dm1"),
                                                      version: 1))
        let row = try f.draftRow(id)
        #expect(row["gmail_draft_id"] as String? == "r1" && row["gmail_message_id"] as String? == "dm1")
        #expect(row["synced_version"] as Int == 1 && row["local_version"] as Int == 2)
        #expect(throws: StoreError.self) { try f.store.complete(op, outcome: .draftDeleted) }
    }

    @Test func aRemoteCopyThatWasOurOwnSaveIsDroppedWhenTheSaveLands() throws {
        let f = try MutationFixture()
        _ = try f.seed(1)
        let id = try f.syncedDraft(replyTo: "m1")
        let gmailDraft = try #require(try f.draftRow(id)["gmail_draft_id"] as String?)
        _ = try f.store.updateDraft(id, content: MutationFixture.content("Mine"), expectedVersion: nil)
        let op = try f.store.saveDraftRemotely(id)
        let remote = RemoteDraftUpsert(gmailDraftID: GmailDraftID(gmailDraft), gmailMessageID: GmailMessageID("dm-ours"),
                                       gmailThreadID: GmailThreadID("t1"), content: MutationFixture.content("Mine"), extraHeaders: [:])
        try f.store.reconcileRemoteDrafts([remote], account: f.account, complete: true)
        #expect(try f.draftRow(id)["remote_conflict_json"] as String? != nil)
        _ = try f.claim()
        try f.store.complete(op, outcome: .draftSaved(gmailDraftID: GmailDraftID(gmailDraft),
                                                      gmailMessageID: GmailMessageID("dm-ours"), version: 2))
        #expect(try f.draftRow(id)["remote_conflict_json"] as String? == nil)
    }

    @Test func conflictsResolveToEitherSide() throws {
        let f = try MutationFixture()
        _ = try f.seed(1)
        let id = try f.syncedDraft(replyTo: "m1")
        let gmailDraft = try #require(try f.draftRow(id)["gmail_draft_id"] as String?)
        _ = try f.store.updateDraft(id, content: MutationFixture.content("Local"), expectedVersion: nil)
        let remote = RemoteDraftUpsert(gmailDraftID: GmailDraftID(gmailDraft), gmailMessageID: GmailMessageID("dm-elsewhere"),
                                       gmailThreadID: GmailThreadID("t1"), content: MutationFixture.content("Remote"),
                                       extraHeaders: ["In-Reply-To": "<m1@example.com>"])
        try f.store.reconcileRemoteDrafts([remote], account: f.account, complete: true)
        try f.store.resolveDraftConflict(id, keep: .takeRemote)
        var row = try f.draftRow(id)
        #expect(row["subject"] as String == "Remote" && row["gmail_message_id"] as String? == "dm-elsewhere")
        #expect(row["local_version"] as Int == row["synced_version"] as Int && row["remote_conflict_json"] as String? == nil)
        #expect(try f.ops([.pending]).isEmpty)
        _ = try f.store.updateDraft(id, content: MutationFixture.content("Local again"), expectedVersion: nil)
        try f.store.reconcileRemoteDrafts([RemoteDraftUpsert(gmailDraftID: GmailDraftID(gmailDraft),
                                                             gmailMessageID: GmailMessageID("dm-third"),
                                                             gmailThreadID: GmailThreadID("t1"),
                                                             content: MutationFixture.content("Remote again"), extraHeaders: [:])],
                                          account: f.account, complete: true)
        try f.store.resolveDraftConflict(id, keep: .keepLocal)
        row = try f.draftRow(id)
        #expect(row["subject"] as String == "Local again" && row["remote_conflict_json"] as String? == nil)
        #expect((row["local_version"] as Int) > (row["synced_version"] as Int))
        try f.store.resolveDraftConflict(id, keep: .takeRemote)
        #expect(try f.draftRow(id)["subject"] as String == "Local again")
    }

    @Test func anAgentRewriteNeverOverwritesTheUsersEdits() throws {
        let f = try MutationFixture()
        let id = try f.newDraft(origin: .cli, review: .pending)
        _ = try f.store.updateAgentDraft(id, content: MutationFixture.content("Agent v2"), agentNote: "shorter")
        var row = try f.draftRow(id)
        #expect(row["subject"] as String == "Agent v2" && row["agent_note"] as String? == "shorter")
        _ = try f.store.updateDraft(id, content: MutationFixture.content("User edit"), expectedVersion: nil)
        try f.store.setReviewState(id, .approved)
        _ = try f.store.updateAgentDraft(id, content: MutationFixture.content("Agent v3"), agentNote: nil)
        row = try f.draftRow(id)
        #expect(row["subject"] as String == "User edit" && row["review_state"] as String == "pending")
        #expect(row["agent_note"] as String? == "shorter")
        let snapshot = try JSONDecoder().decode(DraftContent.self, from: Data((row["agent_snapshot_json"] as String).utf8))
        #expect(snapshot.subject == "Agent v3")
        #expect(DraftRowCodec.decodeConflict(row["remote_conflict_json"])?.content.subject == "Agent v3")
        try f.store.resolveDraftConflict(id, keep: .takeRemote)
        #expect(try f.draftRow(id)["subject"] as String == "Agent v3")
        let mine = try f.newDraft()
        #expect(throws: StoreError.self) { try f.store.updateAgentDraft(mine, content: MutationFixture.content(), agentNote: nil) }
    }

    @Test func approvingRemovesTheAgentLabelAndUploadsWithoutTheMarker() throws {
        let f = try MutationFixture()
        try f.labels([("L_agent", OHGmailLabels.agent)])
        _ = try f.seed(1)
        let id = try f.syncedDraft(origin: .agent, review: .pending, replyTo: "m1")
        let message = try #require(try f.draftRow(id)["gmail_message_id"] as String?)
        try f.store.setReviewState(id, .approved)
        let pending = try f.ops([.pending])
        #expect(pending.map(\.kind) == [.modifyLabels, .upsertDraft])
        #expect(pending[0].payload == .modifyLabels(ids: [GmailMessageID(message)], add: [], remove: [GmailLabelID("L_agent")],
                                                    addNames: []))
        #expect(try f.draftRow(id)["review_state"] as String == "approved")
        try f.store.setReviewState(id, .approved)
        #expect(try f.ops([.pending]).count == 2)
        try f.store.setReviewState(id, .pending)
        #expect(try f.ops([.pending]).count == 2)
    }

    @Test func approvingADraftWithNoGmailCopyQueuesItsUploadAsTheUsers() throws {
        let f = try MutationFixture()
        let id = try f.newDraft(origin: .cli, review: .pending, headers: ["X-OpenHuman-Origin": "cli"])
        #expect(try f.ops([.pending]).isEmpty)
        try f.store.setReviewState(id, .approved)
        let version = try f.draftRow(id)["local_version"] as Int
        let pending = try f.ops([.pending])
        #expect(pending.map(\.kind) == [.upsertDraft] && pending.first?.origin == .app)
        #expect(pending.first?.payload == .upsertDraft(draftID: id, version: version))
        try f.store.setReviewState(id, .approved)
        #expect(try f.ops([.pending]).count == 1)

        let rejected = try f.newDraft(origin: .agent, review: .pending)
        try f.store.setReviewState(rejected, .rejected)
        #expect(try f.ops([.pending]).count == 1)

        let queued = try f.newDraft(origin: .cli, review: .pending)
        let upload = try f.store.saveDraftRemotely(queued)
        try f.store.setReviewState(queued, .approved)
        #expect(try f.ops([.pending]).count == 2)
        #expect(try f.op(upload).payload == .upsertDraft(draftID: queued, version: f.draftRow(queued)["local_version"] as Int))
    }

    @Test func discardDeletesOnGmailOrOnceTheCreationLands() throws {
        let f = try MutationFixture()
        let synced = try f.syncedDraft()
        let gmailDraft = try #require(try f.draftRow(synced)["gmail_draft_id"] as String?)
        let deleteOp = try #require(try f.store.discardDraft(synced))
        #expect(try f.op(deleteOp).payload == .deleteDraft(draftID: synced, gmailDraftID: GmailDraftID(gmailDraft)))
        #expect(try f.draftRow(synced)["state"] as String == "discarded" && f.store.discardDraft(synced) == nil)
        try f.drain()
        let local = try f.newDraft()
        let upload = try f.store.saveDraftRemotely(local)
        #expect(try f.store.discardDraft(local) == nil && f.op(upload).status == .cancelled)
        let racing = try f.newDraft()
        let creating = try f.store.saveDraftRemotely(racing)
        _ = try f.claim()
        #expect(try f.store.discardDraft(racing) == nil)
        try f.store.complete(creating, outcome: .draftSaved(gmailDraftID: GmailDraftID("r-race"), gmailMessageID: GmailMessageID("dm"),
                                                            version: 1))
        #expect(try f.ops([.pending]).contains { $0.payload == .deleteDraft(draftID: racing, gmailDraftID: GmailDraftID("r-race")) })
        try f.drain()
        #expect(try f.ops([.pending, .inFlight]).isEmpty)
    }

    @Test func snippetsAreLocalRowsWithUniqueShortcuts() throws {
        let f = try MutationFixture()
        let intro = SnippetItem(id: "s1", accountID: nil, name: "Intro", shortcut: "intro", subject: nil,
                                bodyHTML: "<p>Hi {{first_name}}</p>",
                                variables: [SnippetVariable(name: "first_name", defaultValue: "there")], useCount: 0)
        try f.store.upsertSnippet(intro)
        var row = try #require(try f.raw("SELECT * FROM snippets WHERE snippet_id = 's1'").first)
        #expect(row["variables_json"] as String == #"[{"default":"there","name":"first_name"}]"#)
        try f.store.recordSnippetUse(id: "s1")
        try f.store.recordSnippetUse(id: "s1")
        var renamed = intro
        renamed.name = "Introduction"
        try f.store.upsertSnippet(renamed)
        row = try #require(try f.raw("SELECT * FROM snippets WHERE snippet_id = 's1'").first)
        #expect(row["name"] as String == "Introduction" && row["use_count"] as Int == 2 && row["last_used_at"] as Int64? != nil)
        let clash = SnippetItem(id: "s2", accountID: f.account, name: "Other", shortcut: "INTRO", subject: nil, bodyHTML: "x",
                                variables: [], useCount: 0)
        #expect(throws: StoreError.self) { try f.store.upsertSnippet(clash) }
        try f.store.deleteSnippet(id: "s1")
        try f.store.upsertSnippet(clash)
        #expect(try f.raw("SELECT snippet_id FROM snippets").map { $0["snippet_id"] as String } == ["s2"])
        #expect(throws: StoreError.notFound("snippet s1")) { try f.store.recordSnippetUse(id: "s1") }
    }

    @Test func splitsRenameToggleReorderCreateAndDelete() throws {
        let f = try MutationFixture()
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX", "IMPORTANT"]), .fixture("m2", thread: "t2", minutes: 1)])
        let important = try #require(try f.raw("SELECT split_id FROM splits WHERE role = 'important'").first?["split_id"] as String?)
        let splitView = MailboxView.split(f.account, SplitID(important))
        func members(_ view: MailboxView) throws -> [String] {
            try f.store.threadPage(view: view, after: nil, limit: 50).items.map(\.ref.gmailThreadID.rawValue)
        }
        #expect(try members(splitView) == ["t1"] && members(.splitOther(f.account)) == ["t2"])
        _ = try f.store.upsertSplit(account: f.account, id: SplitID(important), name: "VIP", ruleText: "is:important",
                                    position: nil, enabled: false)
        #expect(try members(splitView).isEmpty && Set(members(.splitOther(f.account))) == ["t1", "t2"])
        #expect(try f.store.label(account: f.account, key: "oh:split:" + important)?.name == "VIP")
        _ = try f.store.upsertSplit(account: f.account, id: SplitID(important), name: "VIP", ruleText: "is:important",
                                    position: nil, enabled: true)
        #expect(try members(splitView) == ["t1"])
        try f.store.reorderSplits(account: f.account, [SplitID(important)])
        #expect(throws: StoreError.notFound("split nope")) { try f.store.reorderSplits(account: f.account, [SplitID("nope")]) }
        let alice = try f.store.upsertSplit(account: f.account, id: nil, name: "Alice", ruleText: "from:(alice@example.com)",
                                            position: nil, enabled: true)
        #expect(try f.store.splits(account: f.account).first { $0.id == alice }?.ruleText == "from:alice@example.com")
        #expect(try members(splitView) == ["t1"] && members(.split(f.account, alice)) == ["t2"])
        #expect(throws: StoreError.self) {
            try f.store.upsertSplit(account: f.account, id: nil, name: "VIP", ruleText: "is:important", position: nil, enabled: true)
        }
        #expect(throws: StoreError.self) {
            try f.store.upsertSplit(account: f.account, id: alice, name: "Alice", ruleText: "from:(", position: nil, enabled: true)
        }
        try f.store.deleteSplit(SplitID(important))
        try f.store.deleteSplit(alice)
        #expect(try f.raw("SELECT name FROM splits").map { $0["name"] as String } == ["Calendar"])
        #expect(Set(try members(.splitOther(f.account))) == ["t1", "t2"])
    }
}
