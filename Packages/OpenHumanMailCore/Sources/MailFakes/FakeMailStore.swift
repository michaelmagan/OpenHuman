import Foundation
import MailModel
import OpenHumanCore
import Synchronization

public final class FakeMailStore: MailDataSource, MailCommanding, AccountManaging, SettingsPort, Sendable {
    public struct Options: Sendable {
        public enum RemoteAck: Sendable, Equatable {
            case immediate
            case after(Duration)
            case manual
        }

        public enum HeldSends: Sendable, Equatable {
            case realTime
            case manual
        }

        public var remoteAck: RemoteAck
        public var heldSends: HeldSends
        public var bodyDelay: Duration?
        public var liveConnectivity: Bool
        public var oauthClient: OAuthClientStatus
        public var now: @Sendable () -> Date
        public var relatedSearchMatches: Bool

        public init(remoteAck: RemoteAck = .after(.milliseconds(400)), heldSends: HeldSends = .realTime,
                    bodyDelay: Duration? = nil, liveConnectivity: Bool = false,
                    oauthClient: OAuthClientStatus = .configured(source: .file),
                    now: @escaping @Sendable () -> Date = { Date() }, relatedSearchMatches: Bool = false) {
            self.remoteAck = remoteAck
            self.heldSends = heldSends
            self.bodyDelay = bodyDelay
            self.liveConnectivity = liveConnectivity
            self.oauthClient = oauthClient
            self.now = now
            self.relatedSearchMatches = relatedSearchMatches
        }

        public static var manual: Options { Options(remoteAck: .manual, heldSends: .manual) }
    }

    let state: Mutex<State>
    let options: Options
    public var bodyDelay: Duration? { options.bodyDelay }

    public convenience init(corpus: FakeCorpus, bodyDelay: Duration? = nil) {
        self.init(corpus: corpus, options: Options(bodyDelay: bodyDelay))
    }

    public init(corpus: FakeCorpus, options: Options) {
        self.options = options
        state = Mutex(State(corpus: corpus, options: options))
    }

    var now: Date { options.now() }

    @discardableResult
    func mutate<R>(_ change: (inout State) throws -> R) rethrows -> R {
        let (result, subscribers) = try state.withLock { s -> (R, [@Sendable () -> Void]) in
            let result = try change(&s)
            s.revision += 1
            s.windowCache.removeAll(keepingCapacity: true)
            return (result, Array(s.subscribers.values))
        }
        for notify in subscribers { notify() }
        return result
    }

    func stream<V: Sendable & Equatable>(_ compute: @escaping @Sendable (inout State) throws -> V) -> AsyncThrowingStream<V, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            let last = LastValue<V>()
            let emit: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                do {
                    let value = try self.state.withLock { try compute(&$0) }
                    if last.replace(with: value) { continuation.yield(value) }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            state.withLock { $0.subscribers[id] = emit }
            emit()
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
            }
        }
    }

    func plainStream<V: Sendable & Equatable>(_ compute: @escaping @Sendable (inout State) -> V) -> AsyncStream<V> {
        AsyncStream { continuation in
            let id = UUID()
            let last = LastValue<V>()
            let emit: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                let value = self.state.withLock { compute(&$0) }
                if last.replace(with: value) { continuation.yield(value) }
            }
            state.withLock { $0.subscribers[id] = emit }
            emit()
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
            }
        }
    }

    func checkWritable(_ s: inout State) throws {
        if let failure = s.failNextCommand {
            s.failNextCommand = nil
            throw failure
        }
    }
}

final class LastValue<V: Sendable & Equatable>: Sendable {
    private let value = Mutex<V?>(nil)
    func replace(with new: V) -> Bool {
        value.withLock { previous in
            defer { previous = new }
            return previous != new
        }
    }
}

struct FakeMessage: Sendable {
    var summary: MessageSummary
    var labels: Set<GmailLabelID>
    var body: MessageContent?
    var bodySpec: FakeBodySpec?
    var unsubscribe: UnsubscribeInfo?
    var listID: String?
    var isFromMe: Bool

    var content: MessageContent {
        body ?? bodySpec?.content ?? MessageContent(html: nil, text: summary.snippet)
    }
}

struct FakeThread: Sendable {
    var key: ThreadKey
    var subject: String
    var messages: [FakeMessage]
    var boostAt: Date?
    var reminderReturnAt: Date?
}

struct FakeDraft: Sendable {
    var id: DraftKey
    var account: AccountID
    var gmailDraftID: GmailDraftID?
    var thread: ThreadKey?
    var mode: DraftMode
    var replyTo: GmailMessageID?
    var fields: DraftFields
    var source: DraftSource
    var review: DraftReview
    var status: DraftStatus
    var sendStamp: String?
    var sendCondition: SendLaterCondition = .always
    var version: Int
    var syncedVersion: Int
    var hasRemoteConflict: Bool
    var agentNote: String?
    var agentSnapshot: DraftFields?
    var lastError: String?
    var updatedAt: Date
    var agentVersion: Int? = nil

    var summary: DraftSummary {
        var status = self.status
        var sendAt: Date?
        var lastError = self.lastError
        if status == .scheduled {
            if let stamp = sendStamp, let date = ScheduleStamp.parse(stamp) {
                sendAt = date
            } else {
                status = .failed
                lastError = "scheduled time unreadable"
            }
        }
        return DraftSummary(id: id, account: account, gmailDraftID: gmailDraftID, thread: thread, mode: mode,
                            replyToGmailMessageID: replyTo, fields: fields, source: source, review: review,
                            status: status, sendAt: sendAt, sendCondition: sendAt == nil ? .always : sendCondition,
                            version: version, isDirty: version > syncedVersion,
                            hasRemoteConflict: hasRemoteConflict, agentNote: agentNote, agentSnapshot: agentSnapshot,
                            lastError: lastError, updatedAt: updatedAt)
    }

    var isListed: Bool { [.editing, .scheduled, .failed].contains(summary.status) }
}

struct FakeReminder: Sendable, Hashable {
    var id: String
    var thread: ThreadKey
    var dueAt: Date
    var kind: ReminderKind
    var anchor: MessageKey?
}

struct FakeOperation: Sendable {
    enum Status: String, Sendable { case pending, succeeded, failed, cancelled }
    struct Edit: Sendable, Hashable {
        var add: Set<GmailLabelID>
        var remove: Set<GmailLabelID>
        func applied(to labels: Set<GmailLabelID>) -> Set<GmailLabelID> { labels.union(add).subtracting(remove) }
    }

    var id: Int64
    var account: AccountID
    var kind: String
    var threads: [ThreadKey]
    var edits: [MessageKey: Edit]
    var status: Status
    var attempts: Int
}

struct FakeReceipt: Codable, Sendable {
    var operations: [Int64]
    var undo: [MailCommand]
    var redo: [MailCommand]

    var token: UndoToken {
        UndoToken(payload: (try? JSONEncoder().encode(self)) ?? Data(), changesNothing: operations.isEmpty && undo.isEmpty)
    }

    static func decode(_ token: UndoToken) throws -> FakeReceipt {
        do { return try JSONDecoder().decode(FakeReceipt.self, from: token.payload) } catch {
            throw MailPortError.notFound("undo token")
        }
    }
}

struct HeldSend: Codable, Sendable {
    var id: Int64
    var draft: DraftKey
    var sendAfter: Date
}

struct FakeAccountState: Sendable {
    var account: Account
    var labels: [LabelInfo]
    var splits: [SplitInfo]
    var splitRules: [SplitKey: FakeQuery]
    var connectivity: ConnectivityState

    var me: Set<String> { Set([account.email.lowercased()] + account.sendAs.map { $0.email.lowercased() }) }

    func label(_ id: GmailLabelID) -> LabelInfo? { labels.first { $0.labelID == id } }
    func label(named name: String) -> LabelInfo? { labels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    var userLabelRows: [GmailLabelID: Int64] {
        var rows: [GmailLabelID: Int64] = [:]
        for label in labels where label.kind == .user && !label.isHidden
            && (!label.name.hasPrefix(ScheduleLabel.prefix) || label.name == OHGmailLabels.muted
                || OHGmailLabels.autoLabelCategory(inLabelName: label.name) != nil) {
            rows[label.labelID] = label.id
        }
        return rows
    }

    var categoryLabelRows: [GmailLabelID: Int64] {
        var rows: [GmailLabelID: Int64] = [:]
        for label in labels where label.kind == .category { rows[label.labelID] = label.id }
        return rows
    }
}

public struct FakeSentMessage: Sendable, Hashable {
    public let draft: DraftKey
    public let account: AccountID
    public let thread: ThreadKey
    public let to: [EmailAddress]
    public let subject: String
    public let byOtherInstall: Bool
    public var from: EmailAddress? = nil
    public var cc: [EmailAddress] = []
    public var bcc: [EmailAddress] = []
    public var bodyHTML: String = ""
    public var bodyText: String? = nil
}

public enum FakeSignInOutcome: Sendable, Hashable {
    case succeed(email: String, displayName: String?)
    case cancel
    case refuse
    case fail
}

struct SettingSlot: Hashable, Sendable {
    var name: String
    var scope: AppSettingScope
}

struct WindowCacheKey: Hashable, Sendable {
    var account: AccountID
    var location: MailLocation
}

struct FakeGmailSearchKey: Hashable, Sendable {
    var account: AccountID
    var query: String
}

enum FakeGmailSearch: Sendable {
    case answered([ThreadKey])
    case failed
}

struct State: Sendable {
    var accounts: [AccountID: FakeAccountState] = [:]
    var threads: [ThreadKey: FakeThread] = [:]
    var threadOrder: [AccountID: [ThreadKey]] = [:]
    var messageIndex: [MessageKey: ThreadKey] = [:]
    var drafts: [DraftKey: FakeDraft] = [:]
    var draftsByThread: [ThreadKey: Set<DraftKey>] = [:]
    var reminders: [ThreadKey: FakeReminder] = [:]
    var snippets: [String: SnippetInfo] = [:]
    var operations: [Int64: FakeOperation] = [:]
    var pendingByMessage: [MessageKey: [Int64]] = [:]
    var pendingByThread: [ThreadKey: Set<Int64>] = [:]
    var nextOperation: Int64 = 1
    var failures: [FailedOperationInfo] = []
    var held: [Int64: HeldSend] = [:]
    var nextHeld: Int64 = 1
    var settings: [SettingSlot: Data] = [:]
    var oauthClient: OAuthClientStatus
    var offline = false
    var offlineSince: Date?
    var ids: FakeIDs
    var nextThreadRow: Int64 = 1
    var nextMessageRow: Int64 = 1
    var nextAccount: Int64 = 1
    var nextGmailDraft = 1
    var failNextRemote: [String] = []
    var failNextCommand: MailPortError?
    var failingDeliveries: [DraftKey: String] = [:]
    var signInOutcomes: [FakeSignInOutcome] = []
    var unsubscribeRequests: [MessageKey] = []
    var searchIncomplete: [AccountID: [SearchIncompleteness]] = [:]
    var gmailOnly: [AccountID: [ThreadKey]] = [:]
    var gmailSearches: [FakeGmailSearchKey: FakeGmailSearch] = [:]
    var gmailSearchCount = 0
    var failNextGmailSearch = false
    var relatedSearchMatches: Bool
    var smartSearch: SmartSearchStatus
    var syncLines: [AccountID: String] = [:]
    var sent: [FakeSentMessage] = []
    var derived: [ThreadKey: DerivedThread] = [:]
    var windowCache: [WindowCacheKey: [WindowEntry]] = [:]
    var subscribers: [UUID: @Sendable () -> Void] = [:]
    var revision = 0

    init(corpus: FakeCorpus, options: FakeMailStore.Options) {
        oauthClient = options.oauthClient
        relatedSearchMatches = options.relatedSearchMatches
        smartSearch = options.relatedSearchMatches ? .ready : .off
        ids = FakeIDs()
        var maxLabelRow: Int64 = 0
        for box in corpus.mailboxes {
            var rules: [SplitKey: FakeQuery] = [:]
            for split in box.splits { rules[split.id] = try? FakeQuery.parse(split.ruleText, mode: .split) }
            accounts[box.account.id] = FakeAccountState(account: box.account, labels: box.labels, splits: box.splits,
                                                        splitRules: rules,
                                                        connectivity: .online(syncing: false, lastSyncAt: options.now()))
            nextAccount = max(nextAccount, box.account.id.rawValue + 1)
            maxLabelRow = max(maxLabelRow, box.labels.map(\.id).max() ?? 0)
            var order: [ThreadKey] = []
            order.reserveCapacity(box.threads.count)
            for thread in box.threads {
                var messages: [FakeMessage] = []
                messages.reserveCapacity(thread.allMessages.count)
                for summary in thread.allMessages {
                    messages.append(FakeMessage(summary: summary, labels: Set(thread.labels[summary.id] ?? []),
                                                bodySpec: thread.bodySpecs[summary.id],
                                                unsubscribe: thread.unsubscribe[summary.id],
                                                listID: thread.listIDs[summary.id],
                                                isFromMe: thread.fromMe.contains(summary.id)))
                    messageIndex[summary.id] = thread.row.id
                    nextMessageRow = max(nextMessageRow, summary.id.rowID + 1)
                }
                threads[thread.row.id] = FakeThread(key: thread.row.id, subject: thread.detail.subject, messages: messages)
                order.append(thread.row.id)
                nextThreadRow = max(nextThreadRow, thread.row.id.rowID + 1)
            }
            threadOrder[box.account.id] = order
            for draft in box.drafts {
                let stamp = box.draftSendStamps[draft.id]
                drafts[draft.id] = FakeDraft(
                    id: draft.id, account: draft.account, gmailDraftID: draft.gmailDraftID, thread: draft.thread,
                    mode: draft.mode, replyTo: draft.replyToGmailMessageID, fields: draft.fields, source: draft.source,
                    review: draft.review, status: stamp != nil ? .scheduled : draft.status, sendStamp: stamp,
                    version: draft.version, syncedVersion: draft.isDirty ? draft.version - 1 : draft.version,
                    hasRemoteConflict: draft.hasRemoteConflict, agentNote: draft.agentNote,
                    agentSnapshot: draft.agentSnapshot, lastError: stamp != nil ? nil : draft.lastError,
                    updatedAt: draft.updatedAt, agentVersion: draft.isAgentDraft ? draft.version : nil)
                if let thread = draft.thread { draftsByThread[thread, default: []].insert(draft.id) }
            }
            for reminder in box.reminders {
                reminders[reminder.thread] = FakeReminder(id: reminder.id, thread: reminder.thread, dueAt: reminder.dueAt,
                                                          kind: reminder.kind,
                                                          anchor: threads[reminder.thread]?.messages.last?.summary.id)
            }
        }
        for snippet in corpus.snippets { snippets[snippet.id] = snippet }
        ids.labelRow = maxLabelRow + 1
        ids.split = 100_000
        ids.draft = 100_000
        ids.reminder = 100_000
        ids.snippet = 100_000
    }
}
