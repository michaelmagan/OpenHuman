import Foundation
import Synchronization

public struct ThemePreferences: Sendable, Hashable, Codable {
    public var mode: AppearanceMode
    public var lightThemeID: String
    public var darkThemeID: String
    public var accentID: String?
    public var density: ThemeDensity
    public var readerTextSize: Double?
    public var uiFont: FontFamily?
    public var readerFont: FontFamily?
    public var emailColors: EmailColors?
    public private(set) var version: Int

    public static let currentVersion = 1
    public static let defaultReaderTextSize: Double = 14
    public static let readerTextSizeRange: ClosedRange<Double> = 12...20

    public init(mode: AppearanceMode = .system, lightThemeID: String = BuiltinThemeID.systemLight,
                darkThemeID: String = BuiltinThemeID.systemDark, accentID: String? = nil, density: ThemeDensity = .default,
                readerTextSize: Double? = nil, uiFont: FontFamily? = nil,
                readerFont: FontFamily? = nil, emailColors: EmailColors? = nil) {
        self.mode = mode
        self.lightThemeID = lightThemeID
        self.darkThemeID = darkThemeID
        self.accentID = accentID
        self.density = density
        self.readerTextSize = readerTextSize
        self.uiFont = uiFont
        self.readerFont = readerFont
        self.emailColors = emailColors
        self.version = Self.currentVersion
    }

    public func themeID(for appearance: ThemeAppearance) -> String {
        appearance == .dark ? darkThemeID : lightThemeID
    }

    public var clampedReaderTextSize: Double? {
        readerTextSize.map { min(max($0.rounded(), Self.readerTextSizeRange.lowerBound), Self.readerTextSizeRange.upperBound) }
    }

    public static func readerLineHeight(for size: Double) -> Double { (size * 1.57).rounded() }

    /// Brings preferences saved by an older version up to date. Version 1 moves the built-in Light and Dark themes to
    /// System Light and System Dark; Paper, Midnight and custom themes are kept. Runs once: the result carries the
    /// current version, so a later choice of Light or Dark is respected.
    public func migrated() -> ThemePreferences {
        var next = self
        if version < 1 {
            if next.lightThemeID == BuiltinThemeID.light { next.lightThemeID = BuiltinThemeID.systemLight }
            if next.darkThemeID == BuiltinThemeID.dark { next.darkThemeID = BuiltinThemeID.systemDark }
        }
        next.version = max(version, Self.currentVersion)
        return next
    }

    private enum CodingKeys: String, CodingKey {
        case mode, lightThemeID, darkThemeID, accentID, density, readerTextSize, uiFont, readerFont, emailColors, version
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ThemePreferences()
        mode = (try? c.decode(AppearanceMode.self, forKey: .mode)) ?? defaults.mode
        lightThemeID = (try? c.decode(String.self, forKey: .lightThemeID)).flatMap { ThemeFile.isValidID($0) ? $0 : nil } ?? defaults.lightThemeID
        darkThemeID = (try? c.decode(String.self, forKey: .darkThemeID)).flatMap { ThemeFile.isValidID($0) ? $0 : nil } ?? defaults.darkThemeID
        accentID = (try? c.decode(String.self, forKey: .accentID)).flatMap { ThemeFile.isValidAccentShortID($0) ? $0 : nil }
        density = (try? c.decode(ThemeDensity.self, forKey: .density)) ?? defaults.density
        readerTextSize = (try? c.decode(Double.self, forKey: .readerTextSize)).flatMap { $0.isFinite ? $0 : nil }
        uiFont = (try? c.decode(String.self, forKey: .uiFont)).flatMap(FontFamily.init(token:))
        readerFont = (try? c.decode(String.self, forKey: .readerFont)).flatMap(FontFamily.init(token:))
        emailColors = try? c.decode(EmailColors.self, forKey: .emailColors)
        version = (try? c.decode(Int.self, forKey: .version)).map { max(0, $0) } ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(lightThemeID, forKey: .lightThemeID)
        try c.encode(darkThemeID, forKey: .darkThemeID)
        try c.encodeIfPresent(accentID, forKey: .accentID)
        try c.encode(density, forKey: .density)
        try c.encodeIfPresent(readerTextSize, forKey: .readerTextSize)
        try c.encodeIfPresent(uiFont?.token, forKey: .uiFont)
        try c.encodeIfPresent(readerFont?.token, forKey: .readerFont)
        try c.encodeIfPresent(emailColors, forKey: .emailColors)
        try c.encode(version, forKey: .version)
    }
}

public enum BuiltinThemeID {
    public static let base = "openhuman.base"
    public static let light = "openhuman.light"
    public static let dark = "openhuman.dark"
    public static let paper = "openhuman.paper"
    public static let midnight = "openhuman.midnight"
    public static let systemLight = "openhuman.system.light"
    public static let systemDark = "openhuman.system.dark"
    public static let defaultAccent = "periwinkle"
    public static let accents = ["periwinkle", "blue", "iris", "pine", "graphite", "system"]
}

public protocol ThemePreferencesStoring: Sendable {
    func load() -> ThemePreferences?
    func save(_ preferences: ThemePreferences)
}

public struct UserDefaultsThemePreferencesStore: ThemePreferencesStoring {
    public static let key = "dev.openhuman.mail.theme.preferences"
    let suiteName: String?

    public init(suiteName: String? = nil) { self.suiteName = suiteName }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> ThemePreferences? {
        guard let data = defaults.data(forKey: Self.key), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(ThemePreferences.self, from: data)
    }

    public func save(_ preferences: ThemePreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

public final class MemoryThemePreferencesStore: ThemePreferencesStoring {
    private let value: Mutex<ThemePreferences?>

    public init(_ value: ThemePreferences? = nil) { self.value = Mutex(value) }

    public func load() -> ThemePreferences? { value.withLock { $0 } }
    public func save(_ preferences: ThemePreferences) { value.withLock { $0 = preferences } }
}
