import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore
import Synchronization

public protocol RecentSearchesStoring: Sendable {
    func load() -> [String]
    func save(_ queries: [String])
}

public final class InMemoryRecentSearchesStore: RecentSearchesStoring {
    private let queries = Mutex<[String]>([])
    public init() {}
    public func load() -> [String] { queries.withLock { $0 } }
    public func save(_ queries: [String]) { self.queries.withLock { $0 = queries } }
}

public struct UserDefaultsRecentSearchesStore: RecentSearchesStoring {
    public static let key = "dev.openhuman.mail.search.recents.v1"
    private let suiteName: String?

    public init(suiteName: String? = nil) { self.suiteName = suiteName }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> [String] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    public func save(_ queries: [String]) {
        guard let data = try? JSONEncoder().encode(queries) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

public struct SearchCoverageNotice: Sendable, Equatable {
    public static let searchGmailTitle = "Search Gmail"
    public static let searchGmailHint = "Asks Gmail for matching mail that is not on this Mac yet. Nothing in Gmail changes."

    public let text: String
    public let offersGmailSearch: Bool
    public let isSearching: Bool

    public init(text: String, offersGmailSearch: Bool, isSearching: Bool) {
        self.text = text
        self.offersGmailSearch = offersGmailSearch
        self.isSearching = isSearching
    }

    public static func make(_ status: SearchWindowStatus, gmail: GmailSearchState) -> SearchCoverageNotice? {
        let missing = status.completeness.reasons.first.map(phrase)
        let incomplete = missing.map { "Results may be incomplete: \($0)." }
        switch gmail {
        case .notAsked:
            guard let incomplete else { return nil }
            return SearchCoverageNotice(text: incomplete, offersGmailSearch: status.gmailAvailable, isSearching: false)
        case .searching:
            return SearchCoverageNotice(text: [incomplete, "Searching Gmail…"].compactMap { $0 }.joined(separator: " "),
                                        offersGmailSearch: false, isSearching: true)
        case .done(let added):
            let found = switch added {
            case 0: "Also searched Gmail: no more results."
            case 1: "Also searched Gmail: 1 more result, listed after these."
            default: "Also searched Gmail: \(added) more results, listed after these."
            }
            return SearchCoverageNotice(text: found, offersGmailSearch: false, isSearching: false)
        case .failed:
            return SearchCoverageNotice(text: [incomplete, "Couldn't search Gmail."].compactMap { $0 }.joined(separator: " "),
                                        offersGmailSearch: status.gmailAvailable, isSearching: false)
        }
    }

    static func phrase(_ reason: SearchIncompleteness) -> String {
        switch reason {
        case .olderMailNotLocal: "older mail isn't on this Mac yet"
        case .bodiesNotDownloaded(let messages):
            messages == 1 ? "1 message isn't fully downloaded yet"
                : "\(messages.formatted()) messages aren't fully downloaded yet"
        case .tooManyMatches(let limit): "only the newest \(limit.formatted()) matching messages were searched"
        }
    }
}

@MainActor @Observable
public final class SearchModel {
    public static let maxRecent = 10

    public private(set) var focusRequest = 0
    public private(set) var focusTaken = 0
    public private(set) var resultsFocusRequest = 0
    /// Whether the last request for the results' keys also puts the cursor on the first result (Return does; ↓ keeps
    /// the cursor where it is).
    public private(set) var resultsFocusStartsAtTop = false
    public private(set) var recents: [String]
    public private(set) var people: [SearchSuggestions.Person] = []
    public private(set) var savedSearchNameDraft: String?

    public let saved: SavedSearchesModel
    public let recentMail: RecentMailDetails
    public let contactPreview: SearchContactPreview
    public let interpretation: SearchInterpretation
    private var gmailRequest: GmailRequest?
    private var pillSelection: (query: String, pills: IndexSet)?

    @ObservationIgnored private weak var router: AppRouter?
    @ObservationIgnored private let store: any RecentSearchesStoring
    @ObservationIgnored private var returnLocations: [AccountID: MailLocation] = [:]
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var detailAccount: AccountID?
    @ObservationIgnored public var liveDelay: Duration? = .milliseconds(250)
    @ObservationIgnored private var highlighted: SearchSuggestion?

    public init(router: AppRouter, store: any RecentSearchesStoring = InMemoryRecentSearchesStore()) {
        self.router = router
        self.store = store
        self.recents = store.load()
        self.saved = SavedSearchesModel(settings: router.environment.settings)
        self.recentMail = RecentMailDetails()
        self.contactPreview = SearchContactPreview()
        self.interpretation = SearchInterpretation(source: SearchPlanSource.live(router.environment))
    }

    private var state: AccountState? { router?.active }

    public var smartSearchEnabled: Bool { router?.environment.smartSearchEnabled ?? false }

    public var isOpen: Bool { state?.searchOpen ?? false }

    public var text: String {
        get { state?.searchText ?? "" }
        set {
            guard let state, state.searchText != newValue else { return }
            state.searchText = newValue
            if pillSelection != nil { pillSelection = nil }
            queryChanged()
        }
    }

    /// The search field's pills shown selected, by position; ⌫ or ⌦ removes them. A selection belongs to the query it
    /// was made in, so any edit of the query drops it.
    public var selectedPills: IndexSet {
        get { pillSelection?.query == text ? pillSelection?.pills ?? [] : [] }
        set {
            guard newValue != selectedPills else { return }
            pillSelection = newValue.isEmpty ? nil : (text, newValue)
        }
    }

    /// Asks the search field for the keys again, after a click on one of its pills.
    public func focusField() {
        focusRequest += 1
    }

    public var tokens: [SearchToken] { SearchSyntax.tokens(text) }

    public var suggestions: [SearchSuggestion] {
        let labels = (state?.labels ?? []).filter { $0.kind == .user && !$0.isHidden }.map(\.name)
        let savedSearches = smartSearchEnabled && self.saved.account == state?.id ? self.saved.searches : []
        return SearchSuggestions.make(text: text, recents: recents, labels: labels, people: people, saved: savedSearches)
    }

    public var resultsSummary: String? {
        guard let state, case .search? = state.location, let total = state.list?.totalCount else { return nil }
        let name = state.account.alias ?? state.account.displayName ?? state.account.email
        return total == 1 ? "1 result in \(name)" : "\(total) results in \(name)"
    }

    public var shownQuery: String? {
        guard case .search(let query)? = state?.location else { return nil }
        return query
    }

    public var savedSummary: String? {
        guard smartSearchEnabled, let query = shownQuery, let search = saved.saved(forQuery: query) else { return nil }
        return "Saved as \(search.name)"
    }

    public var smartSearchHeader: SmartSearchHeaderStatus? {
        guard smartSearchEnabled, shownQuery != nil, let router else { return nil }
        return SmartSearchStatusText.header(router.environment.status.smartSearch)
    }

    public var addsRelatedResults: Bool {
        guard smartSearchEnabled, let router else { return false }
        return router.environment.status.smartSearch.addsRelatedResults
    }

    public var canSaveShownSearch: Bool {
        guard smartSearchEnabled, saved.canSave, let query = shownQuery else { return false }
        return saved.saved(forQuery: query) == nil
    }

    public var coverageNotice: SearchCoverageNotice? {
        guard let state, case .search(let query)? = state.location, let status = state.list?.searchStatus else { return nil }
        return SearchCoverageNotice.make(status, gmail: gmailState(status, account: state.id, query: query))
    }

    public var canSearchGmail: Bool { coverageNotice?.offersGmailSearch ?? false }

    public func searchGmail() {
        guard canSearchGmail, let router, let state, case .search(let query)? = state.location else { return }
        let account = state.id
        gmailRequest = GmailRequest(account: account, query: query, phase: .asking)
        let data = router.environment.data
        Task { [weak self] in
            let phase: GmailRequest.Phase
            do {
                _ = try await data.searchGmail(query, account: account)
                phase = .answered
            } catch {
                phase = .failed
            }
            guard let self, self.gmailRequest?.account == account, self.gmailRequest?.query == query else { return }
            self.gmailRequest?.phase = phase
        }
    }

    struct GmailRequest: Equatable {
        enum Phase: Equatable { case asking, answered, failed }
        let account: AccountID
        let query: String
        var phase: Phase
    }

    private func gmailState(_ status: SearchWindowStatus, account: AccountID, query: String) -> GmailSearchState {
        guard let request = gmailRequest, request.account == account, request.query == query else { return status.gmail }
        if case .done = status.gmail { return status.gmail }
        return request.phase == .failed ? .failed : .searching
    }

    public func open() {
        guard let state else { return }
        if state.mode == .reader { router?.closeReader() }
        if !state.searchOpen, let location = state.location, !Self.isSearch(location) {
            returnLocations[state.id] = location
        }
        state.searchOpen = true
        focusRequest += 1
        followAccount()
    }

    public func openSavedSearches() {
        open()
        text = ""
    }

    public func fieldTookFocus() {
        focusTaken = focusRequest
    }

    public func submit() {
        liveTask?.cancel()
        interpretation.reset()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let router else { return }
        record(query)
        gmailRequest = nil
        router.go(to: .search(query))
        resultsFocusStartsAtTop = true
        resultsFocusRequest += 1
    }

    @discardableResult
    public func focusResults() -> Bool {
        guard let location = state?.location, Self.isSearch(location) else { return false }
        resultsFocusStartsAtTop = false
        resultsFocusRequest += 1
        return true
    }

    /// Whether the suggestions offer to ask AI about the typed text (⌘J).
    public var canAskAI: Bool {
        guard let router, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let registry = router.environment.actions
        return registry.presenter != nil && registry.availability(.aiAskInbox, host: router).isEnabled
    }

    @discardableResult
    public func askAI() -> Bool {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let router else { return false }
        let registry = router.environment.actions
        guard registry.availability(.aiAskInbox, host: router).isEnabled, let presenter = registry.presenter else {
            return false
        }
        presenter.present(.askInbox(question: question))
        return true
    }

    public func escape() {
        liveTask?.cancel()
        if interpretation.isShowing {
            interpretation.dismiss()
            return
        }
        guard let state else { return }
        if !state.searchText.isEmpty {
            state.searchText = ""
            return
        }
        close()
    }

    public func close() {
        liveTask?.cancel()
        interpretation.reset()
        recentMail.reset()
        contactPreview.reset()
        highlighted = nil
        savedSearchNameDraft = nil
        guard let state, let router else { return }
        let wasSearching = state.location.map(Self.isSearch) ?? false
        state.searchOpen = false
        state.searchText = ""
        if wasSearching {
            router.go(to: returnLocations[state.id] ?? state.lastTab ?? state.firstTab)
        }
        returnLocations[state.id] = nil
    }

    public func accept(_ suggestion: SearchSuggestion) {
        switch suggestion.kind {
        case .recent, .saved:
            text = suggestion.replacement
            submit()
        default:
            text = suggestion.replacement
        }
    }

    @discardableResult
    public func acceptInterpretation() -> Bool {
        guard let query = interpretation.accept() else { return false }
        text = query
        submit()
        return true
    }

    /// What Tab completes the word being typed with: the highlighted suggestion, or with the suggestions closed the
    /// first one that completes.
    public var completion: SearchSuggestion? {
        guard SearchSuggestions.currentWord(text) != nil else { return nil }
        let suggestions = self.suggestions
        if let highlighted, suggestions.contains(highlighted) {
            return SearchSuggestions.completes(highlighted) ? highlighted : nil
        }
        return suggestions.first(where: SearchSuggestions.completes)
    }

    /// Tab: takes the interpretation when one is offered, otherwise the completion. False leaves Tab alone.
    @discardableResult
    public func acceptCompletion() -> Bool {
        if acceptInterpretation() { return true }
        guard let completion else { return false }
        accept(completion)
        return true
    }

    public func refreshPeople() async {
        guard let router, let state else {
            people = []
            return
        }
        // A lookup that was cancelled, or that finished after the text or the account changed, keeps what is there
        let asked = text, account = state.id
        func current() -> Bool { !Task.isCancelled && text == asked && self.state?.id == account }
        if text.isEmpty {
            let found = (try? await router.environment.data.contactSuggestions(state.id, prefix: "",
                                                                             limit: SearchSuggestions.maxPeople)) ?? []
            guard current() else { return }
            people = found.map { SearchSuggestions.Person(name: $0.name, email: $0.email) }
            return
        }
        guard let word = SearchSuggestions.currentWord(text) else {
            people = []
            return
        }
        var body = word.text
        if body.hasPrefix("-") { body.removeFirst() }
        var addressed = false
        if let colon = body.firstIndex(of: ":") {
            guard ["from", "to"].contains(body[..<colon].lowercased()) else { people = []; return }
            body = String(body[body.index(after: colon)...])
            addressed = true
        }
        if body.hasPrefix("\"") { body.removeFirst() }
        // A bare from: or to: offers the people written to most, to arrow through
        guard body.count >= 2 || (addressed && body.isEmpty) else { people = []; return }
        let found = (try? await router.environment.data.contactSuggestions(state.id, prefix: body, limit: 5)) ?? []
        guard current() else { return }
        people = found.map { SearchSuggestions.Person(name: $0.name, email: $0.email) }
    }

    /// The suggestion under the cursor. A person shows in the preview beside the suggestions; with Smart Search on,
    /// their recent mail is looked up for it and for the row.
    public func highlight(_ suggestion: SearchSuggestion?) {
        highlighted = suggestion
        let person = suggestion?.kind == .person ? suggestion : nil
        if smartSearchEnabled { followAccount() }
        contactPreview.show(name: person.flatMap { $0.detail == nil ? nil : $0.title }, email: person?.email,
                            looksUp: smartSearchEnabled)
        guard smartSearchEnabled else { return }
        recentMail.highlight(person?.email)
    }

    public func personDetail(_ suggestion: SearchSuggestion) -> String? {
        guard smartSearchEnabled, suggestion.kind == .person, let email = suggestion.email else { return nil }
        return recentMail.detail(for: email)
    }

    public func saveShownSearch() async {
        guard smartSearchEnabled, let query = shownQuery else { return }
        followAccount()
        guard let stored = await saved.save(query: query) else { return }
        savedSearchNameDraft = stored.name
    }

    public func commitSavedSearchName(_ name: String) async {
        defer { savedSearchNameDraft = nil }
        guard let query = shownQuery, let search = saved.saved(forQuery: query) else { return }
        await saved.rename(search.id, to: name)
    }

    public func cancelSavedSearchName() {
        savedSearchNameDraft = nil
    }

    public func deleteShownSavedSearch() async {
        guard let query = shownQuery, let search = saved.saved(forQuery: query) else { return }
        savedSearchNameDraft = nil
        await saved.delete(search.id)
    }

    public func followAccount() {
        guard let router, let state else { return }
        saved.follow(state.id)
        guard detailAccount != state.id else { return }
        detailAccount = state.id
        recentMail.reset()
        contactPreview.reset()
        let data = router.environment.data
        let account = state.id
        recentMail.lookup = { email in try? await data.recentThreads(involving: email, account: account, limit: 1).first }
        contactPreview.lookup = { email in
            (try? await data.recentThreads(involving: email, account: account, limit: SearchContactPreview.maxConversations)) ?? []
        }
    }

    private func queryChanged() {
        liveTask?.cancel()
        interpretation.textChanged(text, context: smartSearchEnabled ? interpretationContext() : nil)
        guard let liveDelay, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        liveTask = Task { [weak self] in
            try? await Task.sleep(for: liveDelay)
            guard !Task.isCancelled, let self, let state = self.state else { return }
            let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }
            self.router?.go(to: .search(query))
        }
    }

    private func interpretationContext() -> SearchInterpretation.Context? {
        guard let router, let state else { return nil }
        let data = router.environment.data
        let account = state.id
        return SearchInterpretation.Context(
            account: account, accountKey: router.environment.ai?.policyKey(account), labels: state.labels,
            contacts: { prefix in (try? await data.contactSuggestions(account, prefix: prefix, limit: 5)) ?? [] })
    }

    private func record(_ query: String) {
        recents.removeAll { $0 == query }
        recents.insert(query, at: 0)
        if recents.count > Self.maxRecent { recents.removeLast(recents.count - Self.maxRecent) }
        store.save(recents)
    }

    private static func isSearch(_ location: MailLocation) -> Bool {
        if case .search = location { return true }
        return false
    }
}
