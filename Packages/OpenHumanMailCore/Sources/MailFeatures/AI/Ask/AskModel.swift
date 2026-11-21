import Foundation
import MailModel
import Observation
import OpenHumanAI
import OpenHumanCore

@MainActor @Observable
public final class AskModel {
    public enum Scope: Hashable, Sendable {
        case account(AccountID)
        case allAccounts
        case conversation(ThreadKey)
    }

    public enum Phase: Equatable, Sendable {
        case idle, retrieving, planning, answering, done, notFound, stopped
        case failed(AskFailure)
    }

    public enum Row: Hashable, Sendable, Identifiable {
        case source(AskSource)
        case otherMatch(AskSource)
        case showMore(Int)
        case olderMail

        public var id: String {
            switch self {
            case .source(let source): "source.\(source.id.account.rawValue).\(source.id.rowID)"
            case .otherMatch(let source): "match.\(source.id.account.rawValue).\(source.id.rowID)"
            case .showMore: "showMore"
            case .olderMail: "olderMail"
            }
        }
    }

    public static let memoryLifetime: Duration = .seconds(30 * 60)
    public static let historyLimit = 10
    public static let followUpMaxWords = 8
    public static let otherMatchesShown = 3
    public static let otherMatchesMax = 10

    public var question = ""
    public private(set) var scope: Scope = .allAccounts
    public private(set) var scopes: [Scope] = []
    public private(set) var phase: Phase = .idle
    public private(set) var answer = ""
    public private(set) var sources: [AskSource] = []
    public private(set) var otherMatches: [AskSource] = []
    public private(set) var planLine: String?
    public private(set) var provenance: AIProvenance?
    public private(set) var report: AIOutputReport?
    public private(set) var olderMail: OlderMailState?
    public private(set) var askedAt: Date?
    public private(set) var statusText: String?
    public private(set) var consent: AIProviderConsentRequest?
    public private(set) var cursor: Int?
    public private(set) var showsAllOtherMatches = false
    public private(set) var isReopened = false

    @ObservationIgnored private weak var center: AICenter?
    @ObservationIgnored let retriever: any AskRetrieving
    @ObservationIgnored let planner: (any AskPlanning)?
    @ObservationIgnored let clock: any OHClock
    @ObservationIgnored public var locale: Locale = .current
    @ObservationIgnored public var timeZone: TimeZone = .current
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var lastRetrieval: AskRetrieval?
    @ObservationIgnored private var lastQuestion: String?
    @ObservationIgnored private var lastAsked: String?
    @ObservationIgnored private var memoryAccount: AccountID?
    @ObservationIgnored private var history: [String] = []
    @ObservationIgnored private var historyIndex: Int?
    @ObservationIgnored private var scopeChoice: [Bool: ScopeKind] = [:]
    @ObservationIgnored private var dismissPanel: (@MainActor () -> Void)?
    @ObservationIgnored public private(set) var isPresented = false
    @ObservationIgnored private var presentedAccount: AccountID?
    @ObservationIgnored private var switchingForSource = false

    public init(center: AICenter, retriever: any AskRetrieving, planner: (any AskPlanning)? = nil,
                clock: any OHClock = SystemClock()) {
        self.center = center
        self.retriever = retriever
        self.planner = planner
        self.clock = clock
    }

    isolated deinit {
        task?.cancel()
        watchdog?.cancel()
    }

    private var router: AppRouter? { center?.environment?.router }

    public var aiCenter: AICenter? { center }

    public var isWorking: Bool { phase == .retrieving || phase == .planning || phase == .answering }
    public var badge: AIProviderBadge? { provenance.map(AIProviderBadge.init(provenance:)) }
    public var isSuspicious: Bool { report?.suspicious == true }
    public var isTruncated: Bool { report?.truncated == true }
    public var canCopyAnswer: Bool { !answer.isEmpty && !isWorking }
    public var canShowAsList: Bool { lastRetrieval?.queryText != nil }
    public var hasAnswer: Bool { (phase == .done || phase == .stopped) && !answer.isEmpty }

    public var scopeTitle: String { title(of: scope) }

    public func title(of scope: Scope) -> String {
        switch scope {
        case .account(let id):
            guard let account = router?.accounts.first(where: { $0.id == id })?.account else { return AskWording.title }
            return account.alias ?? account.displayName ?? account.email
        case .allAccounts:
            return AskWording.allAccounts
        case .conversation:
            return AskWording.thisConversation
        }
    }

    public var visibleOtherMatches: [AskSource] {
        showsAllOtherMatches ? otherMatches : Array(otherMatches.prefix(Self.otherMatchesShown))
    }

    public var hiddenOtherMatchCount: Int { otherMatches.count - visibleOtherMatches.count }

    public var showsOlderMailRow: Bool {
        guard let olderMail, olderMail != .done else { return false }
        if olderMail == .searching { return true }
        return phase == .notFound || (phase == .done && sources.isEmpty)
    }

    public var olderMailEnabled: Bool {
        switch olderMail {
        case .available?, .failed?: true
        default: false
        }
    }

    public var olderMailText: String? {
        switch olderMail {
        case .available(let searchedBack)?:
            AskWording.olderMail(before: searchedBack.map { format($0, .dateTime.month(.abbreviated).year()) })
        case .searching?: AskWording.searchingGmail
        case .offline?: AskWording.offline
        case .failed?: AskWording.gmailFailed
        case .done?, nil: nil
        }
    }

    public var rows: [Row] {
        var out = sources.map(Row.source) + visibleOtherMatches.map(Row.otherMatch)
        if hiddenOtherMatchCount > 0 { out.append(.showMore(hiddenOtherMatchCount)) }
        if showsOlderMailRow { out.append(.olderMail) }
        return out
    }

    public var askedAtText: String? {
        guard isReopened, let askedAt else { return nil }
        return AskWording.askedAt(format(askedAt, Date.FormatStyle(date: .omitted, time: .shortened)))
    }

    public var footer: String {
        if isWorking { return AskWording.footerWorking }
        return rows.isEmpty && answer.isEmpty ? AskWording.footerIdle : AskWording.footerDone
    }

    public var readyAnnouncement: String? {
        phase == .done ? AskWording.ready(sources: sources.count) : nil
    }

    public func dateText(_ source: AskSource) -> String {
        format(source.date, .dateTime.month(.abbreviated).day())
    }

    public func spokenLabel(_ row: Row) -> String {
        switch row {
        case .source(let source):
            let index = (sources.firstIndex(of: source) ?? 0) + 1
            return AskWording.spokenSource(index, of: sources.count, sender: source.sender, subject: source.subject,
                                           date: format(source.date, .dateTime.month(.wide).day()))
        case .otherMatch(let source):
            return AskWording.spokenMatch(sender: source.sender, subject: source.subject,
                                          date: format(source.date, .dateTime.month(.wide).day()))
        case .showMore(let count):
            return AskWording.showMore(count)
        case .olderMail:
            return olderMailText ?? ""
        }
    }

    private func format(_ date: Date, _ style: Date.FormatStyle) -> String {
        var style = style
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    func presented(question asked: String?, dismiss: @escaping @MainActor () -> Void) {
        dismissPanel = dismiss
        isPresented = true
        presentedAccount = router?.activeAccountID
        forgetIfStale()
        resolveScopes()
        cursor = nil
        observeAccount()
        let text = asked?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            question = text
            ask(followUp: false)
        } else {
            isReopened = askedAt != nil && phase != .idle
        }
    }

    func panelClosed() {
        isPresented = false
        dismissPanel = nil
        cursor = nil
        if isWorking {
            _ = begin()
            phase = .idle
            askedAt = nil
            if olderMail == .searching { olderMail = .failed }
        }
    }

    public func close() {
        if let dismissPanel {
            dismissPanel()
        } else {
            panelClosed()
        }
    }

    public func escape() {
        if isWorking {
            stop()
        } else if !question.isEmpty {
            question = ""
            historyIndex = nil
        } else {
            close()
        }
    }

    public func cycleScope(by delta: Int) {
        guard !scopes.isEmpty else { return }
        let index = scopes.firstIndex(of: scope) ?? 0
        let count = scopes.count
        select(scopes[((index + delta) % count + count) % count])
    }

    public func select(_ scope: Scope) {
        guard scopes.contains(scope) else { return }
        self.scope = scope
        scopeChoice[router?.mode == .reader] = ScopeKind(scope)
    }

    private enum ScopeKind {
        case account, allAccounts, conversation

        init(_ scope: Scope) {
            switch scope {
            case .account: self = .account
            case .allAccounts: self = .allAccounts
            case .conversation: self = .conversation
            }
        }
    }

    private func resolveScopes() {
        guard let router, let active = router.active else {
            scopes = []
            return
        }
        let inConversation = router.mode == .reader
        var available: [Scope] = [.account(active.id)]
        if router.accounts.count >= 2 { available.append(.allAccounts) }
        if inConversation, let thread = router.reader?.thread { available.append(.conversation(thread)) }
        let remembered = askedAt != nil && phase != .idle
        if remembered, !available.contains(scope) { available.append(scope) }
        scopes = available
        guard !remembered else { return }
        let kind = scopeChoice[inConversation] ?? .account
        scope = available.first { ScopeKind($0) == kind } ?? available[0]
    }

    public func submit() {
        if let cursor, rows.indices.contains(cursor) {
            activate(rows[cursor])
        } else {
            ask()
        }
    }

    @discardableResult
    public func moveDown() -> Bool {
        let count = rows.count
        guard count > 0 else { return false }
        cursor = min((cursor ?? -1) + 1, count - 1)
        return true
    }

    @discardableResult
    public func moveUp() -> Bool {
        if let cursor {
            self.cursor = cursor == 0 ? nil : cursor - 1
            return true
        }
        return previousQuestion()
    }

    public func moveCursor(to index: Int) {
        guard rows.indices.contains(index) else { return }
        cursor = index
    }

    @discardableResult
    public func previousQuestion() -> Bool {
        guard !history.isEmpty else { return false }
        let typed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: Int
        if let index = historyIndex, history.indices.contains(index), typed == history[index] {
            next = max(index - 1, 0)
        } else {
            guard typed.isEmpty else { return false }
            next = history.count - 1
        }
        historyIndex = next
        question = history[next]
        return true
    }

    public func activate(_ row: Row) {
        switch row {
        case .source(let source), .otherMatch(let source):
            open(source)
        case .showMore:
            showsAllOtherMatches = true
        case .olderMail:
            searchOlderMail()
        }
    }

    public func ask(followUp: Bool = true) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, center != nil else { return }
        let previous: String? = if followUp, hasAnswer, let lastQuestion, lastQuestion != text,
                                   Self.wordCount(text) <= Self.followUpMaxWords { lastQuestion } else { nil }
        remember(text)
        let generation = begin()
        lastQuestion = text
        askedAt = clock.now
        memoryAccount = router?.activeAccountID
        phase = .retrieving
        let scope = self.scope
        task = Task { [weak self] in
            await self?.run(text, previous: previous, scope: scope, generation: generation)
        }
    }

    public func stop() {
        guard isWorking else { return }
        cancelWork()
        if olderMail == .searching { olderMail = .failed }
        phase = .stopped
    }

    private func run(_ text: String, previous: String?, scope: Scope, generation: Int) async {
        guard let center else { return }
        guard center.settings.enabled else { return fail(.aiOff, generation) }
        let status = await center.features.status(for: .askInbox, accountKey: policyKey(scope))
        guard isCurrent(generation) else { return }
        if case .unavailable(let reason) = status.availability {
            return await unavailable(reason, providerID: status.providerID, providerName: status.providerName,
                                     generation: generation)
        }
        var plan: AskPlan?
        if let planner, !Self.isConversation(scope), AskCueWords.containsCue(text) {
            phase = .planning
            plan = await planner.plan(text, account: account(of: scope))
            guard isCurrent(generation) else { return }
            phase = .retrieving
        }
        var retrieval: AskRetrieval
        do {
            retrieval = try await retriever.retrieve(previous.map { text + " " + $0 } ?? text, scope: scope, plan: plan)
        } catch {
            guard isCurrent(generation) else { return }
            return retrievalFailed(error, generation)
        }
        guard isCurrent(generation) else { return }
        let askedWords = previous.map { text + " " + $0 } ?? text
        if !Self.isConversation(scope), let calendar = center.environment?.calendar, AskCalendarEvents.isAbout(askedWords) {
            let events = await AskCalendarEvents.candidates(provider: calendar, now: clock.now, timeZone: timeZone)
            guard isCurrent(generation) else { return }
            retrieval = AskCalendarEvents.merge(retrieval, events: events)
        }
        lastRetrieval = retrieval
        planLine = previous.map(AskWording.followingUp) ?? retrieval.planLine
        olderMail = olderMailOffer(retrieval, scope: scope)
        guard !retrieval.candidates.isEmpty else {
            phase = .notFound
            statusText = AskWording.nothingMatches(retrieval.searched)
            return
        }
        let asked = previous.map { AskWording.followUpQuestion(previous: $0, question: text) } ?? text
        lastAsked = asked
        await stream(asked, retrieval: retrieval, generation: generation)
    }

    private func stream(_ asked: String, retrieval: AskRetrieval, generation: Int) async {
        guard let center else { return }
        phase = .answering
        startWatchdog(generation)
        do {
            for try await event in center.features.askInbox(asked, candidates: retrieval.candidates) {
                guard isCurrent(generation) else { return }
                switch event {
                case .started(let provenance):
                    self.provenance = provenance
                    if provenance.providerID.isAgentCLI { watchdog?.cancel() }
                case .textDelta(let delta):
                    answer += delta
                case .citations(let ids):
                    sources = Self.sources(cited: ids, in: retrieval)
                case .completed(let report):
                    self.report = report
                }
            }
        } catch {
            guard isCurrent(generation) else { return }
            watchdog?.cancel()
            return await answerFailed(error, generation: generation)
        }
        guard isCurrent(generation) else { return }
        watchdog?.cancel()
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fail(.failed(AskWording.emptyAnswer), generation)
        }
        otherMatches = Self.otherMatches(retrieval, excluding: sources)
        phase = .done
    }

    static func sources(cited: [String], in retrieval: AskRetrieval) -> [AskSource] {
        var seen = Set<ThreadKey>()
        var out: [AskSource] = []
        for id in cited {
            guard let source = retrieval.sources[id], seen.insert(source.thread).inserted else { continue }
            out.append(source)
        }
        return Array(out.prefix(AIPolicy.askInboxMaxCandidates))
    }

    static func otherMatches(_ retrieval: AskRetrieval, excluding cited: [AskSource]) -> [AskSource] {
        let citedThreads = Set(cited.map(\.thread))
        return Array(retrieval.otherThreads.filter { !citedThreads.contains($0.thread) }.prefix(otherMatchesMax))
    }

    private func olderMailOffer(_ retrieval: AskRetrieval, scope: Scope) -> OlderMailState? {
        guard let completeness = retrieval.completeness, retrieval.gmailQuery != nil, case .account(let id) = scope
        else { return nil }
        if case .offline? = center?.environment?.status.connectivity[id] { return .offline }
        return .available(searchedBack: completeness.searchedBack)
    }

    public func searchOlderMail() {
        guard olderMailEnabled, let retrieval = lastRetrieval, let gmailQuery = retrieval.gmailQuery,
              let account = retrieval.queryAccount, let question = lastQuestion else { return }
        let asked = lastAsked ?? question
        let generation = begin()
        olderMail = .searching
        phase = .retrieving
        planLine = AskWording.searchingGmail
        task = Task { [weak self] in
            await self?.runOlderMail(question, asked: asked, gmailQuery: gmailQuery, account: account,
                                     generation: generation)
        }
    }

    private func runOlderMail(_ question: String, asked: String, gmailQuery: String, account: AccountID,
                              generation: Int) async {
        let retrieval: AskRetrieval
        do {
            retrieval = try await retriever.retrieveOlderMail(question, gmailQuery: gmailQuery, account: account)
        } catch {
            guard isCurrent(generation) else { return }
            olderMail = .failed
            phase = .notFound
            statusText = nil
            planLine = lastRetrieval?.planLine
            return
        }
        guard isCurrent(generation) else { return }
        olderMail = .done
        planLine = retrieval.planLine
        guard !retrieval.candidates.isEmpty else {
            phase = .notFound
            statusText = AskWording.nothingInGmail(retrieval.searched)
            return
        }
        lastRetrieval?.candidates = retrieval.candidates
        lastRetrieval?.keys = retrieval.keys
        lastRetrieval?.sources = retrieval.sources
        lastRetrieval?.otherThreads = retrieval.otherThreads
        await stream(asked, retrieval: retrieval, generation: generation)
    }

    public func open(_ source: AskSource) {
        guard let router else { return }
        close()
        if source.thread.account != router.active?.id {
            switchingForSource = true
            router.switchAccount(to: source.thread.account)
            switchingForSource = false
            memoryAccount = source.thread.account
        }
        router.open(source.thread)
        focusWhenShown(source.id, in: source.thread, attempts: 40)
    }

    private func focusWhenShown(_ message: MessageKey, in thread: ThreadKey, attempts: Int) {
        guard attempts > 0, let reader = router?.reader, reader.thread == thread else { return }
        if reader.focusAndReveal(message) { return }
        guard reader.state == .loading else { return }
        withObservationTracking {
            _ = reader.revision
            _ = reader.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.focusWhenShown(message, in: thread, attempts: attempts - 1)
            }
        }
    }

    public func showAsList() {
        guard let router, let retrieval = lastRetrieval, let query = retrieval.queryText else { return }
        close()
        if let account = retrieval.queryAccount, account != router.active?.id {
            switchingForSource = true
            router.switchAccount(to: account)
            switchingForSource = false
            memoryAccount = account
        }
        router.active?.searchText = query
        router.active?.searchOpen = true
        router.go(to: .search(query))
    }

    public func copyAnswer() {
        guard canCopyAnswer, let center else { return }
        center.pasteboard?.copy(answer)
        center.environment?.notices.post(AskWording.copied, style: .info, duration: NoticeCenter.infoDuration)
    }

    public func acceptConsent() async {
        guard let consent, let center else { return }
        do {
            try await center.grantConsent(consent)
            self.consent = nil
            ask(followUp: false)
        } catch {
            fail(.failed(AIWording.failure(error)), generation)
        }
    }

    public func declineConsent() {
        guard let consent else { return }
        self.consent = nil
        fail(.unavailable(AIWording.reason(.notConsented, providerName: consent.providerName)), generation)
    }

    private func unavailable(_ reason: AIAvailability.UnavailableReason, providerID: AIProviderID?,
                             providerName: String?, generation: Int) async {
        if reason == .notConsented, let providerID, let request = await center?.consentRequest(for: providerID) {
            guard isCurrent(generation) else { return }
            consent = request
            return fail(.needsConsent(providerID), generation)
        }
        switch reason {
        case .onDeviceOnly:
            fail(center?.settings.featurePins[.askInbox] == nil ? .unavailable(AskWording.noOnDeviceModel) : .onDeviceOnly,
                 generation)
        case .localeNotSupported:
            fail(.unavailable(AskWording.language), generation)
        case .disabledBySettings where center?.settings.enabled == false:
            fail(.aiOff, generation)
        default:
            fail(.unavailable(AIWording.reason(reason, providerName: providerName)), generation)
        }
    }

    private func answerFailed(_ error: any Error, generation: Int) async {
        switch error {
        case AIError.unavailable(let reason):
            let status = await center?.features.status(for: .askInbox, accountKey: policyKey(scope))
            guard isCurrent(generation) else { return }
            await unavailable(reason, providerID: status?.providerID ?? provenance?.providerID,
                              providerName: status?.providerName ?? provenance?.providerName, generation: generation)
        case AIError.contextOverflow:
            fail(.tooMuch, generation)
        case AIError.refused:
            fail(.refused, generation)
        case AIError.timeout:
            fail(.timedOut, generation)
        case AIError.outputBlocked:
            fail(.blocked, generation)
        case AIError.cancelled, is CancellationError:
            cancelWork()
            phase = .stopped
        default:
            fail(.failed(AIWording.failure(error, providerName: provenance?.providerName)), generation)
        }
    }

    private func retrievalFailed(_ error: any Error, _ generation: Int) {
        switch error {
        case AskRetrievalError.noUsableWords:
            phase = .notFound
            statusText = AskWording.tooFewWords
        case AskRetrievalError.conversationGone:
            fail(.failed(AskWording.conversationGone), generation)
        case MailPortError.unsupported:
            fail(.unavailable(AskWording.searchUnavailable), generation)
        case is CancellationError:
            break
        default:
            fail(.failed(AskWording.searchFailed), generation)
        }
    }

    private func fail(_ failure: AskFailure, _ generation: Int) {
        guard isCurrent(generation) else { return }
        watchdog?.cancel()
        phase = .failed(failure)
        statusText = text(for: failure)
    }

    func text(for failure: AskFailure) -> String {
        switch failure {
        case .aiOff: AskWording.aiOff
        case .unavailable(let reason): reason
        case .needsConsent: AIWording.reason(.notConsented, providerName: consent?.providerName)
        case .onDeviceOnly: scope == .allAccounts ? AskWording.onDeviceOnlySomeAccount : AskWording.onDeviceOnly(scopeTitle)
        case .tooMuch: AskWording.tooMuch
        case .refused: AskWording.refused
        case .timedOut: AskWording.timedOut
        case .blocked: AskWording.blocked
        case .failed(let reason): AskWording.failed(reason)
        }
    }

    private func startWatchdog(_ generation: Int) {
        watchdog?.cancel()
        let clock = self.clock
        watchdog = Task { [weak self] in
            do { try await clock.sleep(for: AIPolicy.askInboxTimeout) } catch { return }
            self?.timedOut(generation)
        }
    }

    private func timedOut(_ generation: Int) {
        guard isCurrent(generation), phase == .answering else { return }
        cancelWork()
        phase = .failed(.timedOut)
        statusText = AskWording.timedOut
    }

    private func begin() -> Int {
        cancelWork()
        answer = ""
        sources = []
        otherMatches = []
        showsAllOtherMatches = false
        provenance = nil
        report = nil
        statusText = nil
        consent = nil
        cursor = nil
        isReopened = false
        planLine = nil
        return generation
    }

    private func cancelWork() {
        task?.cancel()
        task = nil
        watchdog?.cancel()
        watchdog = nil
        generation += 1
    }

    private func isCurrent(_ generation: Int) -> Bool { generation == self.generation && !Task.isCancelled }

    private func remember(_ text: String) {
        history.removeAll { $0 == text }
        history.append(text)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        historyIndex = nil
    }

    private func forgetIfStale() {
        guard askedAt != nil || phase != .idle else { return }
        let expired = askedAt.map { clock.now.timeIntervalSince($0) > Self.memoryLifetime.timeInterval } ?? false
        let switched = memoryAccount != nil && memoryAccount != router?.activeAccountID
        // Why: "This conversation" must mean the one on screen, never the one an earlier answer was about
        let leftConversation: Bool = if case .conversation(let thread) = scope {
            router?.mode != .reader || router?.reader?.thread != thread
        } else { false }
        if expired || switched || leftConversation { forget() }
    }

    private func forget() {
        _ = begin()
        question = ""
        phase = .idle
        olderMail = nil
        askedAt = nil
        lastRetrieval = nil
        lastQuestion = nil
        lastAsked = nil
        memoryAccount = nil
    }

    private func observeAccount() {
        guard let router else { return }
        withObservationTracking {
            _ = router.activeAccountID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.activeAccountChanged() }
        }
    }

    private func activeAccountChanged() {
        guard isPresented, !switchingForSource else { return }
        guard let router, router.activeAccountID != presentedAccount else { return observeAccount() }
        forget()
        close()
    }

    private func policyKey(_ scope: Scope) -> String? {
        switch scope {
        case .account(let id): center?.policyKey(id)
        case .conversation(let thread): center?.policyKey(thread.account)
        case .allAccounts: nil
        }
    }

    private func account(of scope: Scope) -> AccountID? {
        switch scope {
        case .account(let id): id
        case .conversation(let thread): thread.account
        case .allAccounts: nil
        }
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func isConversation(_ scope: Scope) -> Bool {
        if case .conversation = scope { return true }
        return false
    }
}

extension AICenter {
    public var ask: AskModel? {
        if let askStorage { return askStorage }
        guard let environment else { return nil }
        let model = AskModel(center: self, retriever: MailAskRetriever(data: environment.data,
                                                                       conversationBodyTimeout: bodyTimeout),
                             planner: SearchPlanAskPlanner.live(environment))
        askStorage = model
        return model
    }

    public func useAsk(_ model: AskModel) {
        askStorage = model
    }
}
