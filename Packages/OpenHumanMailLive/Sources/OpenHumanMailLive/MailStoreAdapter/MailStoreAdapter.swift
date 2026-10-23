import Foundation
import MailModel
import OpenHumanCore
import OpenHumanStore
import OpenHumanSync

public final class MailStoreAdapter: MailDataSource, Sendable {
    public typealias Store = MailObserving & MailReading

    public struct OnDemand: Sendable {
        public var remoteSearch: (@Sendable (_ gmailQuery: String, _ account: AccountID) async throws -> [ThreadRef])?
        public var loadView: (@Sendable (MailboxView) async throws -> Void)?
        public var remoteSearchDelay: Duration
        public var remoteSearchCapped: (@Sendable (_ gmailQuery: String, _ account: AccountID, _ maxResults: Int) async throws
            -> [ThreadRef])?

        public init(remoteSearch: (@Sendable (_ gmailQuery: String, _ account: AccountID) async throws -> [ThreadRef])? = nil,
                    loadView: (@Sendable (MailboxView) async throws -> Void)? = nil,
                    remoteSearchDelay: Duration = .seconds(1),
                    remoteSearchCapped: (@Sendable (_ gmailQuery: String, _ account: AccountID, _ maxResults: Int) async throws
                        -> [ThreadRef])? = nil) {
            self.remoteSearch = remoteSearch
            self.loadView = loadView
            self.remoteSearchDelay = remoteSearchDelay
            self.remoteSearchCapped = remoteSearchCapped
        }
    }

    let store: any Store
    private let ensureBody: (@Sendable (MessageKey) async throws -> Void)?
    private let attachmentFile: (@Sendable (MessageKey, AttachmentInfo) async throws -> URL)?
    let connectivitySource: (@Sendable () -> AsyncStream<[AccountID: ConnectivityState]>)?
    private let progressSource: (@Sendable () -> AsyncStream<[AccountID: String]>)?
    let searchFallback: GmailSearchFallback?
    let viewLoader: ViewLoader?
    let askRemoteSearch: (@Sendable (_ gmailQuery: String, _ account: AccountID, _ maxResults: Int) async throws
        -> [ThreadRef])?
    let semanticArm: SemanticSearchArm?
    let searchRanking: (any SearchRankingSource)?

    public init(store: any Store, ensureBody: (@Sendable (MessageKey) async throws -> Void)? = nil,
                attachmentFile: (@Sendable (MessageKey, AttachmentInfo) async throws -> URL)? = nil,
                connectivity: (@Sendable () -> AsyncStream<[AccountID: ConnectivityState]>)? = nil,
                syncProgress: (@Sendable () -> AsyncStream<[AccountID: String]>)? = nil,
                onDemand: OnDemand? = nil, semantic: SemanticSearchArm? = nil, ranking: (any SearchRankingSource)? = nil) {
        self.store = store
        self.semanticArm = semantic
        self.searchRanking = ranking
        self.ensureBody = ensureBody
        self.attachmentFile = attachmentFile
        self.connectivitySource = connectivity
        self.progressSource = syncProgress
        self.searchFallback = onDemand?.remoteSearch.map { GmailSearchFallback(delay: onDemand?.remoteSearchDelay ?? .zero,
                                                                              search: $0) }
        self.viewLoader = onDemand?.loadView.map(ViewLoader.init)
        self.askRemoteSearch = onDemand?.remoteSearchCapped
    }

    public func connectivity() -> AsyncStream<[AccountID: ConnectivityState]> {
        connectivitySource?() ?? AsyncStream { $0.finish() }
    }

    public func syncProgress() -> AsyncStream<[AccountID: String]> {
        progressSource?() ?? AsyncStream { $0.finish() }
    }

    public func smartSearchStatus() -> AsyncStream<SmartSearchStatus> {
        semanticArm?.status() ?? AsyncStream { $0.finish() }
    }

    public func accounts() -> AsyncThrowingStream<[Account], Error> {
        Self.map(store.observeAccounts().values()) { $0.map(Self.account) }
    }

    public func labels(_ account: AccountID) -> AsyncThrowingStream<[LabelInfo], Error> {
        Self.map(store.observeLabels(account: account).values()) { $0.map(Self.label) }
    }

    public func splits(_ account: AccountID) -> AsyncThrowingStream<[SplitInfo], Error> {
        Self.map(store.observeSplits(account: account).values()) { $0.map(Self.split) }
    }

    public func counts(_ account: AccountID) -> AsyncThrowingStream<MailboxCountsInfo, Error> {
        let store = self.store
        return Self.map(store.observeCounts(account: account).values()) { counts in
            if let importance = store as? any ImportanceRulesStoring {
                return Self.counts(counts, importantUnread: try importance.importanceCounts(account: account).importantUnread)
            }
            let split = try store.splits(account: account).first {
                $0.enabled && ($0.isImportanceSplit || Self.impliesImportance($0.ruleText))
            }
            return Self.counts(counts, importantUnread: split.map { counts.splitUnread[$0.id] ?? 0 })
        }
    }

    public func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
        if case .search(let text) = location { return searchWindow(text, account: account, limit: limit) }
        guard let view = Self.mailboxView(location, account: account) else {
            return AsyncThrowingStream { $0.finish(throwing: MailPortError.unsupported(Self.unsupportedView)) }
        }
        if ViewLoader.loadsOnOpen(location) { viewLoader?.open(view) }
        let store = self.store
        return Self.map(store.observeThreadList(view: view, limit: limit).values()) { window in
            let primary = Self.primaryCategory(store, account: account)
            return ThreadListWindow(rows: window.items.map { Self.row($0, hiddenCategory: primary) },
                                    hasMore: window.hasMore, totalCount: window.totalCount)
        }
    }

    public func threadPage(_ location: MailLocation, account: AccountID, after: PageCursor?,
                           limit: Int) async throws -> (rows: [ThreadRow], next: PageCursor?) {
        if case .search(let text) = location { return try searchPage(text, account: account, after: after, limit: limit) }
        guard let view = Self.mailboxView(location, account: account) else {
            throw MailPortError.unsupported(Self.unsupportedView)
        }
        let cursor = try after.map(Self.threadCursor)
        let page = try store.threadPage(view: view, after: cursor, limit: limit)
        let primary = Self.primaryCategory(store, account: account)
        return (page.items.map { Self.row($0, hiddenCategory: primary) }, page.nextCursor.map(Self.pageCursor))
    }

    public func localThread(_ account: AccountID, gmailThreadID: GmailThreadID) async throws -> ThreadRow? {
        guard let ref = try store.thread(account: account, gmailThreadID: gmailThreadID),
              let item = try store.thread(ref) else { return nil }
        return Self.row(item, hiddenCategory: Self.primaryCategory(store, account: account))
    }

    public func superhumanReminderEmails(_ account: AccountID, limit: Int) async throws -> [SuperhumanReminderEmail] {
        try store.superhumanReminderEmails(account: account, limit: limit).map { item in
            let match: SuperhumanReminderEmail.Match = switch item.match {
            case .sameConversation: .sameConversation
            case .replyHeaders(let target): .replyHeaders(Self.threadKey(target))
            case .unmatched: .unmatched
            }
            return SuperhumanReminderEmail(
                id: MessageKey(account: account, rowID: item.message.rawValue, gmailMessageID: item.gmailMessageID),
                thread: Self.threadKey(item.thread), date: item.date, isInInbox: item.isInInbox, isHidden: item.isHidden,
                match: match, subject: item.subject, targetInInbox: item.targetInInbox)
        }
    }

    public func refresh(_ account: AccountID) async throws {
        guard try store.accounts().contains(where: { $0.id == account }) else { throw MailPortError.notFound("account") }
        guard let settings = store as? any SettingsStoring else { throw MailPortError.unsupported("refresh") }
        try settings.setSetting(.syncRequestAt, Int(Date().timeIntervalSince1970 * 1000), scope: .global)
    }

    static let unsupportedView = "this view"

    public func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> {
        Self.map(store.observeThreadDetail(ThreadRowID(rawValue: key.rowID)).values()) { detail in
            detail.map(Self.conversation)
        }
    }

    public func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> {
        let store = self.store
        let ensureBody = self.ensureBody
        let source = store.observeBody(MessageRowID(rawValue: key.rowID)).values()
        return AsyncThrowingStream { continuation in
            let task = Task {
                var asked = false
                do {
                    for try await body in source {
                        if let body {
                            continuation.yield(.available(Self.content(body)))
                            continue
                        }
                        let state = try store.message(account: key.account, gmailMessageID: key.gmailMessageID)?.bodyState
                        if state == .failed {
                            continuation.yield(.failed("The message body could not be downloaded."))
                            continue
                        }
                        continuation.yield(.fetching)
                        if !asked, let ensureBody {
                            asked = true
                            do {
                                try await ensureBody(key)
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                continuation.yield(.failed("The message body could not be downloaded."))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func storedBody(_ key: MessageKey) async throws -> MessageContent? {
        try store.body(MessageRowID(rawValue: key.rowID)).map(Self.content)
    }

    public func attachmentData(_ key: MessageKey, attachment: AttachmentInfo) async throws -> URL {
        if let attachmentFile { return try await attachmentFile(key, attachment) }
        let items = try store.attachments(message: MessageRowID(rawValue: key.rowID))
        guard let item = items.first(where: { $0.id == attachment.id }) else { throw MailPortError.notFound("attachment") }
        guard let url = item.localFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw MailPortError.unavailable("attachments can't be opened here")
        }
        return url
    }

    public func drafts(_ account: AccountID?, review: Bool) -> AsyncThrowingStream<[DraftSummary], Error> {
        let rows = review ? store.observeReviewQueue(account: account)
                          : store.observeDrafts(account: account, states: [.editing, .scheduled, .failed])
        return Self.map(rows.values()) { $0.compactMap(Self.draft) }
    }

    public func draft(_ key: DraftKey) -> AsyncThrowingStream<DraftSummary?, Error> {
        Self.map(store.observeDraft(key).values()) { $0.flatMap(Self.draft) }
    }

    public func reviewQueue(_ account: AccountID?) -> AsyncThrowingStream<[DraftSummary], Error> {
        Self.map(store.observeReviewQueue(account: account).values()) { $0.compactMap(Self.draft) }
    }

    public func draftSkeleton(_ input: DraftInput) async throws -> DraftFields? {
        guard input.mode != .new, let replyTo = input.replyTo else { return nil }
        if let ensureBody, try store.body(MessageRowID(rawValue: replyTo.rowID)) == nil {
            try? await ensureBody(replyTo)
        }
        let content = try DraftSkeleton.content(store: store, account: input.account, mode: Self.composeMode(input.mode),
                                                replyTo: replyTo.gmailMessageID)
        return content.map(Self.fields)
    }

    public func contactSuggestions(_ account: AccountID, prefix: String, limit: Int) async throws -> [EmailAddress] {
        try store.contactSuggestions(account: account, prefix: prefix, limit: limit).map {
            EmailAddress(name: $0.name, email: $0.email)
        }
    }

    public func recentThreads(involving email: String, account: AccountID, limit: Int) async throws -> [ThreadRow] {
        try store.recentThreads(involving: email, account: account, limit: limit).map { Self.row($0) }
    }

    public func snippets(_ account: AccountID?) -> AsyncThrowingStream<[SnippetInfo], Error> {
        let files = (store as? MailStore)?.location
        if let observing = store as? any SnippetObserving {
            return Self.map(observing.observeSnippets(account: account).values()) { $0.map { Self.snippet($0, files: files) } }
        }
        let store = self.store
        return AsyncThrowingStream { continuation in
            do {
                continuation.yield(try store.snippets(account: account).map { Self.snippet($0, files: files) })
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    static func mailboxView(_ location: MailLocation, account: AccountID) -> MailboxView? {
        switch location {
        case .reviewQueue, .search:
            return nil
        case .system(let folder):
            return SystemMailbox(rawValue: folder.rawValue).map { .system(account, $0) }
        case .label(let id):
            return .label(account, id)
        case .split(let id):
            return .split(account, id)
        case .splitOther:
            return .splitOther(account)
        }
    }

    static func account(_ item: AccountItem) -> Account {
        let health: AccountHealth = switch item.status {
        case .active: .active
        case .needsReauth: .needsSignIn
        case .disabled: .disabled
        case .removing: .removing
        }
        let sendAs = item.sendAs.map {
            SenderIdentity(email: $0.email, name: $0.name, isDefault: $0.isDefault, isPrimary: $0.isPrimary,
                           signatureHTML: $0.signatureHTML, replyTo: $0.replyTo,
                           needsVerification: needsVerification($0.verificationStatus))
        }
        return Account(id: item.id, email: item.email, displayName: item.displayName, alias: item.alias, health: health,
                       sendAs: sendAs)
    }

    static func needsVerification(_ status: String?) -> Bool {
        guard let status else { return false }
        return status.lowercased() != "accepted"
    }

    static let gmailDisplayNames: [String: String] = [
        "INBOX": "Inbox", "STARRED": "Starred", "IMPORTANT": "Important", "UNREAD": "Unread", "SENT": "Sent",
        "DRAFT": "Drafts", "TRASH": "Trash", "SPAM": "Spam", "CHAT": "Chat",
        "CATEGORY_PERSONAL": "Primary", "CATEGORY_SOCIAL": "Social", "CATEGORY_PROMOTIONS": "Promotions",
        "CATEGORY_UPDATES": "Updates", "CATEGORY_FORUMS": "Forums",
    ]

    static let primaryCategoryKey = "CATEGORY_PERSONAL"

    static func label(_ item: LabelItem) -> LabelInfo {
        let kind: LabelInfo.Kind = switch item.kind {
        case .system: .system
        case .category: .category
        case .user: .user
        case .virtual: .virtual
        case .split: .split
        }
        let display = item.kind == .system || item.kind == .category
            ? gmailDisplayNames[item.key] ?? item.displayName : item.displayName
        return LabelInfo(id: item.id.rawValue, account: item.accountID, labelID: GmailLabelID(item.key), kind: kind,
                         name: item.name, displayName: display, colorBackground: item.colorBackground,
                         colorText: item.colorText, isHidden: item.isHidden, position: item.position,
                         totalThreads: item.totalThreads, unreadThreads: item.unreadThreads)
    }

    static func split(_ item: SplitItem) -> SplitInfo {
        SplitInfo(id: item.id, account: item.accountID, name: item.name, position: item.position,
                  ruleText: item.ruleText, enabled: item.enabled, unreadThreads: item.unreadThreads,
                  totalThreads: item.totalThreads)
    }

    static func counts(_ counts: MailboxCounts, importantUnread: Int?) -> MailboxCountsInfo {
        MailboxCountsInfo(
            account: counts.accountID,
            byLabel: Dictionary(uniqueKeysWithValues: counts.byLabel.map {
                ($0.key.rawValue, LabelTally(total: $0.value.total, unread: $0.value.unread))
            }),
            inboxUnread: counts.inboxUnread, splitUnread: counts.splitUnread, draftsCount: counts.draftsCount,
            pendingReviewCount: counts.pendingReviewCount, failedOperationCount: counts.failedOperationCount,
            importantUnread: importantUnread)
    }

    static func impliesImportance(_ ruleText: String) -> Bool {
        ruleText.trimmingCharacters(in: .whitespaces).lowercased() == "is:important"
    }

    static func primaryCategory(_ store: any Store, account: AccountID) -> LabelRowID? {
        (try? store.label(account: account, key: primaryCategoryKey))?.id
    }

    static func row(_ item: ThreadListItem, hiddenCategory: LabelRowID? = nil) -> ThreadRow {
        ThreadRow(
            id: ThreadKey(account: item.ref.accountID, rowID: item.id.rawValue, gmailThreadID: item.ref.gmailThreadID),
            subject: item.subject, snippet: item.snippet, participantsDisplay: item.participantsDisplay,
            participants: item.participants.map { Participant(name: $0.name, email: $0.email, isMe: $0.isMe, hasUnread: $0.hasUnread) },
            messageCount: item.messageCount, unreadCount: item.unreadCount, draftCount: item.draftCount,
            attachmentCount: item.attachmentCount, isUnread: item.isUnread, isStarred: item.isStarred,
            isImportant: item.isImportant, userLabelIDs: item.userLabelIDs.map(\.rawValue),
            lastMessageAt: item.lastMessageAt, sortAt: item.sortAt, snoozedUntil: item.snoozedUntil,
            reminderAt: item.reminderAt, scheduledSendAt: item.scheduledSendAt, hasPendingChanges: item.hasPendingChanges,
            categoryLabelIDs: item.categoryLabelIDs.filter { $0 != hiddenCategory }.map(\.rawValue),
            returnedByReminder: item.returnedByReminder, isPlacedImportant: item.importance == .important)
    }

    static func pageCursor(_ cursor: ThreadCursor) -> PageCursor {
        PageCursor(payload: Data(cursor.encoded.utf8))
    }

    static func threadCursor(_ cursor: PageCursor) throws -> ThreadCursor {
        guard let text = String(data: cursor.payload, encoding: .utf8), let decoded = ThreadCursor(encoded: text) else {
            throw MailPortError.invalidQuery("try again")
        }
        return decoded
    }

    static func content(_ body: MessageBody) -> MessageContent {
        MessageContent(html: body.html, text: body.text, textFormat: textFormat(body.textFormat))
    }

    static func textFormat(_ format: BodyTextFormat) -> MessageTextFormat {
        switch format {
        case .fixed: .fixed
        case .flowed: .flowed(delSp: false)
        case .flowedDelSp: .flowed(delSp: true)
        }
    }

    static func conversation(_ detail: ThreadDetail) -> ConversationDetail {
        let ref = detail.thread.ref
        let threadKey = ThreadKey(account: ref.accountID, rowID: detail.thread.id.rawValue, gmailThreadID: ref.gmailThreadID)
        let nonDraft = detail.messages.filter { !$0.isDraft }
        let unbinned = nonDraft.filter { !$0.inTrash && !$0.inSpam }
        let visible = unbinned.isEmpty ? nonDraft : unbinned
        let hidden = Set(detail.hiddenMessageIDs)
        let withoutHidden = hidden.isEmpty ? visible : visible.filter { !hidden.contains($0.id) }
        let messages = (withoutHidden.isEmpty ? visible : withoutHidden).map { item in
            MessageSummary(
                id: MessageKey(account: ref.accountID, rowID: item.id.rawValue, gmailMessageID: item.gmailMessageID),
                from: item.from, to: item.to, cc: item.cc, bcc: item.bcc, date: item.date, snippet: item.snippet,
                isUnread: item.isUnread,
                attachments: item.attachments.map {
                    AttachmentInfo(id: $0.id, filename: $0.filename, mimeType: $0.mimeType, size: $0.size,
                                   contentID: $0.contentID, isInline: $0.isInline)
                },
                hasCalendarInvite: item.hasCalendarInvite)
        }
        return ConversationDetail(id: threadKey, subject: detail.thread.subject, messages: messages,
                                  userLabelIDs: detail.thread.userLabelIDs.map(\.rawValue),
                                  isStarred: detail.thread.isStarred, returnedByReminder: detail.thread.returnedByReminder)
    }

    static func threadKey(_ ref: ThreadRef) -> ThreadKey {
        ThreadKey(account: ref.accountID, rowID: ref.rowID.rawValue, gmailThreadID: ref.gmailThreadID)
    }

    static func threadRef(_ key: ThreadKey) -> ThreadRef {
        ThreadRef(accountID: key.account, rowID: ThreadRowID(rawValue: key.rowID), gmailThreadID: key.gmailThreadID)
    }

    static func draft(_ item: DraftListItem) -> DraftSummary? {
        let status: DraftStatus
        switch item.state {
        case .editing: status = .editing
        case .scheduled: status = .scheduled
        case .sending: status = .sending
        case .failed: status = .failed
        case .sent, .discarded: return nil
        }
        let source: DraftSource = switch item.origin {
        case .user: .user
        case .agent: .agent
        case .cli: .cli
        }
        let review: DraftReview = switch item.reviewState {
        case .none: .none
        case .pending: .pending
        case .approved: .approved
        case .rejected: .rejected
        }
        return DraftSummary(id: item.id, account: item.accountID, gmailDraftID: item.gmailDraftID,
                            thread: item.thread.map(threadKey), mode: mode(item.composeMode),
                            replyToGmailMessageID: item.replyToMessageID, fields: fields(item.content), source: source,
                            review: review, status: status, sendAt: item.sendAt,
                            sendCondition: status == .scheduled && hasSendCondition(item.extraHeaders) ? .ifNoReply : .always,
                            version: item.localVersion,
                            isDirty: item.isDirty, hasRemoteConflict: item.hasRemoteConflict, agentNote: item.agentNote,
                            agentSnapshot: item.agentSnapshot.map(fields), lastError: item.lastError,
                            updatedAt: item.updatedAt)
    }

    static func hasSendCondition(_ headers: [String: String]) -> Bool {
        headers.keys.contains { $0.caseInsensitiveCompare(OHGmailLabels.sendAtConditionHeader) == .orderedSame }
    }

    static func mode(_ mode: ComposeMode) -> DraftMode {
        switch mode {
        case .new: .new
        case .reply: .reply
        case .replyAll: .replyAll
        case .forward: .forward
        }
    }

    static func composeMode(_ mode: DraftMode) -> ComposeMode {
        switch mode {
        case .new: .new
        case .reply: .reply
        case .replyAll: .replyAll
        case .forward: .forward
        }
    }

    static func fields(_ content: DraftContent) -> DraftFields {
        DraftFields(from: content.from, to: content.to, cc: content.cc, bcc: content.bcc, subject: content.subject,
                    bodyHTML: content.bodyHTML, bodyText: content.bodyText,
                    attachments: content.attachments.map {
                        DraftAttachmentInfo(localPath: $0.localPath, sourceAttachmentID: $0.sourceAttachmentID,
                                            filename: $0.filename, mimeType: $0.mimeType, size: $0.size,
                                            contentID: $0.contentID, isInline: $0.isInline)
                    })
    }

    static func content(_ fields: DraftFields) -> DraftContent {
        DraftContent(from: fields.from, to: fields.to, cc: fields.cc, bcc: fields.bcc, subject: fields.subject,
                     bodyHTML: fields.bodyHTML, bodyText: fields.bodyText,
                     attachments: fields.attachments.map {
                         DraftAttachment(localPath: $0.localPath, sourceAttachmentID: $0.sourceAttachmentID,
                                         filename: $0.filename, mimeType: $0.mimeType, size: $0.size,
                                         contentID: $0.contentID, isInline: $0.isInline)
                     })
    }

    static func snippet(_ item: SnippetItem, files: StoreLocation? = nil) -> SnippetInfo {
        SnippetInfo(id: item.id, account: item.accountID, name: item.name, shortcut: item.shortcut, subject: item.subject,
                    bodyHTML: item.bodyHTML,
                    variables: item.variables.map { SnippetVariableInfo(name: $0.name, defaultValue: $0.defaultValue) },
                    useCount: item.useCount, to: item.to, cc: item.cc, bcc: item.bcc,
                    attachments: item.attachments.map { snippetAttachment($0, fileURL: files?.snippetFileURL($0)) })
    }

    static func snippetAttachment(_ stored: SnippetAttachment, fileURL: URL?) -> SnippetAttachmentInfo {
        SnippetAttachmentInfo(contentHash: stored.contentHash, filename: stored.filename, mimeType: stored.mimeType,
                              size: stored.size, fileURL: fileURL)
    }

    static func snippetItem(_ info: SnippetInfo) -> SnippetItem {
        SnippetItem(id: info.isNew ? UUID().uuidString : info.id, accountID: info.account, name: info.name,
                    shortcut: info.shortcut, subject: info.subject, bodyHTML: info.bodyHTML,
                    variables: info.variables.map { SnippetVariable(name: $0.name, defaultValue: $0.defaultValue) },
                    useCount: info.useCount, to: info.to, cc: info.cc, bcc: info.bcc,
                    attachments: info.attachments.map {
                        SnippetAttachment(contentHash: $0.contentHash, filename: $0.filename, mimeType: $0.mimeType, size: $0.size)
                    })
    }

    static func map<A: Sendable, B: Sendable>(_ source: AsyncThrowingStream<A, Error>,
                                             _ transform: @escaping @Sendable (A) throws -> B) -> AsyncThrowingStream<B, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in source { continuation.yield(try transform(value)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
