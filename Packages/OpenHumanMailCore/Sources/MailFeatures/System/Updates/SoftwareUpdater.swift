import Foundation

// Why: the app links Sparkle and hands it in, so this package names only what the menu and Settings ask of it
@MainActor
public protocol SoftwareUpdater: AnyObject, Sendable {
    var automaticallyChecksForUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    func checkForUpdates()
}

public enum UpdatesUnavailableReason: Sendable, Equatable, CaseIterable {
    case testRun
    case developerBuild
    case notConfigured
    case incompleteConfiguration
    case notDeveloperIDSigned

    public var explanation: String {
        switch self {
        case .testRun:
            "Updates stay off while tests run."
        case .developerBuild:
            "Debug and DevTools builds never install updates. Check for updates still shows the newest release."
        case .notConfigured:
            "This build was made without an update feed, so a new version is installed by hand."
        case .incompleteConfiguration:
            "This build's update feed or signing key is missing or malformed, so it never installs updates."
        case .notDeveloperIDSigned:
            "This build isn't signed with a Developer ID, so it can't prove an update comes from the same developer."
        }
    }
}

public struct UpdaterConfiguration: Sendable, Equatable {
    public let feed: URL
    public let publicKey: String
}

// Why: every rule alone keeps the updater off, so a build that isn't the signed release flavour never checks
public enum UpdaterPolicy {
    public enum Decision: Sendable, Equatable {
        case start(UpdaterConfiguration)
        case unavailable(UpdatesUnavailableReason)
    }

    public static let feedKey = "SUFeedURL"
    public static let publicKeyKey = "SUPublicEDKey"
    public static let unavailableTitle = "Updates not available in this build"

    // Why: the signature is read last, and only for a build that carries a whole configuration
    public static func decide(info: [String: Any], environment: [String: String], isDeveloperBuild: Bool,
                              isDeveloperIDSigned: () -> Bool) -> Decision {
        if environment["XCTestConfigurationFilePath"] != nil { return .unavailable(.testRun) }
        if isDeveloperBuild { return .unavailable(.developerBuild) }
        let feedText = value(info[feedKey]), keyText = value(info[publicKeyKey])
        if feedText == nil && keyText == nil { return .unavailable(.notConfigured) }
        guard let feedText, let feed = URL(string: feedText), isAcceptedFeed(feed),
              let keyText, isPublicKey(keyText) else { return .unavailable(.incompleteConfiguration) }
        guard isDeveloperIDSigned() else { return .unavailable(.notDeveloperIDSigned) }
        return .start(UpdaterConfiguration(feed: feed, publicKey: keyText))
    }

    // Why: HTTPS for every published feed; plain HTTP only from this Mac's loopback, for the staged two-build test
    public static func isAcceptedFeed(_ url: URL) -> Bool {
        guard let host = url.host(), !host.isEmpty, url.user == nil, url.password == nil else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return host == "127.0.0.1" || host == "localhost"
        default: return false
        }
    }

    // Why: Sparkle's EdDSA public key is 32 bytes; anything else can never verify an update
    public static func isPublicKey(_ text: String) -> Bool {
        Data(base64Encoded: text)?.count == 32
    }

    private static func value(_ raw: Any?) -> String? {
        let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
