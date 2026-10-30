import Foundation
import MailFeatures
import Observation
import Security
#if !OH_DEV_TOOLS
import Sparkle
#endif

#if OH_DEV_TOOLS
// Why: Debug and DevTools builds compile the updater out and name nothing in Sparkle, so the Debug link leaves Sparkle
// out of the app (project.yml) and a test host never loads it. Nothing can make one
@MainActor
final class SparkleUpdater: SoftwareUpdater {
    private init() {}

    var automaticallyChecksForUpdates = false
    var lastUpdateCheckDate: Date? { nil }
    func checkForUpdates() {}
}
#else
@MainActor @Observable
final class SparkleUpdater: SoftwareUpdater {
    private let controller: SPUStandardUpdaterController
    // Why: Sparkle holds its delegate weakly, so the updater keeps it
    private let cycles: UpdateCycleObserver

    private init() {
        let cycles = UpdateCycleObserver()
        self.cycles = cycles
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: cycles, userDriverDelegate: nil)
        cycles.finished = { [weak self] in self?.withMutation(keyPath: \.lastUpdateCheckDate) {} }
    }

    // Why: Sparkle keeps this setting itself; the Settings switch reads and writes it through here so it redraws
    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    // Why: Sparkle sets the date itself; the end of each update cycle tells Settings to read it again
    var lastUpdateCheckDate: Date? {
        access(keyPath: \.lastUpdateCheckDate)
        return controller.updater.lastUpdateCheckDate
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
private final class UpdateCycleObserver: NSObject, SPUUpdaterDelegate {
    var finished: (@MainActor () -> Void)?

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        finished?()
    }
}
#endif

@MainActor
extension SparkleUpdater {
    // Why: the only way to make one. Debug and DevTools builds compile it out, and a release build also needs its own
    // Developer ID signature, which no caller can stand in for
    static func startIfAllowed(environment: [String: String],
                               info: [String: Any]) -> (updater: SparkleUpdater?, unavailable: UpdatesUnavailableReason?) {
        #if OH_DEV_TOOLS
        return (nil, environment["XCTestConfigurationFilePath"] == nil ? .developerBuild : .testRun)
        #else
        switch UpdaterPolicy.decide(info: info, environment: environment, isDeveloperBuild: false,
                                    isDeveloperIDSigned: CodeSignature.isDeveloperIDSigned) {
        case .start: return (SparkleUpdater(), nil)
        case .unavailable(let reason): return (nil, reason)
        }
        #endif
    }
}

enum CodeSignature {
    // Why: Apple's anchor, the Developer ID intermediate and a Developer ID Application leaf. Ad hoc, Apple Development
    // and unsigned copies fail it, so only a Developer ID build can start the updater
    static let developerIDRequirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    static func isDeveloperIDSigned() -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(developerIDRequirement as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }
}
