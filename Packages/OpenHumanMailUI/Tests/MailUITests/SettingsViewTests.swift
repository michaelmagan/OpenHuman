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

private let fixedNow = Date(timeIntervalSince1970: 1_791_000_000)

@MainActor
private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 820, height: 600), name: String,
                           theme: ResolvedTheme = .light) throws -> NSHostingView<some View> {
    let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore())
    let hosting = NSHostingView(rootView: view.environment(\.theme, theme).environment(store)
        .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light).background(theme.bgWindow.color))
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    if let dir = ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] {
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    return hosting
}

@MainActor
private func environment() -> AppEnvironment {
    AppEnvironment.fake(corpus: .rich(threadCount: 20, now: fixedNow), options: .init(remoteAck: .immediate),
                        featureFlags: FeatureFlags())
}

@MainActor
@Test func theShellLaysOutInBothThemes() throws {
    let window = NSSize(width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowHeight)
    let hosting = try host(SettingsShellView(environment: environment(), hosting: SettingsHosting(), defaults: .standard),
                           size: window, name: "settings-shell-light")
    #expect(hosting.frame.width == SettingsMetrics.windowWidth)
    _ = try host(SettingsShellView(environment: environment(), hosting: SettingsHosting(), defaults: .standard),
                 size: window, name: "settings-shell-dark", theme: .dark)
    let standalone = SettingsHosting(appearance: { AnyView(Text(verbatim: "Appearance page")) },
                                     advancedExtras: { AnyView(SettingsSection("Developer") { SettingsRow("A row") }) },
                                     showsDeveloperItems: true)
    _ = try host(SettingsShellView(standaloneHosting: standalone), size: window, name: "settings-shell-signed-out")
    _ = try host(SettingsShellView(standaloneHosting: SettingsHosting(appearance: { AnyView(Text(verbatim: "Appearance page")) })),
                 size: window, name: "settings-shell-signed-out-public")
    let early = BuildLabel(version: "0.1.0", build: "1001", channel: "early-development")
    _ = try host(SettingsShellView(environment: environment(), hosting: SettingsHosting(build: early), defaults: .standard),
                 size: window, name: "settings-shell-early-development")
    _ = try host(SettingsShellView(standaloneHosting: SettingsHosting(appearance: { AnyView(Text(verbatim: "Appearance page")) },
                                                                      build: early)),
                 size: window, name: "settings-shell-signed-out-early-development", theme: .dark)
}

@MainActor
@Test func everyPageLaysOutOnFakes() async throws {
    let env = environment()
    let extras: () -> AnyView = { AnyView(EmptyView()) }
    _ = try host(GeneralSettingsPage(environment: env, extras: extras), name: "settings-general")
    _ = try host(AccountsSettingsPage(environment: env), name: "settings-accounts")
    _ = try host(SplitSettingsPage(environment: env), name: "settings-splits")
    _ = try host(SnippetSettingsPage(environment: env), name: "settings-snippets")
    _ = try host(ShortcutsSettingsPage(environment: env, printText: { _ in }), name: "settings-shortcuts")
    _ = try host(PrivacySettingsPage(environment: env), name: "settings-privacy")
    _ = try host(AISettingsPage(environment: env, providers: nil), name: "settings-ai")
    _ = try host(AdvancedSettingsPage(environment: env, extras: extras), name: "settings-advanced")
    _ = try host(PlatformFeaturesPage(environment: env), name: "settings-platform")
    _ = try host(ImportanceSettingsPage(environment: env), name: "settings-importance")
    _ = try host(AdvancedSettingsPage(environment: env, extras: extras, showsDeveloperItems: false), name: "settings-advanced-public")
    _ = try host(PlatformFeaturesPage(environment: env, showsDeveloperItems: false), name: "settings-platform-public")
    _ = try host(CalendarSettingsPage(environment: env), name: "settings-calendar")
}

@MainActor
@Test func theSearchPageLaysOutWithAndWithoutTheMailRows() throws {
    let env = environment()
    #expect(SettingsShellModel(environment: env).pages.contains { $0.id == "search" })
    _ = try host(SearchSettingsPage(environment: env), name: "settings-search")
    _ = try host(SearchSettingsPage(model: env.searchRanking), name: "settings-search-ranking-only")
}

@MainActor
@Test func confirmBeforeSendingIsOfferedOnALiveAccountOnly() throws {
    let store = FakeMailStore(corpus: .rich(threadCount: 20, now: fixedNow), options: .init(remoteAck: .immediate))
    let live = AppEnvironment(data: store, commands: store, accounts: store, settings: store, isFake: true,
                              featureFlags: FeatureFlags(), isLiveAccount: true)
    #expect(GeneralSettingsModel(environment: live).showsConfirmBeforeSending)
    #expect(!GeneralSettingsModel(environment: environment()).showsConfirmBeforeSending)
    _ = try host(GeneralSettingsPage(environment: live, extras: { AnyView(EmptyView()) }), name: "settings-general-live")
}

@MainActor
@Test func theCalendarPageLaysOutWithAndWithoutACalendar() throws {
    let plain = environment()
    #expect(SettingsShellModel(environment: plain).pages.contains { $0.id == "calendar" })
    let configured = AppEnvironment.fake(corpus: .rich(threadCount: 20, now: fixedNow), options: .init(remoteAck: .immediate),
                                         featureFlags: FeatureFlags(), calendar: FakeCalendar.sample(now: fixedNow))
    let connectable = AppEnvironment.fake(corpus: .rich(threadCount: 20, now: fixedNow), options: .init(remoteAck: .immediate),
                                          featureFlags: FeatureFlags(),
                                          calendarConnection: FakeCalendarConnection(account: "robin@example.com"))
    for (env, name) in [(plain, "settings-calendar-not-connected"), (configured, "settings-calendar-connected"),
                        (connectable, "settings-calendar-connect-switch")] {
        let hosting = try host(CalendarSettingsPage(environment: env), name: name)
        #expect(hosting.frame.width == 820)
        _ = try host(CalendarSettingsPage(environment: env), name: name + "-dark", theme: .dark)
    }
    #expect(CalendarSettingsModel(environment: plain).status == "Google Calendar is not connected.")
    #expect(CalendarSettingsModel(environment: configured).isRunning)
    #expect(CalendarSettingsModel(environment: connectable).canConnect)
}

@MainActor
@Test func theWelcomeGuideLaysOutEveryStepAndClosingKeepsTheStep() async throws {
    let env = environment()
    let progress = InMemoryOnboardingProgress()
    let model = OnboardingModel(store: progress, ports: OnboardingModel.Ports(
        data: env.data, accounts: env.accounts, ai: FakeAIOnboarding(), notifier: FakeSystemNotifier(),
        loginItem: FakeLoginItem()))
    var closed = 0
    for step in OnboardingStep.allCases {
        await model.go(to: step)
        let hosting = try host(WelcomeGuideView(model: model, onClose: { closed += 1 }), size: NSSize(width: 720, height: 520),
                               name: "welcome-\(step.rawValue)")
        #expect(hosting.frame.width == 720)
    }
    #expect(closed == 0, "laying out never closes it")
    await model.go(to: .keys)
    model.close()
    #expect(progress.load().step == .keys && !progress.load().completed)
}
#endif
