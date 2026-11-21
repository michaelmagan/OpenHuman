import Foundation
import OpenHumanCore

public enum MIMEParser {
    public static func parse(gmailPayload root: GmailPayloadPart) throws -> ParsedMessage {
        try parse(gmailPayload: root, initialWarnings: [])
    }

    public static func parse(rfc822 data: Data) throws -> ParsedMessage {
        guard data.count <= RFC822.maxInputBytes else { throw MIMEError.tooLarge(bytes: data.count) }
        guard !data.isEmpty else { throw MIMEError.malformed("empty message") }
        let bytes = [UInt8](data)
        var state = RFC822.State()
        let root = RFC822.buildPart(bytes, 0, bytes.count, depth: 0, partID: "", state: &state)
        guard !root.headers.isEmpty else { throw MIMEError.malformed("no header fields") }
        return try parse(gmailPayload: root, initialWarnings: state.warnings)
    }

    static func parse(gmailPayload root: GmailPayloadPart, initialWarnings: [String]) throws -> ParsedMessage {
        var warnings: [String] = initialWarnings
        let rawHeaders = root.headers
        let headers = MIMEHeaders(fields: rawHeaders.map { MIMEHeaderField(name: $0.name, value: HeaderDecoder.decode($0.value)) })
        let raw = MIMEHeaders(fields: rawHeaders)

        func addresses(_ name: String) -> [EmailAddress] {
            var all: [EmailAddress] = []
            for value in raw.values(name) {
                let parsed = AddressParser.parseList(value)
                all += parsed.addresses
                warnings += parsed.warnings.map { "\(name.lowercased()): \($0)" }
            }
            return all
        }
        let from = addresses("From").first
        let date = raw["Date"].flatMap { value -> Date? in
            let parsed = MIMEDate.parse(value)
            if parsed == nil { warnings.append("date: unparseable") }
            return parsed
        }
        var body = BodyCollector()
        if root.data != nil || !root.parts.isEmpty || root.attachmentID != nil {
            body.walk(root, inRelated: false)
        }
        warnings += body.warnings
        return ParsedMessage(
            headers: headers,
            subject: headers["Subject"] ?? "",
            from: from, to: addresses("To"), cc: addresses("Cc"), bcc: addresses("Bcc"), replyTo: addresses("Reply-To"),
            date: date,
            messageID: raw["Message-ID"].flatMap { HeaderDecoder.messageIDs($0).first },
            inReplyTo: raw["In-Reply-To"].flatMap { HeaderDecoder.messageIDs($0).first },
            references: raw["References"].map(HeaderDecoder.messageIDs) ?? [],
            listID: headers["List-Id"], listUnsubscribe: headers["List-Unsubscribe"],
            listUnsubscribePost: headers["List-Unsubscribe-Post"],
            htmlBody: body.html, textBody: body.text,
            attachments: body.attachments, calendarParts: body.calendar, warnings: warnings,
            textFormat: body.textFormat)
    }
}

struct BodyCollector {
    var html: String?
    var text: String?
    var textFormat: TextPartFormat = .fixed
    var attachments: [ParsedAttachment] = []
    var calendar: [String] = []
    var warnings: [String] = []

    private struct Display {
        var html: String?
        var text: String?
        var textFormat: TextPartFormat = .fixed
    }

    static let maxDepth = 64
    private var depth = 0

    mutating func walk(_ part: GmailPayloadPart, inRelated: Bool) {
        let display = collect(part, inRelated: inRelated)
        html = display.html
        text = display.text
        textFormat = display.text == nil ? .fixed : display.textFormat
    }

    private mutating func collect(_ part: GmailPayloadPart, inRelated: Bool) -> Display {
        if depth >= Self.maxDepth {
            if !warnings.contains("nesting too deep") { warnings.append("nesting too deep") }
            return Display()
        }
        depth += 1
        defer { depth -= 1 }
        let type = (part.mimeType ?? contentType(part)?.type ?? "text/plain").lowercased()
        if type.hasPrefix("multipart/") {
            switch type {
            case "multipart/alternative": return alternative(part)
            case "multipart/related": return related(part)
            case "multipart/signed": return part.parts.first.map { collect($0, inRelated: inRelated) } ?? Display()
            case "multipart/encrypted":
                warnings.append("encrypted message")
                return Display()
            default: return mixed(part)
            }
        }
        if isAttachment(part) {
            addAttachment(part, inRelated: inRelated)
            return Display()
        }
        switch type {
        case "text/html": return Display(html: decodeText(part), text: nil)
        case "text/plain": return Display(html: nil, text: decodeText(part), textFormat: partTextFormat(part))
        case "text/calendar":
            if let ics = decodeText(part) { calendar.append(ics) }
            addAttachment(part, inRelated: inRelated, defaultName: "invite.ics")
            return Display()
        case "message/rfc822":
            addAttachment(part, inRelated: inRelated, defaultName: "message.eml")
            return Display()
        default:
            addAttachment(part, inRelated: inRelated)
            return Display()
        }
    }

    private mutating func alternative(_ part: GmailPayloadPart) -> Display {
        var result = Display()
        for child in part.parts {
            let d = collect(child, inRelated: false)
            if let h = d.html { result.html = h }
            if let t = d.text {
                result.text = t
                result.textFormat = d.textFormat
            }
        }
        return result
    }

    private mutating func related(_ part: GmailPayloadPart) -> Display {
        guard !part.parts.isEmpty else { return Display() }
        var rootIndex = 0
        if let start = contentType(part)?.params["start"] {
            let wanted = start.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            if let i = part.parts.firstIndex(where: { contentID($0) == wanted }) { rootIndex = i }
        }
        var result = Display()
        for (i, child) in part.parts.enumerated() {
            if i == rootIndex {
                result = collect(child, inRelated: true)
            } else {
                _ = collect(child, inRelated: true)
            }
        }
        return result
    }

    private mutating func mixed(_ part: GmailPayloadPart) -> Display {
        var result = Display()
        var haveBody = false
        for child in part.parts {
            let d = collect(child, inRelated: false)
            if !haveBody {
                if d.html != nil || d.text != nil { result = d; haveBody = true }
                continue
            }
            if let h = d.html { result.html = (result.html ?? result.text.map(Self.htmlBlock) ?? "") + "<hr>" + h }
            if let t = d.text {
                if result.text != nil, result.textFormat != d.textFormat { result.textFormat = .fixed }
                if result.text == nil { result.textFormat = d.textFormat }
                result.text = result.text.map { $0 + "\n\n" + t } ?? t
                if d.html == nil, let existing = result.html { result.html = existing + "<hr>" + Self.htmlBlock(t) }
            }
        }
        return result
    }

    private func isAttachment(_ part: GmailPayloadPart) -> Bool {
        let disposition = header(part, "Content-Disposition")?.lowercased() ?? ""
        if disposition.hasPrefix("attachment") { return true }
        if let name = part.filename, !name.isEmpty { return true }
        return false
    }

    private mutating func addAttachment(_ part: GmailPayloadPart, inRelated: Bool, defaultName: String? = nil) {
        let disposition = header(part, "Content-Disposition")?.lowercased() ?? ""
        let cid = contentID(part)
        let inline = disposition.hasPrefix("inline") || (inRelated && cid != nil)
        var name = part.filename ?? ""
        if name.isEmpty {
            name = header(part, "Content-Disposition").flatMap { ContentType.parse($0).params["filename"] }
                .map(HeaderDecoder.decode) ?? ""
        }
        if name.isEmpty { name = contentType(part)?.params["name"].map(HeaderDecoder.decode) ?? "" }
        if name.isEmpty, (part.mimeType ?? "").lowercased() == "message/rfc822",
           let subject = embeddedSubject(part), !subject.isEmpty {
            name = Self.safeFileName(subject) + ".eml"
        }
        if name.isEmpty { name = defaultName ?? "" }
        let mime = (part.mimeType ?? "application/octet-stream").lowercased()
        let data = part.data.flatMap { Base64URL.decode($0) }
        attachments.append(ParsedAttachment(partID: part.partID ?? "", filename: name, mimeType: mime,
                                            size: part.size ?? data?.count ?? 0, contentID: cid, isInline: inline,
                                            gmailAttachmentID: part.attachmentID, inlineData: data))
    }

    private mutating func decodeText(_ part: GmailPayloadPart) -> String? {
        guard let encoded = part.data else {
            if part.attachmentID != nil { warnings.append("body part stored as an attachment") }
            return part.size == 0 ? "" : nil
        }
        guard let bytes = Base64URL.decode(encoded) else {
            warnings.append("body part is not base64url")
            return nil
        }
        let decoded = CharsetDecoder.decode(bytes, declaredCharset: contentType(part)?.params["charset"])
        if let warning = decoded.warning { warnings.append(warning) }
        return decoded.text
    }

    private func embeddedSubject(_ part: GmailPayloadPart) -> String? {
        guard let encoded = part.data, let data = Base64URL.decode(String(encoded.prefix(64 * 1024 * 4 / 3 + 4))) else {
            return nil
        }
        let bytes = [UInt8](data.prefix(64 * 1024))
        var state = RFC822.State()
        let fields = RFC822.parseHeaders(bytes, 0, bytes.count, &state).fields
        return RFC822.value(fields, "Subject").map { HeaderDecoder.decode($0) }
    }

    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.map { bad.contains($0) ? "_" : $0 }.prefix(120)))
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    private func header(_ part: GmailPayloadPart, _ name: String) -> String? {
        MIMEHeaders(fields: part.headers)[name]
    }

    private func contentID(_ part: GmailPayloadPart) -> String? {
        header(part, "Content-ID").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t")) }
    }

    private func partTextFormat(_ part: GmailPayloadPart) -> TextPartFormat {
        guard let params = contentType(part)?.params,
              params["format"]?.trimmingCharacters(in: .whitespaces).lowercased() == "flowed" else { return .fixed }
        return .flowed(delSp: params["delsp"]?.trimmingCharacters(in: .whitespaces).lowercased() == "yes")
    }

    private func contentType(_ part: GmailPayloadPart) -> (type: String, params: [String: String])? {
        header(part, "Content-Type").map(ContentType.parse)
    }

    // A text part joined to an HTML body keeps its line breaks
    static func htmlBlock(_ text: String) -> String {
        "<div style=\"white-space:pre-wrap\">" + htmlEscape(text) + "</div>"
    }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
