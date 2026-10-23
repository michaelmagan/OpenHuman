import Foundation
import MailFakes
import MailModel
import OpenHumanCore

public struct SystemPlatform {
    public var notifier: any SystemNotifying
    public var dock: any DockBadging
    public var loginItem: any LoginItemControlling
    public var urlOpener: any URLOpening
    public var spotlight: any SpotlightIndexing
    public var menuBarItem: any MenuBarItemControlling
    public var hotkeys: any GlobalHotkeyRegistering
    public var services: any ServicesRegistering
    public var textSettings: any SystemTextSettings
    public var isAppActive: @MainActor () -> Bool
    public var activateApp: @MainActor () -> Void
    public var showMainWindow: @MainActor () -> Void
    public var quitApp: @MainActor () -> Void
    public var chooseDiagnosticsFile: @MainActor (_ suggestedName: String) -> URL?
    public var confirmConversationDebug: @MainActor () -> ConversationDebugOptions? = { ConversationDebugOptions() }
    public var chooseConversationDebugFile: @MainActor (_ suggestedName: String) -> URL? = { _ in nil }
    // Without a window to ask in, a rule for a whole common domain is never made
    public var confirmDomainWideRule: @MainActor (DomainWideRuleConfirmation) async -> DomainWideRuleChoice = { _ in .cancel }
    public var copyToClipboard: @MainActor (_ text: String) -> Void = { _ in }
    public var openNotificationSettings: @MainActor () -> Void
    // True while the user is mid-task in Mail, so a Focus change never moves the window under them
    public var isAuthorTyping: @MainActor () -> Bool = { false }
    public var currentFocusFilter: @MainActor () async -> FocusFilterState? = { nil }

    @MainActor
    public init(notifier: any SystemNotifying, dock: any DockBadging, loginItem: any LoginItemControlling,
                urlOpener: any URLOpening, spotlight: any SpotlightIndexing = FakeSpotlightIndex(),
                menuBarItem: any MenuBarItemControlling = FakeMenuBarItem(),
                hotkeys: any GlobalHotkeyRegistering = FakeGlobalHotkey(),
                services: any ServicesRegistering = FakeServicesRegistrar(),
                textSettings: any SystemTextSettings = FakeSystemTextSettings(),
                isAppActive: @escaping @MainActor () -> Bool,
                activateApp: @escaping @MainActor () -> Void = {},
                showMainWindow: (@MainActor () -> Void)? = nil,
                quitApp: @escaping @MainActor () -> Void = {},
                chooseDiagnosticsFile: @escaping @MainActor (String) -> URL? = { _ in nil },
                openNotificationSettings: @escaping @MainActor () -> Void = {}) {
        self.notifier = notifier
        self.dock = dock
        self.loginItem = loginItem
        self.urlOpener = urlOpener
        self.spotlight = spotlight
        self.menuBarItem = menuBarItem
        self.hotkeys = hotkeys
        self.services = services
        self.textSettings = textSettings
        self.isAppActive = isAppActive
        self.activateApp = activateApp
        self.showMainWindow = showMainWindow ?? activateApp
        self.quitApp = quitApp
        self.chooseDiagnosticsFile = chooseDiagnosticsFile
        self.openNotificationSettings = openNotificationSettings
    }

    @MainActor
    public static func inert() -> SystemPlatform {
        SystemPlatform(notifier: FakeSystemNotifier(authorization: .authorized), dock: FakeDockBadge(),
                       loginItem: FakeLoginItem(), urlOpener: FakeURLOpener(), spotlight: FakeSpotlightIndex(),
                       menuBarItem: FakeMenuBarItem(), hotkeys: FakeGlobalHotkey(), isAppActive: { false })
    }
}
