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

    static let feed = "https://raw.githubusercontent.com/michaelmagan/OpenHuman/main/appcast.xml"
    static let key = Data(count: 32).base64EncodedString()

    @Test func aTestRunOrADeveloperBuildNeverStartsSparkle() {
        let info: [String: Any] = [SparkleUpdater.feedKey: Self.feed, SparkleUpdater.publicKeyKey: Self.key]
        #expect(SparkleUpdater.isConfigured(info))
        #expect(UpdateCheckSupport.updater(environment: ["XCTestConfigurationFilePath": "x"], info: info, developerBuild: false) == nil)
        #expect(UpdateCheckSupport.updater(environment: [:], info: info, developerBuild: true) == nil)
        #expect(UpdateCheckSupport.updater(environment: [:], info: [:], developerBuild: false) == nil, "no feed and key, no Sparkle")
        #expect(MailApp.updates.updater == nil, "the app's own center keeps the test-safe GitHub check under tests")
    }

    @Test func sparkleNeedsAnHTTPSFeedAndAnEdDSAPublicKey() {
        func configured(_ feed: String?, _ key: String?) -> Bool {
            var info: [String: Any] = [:]
            info[SparkleUpdater.feedKey] = feed
            info[SparkleUpdater.publicKeyKey] = key
            return SparkleUpdater.isConfigured(info)
        }
        #expect(configured(Self.feed, Self.key))
        #expect(!configured(Self.feed, ""), "the key the project ships before the one-time key setup")
        #expect(!configured(Self.feed, nil) && !configured(nil, Self.key) && !configured("", Self.key))
        #expect(!configured("http://example.com/appcast.xml", Self.key) && !configured("appcast.xml", Self.key))
        #expect(!configured(Self.feed, "not base64") && !configured(Self.feed, Data(count: 16).base64EncodedString()))
    }

    @Test func theAppReadsTheAppcastOnMain() {
        #expect(Bundle.main.object(forInfoDictionaryKey: SparkleUpdater.feedKey) as? String == Self.feed)
        #expect(Bundle.main.object(forInfoDictionaryKey: SparkleUpdater.publicKeyKey) is String)
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
