import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanMIME
import OpenHumanStore

struct DrainContext: Sendable {
    let account: AccountID
    let store: MailStore
    let api: any GmailAPI
    let clock: any OHClock
    let labels: LabelBook
    let log = Log(.queue)

    init(account: AccountID, store: MailStore, api: any GmailAPI, clock: any OHClock) {
        self.account = account
        self.store = store
        self.api = api
        self.clock = clock
        labels = LabelBook(account: account, store: store, api: api)
    }

    func message(for draft: DraftListItem) async throws -> DraftMessage {
        let item = try store.accounts().first { $0.id == account }
        let remote = try await gmailDraftParts(of: draft)
        return try await DraftMessage.make(draft, account: item, date: clock.now) { attachment in
            try await self.attachmentData(attachment, of: draft, remote: remote)
        }
    }

    struct GmailDraftParts: Sendable {
        let messageID: String
        let attachments: [ParsedAttachment]
    }

    // An attachment that arrived with a draft written elsewhere has no local copy; its bytes are in the Gmail draft
    func gmailDraftParts(of draft: DraftListItem) async throws -> GmailDraftParts? {
        guard let id = draft.gmailDraftID,
              draft.content.attachments.contains(where: { $0.localPath == nil && $0.sourceAttachmentID == nil }) else {
            return nil
        }
        let remote: GmailDraft
        do {
            remote = try await api.getDraft(id: id.rawValue, format: .full)
        } catch GmailError.notFound {
            return nil
        }
        guard let message = remote.message, let payload = message.payload,
              let parsed = try? MIMEParser.parse(gmailPayload: payload.mimePart) else { return nil }
        return GmailDraftParts(messageID: message.id, attachments: parsed.attachments)
    }

    func attachmentData(_ attachment: DraftAttachment, of draft: DraftListItem,
                        remote: GmailDraftParts? = nil) async throws -> Data {
        let index = (draft.content.attachments.firstIndex(of: attachment) ?? 0) + 1
        if attachment.localPath == nil, attachment.sourceAttachmentID == nil {
            return try await draftAttachmentData(attachment, of: draft, remote: remote, index: index)
        }
        if let path = attachment.localPath {
            let parts = path.split(separator: "/")
            guard !path.hasPrefix("/"), !parts.contains(".."), !parts.isEmpty,
                  let data = try? Data(contentsOf: store.location.directory.appendingPathComponent(path)) else {
                throw DraftMessage.Failure.attachmentMissing("attachment \(index): local file missing")
            }
            return data
        }
        guard let aid = attachment.sourceAttachmentID, let source = draft.replyToMessageID else {
            throw DraftMessage.Failure.attachmentMissing("attachment \(index): no source")
        }
        let fetcher = AttachmentFetcher(account: account, store: store, api: api, storeDirectory: store.location.directory)
        let file = try await fetcher.attachmentFile(message: source, attachment: aid, priority: .queue)
        guard let data = try? Data(contentsOf: file) else {
            throw DraftMessage.Failure.attachmentMissing("attachment \(index): cached file unreadable")
        }
        return data
    }

    func draftAttachmentData(_ attachment: DraftAttachment, of draft: DraftListItem, remote: GmailDraftParts?,
                             index: Int) async throws -> Data {
        func same(_ a: DraftAttachment) -> Bool {
            a.filename == attachment.filename && a.mimeType.lowercased() == attachment.mimeType.lowercased()
                && a.contentID == attachment.contentID && a.isInline == attachment.isInline
        }
        let position = draft.content.attachments.prefix(index - 1).filter(same).count
        let matches = remote?.attachments.filter {
            $0.filename == attachment.filename && $0.mimeType.lowercased() == attachment.mimeType.lowercased()
                && $0.contentID == attachment.contentID && $0.isInline == attachment.isInline
        } ?? []
        guard let remote, position < matches.count else {
            throw DraftMessage.Failure.attachmentMissing("attachment \(index): no source")
        }
        let part = matches[position]
        let data: Data
        if let aid = part.gmailAttachmentID {
            if part.size > AttachmentFetcher.maxBytes { throw AttachmentFetcher.Failure.tooLarge(part.size) }
            do {
                data = try await api.getAttachment(messageID: remote.messageID, attachmentID: aid)
            } catch GmailError.notFound {
                throw DraftMessage.Failure.attachmentMissing("attachment \(index): no longer in the Gmail draft")
            }
        } else if let inline = part.inlineData {
            data = inline
        } else {
            throw DraftMessage.Failure.attachmentMissing("attachment \(index): no source")
        }
        guard data.count <= AttachmentFetcher.maxBytes else { throw AttachmentFetcher.Failure.tooLarge(data.count) }
        return data
    }

    func labelNames(ofMessage id: GmailMessageID?) throws -> [String] {
        guard let id, let item = try store.message(account: account, gmailMessageID: id) else { return [] }
        return try labels.names(of: item.labelIDs.map(\.rawValue)).keys.sorted()
    }
}
