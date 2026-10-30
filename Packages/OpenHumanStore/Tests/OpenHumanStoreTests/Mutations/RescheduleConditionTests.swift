import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct RescheduleConditionTests {
    @Test func movingAnIfNoReplySendKeepsTheConditionAndItsAnchor() throws {
        let f = try MutationFixture()
        _ = try f.seed(1)
        let id = try f.syncedDraft(replyTo: "m1")
        let before = nine.addingTimeInterval(-3600)
        func headers() throws -> [String: String] { DraftRowCodec.decodeHeaders(try f.draftRow(id)["extra_headers_json"]) }
        try f.store.write { db in try SendMutations.schedule(id, at: nine, onlyIfNoReply: true, now: epochMillis(before), in: db) }
        #expect(try DraftRowCodec.header(OHGmailLabels.sendAtConditionHeader, in: headers()) == "no-reply m1")

        _ = try f.upsert([.fixture("m9", thread: "t1", minutes: 9, labels: ["INBOX"], from: "bob@else.example")])
        try f.store.write { db in try SendMutations.schedule(id, at: ten, onlyIfNoReply: true, now: epochMillis(before), in: db) }
        #expect(try DraftRowCodec.header(OHGmailLabels.sendAtConditionHeader, in: headers()) == "no-reply m1",
                "a reply that came before the move still holds the message back")
        #expect(try DraftRowCodec.header(OHGmailLabels.sendAtHeader, in: headers()) == "20261012T1000Z")
        let draft = try #require(try f.store.draft(id))
        #expect(try f.store.scheduledSendHasReply(draft) == true)

        try f.store.cancelScheduledSend(id)
        try f.store.write { db in try SendMutations.schedule(id, at: nine, onlyIfNoReply: true, now: epochMillis(before), in: db) }
        #expect(try DraftRowCodec.header(OHGmailLabels.sendAtConditionHeader, in: headers()) == "no-reply m9",
                "scheduling again after a cancel starts from the newest message")
    }
}
