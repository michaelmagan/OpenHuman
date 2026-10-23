import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanLinks
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct ComposeSafetyTests {
    @Test func aFileAttachedWhileTheReplyIsBeingPreparedIsKept() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let hold = Checkpoint()
        f.recorder.holdCreates(at: hold)
        let opening = Task { await f.run(.reply) }
        await hold.arrived()
        let session = try #require(f.compose.windowSession)
        let file = AttachmentInfo(id: 9_001, filename: "notes.pdf", mimeType: "application/pdf", size: 1_200, contentID: nil,
                                  isInline: false)
        #expect(session.addOriginalAttachments([file]) == 1)
        hold.release()
        _ = await opening.value
        await session.settle()
        #expect(session.attachments.map(\.filename).contains("notes.pdf"), "the skeleton arriving does not drop it")
        let key = try #require(session.draftKey)
        #expect(await session.save(force: true))
        #expect(await f.draftRow(key)?.fields.attachments.map(\.filename).contains("notes.pdf") == true)
    }

    @Test func sendLaterFromALinkAsksAboutTheRecipientsFirst() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.open(link: ComposePrefill(to: ["ana@example.com"], subject: "Invoice",
                                                                      body: "Synthetic body"), account: nil))
        await session.settle()
        let later = fixedNow.addingTimeInterval(7_200)
        await f.compose.schedule(session, at: later)
        #expect(session.isLinkConfirmationShown && session.linkScheduleDate == later)
        #expect(!f.recorder.calls.contains { $0.hasPrefix("scheduleSend") }, "nothing is queued before the check")

        session.editLinkRecipients()
        #expect(!session.isLinkConfirmationShown && session.linkScheduleDate == nil)

        await f.compose.schedule(session, at: later)
        f.compose.confirmLinkRecipients(in: session)
        await f.compose.settle()
        #expect(f.recorder.calls.contains("scheduleSend") && !f.recorder.calls.contains("send"),
                "confirming continues the schedule, never an immediate send")
        let key = try #require(session.draftKey)
        #expect(await f.draftRow(key)?.status == .scheduled)
    }
}
