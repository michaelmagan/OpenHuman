import Foundation

/// Native features newer than the deployment target, and native looks that can be turned off to compare them with the
/// earlier ones. Code that uses an OS feature checks the flag and `#available` together, and draws the documented
/// fallback otherwise:
///
///     if NativeFeatures.current.splitPickerTabs, #available(macOS 27, *) { … } else { … }
///
/// An override (tests, renders, or the `-NativeFeatures 26` and `-NativeListSelection tint` launch arguments) can only
/// turn features off, so the fallbacks can be checked on a newer system.
public struct NativeFeatures: Sendable, Hashable, CustomStringConvertible {
    /// The split picker uses the tabs role; the fallback is a segmented picker.
    public var splitPickerTabs: Bool
    /// Menu items show symbols; the fallback is text only.
    public var menuItemImages: Bool
    /// Selected rows use the system selection: the accent colour with white text while the window is key. The
    /// fallback is the translucent accent plate (`NativeMetrics.List.selectedAlpha`) with the row's own text colours.
    public var systemListSelection: Bool

    public init(splitPickerTabs: Bool, menuItemImages: Bool, systemListSelection: Bool = true) {
        self.splitPickerTabs = splitPickerTabs
        self.menuItemImages = menuItemImages
        self.systemListSelection = systemListSelection
    }

    public static let macOS26 = NativeFeatures(splitPickerTabs: false, menuItemImages: false)
    public static let macOS27 = NativeFeatures(splitPickerTabs: true, menuItemImages: true)

    public static var system: NativeFeatures {
        if #available(macOS 27, iOS 27, *) { .macOS27 } else { .macOS26 }
    }

    /// These features with the selection set to the translucent plate.
    public var withTintedListSelection: NativeFeatures {
        var features = self
        features.systemListSelection = false
        return features
    }

    public static let launchArgument = "NativeFeatures"
    public static let listSelectionArgument = "NativeListSelection"

    public static func named(_ name: String?) -> NativeFeatures? {
        switch name?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "26", "macos26": .macOS26
        case "27", "macos27": .macOS27
        default: nil
        }
    }

    /// `system` (or a true value) keeps the system list selection; `tint` (or a false value) turns it off.
    public static func listSelection(named name: String?) -> Bool? {
        switch name?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "system", "yes", "true", "1": true
        case "tint", "no", "false", "0": false
        default: nil
        }
    }

    /// The features the launch arguments ask for, or nil when they ask for nothing.
    public static func launchOverride(features: String?, listSelection: String?) -> NativeFeatures? {
        let requested = named(features)
        guard Self.listSelection(named: listSelection) == false else { return requested }
        return (requested ?? system).withTintedListSelection
    }

    public func limited(to available: NativeFeatures) -> NativeFeatures {
        NativeFeatures(splitPickerTabs: splitPickerTabs && available.splitPickerTabs,
                       menuItemImages: menuItemImages && available.menuItemImages,
                       systemListSelection: systemListSelection && available.systemListSelection)
    }

    @MainActor public static var override: NativeFeatures?

    private static let launched = launchOverride(features: UserDefaults.standard.string(forKey: launchArgument),
                                                 listSelection: UserDefaults.standard.string(forKey: listSelectionArgument))

    @MainActor public static var current: NativeFeatures {
        guard let requested = override ?? launched else { return system }
        return requested.limited(to: system)
    }

    @MainActor public static func withOverride<T>(_ features: NativeFeatures, _ body: () throws -> T) rethrows -> T {
        let previous = override
        override = features
        defer { override = previous }
        return try body()
    }

    @MainActor public static func withOverride<T>(_ features: NativeFeatures, _ body: @MainActor () async throws -> T) async rethrows -> T {
        let previous = override
        override = features
        defer { override = previous }
        return try await body()
    }

    public var description: String {
        switch self {
        case .macOS26: "macOS 26"
        case .macOS27: "macOS 27"
        default: "splitPickerTabs=\(splitPickerTabs) menuItemImages=\(menuItemImages) systemListSelection=\(systemListSelection)"
        }
    }
}
