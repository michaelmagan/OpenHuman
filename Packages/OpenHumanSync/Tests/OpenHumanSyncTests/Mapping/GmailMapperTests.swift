import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct GmailMapperTests {
    private func header(_ n: String, _ v: String) -> GmailHeader { GmailHeader(name: n, value: v) }

    private var headers: [GmailHeader] {
        [header("From", "Ann Example <ann@example.com>"), header("To", "me@example.com"),
         header("Subject", "=?UTF-8?Q?Caf=C3=A9?="), header("Date", "Tue, 1 Jul 2003 10:52:37 +0200"),
         header("Message-ID", "<m1@example.com>"), header("List-Id", "<list.example.com>")]
    }

    private func message(payload: GmailMessagePart?) -> GmailMessage {
        GmailMessage(id: "m1", threadId: "t1", labelIds: ["INBOX", "UNREAD"], snippet: "Hi &amp; bye", historyId: "1200",
                     internalDate: "1789900060000", sizeEstimate: 900, payload: payload)
    }

    @Test func metadataGivesHeadersAndNoBody() throws {
        let u = try GmailMapper.messageUpsert(message(payload: GmailMessagePart(mimeType: "text/plain", headers: headers)),
                                              includeBody: false)
        #expect(u.gmailMessageID == GmailMessageID("m1") && u.gmailThreadID == GmailThreadID("t1"))
        #expect(u.historyID == HistoryID(1200) && u.internalDate == Date(timeIntervalSince1970: 1_789_900_060))
        #expect(u.labelIDs == [GmailLabelID("INBOX"), GmailLabelID("UNREAD")] && u.sizeEstimate == 900)
        #expect(u.headers?.subject == "Café" && u.headers?.from?.email == "ann@example.com")
        #expect(u.headers?.messageID == "<m1@example.com>" && u.headers?.listID == "<list.example.com>")
        #expect(u.body == nil && u.attachments == nil)
    }

    @Test func fullGivesBodyAndAttachments() throws {
        let html = GmailMessagePart(partId: "1", mimeType: "text/html",
                                    headers: [header("Content-Type", "text/html; charset=UTF-8")],
                                    body: GmailMessagePartBody(size: 15, data: Base64URL.encode(Data("<p>Hello</p>".utf8))))
        let pdf = GmailMessagePart(partId: "2", mimeType: "application/pdf", filename: "a.pdf",
                                   headers: [header("Content-Disposition", "attachment; filename=a.pdf")],
                                   body: GmailMessagePartBody(attachmentId: "ATT", size: 3000))
        let root = GmailMessagePart(partId: "", mimeType: "multipart/mixed", headers: headers, parts: [html, pdf])
        let u = try GmailMapper.messageUpsert(message(payload: root), includeBody: true)
        #expect(u.body?.html == "<p>Hello</p>" && u.body?.text == nil && u.body?.searchText == "Hello")
        #expect(u.attachments?.map(\.filename) == ["a.pdf"] && u.attachments?.first?.gmailAttachmentID == "ATT")
        let noBody = try GmailMapper.messageUpsert(message(payload: root), includeBody: false)
        #expect(noBody.body == nil && noBody.attachments == nil && noBody.headers != nil)
    }

    @Test func minimalIsLabelsOnlyAndRequiredFieldsAreChecked() throws {
        #expect(try GmailMapper.messageUpsert(message(payload: nil), includeBody: true).headers == nil)
        var broken = message(payload: nil)
        broken.internalDate = nil
        #expect(throws: GmailMapperError.missingField("messages/m1.internalDate")) {
            _ = try GmailMapper.messageUpsert(broken, includeBody: false)
        }
    }

    @Test func labelMapping() {
        let u = GmailMapper.labelUpsert(GmailLabel(id: "Label_3", name: "Clients/Acme", type: "user",
                                                   labelListVisibility: "labelShow",
                                                   color: GmailLabelColor(textColor: "#000000", backgroundColor: "#ffffff")))
        #expect(u.gmailLabelID == GmailLabelID("Label_3") && u.type == "user" && u.colorBackground == "#ffffff")
        #expect(GmailMapper.labelUpsert(GmailLabel(id: "INBOX", name: "INBOX", type: "system")).type == "system")
    }

    @Test func historyCoalescing() {
        func msg(_ id: String, _ labels: [String]? = nil) -> GmailMessage { GmailMessage(id: id, threadId: "t-\(id)", labelIds: labels) }
        let records = [
            GmailHistoryRecord(id: "105", labelsRemoved: [GmailHistoryLabelChange(message: msg("old", ["UNREAD"]), labelIds: ["INBOX"])]),
            GmailHistoryRecord(id: "101", messagesAdded: [GmailHistoryMessageRef(message: msg("a", ["INBOX", "UNREAD"]))]),
            GmailHistoryRecord(id: "102", labelsAdded: [GmailHistoryLabelChange(message: msg("a", ["INBOX", "STARRED"]), labelIds: ["STARRED"])]),
            GmailHistoryRecord(id: "103", messagesAdded: [GmailHistoryMessageRef(message: msg("b", ["DRAFT"]))]),
            GmailHistoryRecord(id: "104", messagesDeleted: [GmailHistoryMessageRef(message: msg("b"))]),
            GmailHistoryRecord(id: "106", labelsAdded: [GmailHistoryLabelChange(message: msg("old", ["Label_9"]), labelIds: ["Label_9"])]),
            GmailHistoryRecord(id: "107", messagesAdded: [GmailHistoryMessageRef(message: msg("a", ["INBOX"]))]),
        ]
        let batch = GmailMapper.labelDeltas(records, knownLabelIDs: ["INBOX", "UNREAD", "STARRED", "DRAFT"])
        #expect(batch.addedMessageIDs == ["a"])
        #expect(batch.deletedMessageIDs == ["b"] && batch.deleteHistoryID == HistoryID(104))
        #expect(batch.labelDeltas.map(\.gmailMessageID.rawValue) == ["old", "old"])
        #expect(batch.labelDeltas.map(\.historyID.rawValue) == [105, 106])
        #expect(batch.labelDeltas[0].removed == [GmailLabelID("INBOX")] && batch.labelDeltas[1].added == [GmailLabelID("Label_9")])
        #expect(batch.labelDeltas.allSatisfy { $0.fullSetIfKnown == nil })
        #expect(batch.addedLabelDeltas.map(\.gmailMessageID.rawValue) == ["a"])
        #expect(batch.addedLabelDeltas.first?.historyID == HistoryID(102))
        #expect(batch.addedLabelDeltas.first?.added == [GmailLabelID("STARRED")])
        #expect(batch.touchesDrafts && batch.unknownLabelIDs == ["Label_9"])
    }

    @Test func remoteDraftCarriesMarkersHeadersAndBody() throws {
        let text = GmailMessagePart(partId: "", mimeType: "text/plain",
                                    headers: [header("From", "me@example.com"), header("To", "Bo <bo@example.com>"),
                                              header("Subject", "Re: Plans"), header("In-Reply-To", "<p1@example.com>"),
                                              header("References", "<p0@example.com> <p1@example.com>"),
                                              header("x-openhuman-origin", " agent "),
                                              header("X-OpenHuman-Send-At", "2026-10-11T08:00:00Z"),
                                              header("X-Other", "ignored"),
                                              header("Content-Type", "text/plain; charset=UTF-8")],
                                    body: GmailMessagePartBody(size: 12, data: Base64URL.encode(Data("a < b\nc & d".utf8))))
        let draft = GmailDraft(id: "r1", message: GmailMessage(id: "dm1", threadId: "t9", labelIds: ["DRAFT"],
                                                               historyId: "1300", internalDate: "1789900060000",
                                                               payload: text))
        let u = try GmailMapper.remoteDraft(draft)
        #expect(u.gmailDraftID == GmailDraftID("r1") && u.gmailMessageID == GmailMessageID("dm1"))
        #expect(u.gmailThreadID == GmailThreadID("t9"))
        #expect(u.content.subject == "Re: Plans" && u.content.to.map(\.email) == ["bo@example.com"])
        #expect(u.content.bodyHTML == "a &lt; b<br>c &amp; d" && u.content.bodyText == "a < b\nc & d")
        #expect(u.extraHeaders == ["x-openhuman-origin": "agent", "X-OpenHuman-Send-At": "2026-10-11T08:00:00Z",
                                   "In-Reply-To": "<p1@example.com>", "References": "<p0@example.com> <p1@example.com>"])

        let quoted = "<p>New text</p><div class=\"gmail_quote\" data-oh-quote=\"1\">old</div>"
        let html = GmailMessagePart(partId: "", mimeType: "text/html",
                                    headers: [header("Subject", "S"), header("Content-Type", "text/html; charset=UTF-8")],
                                    body: GmailMessagePartBody(size: quoted.utf8.count, data: Base64URL.encode(Data(quoted.utf8))))
        let user = try GmailMapper.remoteDraft(GmailDraft(id: "r2", message: GmailMessage(id: "dm2", threadId: "t2",
                                                                                          payload: html)))
        #expect(user.content.bodyHTML == quoted && user.extraHeaders.isEmpty)
        #expect(throws: GmailMapperError.missingField("drafts/r3.message")) { _ = try GmailMapper.remoteDraft(GmailDraft(id: "r3")) }
    }
}
