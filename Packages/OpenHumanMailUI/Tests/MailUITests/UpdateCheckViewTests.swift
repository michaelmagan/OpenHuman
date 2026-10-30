#if os(macOS)
import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI

private let updateNow = Date(timeIntervalSince1970: 1_791_000_000)
private let earlyBuild = BuildLabel(version: "0.1.0", build: "1001", channel: "early-development")
private let newerRelease = Data(#"""
[{"tag_name":"v0.2.0","draft":false,"prerelease":true,"body":"Faster search\n- Fixed sync",
  "html_url":"https://github.com/michaelmagan/OpenHuman/releases/tag/v0.2.0"}]
"""#.utf8)

@MainActor
private func checkedCenter(_ reply: UpdateFeedReply?) async -> UpdateCheckCenter {
    let center = UpdateCheckCenter(current: earlyBuild, fetch: { _ in
        guard let reply else { throw UpdateFeedFailure.offline }
        return reply
    }, openURL: { _ in }, now: { updateNow })
    await center.check()
    return center
}

@MainActor
private func host<V: View>(_ view: V, size: NSSize, theme: ResolvedTheme = .light) -> NSHostingView<some View> {
    let hosting = NSHostingView(rootView: view.environment(\.theme, theme)
        .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light).background(theme.bgWindow.color))
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    return hosting
}

@MainActor
@Test func theUpdateSheetLaysOutInEveryStateAndBothThemes() async {
    let idle = UpdateCheckCenter(current: earlyBuild, fetch: { _ in UpdateFeedReply(status: 404) }, openURL: { _ in },
                                 now: { updateNow })
    let states: [(String, UpdateCheckCenter)] = [
        ("idle", idle),
        ("available", await checkedCenter(UpdateFeedReply(status: 200, body: newerRelease))),
        ("not-published", await checkedCenter(UpdateFeedReply(status: 404))),
        ("offline", await checkedCenter(nil)),
        ("rate-limited", await checkedCenter(UpdateFeedReply(status: 429, headers: ["retry-after": "600"]))),
    ]
    for (name, center) in states {
        for theme in [ResolvedTheme.light, .dark] {
            let hosting = host(UpdateCheckSheet(center: center), size: NSSize(width: UpdateCheckSheet.width, height: 420), theme: theme)
            #expect(hosting.fittingSize.width == UpdateCheckSheet.width, "\(name)")
            #expect(hosting.fittingSize.height > 120, "\(name)")
        }
    }
    let available = states[1].1
    #expect(available.available?.noteLines == ["Faster search", "• Fixed sync"])
}

@MainActor
@Test func theSettingsRowOffersDownloadOnlyForANewerRelease() async {
    let idle = UpdateCheckCenter(current: earlyBuild, fetch: { _ in UpdateFeedReply(status: 404) }, openURL: { _ in },
                                 now: { updateNow })
    #expect(UpdateCheckSettingsSection(center: idle).checkTitle == "Check Now")
    #expect(idle.summary == nil && idle.versionLine == "You have version 0.1.0 (1001).")
    let available = await checkedCenter(UpdateFeedReply(status: 200, body: newerRelease))
    #expect(UpdateCheckSettingsSection(center: available).checkTitle == "Check Again")
    #expect(available.available != nil && available.summary == "Version 0.2.0 is available.")
    let notYet = await checkedCenter(UpdateFeedReply(status: 404))
    #expect(notYet.available == nil)
    for center in [idle, available, notYet] {
        let hosting = host(UpdateCheckSettingsSection(center: center),
                           size: NSSize(width: SettingsMetrics.contentMaxWidth, height: 240))
        #expect(hosting.fittingSize.height > 60)
    }
}

@MainActor
private final class StubUpdater: SoftwareUpdater {
    var automaticallyChecksForUpdates = true
    var lastUpdateCheckDate: Date? = updateNow.addingTimeInterval(-3600)
    var checks = 0
    func checkForUpdates() { checks += 1 }
}

@MainActor
@Test func withAnUpdaterTheSectionOffersCheckNowTheLastCheckAndTheAutomaticSwitch() {
    let updater = StubUpdater()
    let center = UpdateCheckCenter(current: earlyBuild, fetch: { _ in UpdateFeedReply(status: 404) }, openURL: { _ in },
                                   updater: updater, now: { updateNow })
    #expect(center.lastCheckedLine == "Last checked 1 hour ago.")
    #expect(center.updatesUnavailable == nil)
    var heights: [CGFloat] = []
    for theme in [ResolvedTheme.light, .dark] {
        let hosting = host(UpdateCheckSettingsSection(center: center),
                           size: NSSize(width: SettingsMetrics.contentMaxWidth, height: 300), theme: theme)
        heights.append(hosting.fittingSize.height)
    }
    #expect(heights.allSatisfy { $0 > 100 }, "two rows and the note: \(heights)")
    #expect(updater.checks == 0, "drawing the section checks nothing")
    center.begin()
    #expect(updater.checks == 1 && !center.isPresented, "Check Now hands the check to the updater; no sheet as well")
}

@MainActor
@Test func aBuildThatCannotUpdateSaysSoAndWhyBesideTheGitHubCheck() {
    for reason in UpdatesUnavailableReason.allCases {
        let center = UpdateCheckCenter(current: earlyBuild, fetch: { _ in UpdateFeedReply(status: 404) }, openURL: { _ in },
                                       updatesUnavailable: reason, now: { updateNow })
        let plain = UpdateCheckCenter(current: earlyBuild, fetch: { _ in UpdateFeedReply(status: 404) }, openURL: { _ in },
                                      now: { updateNow })
        let size = NSSize(width: SettingsMetrics.contentMaxWidth, height: 400)
        let explained = host(UpdateCheckSettingsSection(center: center), size: size).fittingSize.height
        let unexplained = host(UpdateCheckSettingsSection(center: plain), size: size).fittingSize.height
        #expect(explained > unexplained, "the extra row for \(reason)")
        #expect(UpdateCheckSettingsSection(center: center).checkTitle == "Check Now", "the GitHub check stays")
    }
}

@MainActor
@Test func theGeneralPageShowsUpdatesOnceTheAppInstallsTheCheck() async {
    let environment = AppEnvironment.fake(corpus: .rich(threadCount: 20, now: updateNow), options: .init(remoteAck: .immediate),
                                          featureFlags: FeatureFlags())
    #expect(environment.system.updates == nil, "the page leaves the section out until the app installs the check")
    environment.system.updates = await checkedCenter(UpdateFeedReply(status: 200, body: newerRelease))
    let hosting = host(GeneralSettingsPage(environment: environment, extras: { AnyView(EmptyView()) }),
                       size: NSSize(width: 820, height: 600))
    #expect(hosting.frame.width == 820)
}
#endif
