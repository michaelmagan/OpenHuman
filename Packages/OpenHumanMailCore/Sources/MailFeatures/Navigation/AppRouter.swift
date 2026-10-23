import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

public typealias MailWindowModel = AppRouter

@MainActor
@Observable
public final class AppRouter {
    public typealias Mode = AccountState.Mode

    public private(set) var accounts: [AccountState] = []
    public private(set) var activeAccountID: AccountID?
    public private(set) var accountsError: String?
    public private(set) var accountsLoaded = false
    public let recentOpens = RecentOpens()
    public var isLabelSidebarVisible = true {
        didSet { if isLabelSidebarVisible != oldValue { setNeedsPersist() } }
    }
    public var windowPlace: WindowPlace?
    @ObservationIgnored public var panelsSource: (@MainActor () -> PanelsPlace)?
    public var openDraftIDs: [String] = []
    @ObservationIgnored public var composerContext: (@MainActor () -> ActionContext?)?
    @ObservationIgnored public var willPersist: (@MainActor () -> Void)?
    public internal(set) var unifiedInbox: AllInboxesModel?
    public internal(set) var accountCountMode: AccountCountMode = AppSettings.accountCounts.defaultValue
    public internal(set) var allInboxesEnabled = AppSettings.allInboxesShown.defaultValue
    public var sequenceHint: String?

    @ObservationIgnored public let environment: AppEnvironment
    @ObservationIgnored private let startLocation: MailLocation?
    @ObservationIgnored private let restoration: (any NavigationStateStoring)?
    @ObservationIgnored private var snapshot: NavigationSnapshot?
    @ObservationIgnored private var accountsTask: Task<Void, Never>?
    @ObservationIgnored var accountCountsTask: Task<Void, Never>?
    @ObservationIgnored var allInboxesTask: Task<Void, Never>?
    @ObservationIgnored private var debouncer: PersistDebouncer?
    @ObservationIgnored private var snapshotLoaded = false
    @ObservationIgnored private var frozen = false
    @ObservationIgnored private var trackingStarted = false
    @ObservationIgnored private var started = false
    @ObservationIgnored var undoTargets: [UUID: (account: AccountID, threads: [ThreadKey])] = [:]
    @ObservationIgnored var blockedToast: Toast.ID?

    public init(environment: AppEnvironment, location: MailLocation? = .system(.inbox),
                restoring: (any NavigationStateStoring)? = nil,
                persistDelay: Duration = PersistDebouncer.standardDelay,
                persistSleep: @escaping PersistDebouncer.Sleep = { try await Task.sleep(for: $0) }) {
        self.environment = environment
        self.startLocation = location
        self.restoration = restoring
        if restoring != nil {
            debouncer = PersistDebouncer(delay: persistDelay, sleep: persistSleep) { [weak self] in self?.persist() }
        }
    }

    isolated deinit {
        accountsTask?.cancel()
        accountCountsTask?.cancel()
        allInboxesTask?.cancel()
        debouncer?.cancel()
    }

    public var active: AccountState? {
        guard let activeAccountID else { return nil }
        return accounts.first { $0.id == activeAccountID }
    }

    public var account: Account? { active?.account }
    public var list: ThreadListModel? { active?.list }
    public var reader: ReaderModel? { active?.reader }
    public var mode: Mode { active?.mode ?? .list }
    public var location: MailLocation { active?.location ?? startLocation ?? .system(.inbox) }

    public var showsAccountSwitcher: Bool { accounts.count >= 2 }

    public func banner(now: Date = Date()) -> StatusBanner? {
        StatusBanner.current(active: account, connectivity: environment.status.connectivity, now: now,
                             canReauthorize: environment.accounts != nil)
    }

    public var windowTitle: String {
        guard let active else { return "OpenHuman Mail" }
        if unifiedInbox != nil { return "All Inboxes" }
        let place = active.location.map { active.title(for: $0) } ?? "Inbox"
        return "\(place) — \(active.account.email)"
    }

    public func start() {
        guard !started else { return }
        started = true
        loadSnapshot()
        if let snapshot {
            isLabelSidebarVisible = snapshot.labelSidebarVisible
            windowPlace = snapshot.window
            openDraftIDs = snapshot.openDraftIDs
        }
        if let undo = environment.undo, undo.onUndone == nil {
            undo.onUndone = { [weak self] entry in self?.undone(entry) }
        }
        startTrackingIfNeeded()
        observeAccountCounts()
        followAllInboxesSetting()
        let stream = environment.data.accounts()
        accountsTask = Task { [weak self] in
            do {
                for try await accounts in stream {
                    guard !Task.isCancelled else { return }
                    self?.apply(accounts)
                }
            } catch is CancellationError {
            } catch {
                self?.accountsError = String(describing: error)
                self?.accountsLoaded = true
            }
        }
    }

    public func stop() {
        persist()
        accountsTask?.cancel()
        accountsTask = nil
        accountCountsTask?.cancel()
        accountCountsTask = nil
        allInboxesTask?.cancel()
        allInboxesTask = nil
        for state in accounts { state.stop() }
    }

    func apply(_ list: [Account]) {
        accountsLoaded = true
        let ordered = list.sorted { $0.id < $1.id }
        var next: [AccountState] = []
        for account in ordered {
            if let existing = accounts.first(where: { $0.id == account.id }) {
                existing.update(account)
                next.append(existing)
            } else {
                let state = AccountState(account: account, environment: environment, start: startLocation,
                                         place: startLocation == nil ? snapshot?.place(for: account.id) : nil)
                state.followCounts()
                next.append(state)
            }
        }
        for gone in accounts where !next.contains(where: { $0 === gone }) { gone.stop() }
        accounts = next
        allInboxesFollowAccounts()
        if activeAccountID == nil || !next.contains(where: { $0.id == activeAccountID }) {
            let restored = snapshot?.activeAccount.flatMap { id in next.first { $0.id == id } }
            activate(restored ?? next.first)
        }
    }

    private func activate(_ state: AccountState?) {
        activeAccountID = state?.id
        environment.status.activeAccount = state?.id
        state?.start()
    }

    public func switchAccount(to account: AccountID) {
        leaveAllInboxes()
        guard account != activeAccountID, let state = accounts.first(where: { $0.id == account }) else { return }
        activate(state)
        if let review = environment.reviewIfStarted, review.isOpen { review.locationChanged(state.location, account: state.id) }
        setNeedsPersist()
    }

    @discardableResult
    public func switchAccount(position: Int) -> Bool {
        guard position >= 1, position <= accounts.count else { return false }
        switchAccount(to: accounts[position - 1].id)
        return true
    }

    public func go(to location: MailLocation) {
        guard let active else { return }
        leaveAllInboxes()
        environment.calendarWindowIfStarted?.stepAside()
        active.go(to: location)
        if location == .reviewQueue(nil) || environment.reviewIfStarted != nil {
            environment.review.locationChanged(location, account: active.id)
        }
        setNeedsPersist()
    }

    public func goToInbox() {
        guard let active else { return }
        go(to: active.lastTab ?? active.firstTab)
    }

    public func goToImportant() {
        guard let active else { return }
        if !active.splitsLoaded, active.location == nil { return }
        go(to: active.firstTab)
    }

    public func open(_ key: ThreadKey) {
        if let row = accounts.first(where: { $0.id == key.account })?.list?.row(for: key) {
            recentOpens.record(row, at: recentOpens.now())
        }
        environment.calendarWindowIfStarted?.stepAside()
        leaveAllInboxes()
        active?.open(key)
        setNeedsPersist()
    }

    public func closeReader() {
        active?.closeReader()
        setNeedsPersist()
    }

    private func loadSnapshot() {
        guard !snapshotLoaded else { return }
        snapshotLoaded = true
        snapshot = restoration?.load()
    }

    public var restoredWindowPlace: WindowPlace? {
        loadSnapshot()
        return snapshot?.window
    }

    public var restoredPanels: PanelsPlace? {
        loadSnapshot()
        return snapshot?.panels
    }

    public func attachReader(_ reader: any ReaderStateRestorable) {
        active?.attachReader(reader)
        setNeedsPersist()
    }

    public func readerStateDidChange() { setNeedsPersist() }

    public func persist() {
        debouncer?.cancel()
        guard !frozen, let restoration, accountsLoaded else { return }
        willPersist?()
        var places = snapshot?.places ?? []
        for state in accounts {
            guard let place = state.place() else { continue }
            places.removeAll { $0.account == state.id }
            places.append(place)
        }
        let panels = panelsSource?() ?? snapshot?.panels
        var next = NavigationSnapshot(activeAccount: activeAccountID, labelSidebarVisible: isLabelSidebarVisible,
                                      places: places.filter { place in accounts.contains { $0.id == place.account } },
                                      window: windowPlace ?? snapshot?.window,
                                      panels: panels?.isDefault == true ? nil : panels, openDraftIDs: openDraftIDs)
        next.places.sort { $0.account < $1.account }
        guard next != snapshot else { return }
        snapshot = next
        restoration.save(next)
    }

    public func finalFlush() {
        persist()
        frozen = true
    }

    func setNeedsPersist() {
        guard restoration != nil, !frozen else { return }
        startTrackingIfNeeded()
        debouncer?.schedule()
    }

    private func startTrackingIfNeeded() {
        guard !trackingStarted else { return }
        trackingStarted = true
        track()
    }

    private func track() {
        guard !frozen else { return }
        withObservationTracking {
            _ = accounts.map { $0.place() }
            _ = (activeAccountID, isLabelSidebarVisible, windowPlace, openDraftIDs, panelsSource?())
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.frozen else { return }
                self.debouncer?.schedule()
                self.track()
            }
        }
    }
}
