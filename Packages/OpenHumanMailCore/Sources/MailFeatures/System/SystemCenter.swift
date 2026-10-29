import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class SystemCenter {
    public private(set) var notifications: NotificationService?
    public private(set) var reminderMirror: ReminderNotificationMirror?
    public private(set) var dockBadge: DockBadgeModel?
    public private(set) var launchAtLogin: LaunchAtLoginModel?
    public private(set) var unsubscribe: UnsubscribeModel?
    public private(set) var diagnostics: DiagnosticsExporter?
    public private(set) var spotlight: SpotlightIndexer?
    public private(set) var menuBar: MenuBarModel?
    public private(set) var globalHotkey: GlobalHotkeyModel?
    public private(set) var services: ServicesModel?
    public private(set) var focus: FocusFilterModel?

    @ObservationIgnored public let sendFeedback = SendFeedbackCenter()
    @ObservationIgnored public var updates: UpdateCheckCenter?

    @ObservationIgnored public let platform: SystemPlatform
    @ObservationIgnored public let preferences: SystemPreferences
    @ObservationIgnored public var logLines: @MainActor () -> [String] = { [] }
    @ObservationIgnored public var showsDebuggingTools: @MainActor () -> Bool = { false }
    @ObservationIgnored public var coalesce: Duration = NotificationService.defaultCoalesce
    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var preferenceObserver: UUID?

    init(environment: AppEnvironment, platform: SystemPlatform, preferences: SystemPreferences) {
        self.environment = environment
        self.platform = platform
        self.preferences = preferences
        sendFeedback.showWindow = { [platform] in platform.showMainWindow() }
    }

    isolated deinit {
        for task in observers { task.cancel() }
    }

    public var effectiveCatalog: [ActionDescriptor] { environment.actions.descriptors }

    private func enabled(_ id: FeatureModuleID) -> Bool { environment.modules.modules.contains(id) }

    public func startNotifications() {
        guard notifications == nil else { return }
        var mirror: ReminderNotificationMirror?
        if enabled(.reminders) {
            let made = ReminderNotificationMirror(data: environment.data, settings: environment.settings, notifier: platform.notifier,
                                                  hidePreviews: { [weak self] in self?.preferences.hidePreviews ?? false })
            made.start()
            reminderMirror = made
            mirror = made
            observers.append(Task { [weak made] in
                for await _ in NotificationCenter.default.notifications(named: .NSSystemTimeZoneDidChange) {
                    guard let made else { return }
                    await made.resync()
                }
            })
            preferenceObserver = preferences.addObserver { [weak made] in
                guard let made else { return }
                Task { await made.resync() }
            }
        }
        let service = NotificationService(environment: environment, platform: platform, preferences: preferences,
                                          mirror: mirror, coalesce: coalesce)
        service.start()
        notifications = service
    }

    public func startDockBadge() {
        guard dockBadge == nil else { return }
        let model = DockBadgeModel(data: environment.data, badge: platform.dock, preferences: preferences,
                                   accountFilter: { [weak self] in self?.focus?.badgeAccounts })
        model.start()
        dockBadge = model
    }

    public func startLaunchAtLogin() {
        guard launchAtLogin == nil else { return }
        launchAtLogin = LaunchAtLoginModel(control: platform.loginItem)
    }

    public func startUnsubscribe() {
        guard unsubscribe == nil else { return }
        let model = UnsubscribeModel(environment: environment, urlOpener: platform.urlOpener)
        model.install()
        unsubscribe = model
    }

    public func startDiagnostics() {
        guard diagnostics == nil else { return }
        let environment = self.environment
        diagnostics = DiagnosticsExporter(
            data: environment.data, info: { [isFake = environment.isFake] in Self.appInfo(isFake: isFake) },
            modules: { [weak environment] in
                Dictionary(uniqueKeysWithValues: FeatureModuleID.mur1.map { ($0.rawValue, environment?.modules.modules.contains($0) == true) })
            },
            logLines: { [weak self] in self?.logLines() ?? [] },
            calendars: { [weak environment] in await environment?.calendarDiagnostics() ?? [] })
    }

    public func startSpotlight() {
        guard spotlight == nil else { return }
        let indexer = SpotlightIndexer(data: environment.data, settings: environment.settings, index: platform.spotlight,
                                       defaults: preferences.defaults)
        indexer.start()
        spotlight = indexer
    }

    public func setSpotlight(enabled: Bool) async {
        preferences.spotlightEnabled = enabled
        if enabled {
            startSpotlight()
        } else {
            await removeAllSpotlight()
        }
    }

    public func rebuildSpotlight() async { await spotlight?.rebuild() }

    public func removeAllSpotlight() async {
        preferences.spotlightEnabled = false
        if let indexer = spotlight {
            spotlight = nil
            await indexer.removeAll()
        } else {
            try? await platform.spotlight.deleteAll()
        }
    }

    public func removeAccount(_ account: AccountID) async {
        if let notifications {
            await notifications.removeAccount(account)
        } else {
            await reminderMirror?.removeAccount(account)
        }
        if let spotlight {
            await spotlight.removeAccount(account)
        } else {
            preferences.defaults.removeObject(forKey: SpotlightIndexer.ledgerKey(account))
            try? await platform.spotlight.delete(domains: [SpotlightIdentifier.domain(account)])
        }
        preferences.removeAccount(account)
    }

    public func stopAll() {
        unsubscribe?.uninstall()
        notifications?.stop()
        reminderMirror?.stop()
        dockBadge?.stop()
        spotlight?.stop()
        menuBar?.stop()
        globalHotkey?.stop()
        services?.stop()
        toastOnly?.stop()
        for task in observers { task.cancel() }
        observers = []
        if let preferenceObserver { preferences.removeObserver(preferenceObserver) }
        preferenceObserver = nil
        notifications = nil
        reminderMirror = nil
        dockBadge = nil
        spotlight = nil
        menuBar = nil
        globalHotkey = nil
        services = nil
        unsubscribe = nil
        diagnostics = nil
        toastOnly = nil
        focus?.onChange = nil
        focus = nil
    }

    public func startServices() {
        guard services == nil else { return }
        let platform = self.platform
        let model = ServicesModel(environment: environment, registrar: platform.services, preferences: preferences,
                                  showMainWindow: { platform.showMainWindow() })
        model.start()
        services = model
    }

    public func setServices(enabled: Bool) {
        preferences.servicesEnabled = enabled
        if enabled { startServices() }
    }

    public func startMenuBar() {
        guard menuBar == nil else { return }
        let model = MenuBarModel(data: environment.data, item: platform.menuBarItem, preferences: preferences,
                                 accountFilter: { [weak self] in self?.focus?.badgeAccounts },
                                 openThread: { [weak self] key in self?.openFromMenuBar(key) }) { [weak self] command in
            self?.perform(command)
        }
        model.start()
        menuBar = model
    }

    public func setMenuBar(enabled: Bool) {
        preferences.menuBarEnabled = enabled
        if enabled {
            startMenuBar()
        } else {
            menuBar?.stop()
            menuBar = nil
        }
    }

    public func startGlobalHotkey() {
        guard globalHotkey == nil else { return }
        let model = GlobalHotkeyModel(registrar: platform.hotkeys, preferences: preferences,
                                      catalog: { [weak self] in self?.effectiveCatalog ?? ActionCatalog.all }) { [weak self] in
            self?.composeNewMessage(source: .keyboard)
        }
        model.start()
        globalHotkey = model
    }

    public func setGlobalHotkey(enabled: Bool) {
        preferences.globalHotkeyEnabled = enabled
        if enabled {
            startGlobalHotkey()
        } else {
            globalHotkey?.stop()
            globalHotkey = nil
        }
    }

    public func startFocusFilters() {
        guard focus == nil else { return }
        let model = FocusFilterModel(environment: environment, platform: platform, defaults: preferences.defaults)
        model.onChange = { [weak self] in self?.focusChanged() }
        focus = model
        model.start()
    }

    public func setFocusFilters(enabled: Bool) async {
        preferences.focusFiltersEnabled = enabled
        if enabled {
            startFocusFilters()
        } else if let model = focus {
            focus = nil
            await model.stop()
            model.onChange = nil
            focusChanged()
        }
    }

    public func applyFocusFilter(_ state: FocusFilterState?) async {
        await focus?.apply(state)
    }

    private func focusChanged() {
        dockBadge?.refresh()
        menuBar?.refresh()
        environment.status.focusLine = focus?.statusLine
    }

    func openFromMenuBar(_ key: ThreadKey) {
        platform.showMainWindow()
        environment.router.switchAccount(to: key.account)
        environment.router.open(key)
    }

    func perform(_ command: MenuBarCommand) {
        switch command {
        case .openMail: platform.showMainWindow()
        case .compose: composeNewMessage(source: .menu)
        case .quit: platform.quitApp()
        }
    }

    public func composeNewMessage(source: ActionSource) {
        platform.showMainWindow()
        _ = environment.compose
        environment.router.perform(.compose, source: source)
    }

    public func handle(_ notice: AppEngineNotice) async {
        if let notifications {
            await notifications.handle(notice)
            return
        }
        switch notice {
        case .operationFailed, .sendFailed, .sendInterrupted, .scheduledSendNeedsConfirmation, .scheduledSendCancelledByReply,
             .schedulerDegraded:
            let service = fallbackService()
            await service.handle(notice)
        default:
            break
        }
    }

    private func fallbackService() -> NotificationService {
        if let existing = toastOnly { return existing }
        let made = NotificationService(environment: environment, platform: platform, preferences: preferences, mirror: nil,
                                       coalesce: coalesce, systemNotifications: false)
        toastOnly = made
        return made
    }

    @ObservationIgnored private var toastOnly: NotificationService?

    public func exportDiagnostics() async {
        guard let diagnostics else { return }
        guard let url = platform.chooseDiagnosticsFile(diagnostics.suggestedFileName()) else { return }
        do {
            try await diagnostics.export(to: url)
            environment.notices.post("Diagnostics saved", style: .info, duration: NoticeCenter.infoDuration)
        } catch {
            environment.notices.post("Couldn't export diagnostics", style: .error, duration: NoticeCenter.infoDuration)
        }
    }

    nonisolated static func appInfo(isFake: Bool) -> DiagnosticsAppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let commit = (info["OHGitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        return DiagnosticsAppInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "0", build: info["CFBundleVersion"] as? String ?? "0",
            gitCommit: commit, os: ProcessInfo.processInfo.operatingSystemVersionString, dataMode: isFake ? "fake" : "live")
    }
}

public struct SendFeedbackHostIO {
    public var runner: (any TailscaleRunning)?
    public var screenshot: @MainActor () -> Data?
    public var chooseSaveLocation: @MainActor (String) -> URL?
    public var share: @MainActor (URL) -> Void
    public var defaults: UserDefaults
    public var contributors: [any FeedbackContributor]

    public init(runner: (any TailscaleRunning)?, screenshot: @escaping @MainActor () -> Data? = { nil },
                chooseSaveLocation: @escaping @MainActor (String) -> URL? = { _ in nil },
                share: @escaping @MainActor (URL) -> Void = { _ in }, defaults: UserDefaults = .standard,
                contributors: [any FeedbackContributor] = []) {
        self.runner = runner
        self.screenshot = screenshot
        self.chooseSaveLocation = chooseSaveLocation
        self.share = share
        self.defaults = defaults
        self.contributors = contributors
    }
}

extension SystemCenter {
    public static let feedbackDeviceKey = DevFeedbackSettings.taildropTargetKey

    public func makeSendFeedbackModel(io: SendFeedbackHostIO) -> SendFeedbackModel {
        let isFake = environment.isFake
        let environment = self.environment
        let defaults = io.defaults
        let center = sendFeedback
        let dependencies = SendFeedbackDependencies(
            runner: io.runner, appInfo: { Self.appInfo(isFake: isFake) },
            accountCount: { [weak environment] in
                guard let environment, let snapshot = try? await environment.data.diagnosticsSnapshot() else { return 0 }
                return snapshot.accounts.count
            },
            diagnostics: { [weak self] in
                guard let self else { return nil }
                self.startDiagnostics()
                return try? await self.diagnostics?.build()
            },
            screenshot: io.screenshot, thread: { [weak center] in center?.threadHeader() }, contributors: io.contributors,
            savedDevice: { defaults.string(forKey: SystemCenter.feedbackDeviceKey) ?? "" },
            saveDevice: { defaults.set($0, forKey: SystemCenter.feedbackDeviceKey) },
            chooseSaveLocation: io.chooseSaveLocation, share: io.share)
        return SendFeedbackModel(dependencies)
    }
}
