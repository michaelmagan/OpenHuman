import AppKit
import CoreSpotlight
import MailActions
import MailFeatures
import MailUIMac
import OpenHumanLinks
import OpenHumanMailLive

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuHints = MenuShortcutHints(source: { MailApp.app.router?.environment.actions.descriptors ?? ActionCatalog.all })

    private var terminationSignals: TerminationSignalHandler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuHints.install()
        AppIconController.shared.applyAtLaunch()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            terminationSignals = TerminationSignalHandler(flush: { MailApp.app.router?.finalFlush() }, terminate: { code in
                Self.shutDownEngine(MailApp.app) { exit(code) }
            })
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MailApp.app.router?.finalFlush()
        MailApp.app.router?.environment.actions.shortcutHints?.flush()
        let compose = MailApp.app.router?.environment.composeIfStarted
        let review = MailApp.app.router?.environment.reviewIfStarted
        let calendar = MailApp.app.router?.environment.calendarSidebarIfStarted
        let calendarWindow = MailApp.app.router?.environment.calendarWindowIfStarted
        let invites = MailApp.app.router?.environment.invitesIfStarted
        let composerWork = compose?.hasQuitWork == true || review?.hasQuitWork == true
            || calendar?.hasQuitWork == true || calendarWindow?.hasQuitWork == true || invites?.hasQuitWork == true
        guard composerWork || MailApp.app.session != nil else { return .terminateNow }
        Task { @MainActor in
            if composerWork {
                await Self.finishComposers(compose, review: review, calendar: calendar, calendarWindow: calendarWindow, invites: invites)
            }
            guard MailApp.app.session != nil else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            Self.shutDownEngine(MailApp.app) { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    static func finishComposers(_ compose: ComposeManager?, review: ReviewQueueModel? = nil,
                                calendar: CalendarSidebarModel? = nil, calendarWindow: CalendarWindowModel? = nil,
                                invites: InviteCenter? = nil, limit: Duration = .seconds(5)) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskGroup(of: Void.self) { work in
                    work.addTask {
                        await compose?.prepareForQuit()
                        await review?.prepareForQuit()
                    }
                    work.addTask { await invites?.prepareForQuit() }
                    work.addTask {
                        await calendarWindow?.prepareForQuit()
                        await calendar?.prepareForQuit()
                    }
                }
            }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }

    static func shutDownEngine(_ app: AppModel, limit: Duration = .seconds(8), then done: @escaping @MainActor () -> Void) {
        let once = RunOnce(done)
        Task { @MainActor in
            await app.shutdown()
            once.run()
        }
        Task { @MainActor in
            try? await Task.sleep(for: limit)
            once.run()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        MailApp.app.router?.persist()
        MailApp.app.router?.environment.actions.shortcutHints?.flush()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { _ = Self.open(url, in: MailApp.app) }
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        return Self.openSpotlightResult(identifier, in: MailApp.app)
    }

    @discardableResult
    static func openSpotlightResult(_ identifier: String, in app: AppModel) -> Bool {
        let accounts = app.router?.accounts.map(\.account) ?? []
        guard let url = SpotlightIdentifier.deepLink(for: identifier, accounts: accounts) else { return false }
        _ = open(url, in: app)
        return true
    }

    @discardableResult
    static func open(_ url: URL, in app: AppModel) -> LinkOutcome {
        switch app.deepLinks.handle(url) {
        case .followed(let outcome): outcome
        case .queued: LinkOutcome("No mail window is open.", handled: false)
        case .dropped: LinkOutcome(DeepLinkRouter.rateLimitedText, handled: false)
        case .invalid: LinkOutcome(DeepLinkRouter.invalidText, handled: false)
        }
    }
}

@MainActor
final class RunOnce {
    private var action: (@MainActor () -> Void)?

    init(_ action: @escaping @MainActor () -> Void) { self.action = action }

    func run() {
        let action = self.action
        self.action = nil
        action?()
    }
}
