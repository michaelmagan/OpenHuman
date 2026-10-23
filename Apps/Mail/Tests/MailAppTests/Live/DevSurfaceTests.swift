import Foundation
import MailFakes
import MailFeatures
import MailModel
import MailUI
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

@MainActor
struct DevSurfaceTests {
    private static let appFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func fakeGmailKeepsSyntheticMailOffTheRealPlatform() {
        func notifier(_ platform: SystemPlatform) -> ObjectIdentifier? {
            (platform.notifier as? FakeSystemNotifier).map(ObjectIdentifier.init)
        }
        func spotlight(_ platform: SystemPlatform) -> ObjectIdentifier? {
            (platform.spotlight as? FakeSpotlightIndex).map(ObjectIdentifier.init)
        }
        let real = SystemPlatform.inert()
        let fake = CompositionRoot.syntheticMailOnly(real, notifications: false)
        #expect(notifier(fake) != nil && notifier(fake) != notifier(real), "no real notification, no permission prompt")
        #expect(ObjectIdentifier(fake.dock) != ObjectIdentifier(real.dock), "no real Dock badge")
        #expect(spotlight(fake) != nil && spotlight(fake) != spotlight(real), "no Spotlight items for synthetic threads")
        #expect(ObjectIdentifier(fake.menuBarItem) == ObjectIdentifier(real.menuBarItem)
            && ObjectIdentifier(fake.hotkeys) == ObjectIdentifier(real.hotkeys), "the rest stays the Mac's")
        let notifying = CompositionRoot.syntheticMailOnly(real, notifications: true)
        #expect(notifier(notifying) == notifier(real))
        #expect(ObjectIdentifier(notifying.dock) != ObjectIdentifier(real.dock) && spotlight(notifying) != spotlight(real))
        let none = CompositionRoot.fakeGmailPlatform(arguments: ["-UseFakeGmail", CompositionRoot.fakeGmailNotificationsArgument],
                                                     environment: [:]) == nil
        #expect(none)
    }

    @Test func aTestHomeGetsAKeychainServiceOfItsOwn() {
        let real = URL(fileURLWithPath: "/tmp/oh-real", isDirectory: true)
        #expect(CompositionRoot.keychainService(environment: [:], directory: real) == OHIdentifiers.keychainService)
        #expect(CompositionRoot.keychainService(environment: ["OPENHUMAN_HOME": ""], directory: real)
            == OHIdentifiers.keychainService)
        let a = URL(fileURLWithPath: "/tmp/oh-home-a", isDirectory: true)
        let b = URL(fileURLWithPath: "/tmp/oh-home-b", isDirectory: true)
        let serviceA = CompositionRoot.keychainService(environment: ["OPENHUMAN_HOME": a.path], directory: a)
        #expect(serviceA.hasPrefix(OHIdentifiers.keychainService + ".home.") && serviceA.count == OHIdentifiers.keychainService.count + 22)
        #expect(serviceA == CompositionRoot.keychainService(environment: ["OPENHUMAN_HOME": a.path], directory: a),
                "the same folder finds its token again")
        #expect(serviceA != CompositionRoot.keychainService(environment: ["OPENHUMAN_HOME": b.path], directory: b))
        #expect(CompositionRoot.stableID("") == "cbf29ce484222325", "FNV-1a's offset basis: stable across launches")
    }

    @Test func aDebugStoreRebuildIsAnnouncedOnceBeforeAnythingIsErased() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-rebuild-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation(directory: directory)
        let marker = CompositionRoot.storeRebuildMarker(location)
        #expect(!CompositionRoot.showsStoreRebuildNotice(location, wouldErase: { _ in false }))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(CompositionRoot.showsStoreRebuildNotice(location, wouldErase: { _ in true }))
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(!CompositionRoot.showsStoreRebuildNotice(location, wouldErase: { _ in true }), "once")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(CompositionRoot.showsStoreRebuildNotice(location, wouldErase: { _ in true }))
        #expect(!CompositionRoot.showsStoreRebuildNotice(location, wouldErase: { _ in false }))
        #expect(CompositionRoot.showsStoreRebuildNotice(location, wouldErase: { _ in true }))
        let message = CompositionRoot.storeRebuildMessage
        #expect(message.contains("pre-erase") && message.contains("Your Gmail is unchanged") && message.contains("Quit Mail"))
    }

    @Test func aStoreThatOpensAsItIsShowsNoRebuildNotice() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-rebuild-real-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation(directory: directory)
        #expect(!CompositionRoot.showsStoreRebuildNotice(location), "no file yet")
        let store = try MailStore.open(StoreOptions(location: location, processKind: .test, appVersion: "0.0.0-test",
                                                    changeNotificationName: "dev.openhuman.tests.devsurface.\(UUID().uuidString)"))
        try store.close()
        #expect(!CompositionRoot.showsStoreRebuildNotice(location), "a file this build wrote")
        #expect(!FileManager.default.fileExists(atPath: CompositionRoot.storeRebuildMarker(location).path))
    }

    @Test func aBusyStoreExplainsHowToContinue() {
        let problem = CompositionRoot.storeProblem(StoreError.busy)
        #expect(problem.title == "Another copy of OpenHuman Mail is using your mail")
        #expect(problem.message == "Quit the other copy, then open OpenHuman Mail again. Your Gmail is unchanged.")
        #expect(problem.details == nil)
    }

    @Test func noticesSayWhatToDoAndKeepOnlyACode() {
        #expect(CompositionRoot.storeNoticeTitle == "Mail couldn't open the mail on this Mac")
        let newer = CompositionRoot.storeProblem(StoreError.schemaTooNew(found: 2, supported: 1))
        #expect(newer.title == CompositionRoot.storeNoticeTitle && newer.details == nil)
        #expect(newer.message == "A newer version of Mail last used the mail on this Mac. Install the newest version of Mail.")
        let broken = CompositionRoot.storeProblem(StoreError.integrity("sqlite 11: /Users/someone/Library/x"))
        #expect(broken.message == "Quit and open Mail again. Your Gmail is unchanged.")
        #expect(broken.details == "integrity", "never the payload")
        #expect(CompositionRoot.syncStartMessage(GmailError.reauthRequired) == "Google needs you to sign in again.")
        #expect(CompositionRoot.syncStartMessage(GmailError.server(status: 503, message: "secret body"))
            == "Sign in again, or quit and open Mail again.")
        #expect(CompositionRoot.detailCode(GmailError.server(status: 503, message: "secret body")) == "server_503")
        struct SampleFailure: Error { let path = "/Users/someone/Library/x" }
        #expect(CompositionRoot.detailCode(SampleFailure()) == "SampleFailure", "the type's name, never its contents")
    }

    @Test func releaseBuildsLeaveTheTestChecklistOut() throws {
        let release = try String(contentsOf: Self.appFolder.appendingPathComponent("Config/Release.xcconfig"), encoding: .utf8)
        #expect(release.contains("EXCLUDED_SOURCE_FILE_NAMES = dev-test-checklist.json"))
        let debug = try String(contentsOf: Self.appFolder.appendingPathComponent("Config/Debug.xcconfig"), encoding: .utf8)
        #expect(!debug.contains("dev-test-checklist"), "Debug builds and the tests keep it")
        let app = try String(contentsOf: Self.appFolder.appendingPathComponent("Sources/MailApp.swift"), encoding: .utf8)
        let scene = try #require(app.range(of: "Window(\"Test checklist\""))
        #expect(app[scene.upperBound...].prefix(300).contains(".commandsRemoved()"))
    }
}
