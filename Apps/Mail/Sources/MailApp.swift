import AppKit
import MailFeatures
import MailTheme
import MailUI
import MailUIMac
import OpenHumanMailLive
import SwiftUI

@main
struct MailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @MainActor static let app = CompositionRoot.makeApp()
    @MainActor static let devFeedback = DevFeedbackRuntime.start()
    @MainActor static let updates = UpdateCheckSupport.makeCenter()

    init() {
        // Why: nothing is open yet, so a plain exit loses nothing.
        if SingleInstanceGuard.checkAtLaunch() == .quitThisCopy { exit(0) }
        QuietTestHost.installIfTesting()
        _ = Self.devFeedback
    }

    var body: some Scene {
        Window("OpenHuman Mail", id: DevFeedbackRuntime.mainWindowID) {
            RootView(app: Self.app)
                .frame(minWidth: 960, minHeight: 600)
                #if OH_DEV_TOOLS
                .devFeedbackSheet(Self.devFeedback)
                #endif
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1360, height: 860)
        .defaultLaunchBehavior(.presented)
        .commands {
            AboutCommands(label: .main, updates: Self.updates)
            MailCommands(router: { Self.app.router }, themes: { Self.app.router == nil ? nil : AppThemes.store })
            ToolbarCommands()
            WindowZoomCommands()
            #if OH_DEV_TOOLS
            DeveloperCommands(center: Self.devFeedback)
            #endif
            SystemCommands(environment: { Self.app.router?.environment })
            WelcomeGuideCommands(environment: { Self.app.router?.environment })
        }

        #if OH_DEV_TOOLS
        Window("Test checklist", id: DevFeedbackRuntime.checklistWindowID) {
            DevChecklistWindow(center: Self.devFeedback)
        }
        .defaultSize(width: 680, height: 780)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()
        #endif

        Settings {
            SettingsRoot(devFeedback: Self.devFeedback)
        }
    }
}

struct RootView: View {
    let app: AppModel

    var body: some View {
        screen.quietUnderTests()
            .modifier(UpdateCheckSheetHost(center: MailApp.updates, themes: AppThemes.store))
    }

    @ViewBuilder
    private var screen: some View {
        switch app.screen {
        case .launching:
            LaunchingView()
                .themed(by: AppThemes.store)
                .ignoresSafeArea()
        case .mail(let environment):
            MailWindowView(environment: environment)
                .id(ObjectIdentifier(environment))
        case .signIn(let model):
            ThemedSignInView(model: model)
                .themed(by: AppThemes.store)
                .ignoresSafeArea()
        case .notice(let problem):
            StartupProblemView(problem: problem, quit: { NSApp.terminate(nil) }, copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            })
            .themed(by: AppThemes.store)
            .ignoresSafeArea()
        }
    }
}

private struct ThemedSignInView: View {
    let model: SignInModel
    @Environment(\.theme) private var theme

    var body: some View {
        SignInView(model: model, theme: theme.tokens)
    }
}

struct MailWindowView: View {
    let environment: AppEnvironment
    var themes: ThemeStore = AppThemes.store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MainWindowRoot(environment: environment, themes: themes) { controller in
            DevFeedbackRuntime.attach(controller, to: MailApp.devFeedback)
            SendFeedbackSupport.install(in: environment, window: controller.windowModel)
            UpdateCheckSupport.install(in: environment, center: MailApp.updates)
            DebuggingTools.install(in: environment)
            environment.system.logLines = { MailApp.devFeedback.logs.diagnosticLines(now: Date()) }
        }
        .modifier(SendFeedbackSheetHost(center: environment.system.sendFeedback, themes: themes))
        .sheet(isPresented: Binding(get: { environment.welcomeGuide.isPresented },
                                    set: { if !$0 { environment.welcomeGuide.dismiss() } })) {
            if let guide = environment.welcomeGuide.model {
                WelcomeGuideView(model: guide) { environment.welcomeGuide.dismiss() }
                    .themed(by: themes)
            }
        }
        .onAppear {
            #if OH_DEV_TOOLS
            if MailApp.devFeedback.takeChecklistReopen() { openWindow(id: DevFeedbackRuntime.checklistWindowID) }
            #endif
            MainWindowPresenter.reopen = openWindow
            let openSettings = self.openSettings
            environment.settingsNavigator.openWindow = { openSettings() }
        }
    }
}
