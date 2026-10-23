import Foundation
import OpenHumanCore

public enum DraftMode: String, Sendable, Hashable, Codable { case new, reply, replyAll, forward }

public enum DraftReview: String, Sendable, Hashable, Codable { case none, pending, approved, rejected }

public enum DraftStatus: String, Sendable, Hashable, Codable {
    case editing
    case scheduled
    case sending
    case sent
    case failed
    case discarded
}

public enum DraftSource: String, Sendable, Hashable, Codable { case user, agent, cli }

public struct DraftAttachmentInfo: Sendable, Hashable, Codable {
    public var localPath: String?
    public var sourceAttachmentID: Int64?
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var contentID: String?
    public var isInline: Bool

    public init(localPath: String? = nil, sourceAttachmentID: Int64? = nil, filename: String, mimeType: String,
                size: Int, contentID: String? = nil, isInline: Bool = false) {
        self.localPath = localPath
        self.sourceAttachmentID = sourceAttachmentID
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentID = contentID
        self.isInline = isInline
    }
}

public struct DraftFields: Sendable, Hashable, Codable {
    public var from: EmailAddress?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var bodyHTML: String
    public var bodyText: String?
    public var attachments: [DraftAttachmentInfo]

    public init(from: EmailAddress? = nil, to: [EmailAddress] = [], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
                subject: String = "", bodyHTML: String = "", bodyText: String? = nil,
                attachments: [DraftAttachmentInfo] = []) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyHTML = bodyHTML
        self.bodyText = bodyText
        self.attachments = attachments
    }
}

public struct DraftInput: Sendable, Hashable {
    public var account: AccountID
    public var mode: DraftMode
    public var replyTo: MessageKey?
    public var content: DraftFields?
    public var extraHeaders: [String: String]

    public init(account: AccountID, mode: DraftMode, replyTo: MessageKey? = nil, content: DraftFields? = nil,
                extraHeaders: [String: String] = [:]) {
        self.account = account
        self.mode = mode
        self.replyTo = replyTo
        self.content = content
        self.extraHeaders = extraHeaders
    }
}

public struct DraftSummary: Identifiable, Sendable, Hashable {
    public let id: DraftKey
    public let account: AccountID
    public let gmailDraftID: GmailDraftID?
    public let thread: ThreadKey?
    public let mode: DraftMode
    public let replyToGmailMessageID: GmailMessageID?
    public let fields: DraftFields
    public let source: DraftSource
    public let review: DraftReview
    public let status: DraftStatus
    public let sendAt: Date?
    public let sendCondition: SendLaterCondition
    public let version: Int
    public let isDirty: Bool
    public let hasRemoteConflict: Bool
    public let agentNote: String?
    public let agentSnapshot: DraftFields?
    public let lastError: String?
    public let updatedAt: Date

    public init(id: DraftKey, account: AccountID, gmailDraftID: GmailDraftID? = nil, thread: ThreadKey? = nil,
                mode: DraftMode, replyToGmailMessageID: GmailMessageID? = nil, fields: DraftFields,
                source: DraftSource = .user, review: DraftReview = .none, status: DraftStatus = .editing,
                sendAt: Date? = nil, sendCondition: SendLaterCondition = .always, version: Int = 1, isDirty: Bool = false,
                hasRemoteConflict: Bool = false,
                agentNote: String? = nil, agentSnapshot: DraftFields? = nil, lastError: String? = nil,
                updatedAt: Date) {
        self.id = id
        self.account = account
        self.gmailDraftID = gmailDraftID
        self.thread = thread
        self.mode = mode
        self.replyToGmailMessageID = replyToGmailMessageID
        self.fields = fields
        self.source = source
        self.review = review
        self.status = status
        self.sendAt = sendAt
        self.sendCondition = sendCondition
        self.version = version
        self.isDirty = isDirty
        self.hasRemoteConflict = hasRemoteConflict
        self.agentNote = agentNote
        self.agentSnapshot = agentSnapshot
        self.lastError = lastError
        self.updatedAt = updatedAt
    }

    public var isAgentDraft: Bool { source != .user }

    public var canBeScheduled: Bool { source == .user || review == .approved }
}

public enum DraftConflictResolution: String, Sendable, Hashable, Codable {
    case keepLocal
    case takeRemote
}

public struct SendToken: Hashable, Sendable, Codable {
    public let draft: DraftKey
    public let sendAfter: Date
    public let payload: Data

    public init(draft: DraftKey, sendAfter: Date, payload: Data) {
        self.draft = draft
        self.sendAfter = sendAfter
        self.payload = payload
    }
}
