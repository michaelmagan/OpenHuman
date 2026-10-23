import Foundation
import MailTheme
import Observation
import SwiftUI

@MainActor @Observable
public final class ThemeStore {
    public private(set) var available: [ThemeSummary]
    public var preferences: ThemePreferences {
        didSet {
            guard preferences != oldValue else { return }
            preferencesStore?.save(preferences)
            apply(.preferences)
        }
    }
    public var systemAppearance: ThemeAppearance {
        didSet { if systemAppearance != oldValue { apply(.environment) } }
    }
    public var increaseContrast: Bool {
        didSet { if increaseContrast != oldValue { apply(.environment) } }
    }
    public var reduceMotion: Bool {
        didSet { if reduceMotion != oldValue { apply(.environment) } }
    }
    public var liveAccent: LiveAccent? {
        didSet { if liveAccent != oldValue { apply(.environment) } }
    }
    public private(set) var resolved: ResolvedTheme
    public private(set) var version = 0
    public private(set) var readerCSS: String
    public private(set) var notices: [ThemeIssue] = []
    public let folder: ThemeFolder?

    @ObservationIgnored public var isFontInstalled: (@MainActor (String) -> Bool)? {
        didSet { apply(.environment) }
    }

    @ObservationIgnored public private(set) var library: ThemeLibrary
    @ObservationIgnored private let loader: ThemeLoader?
    @ObservationIgnored private let preferencesStore: (any ThemePreferencesStoring)?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var installedScan = 0

    private enum Reason { case preferences, environment, reload }

    public init(library: ThemeLibrary = .builtIn, preferencesStore: (any ThemePreferencesStoring)? = nil,
                folder: ThemeFolder? = nil, systemAppearance: ThemeAppearance = .light, increaseContrast: Bool = false,
                reduceMotion: Bool = false, liveAccent: LiveAccent? = nil) {
        self.library = library
        self.preferencesStore = preferencesStore
        self.folder = folder
        self.loader = folder.map { ThemeLoader(folder: $0, registry: library.registry) }
        self.systemAppearance = systemAppearance
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
        self.liveAccent = liveAccent
        let stored = preferencesStore?.load()
        let preferences = stored?.migrated() ?? ThemePreferences()
        if let stored, stored != preferences { preferencesStore?.save(preferences) }
        self.preferences = preferences
        let resolved = library.resolve(preferences, appearance: preferences.mode.effective(system: systemAppearance),
                                       increaseContrast: increaseContrast, liveAccent: liveAccent)
            .applyingReduceMotion(reduceMotion)
        self.resolved = resolved
        self.readerCSS = ReaderCSS.stylesheet(for: resolved)
        self.available = library.summaries
        self.notices = resolved.issues
    }

    isolated deinit {
        watchTask?.cancel()
    }

    public var effectiveAppearance: ThemeAppearance { preferences.mode.effective(system: systemAppearance) }

    public func resolve(_ preferences: ThemePreferences, appearance: ThemeAppearance) -> ResolvedTheme {
        let theme = library.resolve(preferences, appearance: appearance, increaseContrast: increaseContrast, liveAccent: liveAccent)
            .applyingReduceMotion(reduceMotion)
        guard let isFontInstalled else { return theme }
        return theme.replacingMissingFonts(isInstalled: isFontInstalled)
    }

    public func resetPreferences() { preferences = ThemePreferences() }

    /// Called when the system colours change. Takes the new accent and always bumps `version`, so observers that
    /// cache system colours in layers redraw even when no theme token changed.
    public func systemColorsDidChange(liveAccent accent: LiveAccent?) {
        let before = version
        liveAccent = accent
        if version == before { version += 1 }
    }

    public func reloadThemes() async {
        guard let loader else { return }
        install(await loader.numberedLibrary(base: .builtIn))
    }

    public func startWatching(_ watcher: any ThemeFolderWatching) {
        watchTask?.cancel()
        watchTask = nil
        guard let loader else { return }
        let changes = watcher.changes()
        watchTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await _ in changes {
                let scan = await loader.numberedLibrary(base: .builtIn)
                guard let self else { return }
                await self.install(scan)
            }
        }
    }

    public func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    @discardableResult
    public func importTheme(from url: URL) async throws -> ThemeSummary {
        guard let loader else { throw ThemeFileError.writeFailed }
        let (destination, result) = try await loader.importFile(from: url)
        await reloadThemes()
        return available.first { $0.source == .user(destination) }
            ?? available.first { $0.id == result.file?.id } ?? ThemeSummary.placeholder(destination)
    }

    public func exportCustomizations(named name: String) async throws -> URL {
        guard let loader else { throw ThemeFileError.writeFailed }
        let baseID = preferences.themeID(for: effectiveAppearance)
        guard let base = library.summary(id: baseID) ?? library.summary(id: resolved.themeID) else { throw ThemeFileError.writeFailed }
        let data = ThemeExport.customizations(named: name, baseTheme: base, preferences: preferences)
        let url = try await loader.write(themeData: data)
        await reloadThemes()
        return url
    }

    public func observe(_ apply: @escaping @MainActor (ResolvedTheme) -> Void) -> ThemeObservation {
        let observation = ThemeObservation()
        observation.arm(store: self, apply)
        return observation
    }

    private func install(_ scan: (number: Int, library: ThemeLibrary)) {
        guard scan.number > installedScan else { return }
        installedScan = scan.number
        library = scan.library
        apply(.reload)
    }

    private func apply(_ reason: Reason) {
        var next = library.resolve(preferences, appearance: effectiveAppearance, increaseContrast: increaseContrast,
                                   liveAccent: liveAccent)
            .applyingReduceMotion(reduceMotion)
        if let isFontInstalled { next = next.replacingMissingFonts(isInstalled: isFontInstalled) }
        let selected = preferences.themeID(for: effectiveAppearance)
        if reason == .reload, next.themeID != selected, resolved.themeID == selected, resolved.appearance == next.appearance {
            let problems = library.summaries.filter { $0.id == selected }.flatMap(\.issues).filter { $0.severity == .refused }
            notices = [ThemeIssue(.warning, .themeUnavailable, path: "",
                                  "\(resolved.themeName) has errors; still showing the last valid version")] + problems
            available = library.summaries
            return
        }
        available = library.summaries
        notices = next.issues
        guard next != resolved else { return }
        resolved = next
        readerCSS = ReaderCSS.stylesheet(for: next)
        version += 1
    }
}

@MainActor
public final class ThemeObservation {
    private var active = true

    public func cancel() { active = false }

    fileprivate func arm(store: ThemeStore, _ apply: @escaping @MainActor (ResolvedTheme) -> Void) {
        guard active else { return }
        withObservationTracking {
            _ = store.version
            apply(store.resolved)
        } onChange: { [weak self, weak store] in
            Task { @MainActor [weak self, weak store] in
                guard let self, let store else { return }
                self.arm(store: store, apply)
            }
        }
    }
}

extension ThemeSummary {
    static func placeholder(_ url: URL) -> ThemeSummary {
        ThemeSummary(id: "file:" + url.lastPathComponent, name: url.lastPathComponent, author: nil, kind: .theme,
                     appearance: .any, source: .user(url), issues: [], isLoaded: false)
    }
}

extension EnvironmentValues {
    @Entry public var theme: ResolvedTheme = .light
}

extension View {
    public func themed(by store: ThemeStore) -> some View {
        modifier(ThemedModifier(store: store))
    }
}

// Reads store.resolved in body so SwiftUI tracks it and re-evaluates on theme change, even inside sheets
struct ThemedModifier: ViewModifier {
    let store: ThemeStore

    func body(content: Content) -> some View {
        let resolved = store.resolved
        let scheme: ColorScheme = resolved.appearance == .dark ? .dark : .light
        content
            .environment(\.theme, resolved)
            .environment(store)
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
            .tint(resolved.controlTint)
            .transaction(value: resolved) { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}
