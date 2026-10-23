import Foundation

// Why: developer variables are read only here, and only in Debug and dev-tools builds; a release build never sees them
enum BuildFlavor {
    static var name: String {
        #if DEBUG
        "Debug"
        #elseif OH_DEV_TOOLS
        "DevTools"
        #else
        "Release"
        #endif
    }

    static var hasDevTools: Bool {
        #if OH_DEV_TOOLS
        true
        #else
        false
        #endif
    }

    static func home(_ environment: [String: String]) -> String? {
        #if DEBUG || OH_DEV_TOOLS
        nonEmpty(environment["OPENHUMAN_HOME"])
        #else
        nil
        #endif
    }

    static func isDevelopmentLaunch(arguments: [String], environment: [String: String]) -> Bool {
        #if DEBUG || OH_DEV_TOOLS
        home(environment) != nil || arguments.contains {
            ["-UseFakeData", "-UseFixtureStore", "-UseFakeGmail", "-UseFakeCalendar"].contains($0)
        }
        #else
        false
        #endif
    }

    static func oauthClientFile(_ environment: [String: String]) -> String? {
        #if DEBUG || OH_DEV_TOOLS
        nonEmpty(environment["OPENHUMAN_OAUTH_CLIENT_JSON"])
        #else
        nil
        #endif
    }

    static func storePollOnly(_ environment: [String: String]) -> Bool {
        #if DEBUG || OH_DEV_TOOLS
        environment["OPENHUMAN_STORE_POLL_ONLY"] == "1"
        #else
        false
        #endif
    }

    static func feedbackDirectory(_ environment: [String: String]) -> String? {
        #if OH_DEV_TOOLS
        nonEmpty(environment["OPENHUMAN_FEEDBACK_DIR"])
        #else
        nil
        #endif
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
