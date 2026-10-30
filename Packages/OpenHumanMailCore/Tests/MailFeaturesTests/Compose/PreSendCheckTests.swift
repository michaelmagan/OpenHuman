import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@Suite struct PreSendCheckRuleTests {
    private func issues(subject: String = "Plan", body: String = "Hello", quote: String = "", forwards: Bool = false,
                        hasAttachments: Bool = false) -> [PreSendIssue] {
        PreSendCheck.issues(subject: subject, body: body, quote: quote, forwards: forwards, hasAttachments: hasAttachments)
    }

    @Test func anEmptyBodyOrSubjectIsFlaggedAndANormalMessageIsNot() {
        #expect(issues().isEmpty)
        #expect(issues(body: " \n\t ") == [.noBody])
        #expect(issues(subject: "  ") == [.noSubject])
        #expect(issues(subject: "", body: "") == [.noSubject, .noBody])
        #expect(issues(body: "", hasAttachments: true).isEmpty, "a file alone is a message")
        #expect(issues(body: "", quote: "On Mon, Dana wrote:\n> hi") == [.noBody], "a reply's quote is not a reply")
        #expect(issues(body: "", quote: "---------- Forwarded message ---------\nhi", forwards: true).isEmpty,
                "a forward carries the original")
        #expect(issues(body: "", quote: " ", forwards: true) == [.noBody])
        #expect(issues(body: "\n---------- Forwarded message ---------\nFrom: Dana", forwards: true).isEmpty,
                "a plain-text forward keeps the original in the body")
    }

    @Test func aMentionedAttachmentIsFlaggedOnlyWhenNothingIsAttached() {
        for text in ["Please see the ATTACHED plan.", "Attachments: two", "I attach the notes", "Enclosed is the form",
                     "The attachment, as promised"] {
            #expect(PreSendCheck.mentionsAttachment(text), "\(text)")
        }
        for text in ["I'll send it later", "Unattached thoughts", "Thanks!"] {
            #expect(!PreSendCheck.mentionsAttachment(text), "\(text)")
        }
        #expect(!PreSendCheck.mentionsAttachment("Sounds good.\n> see the attached file"), "quoted lines are not checked")
        #expect(!PreSendCheck.mentionsAttachment("Sounds good.\n---------- Forwarded message ---------\nSee attached"))
        #expect(!PreSendCheck.mentionsAttachment("Sounds good.\n-- \nAttachments are scanned"), "nor the signature")
        #expect(issues(body: "The report is attached.") == [.missingAttachment])
        #expect(issues(body: "The report is attached.", hasAttachments: true).isEmpty)
        #expect(issues(subject: "", body: "The report is attached.") == [.noSubject, .missingAttachment])
    }

    @Test func theWarningNamesWhatIsMissingAndHowItGoesOut() throws {
        #expect(PreSendWarning(issues: [], kind: .send) == nil)
        let empty = try #require(PreSendWarning(issues: [.noSubject, .noBody], kind: .send))
        #expect(empty.title == "Send without a subject or text?" && empty.confirmTitle == "Send Anyway")
        #expect(try #require(PreSendWarning(issues: [.noBody], kind: .send)).title == "Send without any text?")
        #expect(try #require(PreSendWarning(issues: [.noSubject], kind: .send)).title == "Send without a subject?")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let file = try #require(PreSendWarning(issues: [.noSubject, .missingAttachment], kind: .schedule(at)))
        #expect(file.title == "Send without an attachment?" && file.message.hasSuffix("It also has no subject."))
        #expect(file.kind == .schedule(at) && file.confirmTitle == "Schedule Anyway")
        #expect(PreSendWarning.keepWritingTitle == "Keep Writing")
    }
}

@MainActor
@Suite struct PreSendCheckFlowTests {
    private func message(_ f: ComposeFixture, subject: String, body: String) throws -> ComposeSession {
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.subject = subject
        if !body.isEmpty { session.updateBody(doc(body)) }
        return session
    }

    private func sends(_ f: ComposeFixture) -> Int { f.recorder.calls.filter { $0 == "send" }.count }

    @Test func anEmptyMessageAsksFirstAndSendAnywayKeepsTheUndoWindow() async throws {
        let f = ComposeFixture(isLiveAccount: true)
        await f.loaded()
        let session = try message(f, subject: "Synthetic", body: "")
        #expect(await f.run(.send, in: session))
        let warning = try #require(session.preSendWarning)
        #expect(warning.issues == [.noBody] && warning.kind == .send)
        #expect(sends(f) == 0, "nothing reaches the port before the user decides")
        session.cancelPreSendWarning()
        #expect(session.preSendWarning == nil && session.isOpen && sends(f) == 0, "Keep Writing goes back to the draft")

        #expect(await f.run(.send, in: session))
        let again = try #require(session.preSendWarning, "it asks again on the next send")
        f.compose.confirmPreSendWarning(again, in: session)
        await soon { self.sends(f) == 1 }
        await f.toast("Sending to ")
        #expect(await f.run(.undo))
        await soon { f.recorder.calls.contains("cancelSend") && session.isOpen }
        #expect(f.store.sentMessages.isEmpty, "the undo window still holds it")
    }

    @Test func aWrittenMessageSendsWithoutAPrompt() async throws {
        let f = ComposeFixture(isLiveAccount: true)
        await f.loaded()
        let session = try message(f, subject: "Synthetic", body: "Hello")
        #expect(await f.run(.send, in: session))
        #expect(session.preSendWarning == nil)
        await soon { self.sends(f) == 1 }
    }

    @Test func aMentionedButMissingFileAsksAndAFileClearsIt() async throws {
        let f = ComposeFixture(isLiveAccount: true)
        await f.loaded()
        let session = try message(f, subject: "Synthetic", body: "The plan is attached.")
        #expect(await f.run(.send, in: session))
        #expect(session.preSendWarning?.issues == [.missingAttachment])
        session.cancelPreSendWarning()
        session.addOriginalAttachments([AttachmentInfo(id: 41, filename: "plan.pdf", mimeType: "application/pdf",
                                                       size: 2_048, contentID: nil, isInline: false)])
        #expect(session.preSendIssues.isEmpty)
        #expect(await f.run(.send, in: session))
        #expect(session.preSendWarning == nil)
        await soon { self.sends(f) == 1 }
    }

    @Test func sendLaterWithoutASubjectAsksAndScheduleAnywaySchedules() async throws {
        let f = ComposeFixture(isLiveAccount: true)
        await f.loaded()
        let at = fixedNow.addingTimeInterval(3_600)
        let session = try message(f, subject: "", body: "Later")
        await f.compose.schedule(session, at: at)
        let warning = try #require(session.preSendWarning)
        #expect(warning.issues == [.noSubject] && warning.kind == .schedule(at) && warning.confirmTitle == "Schedule Anyway")
        #expect(!f.recorder.calls.contains("scheduleSend"))
        f.compose.confirmPreSendWarning(warning, in: session)
        await soon { f.recorder.calls.contains("scheduleSend") }
        await f.toast("Scheduled for ")
    }

    @Test func fakeDataNeverAsks() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try message(f, subject: "", body: "")
        #expect(await f.run(.send, in: session))
        #expect(session.preSendWarning == nil)
        await soon { self.sends(f) == 1 }
    }

    @Test func aForwardWithoutANoteSendsWithoutAPrompt() async throws {
        let f = ComposeFixture(isLiveAccount: true)
        await f.loaded()
        let key = try #require(f.router.list?.cursor)
        let session = try #require(f.compose.openReply(key, mode: .forward))
        await session.settle()
        await soon { !session.quotedHTML.isEmpty }
        session.to.text = "sam@acme.example,"
        #expect(session.preSendIssues.isEmpty)
        #expect(await f.run(.send, in: session))
        #expect(session.preSendWarning == nil)
        await soon { self.sends(f) == 1 }
    }
}

@MainActor
@Suite struct ForwardAttachmentTests {
    @Test func aForwardShowsTheOriginalFilesAndKeepsWhatIsLeftAfterARemoval() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let rows = try await f.store.threadPage(.system(.allMail), account: ComposeFixture.work, after: nil, limit: 1_000).rows
        var found: (ThreadKey, [AttachmentInfo])?
        for row in rows where row.attachmentCount > 0 {
            var detail: ConversationDetail?
            for try await value in f.store.threadDetail(row.id) {
                detail = value
                break
            }
            let files = detail?.messages.last?.attachments.filter { !$0.isInline } ?? []
            if !files.isEmpty {
                found = (row.id, files)
                break
            }
        }
        let (key, files) = try #require(found)
        let session = try #require(f.compose.openReply(key, mode: .forward))
        await session.settle()
        await soon { !session.quotedHTML.isEmpty }
        #expect(session.fileAttachments.compactMap(\.sourceAttachmentID) == files.map(\.id))
        #expect(session.quotedHTML.contains("Forwarded message"))

        let removed = try #require(session.fileAttachments.first)
        session.removeAttachment(removed)
        await session.settle()
        let draftKey = try #require(session.draftKey)
        let draft = try #require(await f.draftRow(draftKey))
        #expect(draft.fields.attachments.compactMap(\.sourceAttachmentID) == files.dropFirst().map(\.id))
        #expect(session.assembledFields().attachments.compactMap(\.sourceAttachmentID) == files.dropFirst().map(\.id))
    }
}
