import AppKit
import MailTheme
import MailUI
import Testing
@testable import MailUIMac

private func tempFolder() throws -> ThemeFolder {
    let folder = ThemeFolder(url: FileManager.default.temporaryDirectory.appendingPathComponent("oh-fsevents-\(UUID().uuidString)"))
    try folder.create()
    return folder
}

private func theme(_ bgWindow: String) -> Data {
    let object: [String: Any] = ["format": "openhuman-theme", "formatVersion": 1, "id": "me.edited", "name": "Edited",
                                 "appearance": "light", "extends": "openhuman.light",
                                 "semantic": ["color": ["bg.window": bgWindow]]]
    return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
}

@MainActor
final class EventCounter {
    var count = 0
}

@MainActor
@Suite(.serialized) struct ThemeMacTests {
    @Test func fsEventsReportsAtomicAndInPlaceSaves() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let watcher = FSEventsThemeFolderWatcher(url: folder.url)
        let counter = EventCounter()
        let changes = watcher.changes()
        let task = Task { @MainActor in for await _ in changes { counter.count += 1 } }
        defer { task.cancel() }
        let file = folder.url.appendingPathComponent("a.json")
        try theme("#FFFFFF").write(to: file, options: .atomic)
        try await until(timeout: .seconds(60)) { counter.count >= 1 }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.close()
        try theme("#FAFAFA").write(to: folder.accentsURL.appendingPathComponent("b.json"))
        try await until(timeout: .seconds(60)) { counter.count >= 2 }
    }

    @Test func liveReloadBudgetIsStructurallyUnderOneSecond() {
        let watcher = FSEventsThemeFolderWatcher(url: FileManager.default.temporaryDirectory)
        #expect(watcher.debounce == .milliseconds(200))
        let budget = watcher.debounce + .seconds(FSEventsThemeFolderWatcher.streamLatency)
        #expect(budget < .milliseconds(500), "debounce + FSEvents latency leaves room for the off-main reload inside 1 s")
    }

    @Test func oneChangeEventUpdatesTheStoreWithoutAnyFurtherTrigger() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let file = folder.url.appendingPathComponent("edited.json")
        try theme("#FFF8E0").write(to: file)
        let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light, lightThemeID: "me.edited")),
                               folder: folder)
        await store.reloadThemes()
        #expect(store.resolved.bgWindow == ThemeColor(hex: "#FFF8E0"))
        let watcher = ManualThemeFolderWatcher()
        store.startWatching(watcher)
        defer { store.stopWatching() }
        for color in ["#E0F0FF", "#F0FFF0", "#FFF0F0"] {
            try theme(color).write(to: file, options: .atomic)
            watcher.trigger()
            try await until(timeout: .seconds(60)) { store.resolved.bgWindow == ThemeColor(hex: color) }
        }
    }

    @Test func realFSEventsEditsAllReachTheStore() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let file = folder.url.appendingPathComponent("edited.json")
        try theme("#FFF8E0").write(to: file)
        let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light, lightThemeID: "me.edited")),
                               folder: folder)
        await store.reloadThemes()
        store.startWatching(FSEventsThemeFolderWatcher(url: folder.url))
        defer { store.stopWatching() }
        for color in ["#E0F0FF", "#F0FFF0", "#FFF0F0"] {
            try theme(color).write(to: file, options: .atomic)
            try await until(timeout: .seconds(60)) { store.resolved.bgWindow == ThemeColor(hex: color) }
        }
    }

    @Test func appearanceMapping() throws {
        #expect(SystemAppearanceMonitor.appearance(of: try #require(NSAppearance(named: .darkAqua))) == .dark)
        #expect(SystemAppearanceMonitor.appearance(of: try #require(NSAppearance(named: .aqua))) == .light)
        #expect(SystemAppearanceMonitor.appearance(of: try #require(NSAppearance(named: .accessibilityHighContrastDarkAqua))) == .dark)
    }

    @Test func monitorFeedsTheStore() async {
        let store = ThemeStore()
        let monitor = SystemAppearanceMonitor(store: store)
        #expect(store.systemAppearance == SystemAppearanceMonitor.appearance(of: NSApplication.shared.effectiveAppearance))
        #expect(store.liveAccent == SystemAppearanceMonitor.liveAccent())
        let version = store.version
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        await untilObserved { store.version > version }
        _ = monitor
    }

    @Test func theLiveAccentIsReadPerAppearance() throws {
        let accent = try #require(SystemAppearanceMonitor.liveAccent(NSColor(srgbRed: 0.5, green: 0.25, blue: 0.75, alpha: 1)))
        #expect(accent.light == ThemeColor(red: 0.5, green: 0.25, blue: 0.75) && accent.dark == accent.light)
        let dynamic = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        }
        let pair = try #require(SystemAppearanceMonitor.liveAccent(dynamic))
        #expect(pair.light == ThemeColor(red: 0, green: 0, blue: 0) && pair.dark == ThemeColor(red: 1, green: 1, blue: 1))
    }

    @Test func windowAppearanceFollowsTheResolvedTheme() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        window.applyThemeAppearance(.dark)
        #expect(window.appearance?.name == .darkAqua)
        window.applyThemeAppearance(.light)
        #expect(window.appearance?.name == .aqua)
    }

    @Test func fontsFollowTheFamily() {
        var style = ThemeTokens.light.typeBody
        #expect(style.font.familyName == NSFont.systemFont(ofSize: 13).familyName)
        style.family = .systemMono
        #expect(style.font.isFixedPitch)
        style.family = .named("Definitely Not Installed 123")
        #expect(style.font.familyName == NSFont.systemFont(ofSize: 13).familyName)
        if let installed = MacFontCatalog.families.first(where: { $0 == "Helvetica" || $0 == "Menlo" }) {
            #expect(MacFontCatalog.isInstalled(installed))
            style.family = .named(installed)
            #expect(style.font.familyName == installed)
            style.trackingEm = 0.01
            #expect(style.kern == 0.13)
        }
        #expect(!MacFontCatalog.isInstalled("Definitely Not Installed 123"))
    }

    @Test func appKitObserversSeeLightDarkSwitches() async throws {
        let store = ThemeStore()
        let view = NSView()
        view.wantsLayer = true
        let observation = store.observe { theme in view.layer?.backgroundColor = theme.bgWindow.nsColor.cgColor }
        #expect(view.layer?.backgroundColor == ThemeLibrary.builtIn.resolve(themeID: BuiltinThemeID.systemLight, appearance: .light).bgWindow.nsColor.cgColor)
        store.preferences.mode = .dark
        try await until { view.layer?.backgroundColor == ThemeLibrary.builtIn.resolve(themeID: BuiltinThemeID.systemDark, appearance: .dark).bgWindow.nsColor.cgColor }
        #expect(ReaderCSS.replaceScript(css: store.readerCSS).contains("color-scheme: dark"))
        observation.cancel()
    }
}
