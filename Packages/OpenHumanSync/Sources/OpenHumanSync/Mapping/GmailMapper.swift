import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanMIME
import OpenHumanStore

struct HistoryBatch: Sendable, Equatable {
    var addedMessageIDs: [String] = []
    var deletedMessageIDs: [String] = []
    var labelDeltas: [LabelDelta] = []
    // Why: a message this batch adds is fetched whole, unless it is already stored; then only these carry its changes
    var addedLabelDeltas: [LabelDelta] = []
    var touchesDrafts = false
    var unknownLabelIDs: Set<String> = []
    var deleteHistoryID: HistoryID?

    static func == (a: HistoryBatch, b: HistoryBatch) -> Bool {
        a.addedMessageIDs == b.addedMessageIDs && a.deletedMessageIDs == b.deletedMessageIDs
            && a.labelDeltas.map(DeltaKey.init) == b.labelDeltas.map(DeltaKey.init)
            && a.addedLabelDeltas.map(DeltaKey.init) == b.addedLabelDeltas.map(DeltaKey.init) && a.touchesDrafts == b.touchesDrafts
            && a.unknownLabelIDs == b.unknownLabelIDs && a.deleteHistoryID == b.deleteHistoryID
    }

    private struct DeltaKey: Equatable {
        var id: String, history: UInt64, added: [String], removed: [String], full: [String]?
        init(_ d: LabelDelta) {
            id = d.gmailMessageID.rawValue; history = d.historyID.rawValue
            added = d.added.map(\.rawValue); removed = d.removed.map(\.rawValue); full = d.fullSetIfKnown?.map(\.rawValue)
        }
    }
}

enum GmailMapperError: Error, Equatable {
    case missingField(String)
}

enum GmailMapper {
    // Why: unconfirmed whether history labelsAdded/Removed message.labelIds is the set after the change; deltas use add/remove only
    static let trustHistoryLabelSnapshots = false

    static let searchTextCap = 32 * 1024

    static func labelUpsert(_ l: GmailLabel) -> LabelUpsert {
        LabelUpsert(gmailLabelID: GmailLabelID(l.id), name: l.name, type: l.type == "system" ? "system" : "user",
                    colorBackground: l.color?.backgroundColor, colorText: l.color?.textColor,
                    labelListVisibility: l.labelListVisibility, messageListVisibility: l.messageListVisibility,
                    threadsTotal: l.threadsTotal, threadsUnread: l.threadsUnread)
    }

    static func messageUpsert(_ m: GmailMessage, includeBody: Bool) throws -> MessageUpsert {
        guard let thread = m.threadId else { throw GmailMapperError.missingField("messages/\(m.id).threadId") }
        guard let history = m.historyIDValue else { throw GmailMapperError.missingField("messages/\(m.id).historyId") }
        guard let date = m.internalDateValue else { throw GmailMapperError.missingField("messages/\(m.id).internalDate") }
        var upsert = MessageUpsert(gmailMessageID: GmailMessageID(m.id), gmailThreadID: GmailThreadID(thread),
                                   historyID: history, internalDate: date,
                                   labelIDs: (m.labelIds ?? []).map { GmailLabelID($0) },
                                   snippet: m.snippet ?? "", sizeEstimate: m.sizeEstimate ?? 0)
        guard let payload = m.payload else { return upsert }
        let parsed = try MIMEParser.parse(gmailPayload: payload.mimePart)
        upsert.headers = headers(parsed)
        if includeBody {
            let (body, attachments) = bodyUpsert(parsed)
            upsert.body = body
            upsert.attachments = attachments
        }
        return upsert
    }

    static func headers(_ p: ParsedMessage) -> MessageHeaderFields {
        MessageHeaderFields(subject: p.subject, from: p.from, to: p.to, cc: p.cc, bcc: p.bcc, replyTo: p.replyTo,
                            date: p.date, messageID: p.messageID, inReplyTo: p.inReplyTo, references: p.references,
                            listID: p.listID, listUnsubscribe: p.listUnsubscribe, listUnsubscribePost: p.listUnsubscribePost)
    }

    static func bodyTextFormat(_ format: TextPartFormat) -> BodyTextFormat {
        switch format {
        case .fixed: .fixed
        case .flowed(let delSp): delSp ? .flowedDelSp : .flowed
        }
    }

    static func bodyUpsert(_ parsed: ParsedMessage) -> (MessageBodyUpsert, [AttachmentUpsert]) {
        let format = bodyTextFormat(parsed.textFormat)
        let logical = parsed.textBody.map { text -> String in
            switch parsed.textFormat {
            case .fixed: text
            case .flowed(let delSp): FlowedText.decode(text, delSp: delSp)
            }
        }
        let text = logical ?? parsed.htmlBody.map { HTMLText.extract($0) } ?? ""
        let body = MessageBodyUpsert(html: parsed.htmlBody, text: parsed.textBody,
                                     hasCalendarInvite: hasCalendarPart(parsed), decodeWarnings: parsed.warnings,
                                     searchText: utf8Prefix(text, maxBytes: searchTextCap),
                                     textFormat: parsed.textBody == nil ? .fixed : format)
        let attachments = parsed.attachments.map {
            AttachmentUpsert(partID: $0.partID, gmailAttachmentID: $0.gmailAttachmentID, filename: $0.filename,
                             mimeType: $0.mimeType, size: $0.size, contentID: $0.contentID, isInline: $0.isInline)
        }
        return (body, attachments)
    }

    static func hasCalendarPart(_ parsed: ParsedMessage) -> Bool {
        if !parsed.calendarParts.isEmpty { return true }
        return parsed.attachments.contains { a in
            let mime = a.mimeType.lowercased()
            return mime == "text/calendar" || mime == "application/ics" || a.filename.lowercased().hasSuffix(".ics")
        }
    }

    static func labelDeltas(_ records: [GmailHistoryRecord], knownLabelIDs: Set<String>) -> HistoryBatch {
        var batch = HistoryBatch()
        var added: [String] = [], addedSet = Set<String>()
        var deletedSet = Set<String>()
        var deltas: [LabelDelta] = []
        var maxDelete: UInt64?
        func note(_ message: GmailMessage, _ labels: [String]) {
            let all = (message.labelIds ?? []) + labels
            if all.contains("DRAFT") { batch.touchesDrafts = true }
            for id in all where !knownLabelIDs.contains(id) { batch.unknownLabelIDs.insert(id) }
        }
        let ordered = records.sorted { (UInt64($0.id) ?? 0) < (UInt64($1.id) ?? 0) }
        for record in ordered {
            let h = UInt64(record.id) ?? 0
            for ref in record.messagesAdded ?? [] {
                note(ref.message, [])
                if addedSet.insert(ref.message.id).inserted { added.append(ref.message.id) }
            }
            for ref in record.messagesDeleted ?? [] {
                note(ref.message, [])
                if deletedSet.insert(ref.message.id).inserted { batch.deletedMessageIDs.append(ref.message.id) }
                maxDelete = max(maxDelete ?? 0, h)
            }
            for change in record.labelsAdded ?? [] {
                note(change.message, change.labelIds)
                deltas.append(LabelDelta(gmailMessageID: GmailMessageID(change.message.id), historyID: HistoryID(h),
                                         added: change.labelIds.map { GmailLabelID($0) }, removed: [],
                                         fullSetIfKnown: snapshot(change.message)))
            }
            for change in record.labelsRemoved ?? [] {
                note(change.message, change.labelIds)
                deltas.append(LabelDelta(gmailMessageID: GmailMessageID(change.message.id), historyID: HistoryID(h),
                                         added: [], removed: change.labelIds.map { GmailLabelID($0) },
                                         fullSetIfKnown: snapshot(change.message)))
            }
        }
        batch.addedMessageIDs = added.filter { !deletedSet.contains($0) }
        batch.labelDeltas = deltas.filter {
            !addedSet.contains($0.gmailMessageID.rawValue) && !deletedSet.contains($0.gmailMessageID.rawValue)
        }
        batch.addedLabelDeltas = deltas.filter {
            addedSet.contains($0.gmailMessageID.rawValue) && !deletedSet.contains($0.gmailMessageID.rawValue)
        }
        batch.deleteHistoryID = maxDelete.map { HistoryID($0) }
        return batch
    }

    static func remoteDraft(_ d: GmailDraft) throws -> RemoteDraftUpsert {
        guard let m = d.message else { throw GmailMapperError.missingField("drafts/\(d.id).message") }
        guard let thread = m.threadId else { throw GmailMapperError.missingField("drafts/\(d.id).message.threadId") }
        guard let payload = m.payload else { throw GmailMapperError.missingField("drafts/\(d.id).message.payload") }
        let parsed = try MIMEParser.parse(gmailPayload: payload.mimePart)
        var extra: [String: String] = [:]
        for field in parsed.headers.fields {
            let lower = field.name.lowercased()
            guard lower.hasPrefix("x-openhuman-") || lower == "in-reply-to" || lower == "references" else { continue }
            if extra.keys.contains(where: { $0.lowercased() == lower }) { continue }
            extra[field.name] = field.value.trimmingCharacters(in: .whitespaces)
        }
        var text = parsed.textBody
        var plainTextOnly = false
        if case .flowed(let delSp) = parsed.textFormat, let flowed = parsed.textBody {
            text = FlowedText.decode(flowed, delSp: delSp)
            plainTextOnly = parsed.htmlBody == nil
        }
        let html = plainTextOnly ? "" : (parsed.htmlBody ?? textAsHTML(text ?? ""))
        let attachments = parsed.attachments.map {
            DraftAttachment(filename: $0.filename, mimeType: $0.mimeType, size: $0.size, contentID: $0.contentID,
                            isInline: $0.isInline)
        }
        let content = DraftContent(from: parsed.from, to: parsed.to, cc: parsed.cc, bcc: parsed.bcc,
                                   subject: parsed.subject, bodyHTML: html, bodyText: text,
                                   attachments: attachments)
        return RemoteDraftUpsert(gmailDraftID: GmailDraftID(d.id), gmailMessageID: GmailMessageID(m.id),
                                 gmailThreadID: GmailThreadID(thread), content: content, extraHeaders: extra)
    }

    static func textAsHTML(_ text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\r\n", "\n": out += "<br>"
            case "\r": break
            default: out.append(ch)
            }
        }
        return out
    }

    static func utf8Prefix(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var out = "", used = 0
        for ch in text {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out
    }

    private static func snapshot(_ message: GmailMessage) -> [GmailLabelID]? {
        guard trustHistoryLabelSnapshots, let ids = message.labelIds else { return nil }
        return ids.map { GmailLabelID($0) }
    }
}

extension GmailMessagePart {
    var mimePart: GmailPayloadPart {
        GmailPayloadPart(partID: partId, mimeType: mimeType, filename: filename,
                         headers: (headers ?? []).map { MIMEHeaderField(name: $0.name, value: $0.value) },
                         attachmentID: body?.attachmentId, size: body?.size, data: body?.data,
                         parts: (parts ?? []).map(\.mimePart))
    }
}
