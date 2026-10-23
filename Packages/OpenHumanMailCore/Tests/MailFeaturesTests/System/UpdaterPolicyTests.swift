import Foundation
import Testing
@testable import MailFeatures

private let policyFeed = "https://updates.example.test/appcast.xml"
private let policyKey = Data(count: 32).base64EncodedString()
private var configured: [String: Any] { [UpdaterPolicy.feedKey: policyFeed, UpdaterPolicy.publicKeyKey: policyKey] }

private func decide(_ info: [String: Any] = configured, environment: [String: String] = [:], developer: Bool = false,
                    signed: Bool = true) -> UpdaterPolicy.Decision {
    UpdaterPolicy.decide(info: info, environment: environment, isDeveloperBuild: developer, isDeveloperIDSigned: { signed })
}

@Suite struct UpdaterPolicyTests {
    @Test func onlyASignedReleaseWithAWholeConfigurationStartsTheUpdater() throws {
        let feed = try #require(URL(string: policyFeed))
        #expect(decide() == .start(UpdaterConfiguration(feed: feed, publicKey: policyKey)))
        #expect(decide(environment: ["XCTestConfigurationFilePath": "x"]) == .unavailable(.testRun))
        #expect(decide(developer: true) == .unavailable(.developerBuild))
        #expect(decide(signed: false) == .unavailable(.notDeveloperIDSigned))
    }

    @Test func emptyOrPartialSettingsNeverStartIt() {
        #expect(decide([:]) == .unavailable(.notConfigured))
        #expect(decide([UpdaterPolicy.feedKey: "", UpdaterPolicy.publicKeyKey: " "]) == .unavailable(.notConfigured),
                "the empty values every build but an updating one carries")
        #expect(decide([UpdaterPolicy.feedKey: policyFeed]) == .unavailable(.incompleteConfiguration))
        #expect(decide([UpdaterPolicy.publicKeyKey: policyKey]) == .unavailable(.incompleteConfiguration))
        for key in ["not base64", Data(count: 16).base64EncodedString(), Data(count: 33).base64EncodedString()] {
            #expect(decide([UpdaterPolicy.feedKey: policyFeed, UpdaterPolicy.publicKeyKey: key])
                    == .unavailable(.incompleteConfiguration), "\(key)")
        }
        #expect(decide([UpdaterPolicy.feedKey: 42, UpdaterPolicy.publicKeyKey: policyKey]) == .unavailable(.incompleteConfiguration))
    }

    @Test func theSignatureIsReadOnlyForAReleaseWithAWholeConfiguration() {
        var reads = 0
        let read: () -> Bool = { reads += 1; return true }
        _ = UpdaterPolicy.decide(info: configured, environment: ["XCTestConfigurationFilePath": "x"], isDeveloperBuild: false,
                                 isDeveloperIDSigned: read)
        _ = UpdaterPolicy.decide(info: configured, environment: [:], isDeveloperBuild: true, isDeveloperIDSigned: read)
        _ = UpdaterPolicy.decide(info: [:], environment: [:], isDeveloperBuild: false, isDeveloperIDSigned: read)
        #expect(reads == 0)
        _ = UpdaterPolicy.decide(info: configured, environment: [:], isDeveloperBuild: false, isDeveloperIDSigned: read)
        #expect(reads == 1)
    }

    @Test func feedsAreHTTPSOrThisMacsLoopbackForAStagedTest() throws {
        for accepted in [policyFeed, "https://updates.example.test:8443/mail/appcast.xml", "http://127.0.0.1:8000/appcast.xml",
                         "http://localhost:8000/appcast.xml"] {
            #expect(UpdaterPolicy.isAcceptedFeed(try #require(URL(string: accepted))), "\(accepted)")
        }
        for refused in ["http://updates.example.test/appcast.xml", "file:///tmp/appcast.xml", "ftp://updates.example.test/a",
                        "https://user:secret@updates.example.test/appcast.xml", "appcast.xml", "https:///appcast.xml"] {
            let url = URL(string: refused)
            #expect(url.map(UpdaterPolicy.isAcceptedFeed) != true, "\(refused)")
        }
    }

    @Test func everyReasonIsSaidPlainlyAndDiffers() {
        let explanations = UpdatesUnavailableReason.allCases.map(\.explanation)
        #expect(Set(explanations).count == UpdatesUnavailableReason.allCases.count)
        #expect(explanations.allSatisfy { $0.hasSuffix(".") && !$0.contains("Sparkle") })
        #expect(UpdaterPolicy.unavailableTitle == "Updates not available in this build")
    }
}
