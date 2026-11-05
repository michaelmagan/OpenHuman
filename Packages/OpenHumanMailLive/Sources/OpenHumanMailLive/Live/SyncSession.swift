import Foundation
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore
import OpenHumanSync
import Synchronization

public final class SyncSession: Sendable {
    public struct Wiring: Sendable {
        var factory: DefaultGmailClientFactory
        var gmail: GmailClientConfig
        var metrics: SyncMetricsRegistry
        var tokenStore: (any TokenStore)?
        var oauthClient: OAuthClientConfig?
        var clock: any OHClock
        var pollInterval: Duration
        var systemEvents: (any StoppableSystemEvents)?
        var tokenEvents: AsyncStream<TokenEvent>?
        var draftsDirectory: URL? = nil
        var unsubscribeTransport: (any HTTPTransport)? = nil
        var accounts: (any AccountManaging)? = nil
        var calendar: GoogleCalendarSession? = nil
        var calendarConnections: LiveCalendarConnections? = nil
        var api: (any GmailAPI)? = nil

        public init(factory: DefaultGmailClientFactory, gmail: GmailClientConfig, metrics: SyncMetricsRegistry,
                    tokenStore: (any TokenStore)? = nil, oauthClient: OAuthClientConfig? = nil, clock: any OHClock,
                    pollInterval: Duration, systemEvents: (any StoppableSystemEvents)? = nil,
                    tokenEvents: AsyncStream<TokenEvent>? = nil, draftsDirectory: URL? = nil,
                    unsubscribeTransport: (any HTTPTransport)? = nil, accounts: (any AccountManaging)? = nil) {
            self.factory = factory
            self.gmail = gmail
            self.metrics = metrics
            self.tokenStore = tokenStore
            self.oauthClient = oauthClient
            self.clock = clock
            self.pollInterval = pollInterval
            self.systemEvents = systemEvents
            self.tokenEvents = tokenEvents
            self.draftsDirectory = draftsDirectory
            self.unsubscribeTransport = unsubscribeTransport
            self.accounts = accounts
        }
    }

    let account: AccountID
    public let email: String
    public let store: MailStore
    let api: any GmailAPI
    let engine: MailEngine
    public let environment: AppEnvironment
    let calendar: GoogleCalendarSession?
    let calendarConnections: LiveCalendarConnections?
    private let systemEvents: (any StoppableSystemEvents)?
    private let tokenEvents: AsyncStream<TokenEvent>?
    private let relay = Mutex<Task<Void, Never>?>(nil)
    private let eventRelay = Mutex<Task<Void, Never>?>(nil)

    @MainActor
    public init(account item: AccountItem, store: MailStore, wiring: Wiring, isFake: Bool) throws {
        account = item.id
        email = item.email
        self.store = store
        api = try wiring.api ?? wiring.factory.client(for: item.email)
        systemEvents = wiring.systemEvents
        tokenEvents = wiring.tokenEvents
        calendar = wiring.calendar
        calendarConnections = wiring.calendarConnections
        let slot = EngineSlot()
        let account = item.id
        var oneClick: (@Sendable (MessageKey) async throws -> Void)?
        if let transport = wiring.unsubscribeTransport {
            let request = OneClickUnsubscribe(store: store, transport: transport)
            oneClick = { key in try await request.send(key) }
        }
        let commands = MailStoreCommands(engine: { try slot.engine() }, oneClick: oneClick)
        environment = CompositionRoot.environment(
            store: store,
            ensureBody: { key in
                _ = try await slot.engine().ensureBody(account: key.account, gmailMessageID: key.gmailMessageID)
            },
            attachmentFile: { key, attachment in try await Self.attachmentFile(slot.engine(), key, attachment) },
            connectivity: { Self.connectivity(slot, store: store) },
            syncProgress: { Self.progressLines(slot) },
            commands: commands, accounts: wiring.accounts,
            draftsDirectory: wiring.draftsDirectory,
            isFake: isFake, isLiveAccount: !isFake, onDemand: Self.onDemand(slot),
            calendar: wiring.calendarConnections == nil ? wiring.calendar?.provider : nil,
            calendarConnection: wiring.calendar, calendarConnections: wiring.calendarConnections)
        let configuration = EngineConfiguration(
            role: .app, appVersion: CompositionRoot.appVersion, gmail: wiring.gmail, pollInterval: wiring.pollInterval,
            clock: wiring.clock, schedulers: Self.schedulers(environment.modules))
        engine = MailEngine(store: store, gmailFactory: wiring.factory, tokenStore: wiring.tokenStore,
                            oauthClient: wiring.oauthClient, configuration: configuration,
                            systemEvents: wiring.systemEvents, metrics: { wiring.metrics.collector(for: $0) })
        slot.set(engine)
        Log(.sync).notice("account \(account.rawValue): engine session" + (isFake ? " on FakeGmail" : " on a real account"))
    }

    public func start() async {
        let engine = self.engine
        if let tokenEvents {
            relay.withLock { task in
                guard task == nil else { return }
                task = Task { for await event in tokenEvents { await engine.handle(event) } }
            }
        }
        let environment = self.environment
        eventRelay.withLock { task in
            guard task == nil else { return }
            let events = engine.events
            task = Task {
                for await event in events {
                    guard let notice = EngineNotices.notice(for: event) else { continue }
                    await environment.system.handle(notice)
                }
            }
        }
        await engine.start()
        if let connections = calendarConnections, let accounts = try? store.accounts() {
            let signedIn = accounts.filter { $0.status != .removing && $0.status != .disabled }.map { (id: $0.id, email: $0.email) }
            Task { await connections.resume(signedIn) }
        }
    }

    func stop() async {
        await engine.stop()
        relay.withLock { $0?.cancel() }
        eventRelay.withLock { $0?.cancel() }
        systemEvents?.stop()
    }

    func shutdown() async {
        await engine.flushPendingSends(deadline: .seconds(5))
        await stop()
    }

    public func refreshInBackground(until deadline: Date) async -> RefreshReport {
        await engine.refreshOnce(deadline: deadline)
    }

    var backfillProgress: SyncProgress? { engine.syncProgress(account) }

    @MainActor
    static func schedulers(_ modules: ModuleRegistry) -> Set<ScheduleKind> {
        Set(modules.scheduleKinds.compactMap { ScheduleKind(rawValue: $0.rawValue) })
    }

    static func onDemand(_ slot: EngineSlot) -> MailStoreAdapter.OnDemand {
        MailStoreAdapter.OnDemand(
            remoteSearch: { query, account in try await slot.engine().remoteSearch(query, account: account, maxResults: 50) },
            loadView: { view in try await slot.engine().ensureViewLoaded(view) },
            remoteSearchCapped: { query, account, maxResults in
                try await slot.engine().remoteSearch(query, account: account, maxResults: maxResults)
            })
    }

    static func attachmentFile(_ engine: MailEngine, _ key: MessageKey,
                               _ attachment: AttachmentInfo) async throws -> URL {
        do {
            return try await engine.attachmentFile(account: key.account, message: key.gmailMessageID,
                                                   attachment: attachment.id)
        } catch let failure as AttachmentFetcher.Failure {
            switch failure {
            case .notFound, .noContent: throw MailPortError.notFound("attachment")
            case .tooLarge: throw MailPortError.limitExceeded("attachments over 30 MB open in Gmail")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let kind = String(describing: type(of: error))
            Log(.sync).notice("account \(key.account.rawValue): attachment \(attachment.id) failed (\(kind))")
            throw MailPortError.unavailable("the attachment couldn't be downloaded")
        }
    }

    static func progressLines(_ slot: EngineSlot) -> AsyncStream<[AccountID: String]> {
        guard let engine = slot.current else { return AsyncStream { $0.finish() } }
        let stream = engine.observeSyncProgress()
        return AsyncStream { continuation in
            let task = Task {
                var last: [AccountID: String]?
                for await progress in stream {
                    let lines = Self.lines(progress)
                    guard lines != last else { continue }
                    last = lines
                    continuation.yield(lines)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func lines(_ progress: [AccountID: SyncProgress]) -> [AccountID: String] {
        var lines: [AccountID: String] = [:]
        for (account, value) in progress {
            if let text = value.statusText { lines[account] = text }
        }
        return lines
    }

    static func connectivity(_ slot: EngineSlot, store: MailStore) -> AsyncStream<[AccountID: ConnectivityState]> {
        guard let engine = slot.current else { return AsyncStream { $0.finish() } }
        return connectivity(engine.observeConnectivity(), store: store)
    }

    static func connectivity(_ engineStates: AsyncStream<[AccountID: AccountConnectivity]>,
                             store: MailStore) -> AsyncStream<[AccountID: ConnectivityState]> {
        AsyncStream { continuation in
            let merge = ConnectivityMerge(store: store) { continuation.yield($0) }
            let fromEngine = Task {
                for await states in engineStates { merge.engineChanged(states) }
            }
            let fromAccounts = Task {
                do {
                    for try await accounts in store.observeAccounts().values() { merge.accountsChanged(accounts.map(\.id)) }
                } catch {}
            }
            continuation.onTermination = { _ in
                fromEngine.cancel()
                fromAccounts.cancel()
                merge.stop()
            }
        }
    }

    func currentConnectivity() async -> ConnectivityState {
        var states = engine.observeConnectivity().makeAsyncIterator()
        let engineState = await states.next()?[account]
        return Self.connectivityState(engineState, status: try? store.syncStatus(account: account),
                                      accountStatus: (try? store.accounts())?.first { $0.id == account }?.status)
    }

    static func connectivityState(_ engine: AccountConnectivity?, status: SyncStatus?,
                                  accountStatus: AccountStatus?) -> ConnectivityState {
        if accountStatus == .needsReauth { return .needsReauth }
        switch engine {
        case .needsReauth?: return .needsReauth
        case .offline(let since)?: return .offline(since: since)
        case .rateLimited(let until)?: return .rateLimited(until: until)
        case .ownedElsewhere(_, let lastSyncAt)?:
            return .syncFailing(code: "owned_elsewhere", failures: 0, lastSyncAt: lastSyncAt ?? status?.lastSuccessAt)
        case .online?, nil:
            break
        }
        guard let status else { return .online(syncing: true, lastSyncAt: nil) }
        if status.consecutiveFailures > 0 {
            let code = status.lastError ?? "error"
            if code.hasPrefix("transport:") { return .offline(since: status.lastSuccessAt) }
            if code == "rate_limited" || code == "daily_limit" || code == "quota_budget_exhausted" {
                return .rateLimited(until: nil)
            }
            if code == "reauth_required" { return .needsReauth }
            return .syncFailing(code: code, failures: status.consecutiveFailures, lastSyncAt: status.lastSuccessAt)
        }
        let initial: Bool = switch status.phase {
        case .new, .bootstrapping, .resyncRequired: true
        case .inboxReady, .backfilling, .incremental: false
        }
        return .online(syncing: initial, lastSyncAt: status.lastSuccessAt)
    }
}

final class EngineSlot: Sendable {
    private let value = Mutex<MailEngine?>(nil)

    var current: MailEngine? { value.withLock { $0 } }

    func set(_ engine: MailEngine) { value.withLock { $0 = engine } }

    func engine() throws -> MailEngine {
        guard let engine = current else { throw MailPortError.unavailable("Mail isn't syncing") }
        return engine
    }
}

public final class SyncMetricsRegistry: Sendable {
    private let collectors = Mutex<[String: SyncMetricsCollector]>([:])

    public init() {}

    public func collector(for email: String) -> SyncMetricsCollector {
        let key = email.lowercased()
        return collectors.withLock { all in
            if let existing = all[key] { return existing }
            let made = SyncMetricsCollector()
            all[key] = made
            return made
        }
    }
}

private final class ConnectivityMerge: Sendable {
    private struct State {
        var engine: [AccountID: AccountConnectivity] = [:]
        var accounts: [AccountID] = []
        var watchers: [AccountID: Task<Void, Never>] = [:]
        var last: [AccountID: ConnectivityState]?
        var stopped = false
    }
    private let state = Mutex(State())
    private let serial = Mutex(())
    private let store: MailStore
    private let publish: @Sendable ([AccountID: ConnectivityState]) -> Void

    init(store: MailStore, publish: @escaping @Sendable ([AccountID: ConnectivityState]) -> Void) {
        self.store = store
        self.publish = publish
    }

    func engineChanged(_ states: [AccountID: AccountConnectivity]) { recompute { $0.engine = states } }

    func storeChanged() { recompute { _ in } }

    func accountsChanged(_ ids: [AccountID]) {
        let store = self.store
        recompute { s in
            guard !s.stopped else { return }
            s.accounts = ids
            for (id, task) in s.watchers where !ids.contains(id) {
                task.cancel()
                s.watchers[id] = nil
            }
            for id in ids where s.watchers[id] == nil {
                s.watchers[id] = Task { [weak self] in
                    do {
                        for try await _ in store.observeSyncStatus(account: id).values() { self?.storeChanged() }
                    } catch {}
                }
            }
        }
    }

    func stop() {
        let watchers = state.withLock { s -> [Task<Void, Never>] in
            s.stopped = true
            let all = Array(s.watchers.values)
            s.watchers = [:]
            return all
        }
        for task in watchers { task.cancel() }
    }

    // Why: an engine change and a store change recompute from different tasks; unserialized, the one that read the store
    // first could publish last and leave the status area on a stale state that later identical recomputes never replace
    private func recompute(_ change: (inout State) -> Void) {
        serial.withLock { _ in recomputeSerially(change) }
    }

    private func recomputeSerially(_ change: (inout State) -> Void) {
        let ids = state.withLock { s -> [AccountID] in
            change(&s)
            return s.accounts
        }
        let rows = (try? store.accounts()) ?? []
        var statuses: [AccountID: SyncStatus] = [:]
        for id in ids { statuses[id] = try? store.syncStatus(account: id) }
        let next: [AccountID: ConnectivityState]? = state.withLock { s in
            guard !s.stopped else { return nil }
            var mapped: [AccountID: ConnectivityState] = [:]
            for id in ids where s.accounts.contains(id) {
                mapped[id] = SyncSession.connectivityState(s.engine[id], status: statuses[id],
                                                           accountStatus: rows.first { $0.id == id }?.status)
            }
            if mapped.isEmpty, s.last == nil { return nil }
            guard mapped != s.last else { return nil }
            s.last = mapped
            return mapped
        }
        if let next { publish(next) }
    }
}
