import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import MailUIMac
import SwiftUI

struct SettingsRoot: View {
    let devFeedback: DevFeedbackCenter

    private var developerOptions: DeveloperOptions { AppDeveloperOptions.shared(devFeedback.availability) }

    private static var environment: AppEnvironment? { MailApp.app.router?.environment }

    var body: some View {
        Group {
            if let environment = Self.environment {
                SettingsShellView(environment: environment, hosting: hosting(environment))
            } else {
                SettingsShellView(standaloneHosting: SettingsHosting(
                    appearance: { AnyView(appearance) }, advancedExtras: { AnyView(advanced) },
                    showsDeveloperItems: Self.showsDeveloperItems(developerOptions),
                    offersDeveloperSettings: developerOptions.isAvailable,
                    build: .main))
            }
        }
        .themed(by: AppThemes.store)
        .frame(minWidth: SettingsMetrics.windowWidth, idealWidth: SettingsMetrics.windowWidth,
               minHeight: SettingsMetrics.windowHeight, idealHeight: SettingsMetrics.windowHeight)
        .background(SettingsWindowHook())
    }

    static func showsDeveloperItems(_ options: DeveloperOptions) -> Bool { options.showsDeveloperItems }

    private func hosting(_ environment: AppEnvironment) -> SettingsHosting {
        let modules = environment.modules.modules
        return SettingsHosting(
            appearance: { AnyView(appearance) },
            notifications: { AnyView(NotificationsSettingsPage(environment: environment)) },
            generalExtras: {
                AnyView(Group {
                    if modules.contains(.launchAtLogin) || modules.contains(.dockBadge) {
                        SystemGeneralSettingsView(environment: environment)
                    }
                    OpenIconSwitch()
                })
            },
            advancedExtras: { AnyView(advanced) },
            aiProviders: environment.ai.map { center in {
                AISettingsPageContent.view(center: center, environment: environment,
                                           showsDeveloperItems: Self.showsDeveloperItems(developerOptions))
            } },
            printText: { PrintCheatSheet.print($0) },
            showsDeveloperItems: Self.showsDeveloperItems(developerOptions),
            offersDeveloperSettings: developerOptions.isAvailable,
            build: .main)
    }

    static func promptTester(_ center: AICenter) -> PromptsSettingsModel.Tester {
        { [weak center] info, draft in
            guard let center else { throw PromptTestError.noConversation }
            guard let thread = center.promptTestThread else { throw PromptTestError.noConversation }
            return try await center.testPrompt(info, draft: draft, on: thread)
        }
    }

    private var appearance: some View {
        AppearanceSettingsView(store: AppThemes.store, fontFamilies: MacFontCatalog.families,
                               onRevealFolder: AppThemes.revealFolder)
    }

    private var advanced: some View {
        Group {
            #if OH_DEV_TOOLS
            DeveloperOptionsSection(options: developerOptions)
            DevFeedbackSettingsView(settings: devFeedback.settings, availability: devFeedback.availability,
                                    feedbackFolder: devFeedback.paths.feedbackDirectory.path,
                                    onRevealFolder: { DevFeedbackRuntime.revealFeedbackFolder(devFeedback) })
            #endif
        }
    }
}

@MainActor
enum AppDeveloperOptions {
    private static var created: DeveloperOptions?

    static func shared(_ devFeedback: DevFeedbackAvailability,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> DeveloperOptions {
        if let created { return created }
        let defaults = environment["XCTestConfigurationFilePath"] != nil
            ? (UserDefaults(suiteName: "dev.openhuman.mail.tests.developerOptions") ?? .standard) : .standard
        let options = DeveloperOptions(devFeedback: devFeedback, defaults: defaults)
        created = options
        return options
    }
}

#if OH_DEV_TOOLS
struct DeveloperOptionsSection: View {
    @Bindable var options: DeveloperOptions

    static let detail = "Shows the switches and notes meant for developers in Settings: every feature module, build "
        + "notes and models that aren't available yet. Off by default."
    static let sendToDeviceTitle = "Send to another device via Tailscale"
    static let sendToDeviceDetail = "Adds \"\(SendFeedbackCenter.menuTitle)\" to the Help menu, the command palette and "
        + "this page: a note with scrubbed diagnostics, sent to one of your own devices over Tailscale. Off by default."
    static let debuggingToolsTitle = "Show debugging tools"
    static let debuggingToolsDetail = "Adds \"Copy debug info for this conversation\" and \"Save debug info to a "
        + "file…\" to the Help menu and the command palette. They only read; nothing about your mail changes. Off by "
        + "default."

    var body: some View {
        if options.isAvailable {
            SettingsSection("Developer options") {
                SettingsRow("Show developer options", detail: Self.detail, isOn: $options.isOn)
                SettingsRow(Self.debuggingToolsTitle, detail: Self.debuggingToolsDetail, isOn: $options.debuggingTools)
                SettingsRow(Self.sendToDeviceTitle, detail: Self.sendToDeviceDetail, isOn: $options.sendToDevice)
            }
        }
    }
}
#endif

@MainActor
enum DebuggingTools {
    static func install(in environment: AppEnvironment) {
        #if OH_DEV_TOOLS
        install(in: environment, options: AppDeveloperOptions.shared(DevFeedbackRuntime.availability))
        #endif
    }

    #if OH_DEV_TOOLS
    static func install(in environment: AppEnvironment, options: DeveloperOptions) {
        environment.system.showsDebuggingTools = { options.showsDebuggingTools }
    }
    #endif
}

@MainActor
enum AppThemes {
    private static var monitor: SystemAppearanceMonitor?
    private static var created: ThemeStore?

    static var store: ThemeStore {
        if let created { return created }
        let folder = ThemeFolder.defaultURL().map(ThemeFolder.init(url:))
        let store = ThemeStore(library: .builtIn, preferencesStore: UserDefaultsThemePreferencesStore(), folder: folder)
        store.isFontInstalled = { MacFontCatalog.isInstalled($0) }
        monitor = SystemAppearanceMonitor(store: store)
        if let folder {
            store.startWatching(FSEventsThemeFolderWatcher(url: folder.url))
            Task { await store.reloadThemes() }
        }
        created = store
        return store
    }

    static func revealFolder() {
        guard let folder = store.folder else { return }
        try? folder.create()
        NSWorkspace.shared.activateFileViewerSelecting([folder.url])
    }

    static var themeInfo: DevFeedbackSnapshot.ThemeInfo {
        if let created {
            return DevFeedbackSnapshot.ThemeInfo(themeID: created.resolved.themeID, appearance: "\(created.resolved.appearance)",
                                                 mode: "\(created.preferences.mode)", accentID: created.resolved.accentID)
        }
        let preferences = UserDefaultsThemePreferencesStore().load() ?? ThemePreferences()
        let appearance = preferences.mode.effective(system: SystemAppearanceMonitor.appearance(of: NSApp.effectiveAppearance))
        return DevFeedbackSnapshot.ThemeInfo(themeID: preferences.themeID(for: appearance), appearance: "\(appearance)",
                                             mode: "\(preferences.mode)", accentID: preferences.accentID)
    }
}

private struct NotificationsSettingsPage: View {
    @State private var model: NotificationsSettingsModel

    init(environment: AppEnvironment) {
        _model = State(initialValue: NotificationsSettingsModel(environment: environment))
    }

    var body: some View {
        NotificationsSettingsView(model: model)
    }
}

private struct OpenIconSwitch: View {
    @AppStorage(AppIconController.settingKey) private var on = true

    var body: some View {
        SettingsRow("Show the open envelope in the Dock while Mail is running", isOn: $on)
            .onChange(of: on) { _, value in AppIconController.shared.setEnabled(value) }
    }
}
