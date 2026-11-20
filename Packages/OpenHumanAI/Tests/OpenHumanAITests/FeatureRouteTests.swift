import Foundation
import Testing

@testable import OpenHumanAI

@Suite struct FeatureRouteTests {
    static let system = ProviderSelectionTests.system
    static let claude = ProviderSelectionTests.claude
    static let local = ProviderCandidate(
        id: .local("small"), displayName: "Small", dataLocation: .onDevice, availability: .available, consented: true,
        autoSelectable: true)

    func route(_ feature: AIFeature, _ candidates: [ProviderCandidate], _ settings: AISettings = AISettings(),
               workload: AIWorkload = .interactive, account: String? = nil) -> FeatureRoute {
        FeatureRoute.explain(feature: feature, workload: workload, accountKeys: [account], candidates: candidates,
                             settings: settings)
    }

    @Test func everyFeatureHasAnExplicitDefaultOnThisMac() {
        for feature in AIFeature.allCases where feature != .classify {
            #expect(AIModelDefaults.pins[feature] == .appleSystem)
        }
        #expect(AIModelDefaults.pins[.classify] == .appleSystemClassifier)
        #expect(Set(AIModelDefaults.pins.keys) == Set(AIFeature.allCases))
    }

    @Test func readyGemmaModelsArePreferredForWritingAndExplicitChoicesWin() {
        var large = Self.local, small = Self.local
        large.id = .local(AIModelDefaults.gemmaE4BID)
        small.id = .local(AIModelDefaults.gemmaE2BID)
        for feature in [AIFeature.summarize, .replyOptions] {
            let choices = [Self.system, small, large]
            #expect(route(feature, choices).choice == large.id)
            var settings = AISettings()
            settings.featurePins[feature] = small.id
            #expect(route(feature, choices, settings).choice == small.id)
            var missing = large
            missing.availability = .unavailable(reason: .modelNotDownloaded(sizeBytes: 100))
            #expect(route(feature, [missing, small, Self.system]).choice == small.id)
            #expect(route(feature, [missing, Self.system]).choice == .appleSystem)
        }
        #expect(route(.rewrite, [small, large, Self.system]).choice == .appleSystem)
    }

    @Test func theDefaultIsUsedAndNamedAsTheDefault() {
        let chosen = route(.rewrite, [Self.claude, Self.local, Self.system])
        #expect(chosen.origin == .mailDefault && chosen.choice == .appleSystem && chosen.defaultModel == .appleSystem)
        #expect(chosen.selection.candidate?.id == .appleSystem)
    }

    @Test func anUnreadyDefaultFailsWithItsOwnReasonInsteadOfFallingBack() {
        var unready = Self.system
        unready.availability = .unavailable(reason: .appleIntelligenceNotEnabled)
        let chosen = route(.rewrite, [Self.claude, Self.local, unready])
        #expect(chosen.selection == .unavailable(.appleIntelligenceNotEnabled, providerID: .appleSystem))
        #expect(chosen.choice == .appleSystem && chosen.origin == .mailDefault)
    }

    @Test func yourChoiceWinsAndIsNamedAsYours() {
        var settings = AISettings()
        settings.featurePins[.summarize] = .local("small")
        let chosen = route(.summarize, [Self.system, Self.local], settings)
        #expect(chosen.origin == .yourChoice && chosen.choice == .local("small") && chosen.defaultModel == .appleSystem)
        #expect(chosen.selection.candidate?.id == .local("small"))
        #expect(route(.rewrite, [Self.system, Self.local], settings).origin == .mailDefault, "pins are per feature")
    }

    @Test func aPinnedModelOffThisMacStillObeysOnDeviceOnlyAccounts() {
        var settings = AISettings(onDeviceOnlyAccounts: ["work"])
        settings.featurePins[.rewrite] = .agentClaude
        #expect(route(.rewrite, [Self.system, Self.claude], settings, account: "work").selection
            == .unavailable(.onDeviceOnly, providerID: .agentClaude))
        #expect(route(.rewrite, [Self.system, Self.claude], settings, account: "home").selection.candidate?.id
            == .agentClaude)
    }

    @Test func aBuildWithoutApplesModelStandsInItsFirstOnDeviceModel() {
        let chosen = route(.askInbox, [Self.claude, Self.local])
        #expect(chosen.origin == .mailDefault && chosen.choice == .local("small"))
        let offOnly = route(.rewrite, [Self.claude])
        #expect(offOnly.origin == .firstReady && offOnly.defaultModel == nil)
    }

    @Test func withOnlyClaudeAndCodexTheFeaturesYouAskForUseClaudeAndOnDeviceOnesStayOff() {
        let candidates = [Self.claude, ProviderSelectionTests.codex]
        let summary = route(.summarize, candidates)
        #expect(summary.origin == .firstReady && summary.defaultModel == nil)
        #expect(summary.selection.candidate?.id == .agentClaude)
        #expect(route(.rewrite, candidates).selection.candidate?.id == .agentClaude)
        #expect(route(.followUp, candidates, workload: .background).selection
            == .unavailable(.onDeviceOnly, providerID: .agentClaude))
        #expect(route(.askInbox, candidates).selection == .unavailable(.onDeviceOnly, providerID: .agentClaude),
                "Ask needs a pin")
        var settings = AISettings()
        settings.featurePins[.askInbox] = .agentClaude
        #expect(route(.askInbox, candidates, settings).selection.candidate?.id == .agentClaude)
    }

    static let appleClassifier = ProviderCandidate(
        id: .appleSystemClassifier, displayName: "Apple classifier", kind: .classifier, dataLocation: .onDevice,
        availability: .available, consented: true, autoSelectable: true)
    static let downloadedClassifier = ProviderCandidate(
        id: "local.tiny.classifier", displayName: "Tiny model", kind: .classifier, dataLocation: .onDevice,
        availability: .available, consented: true, autoSelectable: true)

    @Test func triageUsesApplesModelByDefaultAndNeverTheDownloadedOneOnItsOwn() {
        let chosen = route(.classify, [Self.downloadedClassifier, Self.appleClassifier, Self.system], workload: .background)
        #expect(chosen.origin == .mailDefault && chosen.choice == .appleSystemClassifier)
        #expect(chosen.selection.candidate?.id == .appleSystemClassifier)
        var off = Self.appleClassifier
        off.availability = .unavailable(reason: .appleIntelligenceNotEnabled)
        let unready = route(.classify, [Self.downloadedClassifier, off, Self.system], workload: .background)
        #expect(unready.selection == .unavailable(.appleIntelligenceNotEnabled, providerID: .appleSystemClassifier),
                "no fallback to the downloaded model or a language model")
        #expect(unready.origin == .mailDefault)
    }

    @Test func triageUsesTheDownloadedModelOnlyWhenChosenAndSaysSoWhenItIsMissing() {
        let settings = AISettings(classifier: .localModel)
        let chosen = route(.classify, [Self.downloadedClassifier, Self.system], settings, workload: .background)
        #expect(chosen.origin == .yourChoice && chosen.selection.candidate?.id == "local.tiny.classifier")
        let missing = route(.classify, [Self.system], settings, workload: .background)
        #expect(missing.origin == .yourChoice && missing.choice == nil)
        #expect(missing.selection.candidate == nil, "never the language model instead")
    }

    @Test func triageAndAutoLabelsDefaultToApplesModelWithMailsRules() {
        #expect(AISettings().classifier == .appleModel && AISettings().selectedLocalModel == nil)
        #expect(AIModelDefaults.pins[.classify] == .appleSystemClassifier)
        let rules = ClassificationConfig.shipped.defaultRules
        #expect(!rules.isEmpty && rules.allSatisfy(\.enabled), "the rules layer is on by default")
    }

    @Test func choosingAClassifierRecordsWhichModel() {
        var settings = AISettings()
        settings.featurePins[.classify] = .appleSystemClassifier
        settings.useClassifier("local.tiny.classifier")
        #expect(settings.classifier == .localModel && settings.selectedLocalModel == "tiny")
        #expect(settings.featurePins[.classify] == nil)
        let chosen = route(.classify, [Self.downloadedClassifier, Self.appleClassifier], settings, workload: .background)
        #expect(chosen.origin == .yourChoice && chosen.selection.candidate?.id == "local.tiny.classifier")
        settings.useClassifier(.appleSystemClassifier)
        #expect(settings.classifier == .appleModel && settings.selectedLocalModel == nil)
    }

    @Test func localModelIDsReadBackFromProviderIDs() {
        #expect(AIProviderID("local.qwen3.5-9b-optiq-4bit.classifier").localModelID == "qwen3.5-9b-optiq-4bit")
        #expect(AIProviderID.local("small").localModelID == "small")
        #expect(AIProviderID.appleSystemClassifier.localModelID == nil)
        #expect(AIProviderID("local.").localModelID == nil)
    }

    @Test func retiringRemovesOnlyRetiredLocalModels() {
        var settings = AISettings()
        settings.useClassifier("local.old.classifier")
        settings.featurePins[.summarize] = .local("old")
        settings.featurePins[.rewrite] = .local("small")
        settings.providerOrder = [.local("old"), .local("small"), .appleSystem]
        let retired = settings.retiringLocalModels(["old"])
        #expect(retired.classifier == .appleModel && retired.selectedLocalModel == nil)
        #expect(retired.featurePins == [.rewrite: .local("small")])
        #expect(retired.providerOrder == [.local("small"), .appleSystem])
        #expect(settings.retiringLocalModels(["other"]) == settings)
    }

    @Test func theFeatureSwitchComesBeforeTheModel() {
        let chosen = route(.summarize, [Self.system], AISettings(enabled: false))
        #expect(chosen.selection == .unavailable(.disabledBySettings, providerID: nil) && chosen.choice == .appleSystem)
    }

    @Test func selectAndExplainAlwaysAgree() {
        var settings = AISettings(onDeviceOnlyAccounts: ["work"])
        settings.featurePins[.askInbox] = .agentClaude
        for feature in AIFeature.allCases {
            for account in [nil, "work", "home"] {
                let candidates = [Self.claude, Self.local, Self.system]
                #expect(ProviderSelectionPolicy.select(feature: feature, workload: .interactive, accountKeys: [account],
                                                       candidates: candidates, settings: settings)
                    == route(feature, candidates, settings, account: account).selection)
            }
        }
    }
}
