import Foundation
import OpenHumanCore
import OpenHumanGmail

public struct FakeGmailAttachment: Sendable, Hashable {
    public var filename: String
    public var mimeType: String
    public var data: Data
    public var contentID: String?

    public init(filename: String, mimeType: String, data: Data, contentID: String? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
    }

    public static let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
}

extension FakeGmail {
    static func payload(headers: [GmailHeader], text: String, html: String?, attachments: [FakeGmailAttachment],
                        messageID: String) -> (GmailMessagePart, [String: Data]) {
        var stored: [String: Data] = [:]
        func leaf(_ id: String, _ type: String, _ content: String) -> GmailMessagePart {
            GmailMessagePart(partId: id, mimeType: type, filename: "",
                             headers: [GmailHeader(name: "Content-Type", value: "\(type); charset=\"UTF-8\"")],
                             body: GmailMessagePartBody(size: content.utf8.count, data: Base64URL.encode(Data(content.utf8))))
        }
        func bodyPart(_ id: String) -> GmailMessagePart {
            guard let html else { return leaf(id, "text/plain", text) }
            return GmailMessagePart(partId: id, mimeType: "multipart/alternative", filename: "",
                                    headers: [GmailHeader(name: "Content-Type", value: "multipart/alternative; boundary=\"alt\"")],
                                    body: GmailMessagePartBody(size: 0),
                                    parts: [leaf("\(id).0", "text/plain", text), leaf("\(id).1", "text/html", html)])
        }
        func filePart(_ id: String, _ attachment: FakeGmailAttachment, index: Int) -> GmailMessagePart {
            let attachmentID = "ANGjdJ-fake-\(messageID)-\(index)"
            stored[attachmentID] = attachment.data
            var partHeaders = [
                GmailHeader(name: "Content-Type", value: "\(attachment.mimeType); name=\"\(attachment.filename)\""),
                GmailHeader(name: "Content-Transfer-Encoding", value: "base64"),
            ]
            if let cid = attachment.contentID {
                partHeaders.append(GmailHeader(name: "Content-Disposition", value: "inline; filename=\"\(attachment.filename)\""))
                partHeaders.append(GmailHeader(name: "Content-ID", value: "<\(cid)>"))
            } else {
                partHeaders.append(GmailHeader(name: "Content-Disposition", value: "attachment; filename=\"\(attachment.filename)\""))
            }
            return GmailMessagePart(partId: id, mimeType: attachment.mimeType, filename: attachment.filename,
                                    headers: partHeaders,
                                    body: GmailMessagePartBody(attachmentId: attachmentID, size: attachment.data.count))
        }
        let inline = attachments.filter { $0.contentID != nil }
        let files = attachments.filter { $0.contentID == nil }
        var index = 0
        let first: GmailMessagePart
        if inline.isEmpty {
            first = bodyPart("0")
        } else {
            var related = [bodyPart("0.0")]
            for (n, attachment) in inline.enumerated() {
                related.append(filePart("0.\(n + 1)", attachment, index: index))
                index += 1
            }
            first = GmailMessagePart(partId: "0", mimeType: "multipart/related", filename: "",
                                     headers: [GmailHeader(name: "Content-Type", value: "multipart/related; boundary=\"rel\"")],
                                     body: GmailMessagePartBody(size: 0), parts: related)
        }
        var parts = [first]
        for (n, attachment) in files.enumerated() {
            parts.append(filePart("\(n + 1)", attachment, index: index))
            index += 1
        }
        let root = GmailMessagePart(partId: "", mimeType: "multipart/mixed", filename: "",
                                    headers: headers + [GmailHeader(name: "Content-Type", value: "multipart/mixed; boundary=\"mix\"")],
                                    body: GmailMessagePartBody(size: 0), parts: parts)
        return (root, stored)
    }
}

extension FakeGmail {
    @discardableResult
    public func seedDraft(to: String = "bob@example.com", subject: String = "Synthetic draft",
                          body: String = "Synthetic draft body.",
                          attachments: [FakeGmailAttachment] = []) -> (draftID: String, messageID: String) {
        let (messageID, _) = deliver(from: accountEmail, to: to, subject: subject, body: body, labels: ["DRAFT"],
                                     attachments: attachments)
        let draftID = "r" + nextID()
        drafts[draftID] = messageID
        return (draftID, messageID)
    }
}
