import Foundation
import MailActions
import MailFeatures
import MailModel
import MailTheme
import Observation
import Testing
@testable import MailUI

private final class Count: @unchecked Sendable { var value = 0 }

@MainActor
struct ThemeActionsTests {
    private func rig() -> (registry: ActionRegistry, store: ThemeStore, persisted: MemoryThemePreferencesStore) {
        let persisted = MemoryThemePreferencesStore()
        let store = ThemeStore(preferencesStore: persisted)
        let registry = ActionRegistry()
        ThemeActionHandler.install(in: registry, store: store)
        return (registry, store, persisted)
    }

    private func storeWithACustomAccent() -> ThemeStore {
        let accent: [String: Any] = ["format": "openhuman-accent", "formatVersion": 1, "id": "me.accent.sunset", "name": "Sunset",
                                     "light": ["accent.fill": "#C2410C", "accent.fillHover": "#A8380A", "accent.text": "#B23C0B",
                                               "accent.subtle": "#FDEEE6", "accent.onFill": "#FFFFFF", "accent.ring": "#C2410C"],
                                     "dark": ["accent.fill": "#C2410C", "accent.fillHover": "#D24A12", "accent.text": "#F59E6B",
                                              "accent.subtle": "#3A2216", "accent.onFill": "#FFFFFF", "accent.ring": "#F08A4B"]]
        var library = ThemeLibrary.builtIn
        library.add(data: (try? JSONSerialization.data(withJSONObject: accent)) ?? Data(),
                    source: .user(URL(fileURLWithPath: "/themes/accents/sunset.json")))
        return ThemeStore(library: library, preferencesStore: MemoryThemePreferencesStore())
    }

    private func watch(_ registry: ActionRegistry) -> Count {
        let changes = Count()
        withObservationTracking {
            _ = (registry.descriptors, registry.defaultDescriptors, registry.keymap, registry.keymapRevision)
            _ = registry.enabledModules
        } onChange: { changes.value += 1 }
        return changes
    }

    /// Evaluates the way SwiftUI does: each pass runs while the tracking from the pass before is still live, and a
    /// pass that invalidates that tracking earns another pass. Two passes means the forced second pass settled.
    private func passes(limit: Int = 20, of body: @MainActor () -> Void) -> Int {
        let invalidations = Count()
        withObservationTracking { body() } onChange: { invalidations.value += 1 }
        var passes = 1
        repeat {
            invalidations.value = 0
            withObservationTracking { body() } onChange: { invalidations.value += 1 }
            passes += 1
        } while invalidations.value > 0 && passes < limit
        return passes
    }

    @Test func theCatalogHasTheThemeActionsAsViewEffects() {
        let ids = ["theme.light", "theme.dark", "theme.system"] + ActionCatalog.builtInAccents.map { "theme.accent.\($0)" }
        for id in ids {
            let descriptor = ActionCatalog.descriptor(ActionID(id))
            #expect(descriptor != nil, "\(id)")
            #expect(descriptor?.effect == .view && descriptor?.changesMail == false, "\(id)")
            #expect(descriptor?.appearsInPalette == true, "\(id)")
        }
        #expect(Set(ActionCatalog.builtInAccents) == Set(ThemeLibrary.builtIn.accentIDs))
    }

    @Test func modeAndAccentActionsWriteTheSharedPreferences() {
        let (registry, store, persisted) = rig()
        #expect(registry.perform(.themeDark, source: .palette, host: nil))
        #expect(store.preferences.mode == .dark && store.resolved.appearance == .dark)
        #expect(persisted.load()?.mode == .dark)
        #expect(registry.perform(.themeLight, source: .menu, host: nil))
        #expect(store.preferences.mode == .light)
        #expect(registry.perform(.themeSystem, source: .menu, host: nil))
        #expect(store.preferences.mode == .system)
        #expect(registry.perform(.themeAccent("iris"), source: .palette, host: nil))
        #expect(store.preferences.accentID == "iris" && store.resolved.accentID == "iris")
        #expect(persisted.load()?.accentID == "iris")
    }

    @Test func aChangeMadeElsewhereIsWhatTheMenuReads() {
        let (_, store, _) = rig()
        store.preferences.mode = .dark
        store.preferences.accentID = "pine"
        #expect(store.preferences.mode == .dark && store.resolved.accentID == "pine")
        #expect(ThemeActionHandler.action(for: store.preferences.mode) == .themeDark)
    }

    @Test func theyWorkWhenMailCantBeChanged() {
        let (registry, store, _) = rig()
        var context = ActionContext()
        context.canWrite = false
        for id in [ActionID.themeLight, .themeDark, .themeSystem, .themeAccent("blue")] {
            #expect(registry.availability(id, host: nil, context: context) == .enabled, "\(id.rawValue)")
        }
        #expect(registry.perform(.themeDark, source: .palette, host: nil, context: context))
        #expect(store.preferences.mode == .dark)
    }

    @Test func anUnknownAccentIsRefused() {
        let (registry, store, _) = rig()
        #expect(!registry.perform(ActionID.themeAccent("chartreuse"), source: .palette, host: nil))
        #expect(store.preferences.accentID == nil)
        #expect(ActionID("theme.accent.").themeAccentName == nil)
        #expect(ActionID.themeAccent("iris").themeAccentName == "iris")
    }

    @Test func thePaletteListsThem() {
        let (registry, _, _) = rig()
        let titles = registry.descriptors.filter(\.appearsInPalette).map(\.title)
        #expect(titles.contains("Appearance: Dark") && titles.contains("Accent: Iris"))
    }

    @Test func aCustomAccentIsListedAndPerformed() {
        let store = storeWithACustomAccent()
        let registry = ActionRegistry()
        ThemeActionHandler.install(in: registry, store: store)
        #expect(registry.descriptors.contains { $0.id == .themeAccent("sunset") })
        #expect(registry.perform(.themeAccent("sunset"), source: .palette, host: nil))
        #expect(store.preferences.accentID == "sunset")
    }

    @Test(arguments: [false, true]) func installingAgainDoesNotDisturbObservers(customAccent: Bool) {
        let store = customAccent ? storeWithACustomAccent() : ThemeStore(preferencesStore: MemoryThemePreferencesStore())
        let registry = ActionRegistry()
        ThemeActionHandler.install(in: registry, store: store)
        let revision = registry.keymapRevision
        let changes = watch(registry)
        ThemeActionHandler.install(in: registry, store: store)
        #expect(changes.value == 0)
        #expect(registry.keymapRevision == revision)
    }

    @Test func installingOnlyBuiltInsDoesNotDisturbObserversTheFirstTime() {
        let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore())
        let registry = ActionRegistry()
        let changes = watch(registry)
        ThemeActionHandler.install(in: registry, store: store)
        #expect(changes.value == 0)
    }

    @Test(arguments: [false, true]) func installingInATrackedScopeLeavesNoDependencyOnTheRegistry(customAccent: Bool) {
        let store = customAccent ? storeWithACustomAccent() : ThemeStore(preferencesStore: MemoryThemePreferencesStore())
        let registry = ActionRegistry()
        let changes = Count()
        withObservationTracking { ThemeActionHandler.install(in: registry, store: store) } onChange: { changes.value += 1 }
        registry.applyKeymap(KeymapOverrides())
        #expect(changes.value == 0)
    }

    @Test(arguments: [false, true]) func installingInABodySettlesAfterTheSecondPass(customAccent: Bool) {
        let store = customAccent ? storeWithACustomAccent() : ThemeStore(preferencesStore: MemoryThemePreferencesStore())
        let registry = ActionRegistry()
        #expect(passes { ThemeActionHandler.install(in: registry, store: store) } == 2)
    }

    @Test func installingTheHandlerAloneLeavesTheRegistryAsItWas() {
        let store = storeWithACustomAccent()
        let registry = ActionRegistry()
        let revision = registry.keymapRevision
        let changes = watch(registry)
        ThemeActionHandler.installHandler(in: registry, store: store)
        #expect(changes.value == 0 && registry.keymapRevision == revision)
        #expect(registry.handler(for: .themeDark) != nil)
        #expect(!registry.contains(.themeAccent("sunset")), "custom accents wait for registerAccents")
    }
}
