import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class OnboardingModel {
    public private(set) var step: OnboardingStep
    public private(set) var progress: OnboardingProgress
    public let permissions: PermissionsModel
    public let keys = KeysTutorial()
    public let ai: AIStepModel
    public private(set) var syncLine: String?
    public private(set) var firstMailArrived = false
    public private(set) var isFinished = false

    public private(set) var inboxes: [Account] = []
    public private(set) var calendars: [AccountID: InboxCalendar] = [:]
    public private(set) var skippedCalendars: Set<AccountID> = []
    public private(set) var syncLines: [AccountID: String] = [:]
    public private(set) var connectivity: [AccountID: ConnectivityState] = [:]
    public private(set) var emailSignIn: SignInModel?
    public private(set) var calendarClients: [OAuthClientSummary] = []
    public private(set) var setupInboxClientShortID: String?
    public var calendarClientChoice: OAuthClientSummary.ID?
    public private(set) var fixError: String?

    @ObservationIgnored private let store: any OnboardingProgressStoring
    @ObservationIgnored private let aiPort: any AIOnboardingPort
    @ObservationIgnored private let accounts: (any AccountManaging)?
    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private let calendarPorts: (any CalendarConnectionsProviding)?
    @ObservationIgnored private let settings: (any SettingsPort)?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var firstMailTask: Task<Void, Never>?
    @ObservationIgnored private var inboxTask: Task<Void, Never>?
    @ObservationIgnored private var connectivityTask: Task<Void, Never>?
    @ObservationIgnored private var emailTask: Task<Void, Never>?
    @ObservationIgnored private var returnsToSummary = false

    public init(store: any OnboardingProgressStoring, ports: Ports) {
        self.store = store
        self.accounts = ports.accounts
        self.data = ports.data
        self.calendarPorts = ports.calendars
        self.settings = ports.settings
        var resumed = store.load()
        if resumed.completed {
            resumed.step = .welcome
            resumed.skipped = []
            resumed.setupAccount = nil
        }
        resumed.completed = false
        self.progress = resumed
        self.aiPort = ports.ai
        self.step = resumed.step
        let data = ports.data
        self.permissions = PermissionsModel(notifier: ports.notifier, loginItem: ports.loginItem, ai: ports.ai,
                                            signedIn: ports.signedIn)
        self.ai = AIStepModel(port: ports.ai, sampleThread: {
            for account in (try? await Self.first(data.accounts())) ?? [] {
                if let window = try? await Self.first(data.threadWindow(.system(.inbox), account: account.id, limit: 1)),
                   let row = window.rows.first {
                    return row.id
                }
            }
            return nil
        }, openAISettings: ports.openAISettings)
    }

    public struct Ports {
        public var data: any MailDataSource
        public var accounts: (any AccountManaging)?
        public var ai: any AIOnboardingPort
        public var notifier: any SystemNotifying
        public var loginItem: any LoginItemControlling
        public var signedIn: @MainActor () -> Bool
        public var calendars: (any CalendarConnectionsProviding)?
        public var settings: (any SettingsPort)?
        public var openAISettings: (@MainActor () -> Void)?

        public init(data: any MailDataSource, accounts: (any AccountManaging)?, ai: any AIOnboardingPort,
                    notifier: any SystemNotifying, loginItem: any LoginItemControlling,
                    signedIn: @escaping @MainActor () -> Bool = { true },
                    calendars: (any CalendarConnectionsProviding)? = nil, settings: (any SettingsPort)? = nil,
                    openAISettings: (@MainActor () -> Void)? = nil) {
            self.data = data
            self.accounts = accounts
            self.ai = ai
            self.notifier = notifier
            self.loginItem = loginItem
            self.signedIn = signedIn
            self.calendars = calendars
            self.settings = settings
            self.openAISettings = openAISettings
        }
    }

    isolated deinit {
        syncTask?.cancel()
        firstMailTask?.cancel()
        inboxTask?.cancel()
        connectivityTask?.cancel()
        emailTask?.cancel()
    }

    public var steps: [OnboardingStep] { OnboardingStep.allCases.filter { $0 != .connectEmail } }
    public var stepIndex: Int { steps.firstIndex(of: step == .connectEmail ? .inboxes : step) ?? 0 }
    public var stepCountText: String { "Step \(stepIndex + 1) of \(steps.count)" }

    public var title: String {
        if step == .calendar, let inbox = setupInbox { return "Connect calendar for \(inbox.email)" }
        return step.title
    }

    public var readingLine: String {
        firstMailArrived ? Self.canStartReadingText : Self.waitingForFirstMailText
    }
    public static let canStartReadingText = "Start reading now; older mail keeps arriving while Mail is open."
    public static let waitingForFirstMailText = "Your newest mail shows up first."
    public var isFirst: Bool { step == .welcome }
    public var isLast: Bool { step == .ready }
    public var canSkip: Bool { step.isSkippable }

    public func enter() async {
        await loadInboxes()
        switch step {
        case .permissions: await permissions.refresh()
        case .ai: await ai.load(previous: progress.aiAnswered ? await aiPort.draftReplies() : nil)
        case .calendar: await loadCalendarStep()
        case .connectEmail: startEmailSignIn()
        case .ready: watchFirstMail()
        default: break
        }
    }

    public func confirmAI() async {
        await ai.confirm()
        guard ai.saved != nil else { return }
        progress.aiAnswered = true
        store.save(progress)
    }

    public func next() async {
        if step == .connectEmail { return await go(to: .inboxes) }
        if step == .calendar, returnsToSummary { return await go(to: .ready) }
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        await go(to: steps[index + 1])
    }

    public func back() async {
        switch step {
        case .connectEmail:
            await go(to: .inboxes)
        case .calendar where returnsToSummary:
            await go(to: .ready)
        case .calendar where setupInbox != nil && setupInbox?.id != inboxes.first?.id:
            await go(to: .inboxes)
        default:
            guard let index = steps.firstIndex(of: step), index > 0 else { return }
            await go(to: steps[index - 1])
        }
    }

    public func skip() async {
        guard step.isSkippable else { return }
        if step == .calendar { return await skipCalendar() }
        progress.skipped.insert(step)
        await next()
    }

    public func go(to target: OnboardingStep) async {
        if step == .connectEmail, target != .connectEmail { stopEmailSignIn() }
        if target != .calendar { returnsToSummary = false }
        step = target
        progress.step = target
        progress.skipped.remove(target)
        store.save(progress)
        await enter()
    }

    public func finish() {
        stopEmailSignIn()
        progress.completed = true
        progress.step = .ready
        progress.isOpen = false
        store.save(progress)
        isFinished = true
    }

    public func close() {
        stopEmailSignIn()
        progress.completed = false
        progress.isOpen = false
        store.save(progress)
        isFinished = true
    }

    public static func shouldAutoPresent(_ store: any OnboardingProgressStoring) -> Bool {
        let progress = store.load()
        return !progress.completed && (!progress.shown || progress.isOpen)
    }

    public var canAddAccount: Bool { accounts != nil }

    public var setupInbox: Account? {
        inboxes.first { $0.id == progress.setupAccount } ?? inboxes.first
    }

    public var setupCalendar: InboxCalendar? { setupInbox.flatMap { calendars[$0.id] } }

    public var inboxRows: [InboxRow] {
        inboxes.map { account in
            let email: InboxRow.EmailStatus = account.health == .needsSignIn || connectivity[account.id] == .needsReauth
                ? .needsSignIn : .connected
            let calendar: InboxRow.CalendarStatus
            if let connection = calendars[account.id], connection.canConnect {
                if connection.isConnected { calendar = .connected }
                else if connection.needsReconnect { calendar = .needsReconnect }
                else if skippedCalendars.contains(account.id) { calendar = .skipped }
                else { calendar = .notConnected }
            } else {
                calendar = .unavailable
            }
            return InboxRow(account: account, email: email, calendar: calendar, syncLine: syncText(for: account.id))
        }
    }

    public var summaryLine: String {
        let open = inboxRows.filter { !$0.isComplete }.count
        if open == 0 { return inboxes.count == 1 ? "Your inbox is ready." : "All \(inboxes.count) inboxes are ready." }
        return open == 1 ? "One inbox has a step left; finish it here or later."
                         : "\(open) inboxes have a step left; finish them here or later."
    }

    public func addAnotherInbox() async {
        guard canAddAccount else { return }
        await go(to: .connectEmail)
    }

    public func fixCalendar(_ account: AccountID) async {
        progress.setupAccount = account
        let fromSummary = step == .ready
        await go(to: .calendar)
        returnsToSummary = fromSummary
    }

    public func signInAgain(_ account: AccountID) async {
        guard let accounts else { return }
        fixError = nil
        do {
            try await accounts.reauthorize(account)
        } catch {
            if let setup = error as? AccountSetupError, setup.kind == .cancelled { return }
            fixError = (error as? AccountSetupError)?.message ?? "Sign-in failed. Try again."
        }
    }

    public static let calendarWhat = "Mail shows this inbox's Google Calendar next to your mail: your events on the day "
        + "an email talks about, and when you're free."
    public static var calendarCreate: String {
        "Mail never creates an event on its own: you press Create event first. If it invites people, it waits "
            + "\(NoticeCenter.toastDuration.components.seconds) seconds so you can Undo."
    }
    public static let calendarScope = "Google Calendar only, and Google Meet links only."
    public static let calendarSeparate = "Google asks you about the calendar on its own page. Your email sign-in doesn't "
        + "change, and if this doesn't work, your email keeps working."
    public static let calendarUnavailable = "Calendars connect only on a real Google account. This run has none, so "
        + "there is nothing to connect here."

    public struct CalendarClientChoice: Identifiable, Hashable, Sendable {
        public let client: OAuthClientSummary.ID?
        public let title: String
        public var id: String { client ?? "" }
    }

    public var showsCalendarClientChoice: Bool { calendarClients.count > 1 && setupCalendar?.canConnect == true }

    public var calendarClientChoices: [CalendarClientChoice] {
        let ownTitle = setupInboxClientShortID.map { "This inbox's Google client (…\($0))" } ?? "This inbox's Google client"
        let others = calendarClients.filter { $0.shortID != setupInboxClientShortID && $0.hasSecret }
        return [CalendarClientChoice(client: nil, title: ownTitle)]
            + others.map { CalendarClientChoice(client: $0.id, title: "Google client …\($0.shortID)") }
    }

    public func connectCalendar() async {
        guard let inbox = setupInbox, let calendar = calendars[inbox.id] else { return }
        guard await calendar.connect(client: calendarClientChoice) else { return }
        skippedCalendars.remove(inbox.id)
        try? await settings?.set(AppSettings.calendarSetupSkipped(inbox.id), false)
        guard step == .calendar, setupInbox?.id == inbox.id else { return }
        progress.skipped.remove(.calendar)
        await next()
    }

    public func skipCalendar() async {
        if let inbox = setupInbox, calendars[inbox.id]?.isConnected != true {
            skippedCalendars.insert(inbox.id)
            try? await settings?.set(AppSettings.calendarSetupSkipped(inbox.id), true)
        }
        progress.skipped.insert(.calendar)
        await next()
    }

    private func loadCalendarStep() async {
        calendarClientChoice = nil
        guard let inbox = setupInbox else { return }
        setupInboxClientShortID = await accounts?.oauthClientShortID(for: inbox.id)
        calendarClients = await accounts?.oauthClients() ?? []
    }

    private func startEmailSignIn() {
        guard emailSignIn == nil, let accounts else { return }
        let signIn = SignInModel(accounts: accounts)
        signIn.onSignedIn = { [weak self] id in
            guard let self else { return }
            Task { await self.emailConnected(id) }
        }
        emailSignIn = signIn
        emailTask = Task { await signIn.run() }
    }

    private func stopEmailSignIn() {
        emailSignIn?.cancel()
        emailTask?.cancel()
        emailTask = nil
        emailSignIn = nil
    }

    private func emailConnected(_ id: AccountID) async {
        progress.setupAccount = id
        await loadInboxes(force: true)
        await go(to: .calendar)
    }

    private func loadInboxes(force: Bool = false) async {
        if inboxes.isEmpty || force, let list = try? await Self.first(data.accounts()) {
            await apply(list)
        }
        guard inboxTask == nil else { return }
        let data = self.data
        inboxTask = Task { [weak self] in
            do {
                for try await list in data.accounts() {
                    guard !Task.isCancelled else { return }
                    await self?.apply(list)
                }
            } catch {
                return
            }
        }
        syncTask = Task { [weak self] in
            for await progress in data.syncProgress() {
                guard !Task.isCancelled else { return }
                self?.syncLines = progress
                self?.syncLine = progress.values.sorted().first
            }
        }
        connectivityTask = Task { [weak self] in
            for await states in data.connectivity() {
                guard !Task.isCancelled else { return }
                self?.connectivity = states
            }
        }
    }

    private func apply(_ list: [Account]) async {
        let shown = list.filter { $0.health != .removing && $0.health != .disabled }
        var fresh: [AccountID] = []
        for account in shown where calendars[account.id] == nil {
            let calendar = InboxCalendar(account: account, port: calendarPorts?.calendarConnection(for: account))
            calendar.start()
            calendars[account.id] = calendar
            fresh.append(account.id)
        }
        for gone in Set(calendars.keys).subtracting(shown.map(\.id)) {
            calendars.removeValue(forKey: gone)?.stop()
            skippedCalendars.remove(gone)
        }
        inboxes = shown
        guard let settings else { return }
        for id in fresh {
            if (try? await settings.get(AppSettings.calendarSetupSkipped(id))) == true { skippedCalendars.insert(id) }
        }
    }

    private func syncText(for account: AccountID) -> String? {
        if let line = syncLines[account] { return line }
        switch connectivity[account] {
        case .online(let syncing, let lastSyncAt)?:
            if syncing { return "Syncing…" }
            return lastSyncAt == nil ? nil : "Up to date"
        case .offline?: return "Offline. Mail keeps trying."
        case .rateLimited?: return "Google asked Mail to slow down. It carries on shortly."
        case .syncFailing?: return "Sync is having trouble. Mail keeps trying."
        case .needsReauth?: return "Sign in again to keep syncing."
        case nil: return nil
        }
    }

    private func watchFirstMail() {
        guard firstMailTask == nil, !firstMailArrived else { return }
        let data = self.data
        firstMailTask = Task { [weak self] in
            guard let account = (try? await Self.first(data.accounts()))?.first?.id else { return }
            do {
                for try await window in data.threadWindow(.system(.inbox), account: account, limit: 1) {
                    guard !Task.isCancelled else { return }
                    if !window.rows.isEmpty {
                        self?.firstMailArrived = true
                        return
                    }
                }
            } catch {
                return
            }
        }
    }

    private static func first<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T? {
        for try await value in stream { return value }
        return nil
    }
}
