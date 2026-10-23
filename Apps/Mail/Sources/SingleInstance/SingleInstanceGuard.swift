import Foundation

struct RunningInstance: Equatable, Sendable {
    var pid: Int32
    var bundleURL: URL?
    var version: String?
    var build: String?
    var isTerminated: Bool
}

enum SingleInstanceDecision: Equatable {
    case launch
    case switchToOpenCopy(RunningInstance)
    case askUser(RunningInstance)
}

enum SingleInstanceChoice { case switchToOpenCopy, quitOtherAndContinue }
enum SingleInstanceOutcome: Equatable { case continueLaunch, quitThisCopy }

@MainActor
protocol InstanceHost {
    func runningInstances() -> [RunningInstance]
    func activate(_ instance: RunningInstance) -> Bool
    func requestTermination(of instance: RunningInstance) -> Bool
    func isStillRunning(_ instance: RunningInstance) -> Bool
    func chooseAction(for other: RunningInstance) -> SingleInstanceChoice
    func pause(_ seconds: TimeInterval)
}

enum SingleInstanceGuard {
    static let alertTitle = "OpenHuman Mail is already open"
    static let switchButtonTitle = "Switch to the Open Copy"
    static let quitOtherButtonTitle = "Quit the Other Copy and Continue"

    static func isExempt(bundleIdentifier: String?, arguments: [String], environment: [String: String],
                         developerBuild: Bool = BuildFlavor.hasDevTools) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return true }
        return developerBuild || environment["XCTestConfigurationFilePath"] != nil
            || BuildFlavor.isDevelopmentLaunch(arguments: arguments, environment: environment)
    }

    static func decide(own: RunningInstance, others: [RunningInstance]) -> SingleInstanceDecision {
        guard let other = others.filter({ $0.pid != own.pid && !$0.isTerminated }).min(by: { $0.pid < $1.pid }) else {
            return .launch
        }
        if let otherURL = other.bundleURL, let ownURL = own.bundleURL,
           let version = other.version, let build = other.build,
           version == own.version, build == own.build,
           otherURL.standardizedFileURL.path == ownURL.standardizedFileURL.path,
           !isOnDiskImage(otherURL), !isOnDiskImage(ownURL) {
            return .switchToOpenCopy(other)
        }
        return .askUser(other)
    }

    static func isOnDiskImage(_ url: URL?) -> Bool {
        url?.standardizedFileURL.path.hasPrefix("/Volumes/") ?? false
    }

    static func informativeText(for other: RunningInstance) -> String {
        var text: String
        if let version = other.version {
            text = "Version \(version)"
            if let build = other.build { text += " (\(build))" }
            text += " is running"
        } else {
            text = "Another version of OpenHuman Mail is running"
        }
        if let url = other.bundleURL?.standardizedFileURL {
            text += " from \"\(url.lastPathComponent)\""
            let folder = url.deletingLastPathComponent().lastPathComponent
            if isOnDiskImage(url) {
                text += " on a disk image"
            } else if folder == "Applications" {
                text += " in Applications"
            } else {
                text += " in the folder \"\(folder)\""
            }
        }
        return text + ". Two copies cannot use the same mail at once."
    }

    @MainActor
    static func run(own: RunningInstance, host: any InstanceHost, terminationWait: TimeInterval = 5,
                    pollInterval: TimeInterval = 0.1) -> SingleInstanceOutcome {
        let other: RunningInstance
        switch decide(own: own, others: host.runningInstances()) {
        case .launch:
            return .continueLaunch
        case .switchToOpenCopy(let instance):
            _ = host.activate(instance)
            return .quitThisCopy
        case .askUser(let instance):
            other = instance
        }
        switch host.chooseAction(for: other) {
        case .switchToOpenCopy:
            _ = host.activate(other)
            return .quitThisCopy
        case .quitOtherAndContinue:
            if host.requestTermination(of: other) {
                var elapsed: TimeInterval = 0
                while host.isStillRunning(other) {
                    guard elapsed < terminationWait, pollInterval > 0 else {
                        _ = host.activate(other)
                        return .quitThisCopy
                    }
                    let interval = min(pollInterval, terminationWait - elapsed)
                    host.pause(interval)
                    elapsed += interval
                }
                return .continueLaunch
            }
            _ = host.activate(other)
            return .quitThisCopy
        }
    }
}
