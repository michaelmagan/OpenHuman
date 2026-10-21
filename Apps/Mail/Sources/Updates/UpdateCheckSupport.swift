import AppKit
import MailFeatures
import MailUI
import OpenHumanMailLive
import SwiftUI

@MainActor
enum UpdateCheckSupport {
    static func makeCenter(environment: [String: String] = ProcessInfo.processInfo.environment,
                           label: BuildLabel = .main, info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> UpdateCheckCenter {
        let center = UpdateCheckCenter(current: label, feed: .openHuman, fetch: fetch(environment: environment),
                                       openURL: { NSWorkspace.shared.open($0) },
                                       updater: updater(environment: environment, info: info))
        center.showWindow = { MainWindowPresenter.show() }
        return center
    }

    // Why: a test run or a developer build never starts Sparkle, and a build without a feed and key keeps the GitHub check
    static func updater(environment: [String: String], info: [String: Any],
                        developerBuild: Bool = isDeveloperBuild) -> (any SoftwareUpdater)? {
        guard environment["XCTestConfigurationFilePath"] == nil, !developerBuild, SparkleUpdater.isConfigured(info) else { return nil }
        return SparkleUpdater()
    }

    #if OH_DEV_TOOLS
    static let isDeveloperBuild = true
    #else
    static let isDeveloperBuild = false
    #endif

    // Why: a test run never reaches the network; only a click in a real launch asks GitHub
    static func fetch(environment: [String: String]) -> UpdateFeedFetch {
        guard environment["XCTestConfigurationFilePath"] == nil else { return { _ in throw UpdateFeedFailure.unreachable } }
        return ReleaseFeedClient.live(appVersion: CompositionRoot.appVersion).fetch
    }

    static func install(in environment: AppEnvironment, center: UpdateCheckCenter) {
        environment.system.updates = center
    }
}

struct UpdateCheckSheetHost: ViewModifier {
    let center: UpdateCheckCenter
    let themes: ThemeStore

    func body(content: Content) -> some View {
        let presented = center.isPresented
        content.sheet(isPresented: Binding(get: { presented }, set: { if !$0 { center.close() } })) {
            UpdateCheckSheet(center: center)
                .themed(by: themes)
        }
    }
}
