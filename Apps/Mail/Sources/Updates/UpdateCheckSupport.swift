import AppKit
import MailFeatures
import MailUI
import OpenHumanMailLive
import SwiftUI

@MainActor
enum UpdateCheckSupport {
    static func makeCenter(environment: [String: String] = ProcessInfo.processInfo.environment,
                           label: BuildLabel = .main,
                           info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> UpdateCheckCenter {
        let updates = SparkleUpdater.startIfAllowed(environment: environment, info: info)
        let center = UpdateCheckCenter(current: label, feed: .openHuman, fetch: fetch(environment: environment),
                                       openURL: { NSWorkspace.shared.open($0) }, updater: updates.updater,
                                       updatesUnavailable: updates.unavailable)
        center.showWindow = { MainWindowPresenter.show() }
        return center
    }

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
