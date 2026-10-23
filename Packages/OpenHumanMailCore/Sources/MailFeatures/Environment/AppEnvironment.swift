import Foundation
import MailModel
import MailTheme
import OpenHumanCore

@MainActor
public final class AppEnvironment {
    public let data: any MailDataSource
    public let commands: (any MailCommanding)?
    public let accounts: (any AccountManaging)?
    public let settings: (any SettingsPort)?
    public let renderQueue: RenderQueue
    public let theme: ThemeTokens
    public let isFake: Bool
    public let status: StatusModel
    public let notices: NoticeCenter
    public let undo: UndoCoordinator?
    public let navigationStore: any NavigationStateStoring
    public let importance: (any ImportanceRulesPort)?
    public let waiting: (any WaitingPort)?
    public let ai: AICenter?
    public let actions: ActionRegistry
    public private(set) var modules = ModuleRegistry()
    public let draftsDirectory: URL?
    private var systemPlatform: SystemPlatform
    public let aiOnboarding: (any AIOnboardingPort)?
    public let aiConnections: (any AIConnectionsPort)?
    public let secrets: (any SecretStoring)?
    public let onboardingProgress: any OnboardingProgressStoring
    public let isLiveAccount: Bool
    public let calendar: (any CalendarProviding)?
    public let calendarConnection: (any CalendarConnecting)?
    public let calendarConnections: (any CalendarConnectionsProviding)?
    private let systemPreferences: SystemPreferences
    private var systemStorage: SystemCenter?
    private var launched = false

    public init(data: any MailDataSource, commands: (any MailCommanding)? = nil, accounts: (any AccountManaging)? = nil,
                settings: (any SettingsPort)? = nil, theme: ThemeTokens = .light, isFake: Bool = false,
                navigationStore: (any NavigationStateStoring)? = nil, notices: NoticeCenter? = nil,
                importance: (any ImportanceRulesPort)? = nil, featureFlags: FeatureFlags = .atLaunch,
                modules moduleList: [any FeatureModule] = ModuleList.all, platform: SystemPlatform? = nil,
                systemPreferences: SystemPreferences? = nil, draftsDirectory: URL? = nil,
                aiOnboarding: (any AIOnboardingPort)? = nil, aiConnections: (any AIConnectionsPort)? = nil,
                secrets: (any SecretStoring)? = nil, onboardingProgress: (any OnboardingProgressStoring)? = nil,
                ai: AICenter? = nil, isLiveAccount: Bool = false, calendar: (any CalendarProviding)? = nil,
                calendarConnection: (any CalendarConnecting)? = nil, keymapStore: (any KeymapStoring)? = nil,
                calendarConnections: (any CalendarConnectionsProviding)? = nil,
                autoLabelStore: (any AutoLabelStoring)? = nil,
                calendarCache: (any CalendarCachePersisting)? = nil,
                learnedBehaviourStore: (any LearnedBehaviourStoring)? = nil,
                waiting: (any WaitingPort)? = nil) {
        self.data = data
        self.calendarCache = calendarCache
        self.learnedBehaviourStore = learnedBehaviourStore
        self.calendarConnections = calendarConnections
        self.autoLabelStore = autoLabelStore
        self.keymapStore = keymapStore ?? (isFake ? InMemoryKeymapStore() : UserDefaultsKeymapStore())
        self.isLiveAccount = isLiveAccount
        var routed: (any CalendarProviding)?
        if let connections = calendarConnections, connections.routesByAccount {
            routed = RoutedCalendarProvider(connections: connections)
        }
        self.calendar = calendar ?? routed
        self.calendarConnection = calendarConnection
        self.aiOnboarding = aiOnboarding
        self.aiConnections = aiConnections
        self.secrets = secrets
        self.onboardingProgress = onboardingProgress
            ?? (isFake ? InMemoryOnboardingProgress() : UserDefaultsOnboardingProgress())
        self.commands = commands
        self.accounts = accounts
        self.settings = settings
        self.draftsDirectory = draftsDirectory
        self.renderQueue = RenderQueue(settings: settings)
        self.theme = theme
        self.isFake = isFake
        self.status = StatusModel(data: data, settings: settings)
        let notices = notices ?? NoticeCenter()
        notices.timing = ToastTiming(theme: theme)
        self.notices = notices
        self.undo = commands.map { UndoCoordinator(commands: $0, notices: notices) }
        self.navigationStore = navigationStore ?? InMemoryNavigationStore()
        self.importance = importance
        self.waiting = waiting
        self.systemPlatform = platform ?? .inert()
        self.systemPreferences = systemPreferences
            ?? SystemPreferences(defaults: isFake ? AppEnvironment.fakeDefaults() : .standard)
        self.actions = ActionRegistry(recents: RecentActions(store: isFake ? InMemoryRecentActionsStore()
                                                                  : UserDefaultsRecentActionsStore()))
        self.ai = ai
        ai?.attach(self)
        self.modules = actions.install(environment: self,
                                       modules: moduleList + ModuleList.configured(calendar: self.calendar),
                                       flags: featureFlags)
        if let stored = self.keymapStore.load(), !stored.isEmpty { actions.applyKeymap(stored) }
    }

    public let keymapStore: any KeymapStoring

    // Why: fake data never touches real settings
    static func fakeDefaults() -> UserDefaults { ScopedDefaults("openhuman.fake") }

    private let autoLabelStore: (any AutoLabelStoring)?

    public private(set) lazy var autoLabels: AutoLabelCenter? = {
        guard ai != nil else { return nil }
        return AutoLabelCenter(environment: self, store: autoLabelStore ?? InMemoryAutoLabelStore())
    }()

    public private(set) lazy var classification = ClassificationRuleSet(environment: self)

    public var superhumanLabels: SuperhumanLabelDisplay {
        if let superhumanLabelsStorage { return superhumanLabelsStorage }
        let made = SuperhumanLabelDisplay(settings: settings)
        superhumanLabelsStorage = made
        return made
    }

    private var superhumanLabelsStorage: SuperhumanLabelDisplay?

    private let learnedBehaviourStore: (any LearnedBehaviourStoring)?

    public private(set) lazy var learning: LearnedBehaviourCenter = {
        LearnedBehaviourCenter(environment: self, store: learnedBehaviourStore ?? InMemoryLearnedBehaviourStore())
    }()

    public var searchRanking: SearchRankingModel {
        if let searchRankingStorage { return searchRankingStorage }
        let made = SearchRankingModel(port: InMemorySearchRankingPort(), notices: notices)
        searchRankingStorage = made
        return made
    }
    private var searchRankingStorage: SearchRankingModel?

    public func installSearchRanking(_ port: any SearchRankingPort) {
        searchRankingStorage = SearchRankingModel(port: port, notices: notices)
    }

    public var archiveSuggestion: ArchiveSuggestionModel? {
        if let archiveSuggestionStorage { return archiveSuggestionStorage }
        guard modules.modules.contains(.hygiene) else { return nil }
        let model = ArchiveSuggestionModel(environment: self)
        archiveSuggestionStorage = model
        return model
    }

    private var archiveSuggestionStorage: ArchiveSuggestionModel?

    public var followUps: FollowUpReminders {
        if let followUpsStorage { return followUpsStorage }
        let made = FollowUpReminders(environment: self)
        followUpsStorage = made
        return made
    }

    private var followUpsStorage: FollowUpReminders?

    public var vips: VIPCenter {
        if let vipsStorage { return vipsStorage }
        let made = VIPCenter(data: data, importance: importance, settings: settings, undo: undo)
        vipsStorage = made
        made.start()
        return made
    }

    private var vipsStorage: VIPCenter?

    public var calendarSidebar: CalendarSidebarModel? {
        if let calendarStorage { return calendarStorage }
        guard let calendar, modules.modules.contains(.calendar) else { return nil }
        let model = CalendarSidebarModel(environment: self, provider: calendar)
        calendarStorage = model
        return model
    }

    public var calendarSidebarIfStarted: CalendarSidebarModel? { calendarStorage }
    private var calendarStorage: CalendarSidebarModel?

    public var scheduling: SchedulingAssistant? {
        if let schedulingStorage { return schedulingStorage }
        guard let calendar, calendarSidebar != nil else { return nil }
        let model = SchedulingAssistant(environment: self, provider: calendar)
        schedulingStorage = model
        return model
    }

    public var schedulingIfStarted: SchedulingAssistant? { schedulingStorage }
    private var schedulingStorage: SchedulingAssistant?

    public var invites: InviteCenter {
        if let invitesStorage { return invitesStorage }
        let made = InviteCenter(environment: self)
        invitesStorage = made
        return made
    }

    public var invitesIfStarted: InviteCenter? { invitesStorage }
    private var invitesStorage: InviteCenter?

    public var pendingEvents: PendingEventStore {
        if let pendingEventsStorage { return pendingEventsStorage }
        let made = PendingEventStore()
        pendingEventsStorage = made
        return made
    }

    private var pendingEventsStorage: PendingEventStore?

    public let calendarCache: (any CalendarCachePersisting)?

    public var calendarEvents: CalendarEventStore {
        if let calendarEventsStorage { return calendarEventsStorage }
        let made = CalendarEventStore(persistence: calendarCache)
        made.isOffline = { [weak self] in
            self?.status.connectivity.values.contains { if case .offline = $0 { true } else { false } } ?? false
        }
        calendarEventsStorage = made
        return made
    }

    private var calendarEventsStorage: CalendarEventStore?
    private var calendarFollowers: [Task<Void, Never>] = []

    func startCalendarCache() {
        guard calendarCache != nil else { return }
        let store = calendarEvents
        guard let calendar else { return store.forgetAll() }
        Task { @MainActor [weak self] in
            await store.restore(now: Date())
            guard let self else { return }
            var keep: Set<CalendarCacheKey> = [CalendarEventStore.key(for: calendar)]
            var connections: [any CalendarConnecting] = self.calendarConnection.map { [$0] } ?? []
            if let routed = self.calendarConnections, routed.routesByAccount {
                keep = []
                let accounts = await AIThreadLoader.first(self.data.accounts()) ?? []
                for account in accounts {
                    if let provider = routed.calendarProvider(for: account) { keep.insert(CalendarEventStore.key(for: provider)) }
                    if let connection = routed.calendarConnection(for: account) { connections.append(connection) }
                }
            }
            store.retain(keep)
            self.calendarFollowers = connections.map { store.follow($0.connectionStates()) }
        }
    }

    public var calendarWindow: CalendarWindowModel? {
        if let calendarWindowStorage { return calendarWindowStorage }
        guard let sidebar = calendarSidebar else { return nil }
        let model = CalendarWindowModel(environment: self, sidebar: sidebar)
        calendarWindowStorage = model
        return model
    }

    public var calendarWindowIfStarted: CalendarWindowModel? { calendarWindowStorage }
    private var calendarWindowStorage: CalendarWindowModel?

    public func calendarDiagnostics(now: Date = Date()) async -> [DiagnosticsCalendarEntry] {
        guard let connections = calendarConnections else { return [] }
        let accounts = await AIThreadLoader.first(data.accounts()) ?? []
        var out: [DiagnosticsCalendarEntry] = []
        for (offset, account) in accounts.enumerated() {
            var state: CalendarConnectionState?
            if let connection = connections.calendarConnection(for: account) {
                for await first in connection.connectionStates() {
                    state = first
                    break
                }
            }
            out.append(DiagnosticsCalendarEntry(index: offset + 1, state: state, now: now))
        }
        return out
    }

    public private(set) lazy var router: AppRouter = AppRouter(environment: self, location: nil, restoring: navigationStore)

    public private(set) lazy var overlays: OverlayCenter = {
        let center = OverlayCenter(environment: self, router: router,
                                   searchStore: isFake ? InMemoryRecentSearchesStore() : UserDefaultsRecentSearchesStore())
        actions.presenter = center
        return center
    }()

    public var compose: ComposeManager {
        if let composeStorage { return composeStorage }
        let drafts = draftsDirectory
        let manager = ComposeManager(environment: self, recovery: drafts.map { FileDraftRecovery(directory: $0) },
                                     staging: drafts.map { DirectoryAttachmentStaging(directory: $0) })
        composeStorage = manager
        return manager
    }

    public var composeIfStarted: ComposeManager? { composeStorage }
    private var composeStorage: ComposeManager?

    public var composeText: ComposeTextSettings {
        if let composeTextStorage { return composeTextStorage }
        let defaults = isFake ? AppEnvironment.fakeDefaults() : .standard
        let made = ComposeTextSettings(defaults: defaults, system: systemPlatform.textSettings,
                                       onDeviceOnly: { [weak self] account in self?.ai?.isOnDeviceOnly(account) ?? false })
        composeTextStorage = made
        return made
    }

    private var composeTextStorage: ComposeTextSettings?

    public private(set) var attachmentDrag: AttachmentDragWriter?
    public private(set) var threadDrag: ThreadEMLDragWriter?

    func installAttachmentDrag() {
        guard attachmentDrag == nil else { return }
        attachmentDrag = AttachmentDragWriter(data: data)
        threadDrag = ThreadEMLDragWriter(data: data)
    }

    public var review: ReviewQueueModel {
        if let reviewStorage { return reviewStorage }
        let model = ReviewQueueModel(environment: self)
        reviewStorage = model
        return model
    }

    public var reviewIfStarted: ReviewQueueModel? { reviewStorage }
    private var reviewStorage: ReviewQueueModel?

    public var failedOperationNotices: FailedOperationNotices {
        if let failedNoticesStorage { return failedNoticesStorage }
        let made = FailedOperationNotices(environment: self)
        failedNoticesStorage = made
        return made
    }

    private var failedNoticesStorage: FailedOperationNotices?

    public var reminderTimes: ReminderTimeSettings {
        if let reminderTimesStorage { return reminderTimesStorage }
        let made = ReminderTimeSettings(settings: settings)
        reminderTimesStorage = made
        return made
    }

    private var reminderTimesStorage: ReminderTimeSettings?

    public var welcomeGuide: WelcomeGuideCenter {
        if let welcomeStorage { return welcomeStorage }
        let center = WelcomeGuideCenter(environment: self)
        welcomeStorage = center
        return center
    }

    private var welcomeStorage: WelcomeGuideCenter?

    public let settingsNavigator = SettingsNavigator()

    public var system: SystemCenter {
        if let systemStorage { return systemStorage }
        let center = SystemCenter(environment: self, platform: systemPlatform, preferences: systemPreferences)
        systemStorage = center
        return center
    }

    public func installPlatform(_ platform: SystemPlatform) {
        guard systemStorage == nil else { return }
        systemPlatform = platform
    }

    public func runLaunchTasks() {
        guard !launched else { return }
        launched = true
        autoLabels?.start()
        startCalendarCache()
        let learning = self.learning
        Task { @MainActor in await learning.start() }
        if let shortcutHints = actions.shortcutHints { Task { @MainActor in await shortcutHints.start() } }
        let tasks = modules.launchTasks
        Task { @MainActor [data, commands, availability = SettingsAvailability(environment: self)] in
            await SplitPresetMigration.runAtLaunch(data: data, commands: commands, availability: availability)
            for task in tasks { await task() }
        }
    }
}
