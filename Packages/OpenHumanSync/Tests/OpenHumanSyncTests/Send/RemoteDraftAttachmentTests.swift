import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanMIME
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct RemoteDraftAttachmentTests {
    private let file = FakeGmailAttachment(filename: "plan.pdf", mimeType: "application/pdf",
                                           data: Data("Synthetic PDF bytes".utf8))

    private func imported(_ h: WriteHarness) async throws -> DraftListItem {
        let (gmailDraftID, _) = await h.gmail.seedDraft(subject: "Written elsewhere", attachments: [file])
        try await h.syncer.refreshDrafts()
        let draft = try #require(try h.store.draft(account: h.account, gmailDraftID: GmailDraftID(gmailDraftID)))
        #expect(draft.content.attachments.map(\.filename) == ["plan.pdf"])
        #expect(draft.content.attachments.allSatisfy { $0.localPath == nil && $0.sourceAttachmentID == nil })
        #expect(!draft.isDirty)
        return draft
    }

    @Test func aDraftWrittenInGmailWithAnAttachmentSends() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let draft = try await imported(h)
        let receipt = try h.store.send(draft.id, undoWindow: .seconds(10), origin: .app)
        await drainer.drainOnce()
        h.advancePast(receipt)
        let report = await drainer.drainOnce()
        #expect(report.succeeded == 1 && report.failed == 0)
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        #expect(await h.gmail.callCount(.updateDraft) == 0, "Gmail's own draft goes out as it is")
        #expect(try h.draft(draft.id).state == .sent)
    }

    @Test func editingSuchADraftInMailUploadsTheAttachmentBytesFromGmail() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: try h.client)
        let draft = try await imported(h)
        var content = draft.content
        content.subject = "Edited in Mail"
        _ = try h.store.updateDraft(draft.id, content: content, expectedVersion: nil)
        let saved = try await h.upload(draft.id, drainer: drainer)
        #expect(!saved.isDirty)
        let raw = try #require(h.uploads().last?.raw)
        #expect(raw.contains("Edited in Mail") && raw.contains("plan.pdf"))
        #expect(raw.contains(file.data.base64EncodedString()), "the bytes came from the Gmail draft")
    }

    @Test func anAttachmentMissingFromTheGmailDraftStillFailsClearly() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let draft = try await imported(h)
        var content = draft.content
        content.attachments.append(DraftAttachment(filename: "other.txt", mimeType: "text/plain", size: 4, isInline: false))
        _ = try h.store.updateDraft(draft.id, content: content, expectedVersion: nil)
        let op = try h.store.saveDraftRemotely(draft.id)
        await drainer.drainOnce()
        let item = try #require(try h.store.operation(op))
        #expect(item.status == .failed && item.lastErrorCode == "attachment_missing")
    }
}
