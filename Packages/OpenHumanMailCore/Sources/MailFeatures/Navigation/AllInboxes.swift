import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class AllInboxesModel {
    public struct Row: Identifiable, Hashable, Sendable {
        public let thread: ThreadRow
        public let account: String
        public var id: ThreadKey { thread.id }
    }

    public nonisolated static let perAccountLimit = 200
    public nonisolated static let searchLimit = 50

    public private(set) var rows: [Row] = []
    public private(set) var cursor: ThreadKey?
    public private(set) var isLoading = true
    public private(set) var failedAccounts: [AccountID] = []
    public private(set) var isClosed = false
    public private(set) var query = ""
    public private(set) var searchAllAccounts = false
    public private(set) var isSearching = false
    public private(set) var searchFailedAccounts: [AccountID] = []
    public private(set) var searchFocusRequest = 0

    @ObservationIgnored private let accounts: [Account]
    @ObservationIgnored private var windows: [AccountID: [ThreadRow]] = [:]
    @ObservationIgnored private var inboxRows: [Row] = []
    @ObservationIgnored private var searchResults: [Row] = []
    @ObservationIgnored private var data: (any MailDataSource)?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var searchGeneration = 0
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let onOpen: @MainActor (ThreadKey) -> Void
    @ObservationIgnored private let onDone: @MainActor ([ThreadKey]) -> Bool
    @ObservationIgnored private let onLabel: @MainActor ([ThreadKey]) -> Bool
    @ObservationIgnored private var reads = ThreadListOverlay()

    public init(accounts: [Account], open: @escaping @MainActor (ThreadKey) -> Void,
                done: @escaping @MainActor ([ThreadKey]) -> Bool,
                label: @escaping @MainActor ([ThreadKey]) -> Bool = { _ in false },
                localReads: [ThreadKey: Date] = [:]) {
        self.accounts = accounts
        for (key, date) in localReads { reads.markReadLocally(key, through: date) }
        self.onLabel = label
        chipNames = Dictionary(accounts.map { ($0.id, $0.alias ?? $0.email) }, uniquingKeysWith: { first, _ in first })
        self.onOpen = open
        self.onDone = done
    }

    isolated deinit {
        for task in tasks { task.cancel() }
        searchTask?.cancel()
    }

    public var title: String { "All Inboxes" }

    public var unreadCount: Int { inboxRows.filter(\.thread.isUnread).count }

    public var unreadByAccount: [(account: String, count: Int)] {
        accounts.compactMap { account in
            let n = inboxRows.filter { $0.id.account == account.id && $0.thread.isUnread }.count
            return n == 0 ? nil : (chipNames[account.id] ?? account.email, n)
        }
    }

    // Whether these are the accounts it reads, in this order and under these names
    public func reads(_ list: [Account]) -> Bool {
        list.map(\.id) == accounts.map(\.id) && list.map(\.email) == accounts.map(\.email)
            && list.map(\.alias) == accounts.map(\.alias)
    }

    public func threadRows(for keys: [ThreadKey]) -> [ThreadRow] {
        let wanted = Set(keys)
        return (inboxRows + searchResults).map(\.thread).filter { wanted.contains($0.id) }
    }

    public var emptyText: String? {
        if isSearchActive {
            guard !isSearching, rows.isEmpty else { return nil }
            return searchFailedAccounts.isEmpty ? "No conversations match." : "Couldn't search every account."
        }
        guard !isLoading, rows.isEmpty else { return nil }
        return failedAccounts.isEmpty ? "All inboxes are empty." : "Couldn't read the inboxes."
    }

    public func start(data: any MailDataSource) {
        guard tasks.isEmpty, !isClosed else { return }
        self.data = data
        if accounts.isEmpty { isLoading = false }
        let limit = Self.perAccountLimit
        for account in accounts {
            let id = account.id
            tasks.append(Task.detached { [weak self] in
                do {
                    for try await window in data.threadWindow(.system(.inbox), account: id, limit: limit) {
                        guard !Task.isCancelled else { return }
                        await self?.apply(window.rows, for: id)
                    }
                } catch {
                    await self?.failed(id)
                }
            })
        }
    }

    func apply(_ threadRows: [ThreadRow], for account: AccountID) {
        windows[account] = threadRows
        rebuild()
    }

    func failed(_ account: AccountID) {
        if !failedAccounts.contains(account) { failedAccounts.append(account) }
        rebuild()
    }

    private func rebuild() {
        let order = accounts.map(\.id)
        let chips = Dictionary(accounts.map { ($0.id, $0.alias ?? $0.email) }, uniquingKeysWith: { first, _ in first })
        chipNames = chips
        inboxRows = Self.merge(windows, order: order).map {
            Row(thread: reads.locallyRead($0), account: chips[$0.id.account] ?? "")
        }
        isLoading = Set(windows.keys).union(failedAccounts).count < accounts.count
        refreshRows()
    }

    @ObservationIgnored private var chipNames: [AccountID: String] = [:]

    private func refreshRows() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            rows = inboxRows
        } else if searchAllAccounts {
            rows = searchResults
        } else {
            rows = Self.filter(inboxRows, by: text)
        }
        if cursor == nil || !rows.contains(where: { $0.id == cursor }) {
            cursor = rows.first?.id
        }
    }

    nonisolated static func filter(_ rows: [Row], by text: String) -> [Row] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return rows }
        return rows.filter { row in
            let haystack = [row.thread.participantsDisplay, row.thread.subject, row.thread.snippet, row.account]
                .joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    public func requestSearchFocus() { searchFocusRequest += 1 }

    public var isSearchActive: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        runSearch()
    }

    public func setSearchAllAccounts(_ on: Bool) {
        guard on != searchAllAccounts else { return }
        searchAllAccounts = on
        runSearch()
    }

    private func runSearch() {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = []
        searchFailedAccounts = []
        guard searchAllAccounts, !text.isEmpty, let data, !isClosed else {
            isSearching = false
            refreshRows()
            return
        }
        isSearching = true
        refreshRows()
        let accounts = self.accounts.map(\.id)
        let limit = Self.searchLimit
        searchTask = Task { [weak self] in
            var found: [AccountID: [ThreadRow]] = [:]
            var failed: [AccountID] = []
            await withTaskGroup(of: (AccountID, [ThreadRow]?).self) { group in
                for id in accounts {
                    group.addTask {
                        let page = try? await data.threadPage(.search(text), account: id, after: nil, limit: limit)
                        return (id, page?.rows)
                    }
                }
                for await (id, rows) in group {
                    if let rows { found[id] = rows } else { failed.append(id) }
                }
            }
            guard !Task.isCancelled else { return }
            self?.finishSearch(found, failed: accounts.filter(failed.contains), generation: generation)
        }
    }

    func finishSearch(_ found: [AccountID: [ThreadRow]], failed: [AccountID], generation: Int) {
        guard generation == searchGeneration else { return }
        let order = accounts.map(\.id)
        searchResults = Self.merge(found, order: order).map {
            Row(thread: reads.locallyRead($0), account: chipNames[$0.id.account] ?? "")
        }
        searchFailedAccounts = failed
        isSearching = false
        refreshRows()
    }

    nonisolated static func merge(_ windows: [AccountID: [ThreadRow]], order: [AccountID]) -> [ThreadRow] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return windows.values.flatMap { $0 }.sorted { a, b in
            if a.lastMessageAt != b.lastMessageAt { return a.lastMessageAt > b.lastMessageAt }
            let ra = rank[a.id.account] ?? Int.max, rb = rank[b.id.account] ?? Int.max
            if ra != rb { return ra < rb }
            return a.id.rowID > b.id.rowID
        }
    }

    public var cursorIndex: Int? { cursor.flatMap { key in rows.firstIndex { $0.id == key } } }

    @discardableResult
    public func moveCursor(by delta: Int) -> Bool {
        guard !rows.isEmpty else { return false }
        let current = cursorIndex ?? 0
        let next = min(max(current + delta, 0), rows.count - 1)
        guard next != current || cursor == nil else { return false }
        cursor = rows[next].id
        return true
    }

    public func setCursor(_ key: ThreadKey) {
        if rows.contains(where: { $0.id == key }) { cursor = key }
    }

    public func openCursor() {
        guard let cursor, !isClosed else { return }
        close()
        onOpen(cursor)
    }

    @discardableResult
    public func markDoneAtCursor() -> Bool {
        guard let cursor else { return false }
        let index = cursorIndex ?? 0
        // The neighbours before the done row leaves: a search result goes at once, an inbox row with the next window
        let below = rows.indices.contains(index + 1) ? rows[(index + 1)...].map(\.id) : []
        let above = rows.prefix(min(index, rows.count)).reversed().map(\.id)
        let started = markDone([cursor])
        if started {
            let shown = Set(rows.map(\.id))
            if let next = (below + above).first(where: shown.contains) { self.cursor = next }
        }
        return started
    }

    @discardableResult
    public func markDone(_ keys: [ThreadKey]) -> Bool {
        var started = false
        for group in Self.byAccount(keys) where onDone(group) {
            started = true
            let gone = Set(group)
            searchResults.removeAll { gone.contains($0.id) }
        }
        if started { refreshRows() }
        return started
    }

    nonisolated static func byAccount(_ keys: [ThreadKey]) -> [[ThreadKey]] {
        var order: [AccountID] = []
        var groups: [AccountID: [ThreadKey]] = [:]
        for key in keys {
            if groups[key.account] == nil { order.append(key.account) }
            groups[key.account, default: []].append(key)
        }
        return order.compactMap { groups[$0] }
    }

    @discardableResult
    public func labelAtCursor() -> Bool {
        guard let cursor, !isClosed else { return false }
        return onLabel([cursor])
    }

    public func close() {
        isClosed = true
        for task in tasks { task.cancel() }
        tasks = []
        searchTask?.cancel()
    }
}

@MainActor
final class AllInboxesActionHandler: ActionHandler {
    private weak var router: AppRouter?

    init(router: AppRouter) {
        self.router = router
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard let router else { return .hidden }
        return Self.availability(accountCount: context.accountCount, enabled: router.allInboxesEnabled)
    }

    nonisolated static func availability(accountCount: Int, enabled: Bool) -> ActionAvailability {
        accountCount >= 2 && enabled ? .enabled : .hidden
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let router, router.goToAllInboxes() else { return .notHandled }
        return .done
    }
}
