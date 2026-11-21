import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

final class AskTestSource: MailDataSource, Sendable {
    struct Search: Sendable, Equatable {
        let query: String
        let semanticText: String?
        let accounts: [AccountID]?
    }

    struct GmailCall: Sendable, Equatable {
        let query: String
        let account: AccountID
        let maxResults: Int
    }

    private struct State {
        var searches: [Search] = []
        var bodyReads: [MessageKey] = []
        var held: Set<MessageKey> = []
        var holdAll = false
        var holdDetails = false
        var completeness = SearchCompletenessInfo.complete
        var gmail: [ThreadKey] = []
        var gmailFails = false
        var gmailCalls: [GmailCall] = []
    }

    let store: FakeMailStore
    private let state = Mutex(State())

    init(_ store: FakeMailStore) {
        self.store = store
    }

    var searches: [Search] { state.withLock { $0.searches } }
    var bodyReads: [MessageKey] { state.withLock { $0.bodyReads } }
    var gmailCalls: [GmailCall] { state.withLock { $0.gmailCalls } }

    func hold(_ keys: Set<MessageKey>) { state.withLock { $0.held = keys } }
    func holdAllBodies() { state.withLock { $0.holdAll = true } }
    func holdDetails() { state.withLock { $0.holdDetails = true } }
    func olderMailMissing(searchedBack: Date?) {
        state.withLock { $0.completeness = SearchCompletenessInfo(reasons: [.olderMailNotLocal(searchedBack: searchedBack)]) }
    }
    func gmailFinds(_ threads: [ThreadKey], fails: Bool = false) {
        state.withLock { s in
            s.gmail = threads
            s.gmailFails = fails
        }
    }

    func accounts() -> AsyncThrowingStream<[Account], Error> { store.accounts() }
    func labels(_ account: AccountID) -> AsyncThrowingStream<[LabelInfo], Error> { store.labels(account) }
    func splits(_ account: AccountID) -> AsyncThrowingStream<[SplitInfo], Error> { store.splits(account) }
    func counts(_ account: AccountID) -> AsyncThrowingStream<MailboxCountsInfo, Error> { store.counts(account) }
    func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
        store.threadWindow(location, account: account, limit: limit)
    }
    func threadPage(_ location: MailLocation, account: AccountID, after: PageCursor?,
                    limit: Int) async throws -> (rows: [ThreadRow], next: PageCursor?) {
        try await store.threadPage(location, account: account, after: after, limit: limit)
    }
    func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> {
        guard state.withLock({ $0.holdDetails }) else { return store.threadDetail(key) }
        return AsyncThrowingStream { _ in }
    }

    func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> {
        let held = state.withLock { s in
            s.bodyReads.append(key)
            return s.holdAll || s.held.contains(key)
        }
        guard held else { return store.body(key) }
        return AsyncThrowingStream { $0.yield(.fetching) }
    }

    func attachmentData(_ key: MessageKey, attachment: AttachmentInfo) async throws -> URL {
        try await store.attachmentData(key, attachment: attachment)
    }
    func search(_ query: String, accounts: [AccountID]?, limit: Int) -> AsyncThrowingStream<SearchResultsInfo, Error> {
        store.search(query, accounts: accounts, limit: limit)
    }

    func searchOnce(_ query: String, semanticText: String?, accounts: [AccountID]?,
                    limit: Int) async throws -> SearchResultsInfo {
        let completeness = state.withLock { s in
            s.searches.append(Search(query: query, semanticText: semanticText, accounts: accounts))
            return s.completeness
        }
        for try await results in store.search(query, accounts: accounts, limit: limit) {
            return SearchResultsInfo(hits: results.hits, hasMore: results.hasMore, completeness: completeness)
        }
        throw MailPortError.unavailable("search")
    }

    func remoteSearch(gmailQuery: String, account: AccountID, maxResults: Int) async throws -> [ThreadKey] {
        let (threads, fails) = state.withLock { s in
            s.gmailCalls.append(GmailCall(query: gmailQuery, account: account, maxResults: maxResults))
            return (s.gmail, s.gmailFails)
        }
        if fails { throw MailPortError.unavailable("Gmail search") }
        return Array(threads.prefix(maxResults))
    }

    func drafts(_ account: AccountID?, review: Bool) -> AsyncThrowingStream<[DraftSummary], Error> {
        store.drafts(account, review: review)
    }
    func draft(_ key: DraftKey) -> AsyncThrowingStream<DraftSummary?, Error> { store.draft(key) }
    func draftSkeleton(_ input: DraftInput) async throws -> DraftFields? { try await store.draftSkeleton(input) }
    func reviewQueue(_ account: AccountID?) -> AsyncThrowingStream<[DraftSummary], Error> { store.reviewQueue(account) }
    func connectivity() -> AsyncStream<[AccountID: ConnectivityState]> { store.connectivity() }
    func syncProgress() -> AsyncStream<[AccountID: String]> { store.syncProgress() }
    func contactSuggestions(_ account: AccountID, prefix: String, limit: Int) async throws -> [EmailAddress] {
        try await store.contactSuggestions(account, prefix: prefix, limit: limit)
    }
    func snippets(_ account: AccountID?) -> AsyncThrowingStream<[SnippetInfo], Error> { store.snippets(account) }
    func reminders(_ account: AccountID?) -> AsyncThrowingStream<[ReminderItem], Error> { store.reminders(account) }
    func failedOperations(_ account: AccountID?) -> AsyncThrowingStream<[FailedOperationInfo], Error> {
        store.failedOperations(account)
    }
    func unsubscribeInfo(_ key: MessageKey) async throws -> UnsubscribeInfo? { try await store.unsubscribeInfo(key) }
    func diagnosticsSnapshot() async throws -> DiagnosticsSnapshot { try await store.diagnosticsSnapshot() }
}

@MainActor
final class AskFixture {
    static let work = AccountID(1)
    static let personal = AccountID(2)

    let store: FakeMailStore
    let source: AskTestSource
    let env: AppEnvironment
    let router: AppRouter
    let overlays: OverlayCenter
    let center: AICenter
    let model: AskModel
    let clock = TestClock()
    let pasteboard = RecordingPasteboard()

    init(providers: [any AIProvider]? = nil, settings: AISettings = AISettings(), liveConnectivity: Bool = false,
         planner: (any AskPlanning)? = nil, flags: FeatureFlags = FeatureFlags(), withAI: Bool = true,
         navigationStore: (any NavigationStateStoring)? = nil, calendar: (any CalendarProviding)? = nil) {
        store = FakeMailStore(corpus: .rich(threadCount: 60, now: fixedNow),
                              options: .init(remoteAck: .immediate, heldSends: .manual, liveConnectivity: liveConnectivity,
                                             now: { fixedNow }))
        source = AskTestSource(store)
        let registry = ProviderRegistry(providers: providers ?? [ScriptedProvider()])
        center = AICenter.make(registry: registry, settings: AISettingsBox(store: InMemoryAISettingsStore(settings)))
        center.pasteboard = pasteboard
        env = AppEnvironment(data: source, commands: store, accounts: store, settings: store, isFake: true,
                             navigationStore: navigationStore, featureFlags: flags, ai: withAI ? center : nil,
                             calendar: calendar)
        router = env.router
        overlays = env.overlays
        model = AskModel(center: center, retriever: MailAskRetriever(data: source, clock: clock), planner: planner,
                         clock: clock)
        model.locale = Locale(identifier: "en_US_POSIX")
        model.timeZone = TimeZone(identifier: "UTC")!
        center.useAsk(model)
        router.start()
    }

    func loaded() async {
        await eventually { router.active != nil && router.list?.state == .loaded && router.accounts.count == 2 }
    }

    @discardableResult
    func run(_ id: ActionID) async -> Bool {
        await env.actions.run(id, source: .keyboard, host: router)
    }

    var isAskShown: Bool {
        if case .ask = overlays.overlay { true } else { false }
    }

    func ask(_ question: String, followUp: Bool = true) async {
        if !isAskShown { await run(.aiAskInbox) }
        model.question = question
        model.ask(followUp: followUp)
        await eventually { !model.isWorking }
    }

    func conversation(matching query: String) async throws -> ConversationDetail {
        let hits = try #require(try await firstAnswer(store.search(query, accounts: [Self.work], limit: 20))).hits
        let first = try #require(hits.first, "the fake has mail for “\(query)”")
        return try #require(try await firstAnswer(store.threadDetail(first.row.id)) ?? nil)
    }
}

func firstAnswer<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T? {
    for try await value in stream { return value }
    return nil
}

final class RecordingPlanner: AskPlanning, Sendable {
    private let asked = Mutex<[String]>([])
    private let answer: AskPlan?

    init(_ answer: AskPlan?) {
        self.answer = answer
    }

    var questions: [String] { asked.withLock { $0 } }

    func plan(_ question: String, account: AccountID?) async -> AskPlan? {
        asked.withLock { $0.append(question) }
        return answer
    }
}
