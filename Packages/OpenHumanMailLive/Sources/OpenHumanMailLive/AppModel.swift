import Foundation
import MailFeatures
import MailModel
import MailUI
import Observation
import OpenHumanCore
import OpenHumanStore

@MainActor
@Observable
public final class AppModel {
    public enum Screen {
        case launching
        case mail(AppEnvironment)
        case signIn(SignInModel)
        case notice(StartupProblem)
    }

    public private(set) var screen: Screen
    @ObservationIgnored public private(set) var session: SyncSession?

    public var router: AppRouter? {
        if case .mail(let environment) = screen { return environment.router }
        return nil
    }
    @ObservationIgnored public private(set) lazy var deepLinks: DeepLinkRouter = {
        let links = DeepLinkRouter(router: { [weak self] in self?.router })
        links.didFollow = { _ in PlatformServices.current.activateApp() }
        return links
    }()
    @ObservationIgnored public private(set) lazy var intents: IntentActions = IntentActions(router: { [weak self] in self?.router },
                                                                                  links: deepLinks)
    @ObservationIgnored private let live: LiveBackend?
    @ObservationIgnored private(set) var launchTask: Task<Void, Never>?
    @ObservationIgnored private var starting = false
    public var liveAccounts: LiveAccountManager? { live?.accounts }
    @ObservationIgnored var platform: (@MainActor () -> SystemPlatform)?

    public init(screen: Screen, session: SyncSession? = nil, platform: (@MainActor () -> SystemPlatform)? = nil) {
        self.screen = screen
        self.session = session
        self.live = nil
        self.platform = platform
        if case .mail(let environment) = screen { startSystemFeatures(environment) }
    }

    private func startSystemFeatures(_ environment: AppEnvironment) {
        if let platform { environment.installPlatform(platform()) }
        environment.runLaunchTasks()
        if platform != nil { environment.welcomeGuide.presentIfFirstRun() }
    }

    public init(live: LiveBackend, platform: (@MainActor () -> SystemPlatform)? = nil) {
        self.live = live
        self.platform = platform
        self.screen = .launching
        launch(live, explainFirst: true, explained: false)
    }

    public func launched() async {
        await launchTask?.value
    }

    // Why: a second Continue or Try again must not build a second engine on the same store
    private var idle: Bool { !starting && session == nil }

    private func launch(_ live: LiveBackend, explainFirst: Bool, explained: Bool) {
        guard idle else { return }
        starting = true
        screen = .launching
        launchTask = Task { [weak self] in
            let next = await live.loadLaunch(explainFirst: explainFirst, explained: explained)
            await self?.open(next, live: live)
            self?.starting = false
        }
    }

    private func open(_ next: LiveBackend.Launch, live: LiveBackend) async {
        switch next {
        case .explain:
            screen = .notice(.keychainExplainer(continue: { [weak self] in
                self?.launch(live, explainFirst: false, explained: true)
            }))
        case .start(.session(let account)):
            await startSession(account, backend: live)
        case .start(.signIn(let hint, let notice)):
            showSignIn(backend: live, loginHint: hint, notice: notice)
        case .start(.needsWriteAccess(let account)):
            showSignIn(backend: live, loginHint: account.email, notice: LiveBackend.writeAccessNotice)
        case .start(.keychainRefused(let account)):
            showKeychainProblem(account, backend: live)
        case .start(.keychainUnreadable(let account, let status)):
            showKeychainProblem(account, unreadable: status, backend: live)
        }
    }

    private func showKeychainProblem(_ account: AccountItem, unreadable status: Int32? = nil, backend: LiveBackend) {
        let tryAgain: @MainActor () -> Void = { [weak self] in
            guard let self, idle else { return }
            backend.forgetKeychainRefusals()
            launch(backend, explainFirst: false, explained: false)
        }
        let signInAgain: @MainActor () -> Void = { [weak self] in
            self?.showSignIn(backend: backend, loginHint: account.email, notice: nil)
        }
        if let status {
            screen = .notice(.keychainUnreadable(status: status, tryAgain: tryAgain, signInAgain: signInAgain))
        } else {
            screen = .notice(.keychainRefused(tryAgain: tryAgain, signInAgain: signInAgain))
        }
    }

    private func showSignIn(backend: LiveBackend, loginHint: String, notice: String?) {
        let model = SignInModel(accounts: backend.accounts, loginHint: loginHint, notice: notice)
        model.onSignedIn = { [weak self] id in self?.signedIn(id) }
        screen = .signIn(model)
    }

    private func signedIn(_ id: AccountID) {
        guard let live, let account = live.account(id) else {
            screen = .notice(StartupProblem(title: "Mail couldn't finish signing in",
                                            message: "Your sign-in is saved. Quit and open Mail again to continue."))
            return
        }
        proceed(account, backend: live)
    }

    private func proceed(_ account: AccountItem, backend: LiveBackend) {
        guard idle else { return }
        starting = true
        launchTask = Task { [weak self] in
            await self?.startSession(account, backend: backend)
            self?.starting = false
        }
    }

    public func shutdown() async {
        await session?.shutdown()
    }

    private func startSession(_ account: AccountItem, backend: LiveBackend) async {
        guard session == nil else { return }
        do {
            let session = try await backend.makeSession(for: account)
            self.session = session
            backend.accounts.attach(link(for: session))
            screen = .mail(session.environment)
            deepLinks.readinessChanged()
            startSystemFeatures(session.environment)
            Task { await session.start() }
        } catch let error as AccountSetupError where error.kind == .clientMissing {
            if backend.keychainRefused {
                showKeychainProblem(account, backend: backend)
            } else {
                showSignIn(backend: backend, loginHint: account.email, notice: error.message)
            }
        } catch {
            screen = .notice(StartupProblem(
                title: "Mail couldn't start syncing",
                message: "Mail opened but couldn't start syncing \(account.email). " + CompositionRoot.syncStartMessage(error),
                details: CompositionRoot.detailCode(error),
                action: (title: "Sign in again", run: { [weak self] in
                    self?.showSignIn(backend: backend, loginHint: account.email, notice: nil)
                })))
        }
    }

    private func link(for session: SyncSession) -> LiveAccountManager.SessionLink {
        LiveAccountManager.SessionLink(
            engine: session.engine,
            forgetInWindow: { [weak environment = session.environment, weak session] account, email in
                if let session, session.account == account { await session.calendar?.forget() }
                await session?.calendarConnections?.forget(account)
                guard let environment else { return }
                await environment.ai?.clearCache()
                await environment.ai?.forgetTraces(email: email)
                await environment.system.removeAccount(account)
            },
            removed: { [weak self] account in await self?.accountRemoved(account) })
    }

    static let signedOutNotice = "Signed out and removed from this Mac; nothing changed in Gmail."

    private func accountRemoved(_ account: AccountID) async {
        guard let live, case .mail(let environment) = screen else { return }
        let remaining = ((try? live.store.accounts()) ?? []).filter { $0.status != .removing && $0.status != .disabled }
        guard remaining.isEmpty else { return }
        live.accounts.attach(nil)
        environment.system.stopAll()
        let ending = session
        session = nil
        showSignIn(backend: live, loginHint: "", notice: Self.signedOutNotice)
        await ending?.stop()
    }
}
