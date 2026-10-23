import AppKit
import MailFakes
import MailFeatures
import Testing
@testable import OpenHumanMail

@MainActor
@Suite(.serialized)
struct UpdateCheckAppTests {
    static let label = BuildLabel(version: "0.1.0", build: "1001", channel: BuildLabel.earlyDevelopmentChannel)

    @Test func aTestRunNeverAsksGitHub() async {
        let center = UpdateCheckSupport.makeCenter(environment: ["XCTestConfigurationFilePath": "x"], label: Self.label)
        #expect(center.feed == .openHuman && center.phase == .idle)
        await center.check()
        #expect(center.result == .couldNotCheck(.unavailable))
        await MailApp.updates.check()
        #expect(MailApp.updates.result == .couldNotCheck(.unavailable), "the app's own check is the test-safe one under tests")
        #expect(MailApp.updates.feed == .openHuman && !MailApp.updates.isPresented)
    }

    static let feed = "https://updates.example.test/appcast.xml"
    static let key = Data(count: 32).base64EncodedString()

    @Test func noTestRunOrDeveloperBuildEverStartsSparkle() {
        let info: [String: Any] = [UpdaterPolicy.feedKey: Self.feed, UpdaterPolicy.publicKeyKey: Self.key]
        let underTest = SparkleUpdater.startIfAllowed(environment: ["XCTestConfigurationFilePath": "x"], info: info)
        #expect(underTest.updater == nil && underTest.unavailable == .testRun)
        let launched = SparkleUpdater.startIfAllowed(environment: [:], info: info)
        #expect(launched.updater == nil && launched.unavailable == .developerBuild, "Debug and DevTools never start the updater")
        let center = UpdateCheckSupport.makeCenter(environment: ["XCTestConfigurationFilePath": "x"], label: Self.label, info: info)
        #expect(center.updater == nil && center.updatesUnavailable == .testRun)
        #expect(MailApp.updates.updater == nil && MailApp.updates.updatesUnavailable == .testRun,
                "the app's own center keeps the test-safe GitHub check under tests")
    }

    @Test func thisBuildCarriesNoFeedAndNoDeveloperIDSignature() {
        #expect((Bundle.main.object(forInfoDictionaryKey: UpdaterPolicy.feedKey) as? String ?? "").isEmpty)
        #expect((Bundle.main.object(forInfoDictionaryKey: UpdaterPolicy.publicKeyKey) as? String ?? "").isEmpty)
        #expect(!CodeSignature.isDeveloperIDSigned(), "a test build is signed ad hoc or for development")
        #expect(UpdaterPolicy.decide(info: Bundle.main.infoDictionary ?? [:], environment: [:], isDeveloperBuild: false,
                                     isDeveloperIDSigned: CodeSignature.isDeveloperIDSigned) == .unavailable(.notConfigured))
    }

    @Test func theAppMenuOffersCheckForUpdatesUnderAbout() throws {
        let appMenu = try #require(NSApp.mainMenu?.items.first?.submenu)
        let titles = appMenu.items.map(\.title)
        let about = try #require(titles.firstIndex(of: "About OpenHuman Mail"), "\(titles)")
        let check = try #require(titles.firstIndex(of: UpdateCheckCenter.menuTitle), "\(titles)")
        #expect(check > about && check <= about + 2, "\(titles)")
        #expect(appMenu.items[check].keyEquivalent.isEmpty)
    }

    @Test func installingPutsTheCheckWhereSettingsAndThePaletteFindIt() {
        let environment = AppEnvironment.fake(corpus: FakeCorpus.make(threadCount: 4))
        #expect(environment.system.updates == nil)
        let center = UpdateCheckSupport.makeCenter(environment: ["XCTestConfigurationFilePath": "x"], label: Self.label)
        UpdateCheckSupport.install(in: environment, center: center)
        #expect(environment.system.updates === center)
    }
}
