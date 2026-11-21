import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanMIME

@Suite struct HeaderAndAddressTests {
    @Test func rfc2047() {
        #expect(HeaderDecoder.decode("=?UTF-8?B?w6l0w6k=?=") == "été")
        #expect(HeaderDecoder.decode("=?iso-8859-1?Q?caf=E9_cr=E8me?=") == "café crème")
        #expect(HeaderDecoder.decode("=?UTF-8?Q?a?= =?UTF-8?Q?b?=") == "ab")
        #expect(HeaderDecoder.decode("Re: =?UTF-8?Q?r=C3=A9union?= today") == "Re: réunion today")
        #expect(HeaderDecoder.decode("=?UTF-8?X?bad?=") == "=?UTF-8?X?bad?=")
        #expect(HeaderDecoder.decode("plain subject") == "plain subject")
        #expect(HeaderDecoder.decode(HeaderDecoder.decode("=?UTF-8?B?w6l0w6k=?=")) == "été")
    }

    @Test func addressLists() {
        let raw = #"Alice Smith <alice@example.com>, "Doe, John" <john@example.com>, bob@example.com (Bob B), undisclosed-recipients:;"#
        let parsed = AddressParser.parseList(raw)
        #expect(parsed.addresses == [EmailAddress(name: "Alice Smith", email: "alice@example.com"),
                                     EmailAddress(name: "Doe, John", email: "john@example.com"),
                                     EmailAddress(name: "Bob B", email: "bob@example.com")])
        #expect(AddressParser.parseList("Smith, Jane <jane@example.com>").addresses
                == [EmailAddress(name: "Smith, Jane", email: "jane@example.com")])
        #expect(AddressParser.parseList("=?UTF-8?Q?Ren=C3=A9?= <rene@example.com>").addresses.first?.name == "René")
        #expect(AddressParser.parseList("team: a@example.com, b@example.com;, c@example.com").addresses.map(\.email)
                == ["a@example.com", "b@example.com", "c@example.com"])
        #expect(AddressParser.parseList("<only@example.com>").addresses == [EmailAddress(email: "only@example.com")])
        let broken = AddressParser.parseList("not an address")
        #expect(broken.addresses.isEmpty && !broken.warnings.isEmpty)
    }

    @Test func dates() {
        let expected = Date(timeIntervalSince1970: 1_057_049_557)
        for value in ["Tue, 1 Jul 2003 10:52:37 +0200", "1 Jul 2003 10:52:37 +0200", "Tue, 01 Jul 2003 08:52:37 GMT",
                      "Tue, 1 Jul 2003 08:52:37 +0000 (UTC)", "Tue,  1 Jul 03 10:52:37 +0200"] {
            #expect(MIMEDate.parse(value) == expected, "\(value)")
        }
        #expect(MIMEDate.parse("yesterday") == nil)
    }

    @Test func messageIDs() {
        #expect(HeaderDecoder.messageIDs("<a@x> <b@y>\r\n <c@z>") == ["<a@x>", "<b@y>", "<c@z>"])
        #expect(HeaderDecoder.messageIDs("bare@id") == ["bare@id"])
    }

    @Test func charsets() {
        #expect(CharsetDecoder.decode(Data([0x63, 0x61, 0x66, 0xE9]), declaredCharset: "ISO-8859-1") == ("café", nil))
        #expect(CharsetDecoder.decode(Data("é".utf8), declaredCharset: "\"utf8\"") == ("é", nil))
        let mislabeled = CharsetDecoder.decode(Data([0x80]), declaredCharset: "us-ascii")
        #expect(mislabeled.text == "€" && mislabeled.warning != nil)
        let unknown = CharsetDecoder.decode(Data("ok".utf8), declaredCharset: "x-made-up")
        #expect(unknown.text == "ok" && unknown.warning != nil)
        #expect(CharsetDecoder.decode(Data([0xFF, 0xFE, 0x41]), declaredCharset: nil).warning != nil)
    }

    @Test func htmlToText() {
        let html = "<html><head><title>t</title><style>p{}</style></head><body><p>Hello&nbsp;<b>world</b> &amp; co</p>"
            + "<script>alert(1)</script><!-- note --><div>Line&#33;</div><br>Tail &#x263A;</body></html>"
        #expect(HTMLText.extract(html) == "Hello world & co\nLine!\nTail ☺")
        #expect(HTMLText.extract("<p>abcdef</p>", maxBytes: 3) == "abc")
    }
}

@Suite struct PayloadParsingTests {
    private func leaf(_ id: String, _ type: String, _ text: String, charset: String = "UTF-8", extra: [MIMEHeaderField] = [],
                      filename: String? = nil) -> GmailPayloadPart {
        GmailPayloadPart(partID: id, mimeType: type, filename: filename ?? "",
                         headers: [MIMEHeaderField(name: "Content-Type", value: "\(type); charset=\"\(charset)\"")] + extra,
                         size: text.utf8.count, data: Base64URL.encode(Data(text.utf8)), parts: [])
    }

    private let top = [
        MIMEHeaderField(name: "From", value: "\"Ann Example\" <ann@example.com>"),
        MIMEHeaderField(name: "To", value: "me@example.com, Bo <bo@example.com>"),
        MIMEHeaderField(name: "Subject", value: "=?UTF-8?Q?Caf=C3=A9?= plans"),
        MIMEHeaderField(name: "Date", value: "Tue, 1 Jul 2003 10:52:37 +0200"),
        MIMEHeaderField(name: "Message-ID", value: "<m1@example.com>"),
        MIMEHeaderField(name: "References", value: "<r1@example.com> <r2@example.com>"),
        MIMEHeaderField(name: "In-Reply-To", value: "<r2@example.com>"),
        MIMEHeaderField(name: "List-Unsubscribe", value: "<mailto:u@example.com>"),
    ]

    @Test func metadataPayloadGivesHeadersOnly() throws {
        let parsed = try MIMEParser.parse(gmailPayload: GmailPayloadPart(mimeType: "text/plain", headers: top, parts: []))
        #expect(parsed.subject == "Café plans")
        #expect(parsed.from == EmailAddress(name: "Ann Example", email: "ann@example.com"))
        #expect(parsed.to.map(\.email) == ["me@example.com", "bo@example.com"])
        #expect(parsed.date == Date(timeIntervalSince1970: 1_057_049_557))
        #expect(parsed.messageID == "<m1@example.com>" && parsed.inReplyTo == "<r2@example.com>")
        #expect(parsed.references == ["<r1@example.com>", "<r2@example.com>"])
        #expect(parsed.listUnsubscribe == "<mailto:u@example.com>")
        #expect(parsed.htmlBody == nil && parsed.textBody == nil && parsed.attachments.isEmpty)
    }

    @Test func alternativePrefersHTMLAndKeepsText() throws {
        let root = GmailPayloadPart(partID: "", mimeType: "multipart/alternative", headers: top,
                                    parts: [leaf("0", "text/plain", "Plain"), leaf("1", "text/html", "<p>Rich</p>")])
        let parsed = try MIMEParser.parse(gmailPayload: root)
        #expect(parsed.htmlBody == "<p>Rich</p>" && parsed.textBody == "Plain")
    }

    @Test func relatedWithInlineImageInsideMixedWithAttachment() throws {
        let image = GmailPayloadPart(partID: "0.1.1", mimeType: "image/png", filename: "logo.png",
                                     headers: [MIMEHeaderField(name: "Content-ID", value: "<logo@x>"),
                                               MIMEHeaderField(name: "Content-Disposition", value: "inline")],
                                     attachmentID: "ATT1", size: 120, parts: [])
        let related = GmailPayloadPart(partID: "0.1", mimeType: "multipart/related", headers: [],
                                       parts: [leaf("0.1.0", "text/html", "<img src=\"cid:logo@x\">"), image])
        let alternative = GmailPayloadPart(partID: "0", mimeType: "multipart/alternative", headers: [],
                                           parts: [leaf("0.0", "text/plain", "See logo"), related])
        let pdf = GmailPayloadPart(partID: "1", mimeType: "application/pdf", filename: "report.pdf",
                                   headers: [MIMEHeaderField(name: "Content-Disposition", value: "attachment; filename=\"report.pdf\"")],
                                   attachmentID: "ATT2", size: 2048, parts: [])
        let footer = leaf("2", "text/plain", "Footer")
        let root = GmailPayloadPart(partID: "", mimeType: "multipart/mixed", headers: top, parts: [alternative, pdf, footer])
        let parsed = try MIMEParser.parse(gmailPayload: root)
        #expect(parsed.htmlBody?.hasPrefix("<img src=\"cid:logo@x\">") == true)
        #expect(parsed.textBody == "See logo\n\nFooter")
        #expect(parsed.attachments.map(\.filename) == ["logo.png", "report.pdf"])
        #expect(parsed.attachments[0].isInline && parsed.attachments[0].contentID == "logo@x")
        #expect(!parsed.attachments[1].isInline && parsed.attachments[1].gmailAttachmentID == "ATT2")
    }

    @Test func aTextPartAfterAnHTMLBodyKeepsItsLineBreaks() throws {
        let root = GmailPayloadPart(partID: "", mimeType: "multipart/mixed", headers: top,
                                    parts: [leaf("0", "text/html", "<p>Rich</p>"), leaf("1", "text/plain", "List footer\n<unsubscribe>")])
        let parsed = try MIMEParser.parse(gmailPayload: root)
        #expect(parsed.htmlBody
            == "<p>Rich</p><hr><div style=\"white-space:pre-wrap\">List footer\n&lt;unsubscribe&gt;</div>")
        #expect(parsed.textBody == "List footer\n<unsubscribe>")
    }

    @Test func latin1BodyAndCalendarPart() throws {
        var body = leaf("0", "text/plain", "", charset: "iso-8859-1")
        body.data = Base64URL.encode(Data([0x63, 0x61, 0x66, 0xE9]))
        let ics = leaf("1", "text/calendar", "BEGIN:VCALENDAR\r\nEND:VCALENDAR")
        let root = GmailPayloadPart(partID: "", mimeType: "multipart/mixed", headers: top, parts: [body, ics])
        let parsed = try MIMEParser.parse(gmailPayload: root)
        #expect(parsed.textBody == "café")
        #expect(parsed.calendarParts.count == 1 && parsed.attachments.first?.filename == "invite.ics")
    }

    @Test func encryptedMessageHasNoBody() throws {
        let root = GmailPayloadPart(partID: "", mimeType: "multipart/encrypted", headers: top,
                                    parts: [leaf("0", "application/pgp-encrypted", "Version: 1")])
        let parsed = try MIMEParser.parse(gmailPayload: root)
        #expect(parsed.htmlBody == nil && parsed.textBody == nil && parsed.warnings.contains("encrypted message"))
    }
}
