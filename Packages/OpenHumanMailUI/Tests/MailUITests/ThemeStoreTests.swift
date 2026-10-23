import Foundation
import MailTheme
import Testing
@testable import MailUI

@MainActor
func waitUntil(timeout: Duration = testBackstop, _ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline { throw WaitTimeout() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

struct WaitTimeout: Error {}

func themeData(id: String, name: String = "Live", bgWindow: String, textPrimary: String = "#1A1C20") -> Data {
    let object: [String: Any] = ["format": "openhuman-theme", "formatVersion": 1, "id": id, "name": name, "appearance": "light",
                                 "extends": "openhuman.light",
                                 "semantic": ["color": ["bg.window": bgWindow, "text.primary": textPrimary]]]
    return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
}

func temporaryThemeFolder() throws -> ThemeFolder {
    let folder = ThemeFolder(url: FileManager.default.temporaryDirectory.appendingPathComponent("oh-store-\(UUID().uuidString)"))
    try folder.create()
    return folder
}

@MainActor
@Suite struct ThemeStoreTests {
    @Test func defaultsFollowTheSystemAppearance() {
        let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore())
        #expect(store.preferences.mode == .system)
        #expect(store.resolved.themeID == BuiltinThemeID.systemLight && store.resolved.accentID == "system" && store.version == 0)
        store.systemAppearance = .dark
        #expect(store.resolved.themeID == BuiltinThemeID.systemDark && store.resolved.appearance == .dark)
        #expect(store.version == 1)
        #expect(store.readerCSS.contains("color-scheme: dark;"))
        store.systemAppearance = .dark
        #expect(store.version == 1)
        store.preferences.mode = .light
        #expect(store.resolved.appearance == .light && store.version == 2)
    }

    @Test func preferencesPersistAndReload() {
        let persisted = MemoryThemePreferencesStore()
        let store = ThemeStore(preferencesStore: persisted)
        store.preferences.accentID = "iris"
        store.preferences.density = .comfortable
        #expect(persisted.load()?.accentID == "iris")
        let again = ThemeStore(preferencesStore: persisted)
        #expect(again.resolved.accentID == "iris" && again.resolved.rowHeight == 48)
        again.resetPreferences()
        #expect(again.resolved.accentID == "system" && persisted.load() == ThemePreferences())
    }

    @Test func savedLightAndDarkMoveToTheSystemThemesOnce() throws {
        let legacy = #"{"mode":"system","lightThemeID":"openhuman.light","darkThemeID":"openhuman.midnight","accentID":"pine"}"#
        let persisted = MemoryThemePreferencesStore(try JSONDecoder().decode(ThemePreferences.self, from: Data(legacy.utf8)))
        let store = ThemeStore(preferencesStore: persisted)
        #expect(store.preferences.lightThemeID == BuiltinThemeID.systemLight)
        #expect(store.preferences.darkThemeID == BuiltinThemeID.midnight && store.preferences.accentID == "pine")
        #expect(persisted.load() == store.preferences, "the move is saved right away")
        store.preferences.lightThemeID = BuiltinThemeID.light
        let again = ThemeStore(preferencesStore: persisted)
        #expect(again.preferences.lightThemeID == BuiltinThemeID.light, "a later choice of Light is kept")
        #expect(again.resolved.themeID == BuiltinThemeID.light)
    }

    @Test func currentPreferencesAreNotRewrittenOnLoad() {
        final class CountingStore: ThemePreferencesStoring, @unchecked Sendable {
            var saves = 0
            let value: ThemePreferences
            init(_ value: ThemePreferences) { self.value = value }
            func load() -> ThemePreferences? { value }
            func save(_ preferences: ThemePreferences) { saves += 1 }
        }
        let counting = CountingStore(ThemePreferences(lightThemeID: BuiltinThemeID.paper))
        let store = ThemeStore(preferencesStore: counting)
        #expect(store.preferences.lightThemeID == BuiltinThemeID.paper && counting.saves == 0)
    }

    @Test func theLiveAccentRecolorsTheSystemAccentOnly() {
        let purple = LiveAccent(light: ThemeColor(hex: "#953D96")!, dark: ThemeColor(hex: "#A550A7")!)
        let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore())
        let fixed = store.resolved.accentFill
        store.liveAccent = purple
        #expect(store.resolved.accentFill == ThemeColor(hex: "#953D96") && store.version == 1)
        #expect(store.resolve(store.preferences, appearance: .dark).accentFill == ThemeColor(hex: "#A550A7"), "previews follow it")
        store.preferences.accentID = "iris"
        #expect(store.resolved.accentID == "iris" && store.resolved.accentRing == ThemeColor(hex: "#5B45E0"))
        store.preferences.accentID = nil
        store.liveAccent = nil
        #expect(store.resolved.accentFill == fixed)
    }

    @Test func systemColorChangesAlwaysNotifyObservers() {
        let purple = LiveAccent(light: ThemeColor(hex: "#953D96")!, dark: ThemeColor(hex: "#A550A7")!)
        let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore())
        store.systemColorsDidChange(liveAccent: purple)
        #expect(store.version == 1 && store.liveAccent == purple)
        store.systemColorsDidChange(liveAccent: purple)
        #expect(store.version == 2, "same accent: observers still refresh cached system colours")
    }

    @Test func nativeControlsAreTintedOnlyByAChosenAccent() {
        let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore())
        #expect(store.resolved.usesSystemAccent && store.resolved.controlTint == nil)
        store.preferences.accentID = "pine"
        #expect(!store.resolved.usesSystemAccent && store.resolved.controlTint == store.resolved.accentFill.color)
        store.preferences = ThemePreferences(lightThemeID: BuiltinThemeID.paper, accentID: "system")
        #expect(store.resolved.controlTint == nil)
    }

    @Test func increaseContrastReResolves() {
        let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(lightThemeID: BuiltinThemeID.light)))
        store.increaseContrast = true
        #expect(store.resolved.borderHairline == ThemeTokens.light.borderControl)
    }

    @Test func previewResolveDoesNotTouchTheStore() {
        let store = ThemeStore()
        let candidate = store.resolve(ThemePreferences(darkThemeID: BuiltinThemeID.midnight, accentID: "pine"), appearance: .dark)
        #expect(candidate.tokens.bgWindow == ThemeTokens.midnight.bgWindow && candidate.accentID == "pine")
        #expect(store.resolved.themeID == BuiltinThemeID.systemLight && store.version == 0)
    }

    @Test func observeFiresOnEveryChange() async throws {
        let store = ThemeStore()
        var seen: [ThemeAppearance] = []
        let observation = store.observe { seen.append($0.appearance) }
        #expect(seen == [.light])
        store.preferences.mode = .dark
        try await waitUntil { seen == [.light, .dark] }
        store.preferences.mode = .light
        try await waitUntil { seen == [.light, .dark, .light] }
        observation.cancel()
        var second: [ThemeAppearance] = []
        let other = store.observe { second.append($0.appearance) }
        store.preferences.mode = .dark
        try await waitUntil { second == [.light, .dark] }
        #expect(seen.count == 3)
        other.cancel()
    }

    @Test func missingFontsFallBackToSystem() {
        let store = ThemeStore()
        store.isFontInstalled = { $0 == "Inter" }
        store.preferences.uiFont = .named("Not Installed Sans")
        #expect(store.resolved.fontFamilyUI == .system && store.resolved.typeBody.family == .system)
        #expect(store.notices.contains { $0.code == .fontMissing })
        store.preferences.uiFont = .named("Inter")
        #expect(store.resolved.typeBody.family == .named("Inter"))
    }

    @Test func liveReloadFollowsTheFolder() async throws {
        let folder = try temporaryThemeFolder()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let file = folder.url.appendingPathComponent("live.json")
        try themeData(id: "me.live", bgWindow: "#FFF8E0").write(to: file)
        let watcher = ManualThemeFolderWatcher()
        let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light, lightThemeID: "me.live")),
                               folder: folder)
        #expect(store.resolved.themeID == BuiltinThemeID.light)
        store.startWatching(watcher)
        await store.reloadThemes()
        #expect(store.resolved.themeID == "me.live" && store.resolved.bgWindow == ThemeColor(hex: "#FFF8E0"))
        #expect(store.available.contains { $0.id == "me.live" && $0.isSelectable })
        let version = store.version

        try themeData(id: "me.live", bgWindow: "#E8F0FF").write(to: file, options: .atomic)
        watcher.trigger()
        try await waitUntil { store.resolved.bgWindow == ThemeColor(hex: "#E8F0FF") }
        #expect(store.version == version + 1)

        try themeData(id: "me.live", bgWindow: "#FFFFFF", textPrimary: "#FAFAFA").write(to: file, options: .atomic)
        watcher.trigger()
        try await waitUntil { store.notices.contains { $0.code == .themeUnavailable } }
        #expect(store.resolved.themeID == "me.live" && store.resolved.bgWindow == ThemeColor(hex: "#E8F0FF"))
        #expect(store.notices.contains { $0.code == .contrastRefused })
        #expect(store.available.contains { $0.id == "me.live" && !$0.isUsable })

        try themeData(id: "me.live", bgWindow: "#F0FFF0").write(to: file, options: .atomic)
        watcher.trigger()
        try await waitUntil { store.resolved.bgWindow == ThemeColor(hex: "#F0FFF0") }
        #expect(!store.notices.contains { $0.code == .themeUnavailable })

        try FileManager.default.removeItem(at: file)
        let fresh = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light, lightThemeID: "me.live")),
                               folder: folder)
        await fresh.reloadThemes()
        #expect(fresh.resolved.themeID == BuiltinThemeID.light && fresh.notices.contains { $0.code == .themeUnavailable })
        store.stopWatching()
    }

    @Test func importAndExportThroughTheStore() async throws {
        let folder = try temporaryThemeFolder()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let store = ThemeStore(folder: folder)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("solar-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        try themeData(id: "me.solar", name: "Solar", bgWindow: "#FFFBF0").write(to: outside)
        let summary = try await store.importTheme(from: outside)
        #expect(summary.id == "me.solar" && summary.isSelectable)
        store.preferences.lightThemeID = "me.solar"
        store.preferences.mode = .light
        #expect(store.resolved.bgWindow == ThemeColor(hex: "#FFFBF0"))

        store.preferences.accentID = "graphite"
        store.preferences.readerTextSize = 16
        let url = try await store.exportCustomizations(named: "Solar Reading")
        #expect(url.lastPathComponent == "user.solar-reading.json")
        #expect(store.available.contains { $0.id == "user.solar-reading" && $0.isSelectable })
        let exported = store.resolve(ThemePreferences(lightThemeID: "user.solar-reading"), appearance: .light)
        #expect(exported.tokens == store.resolved.tokens)

        try Data("{ nope".utf8).write(to: outside)
        await #expect(throws: ThemeFileError.self) { try await store.importTheme(from: outside) }
    }
}
