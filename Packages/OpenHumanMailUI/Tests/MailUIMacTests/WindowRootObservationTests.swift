import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import Observation
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

private let now = Date(timeIntervalSince1970: 1_791_000_000)

private let accentData: Data = {
    let accent: [String: Any] = ["format": "openhuman-accent", "formatVersion": 1, "id": "me.accent.sunset", "name": "Sunset",
                                 "light": ["accent.fill": "#C2410C", "accent.fillHover": "#A8380A", "accent.text": "#B23C0B",
                                           "accent.subtle": "#FDEEE6", "accent.onFill": "#FFFFFF", "accent.ring": "#C2410C"],
                                 "dark": ["accent.fill": "#C2410C", "accent.fillHover": "#D24A12", "accent.text": "#F59E6B",
                                          "accent.subtle": "#3A2216", "accent.onFill": "#FFFFFF", "accent.ring": "#F08A4B"]]
    return (try? JSONSerialization.data(withJSONObject: accent)) ?? Data()
}()

@MainActor @Observable
private final class ParentProbe {
    /// A runaway body stops building the root here, so the loop fails the test instead of hanging the run.
    static let evaluationCap = 100

    var generation = 0
    @ObservationIgnored var evaluations = 0
    @ObservationIgnored var attached = false

    func evaluate() {
        _ = generation
        evaluations += 1
    }
}

/// Builds the root inside its body, as the app's window view does, and reports how often that body runs.
private struct ParentOfTheRoot: View {
    let probe: ParentProbe
    let environment: AppEnvironment
    let themes: ThemeStore

    var body: some View {
        let _ = probe.evaluate()
        if probe.evaluations > ParentProbe.evaluationCap {
            Color.clear
        } else {
            MainWindowRoot(environment: environment, themes: themes) { _ in probe.attached = true }
        }
    }
}

@MainActor
@Suite(.serialized)
struct WindowRootObservationTests {
    private final class Count: @unchecked Sendable { var value = 0 }

    private func storeWithACustomAccent() -> ThemeStore {
        var library = ThemeLibrary.builtIn
        library.add(data: accentData, source: .user(URL(fileURLWithPath: "/themes/accents/sunset.json")))
        return ThemeStore(library: library, preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light)))
    }

    private func show(_ view: some View, frameName: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        #expect(window.setFrameAutosaveName(frameName))
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        return window
    }

    @Test func buildingTheRootInAParentsBodyWritesAndReadsNothingObserved() {
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 20, now: now))
        let themes = storeWithACustomAccent()
        let registry = environment.actions
        let revision = registry.keymapRevision
        let registryChanges = Count()
        withObservationTracking {
            _ = (registry.descriptors, registry.defaultDescriptors, registry.keymap, registry.keymapRevision)
        } onChange: { registryChanges.value += 1 }
        let bodyChanges = Count()
        withObservationTracking {
            _ = MainWindowRoot(environment: environment, themes: themes)
            _ = MainWindowRoot(environment: environment, themes: themes)
        } onChange: { bodyChanges.value += 1 }
        #expect(registryChanges.value == 0 && registry.keymapRevision == revision)
        #expect(registry.handler(for: .themeDark) != nil, "the theme commands work before the window draws")

        registry.applyKeymap(KeymapOverrides())
        #expect(bodyChanges.value == 0, "a keymap change has no reason to rebuild the parent")
    }

    // Why: RunLoop.run(until:) is unavailable from an async context, so the turns happen in a synchronous helper
  private func turnTheRunLoop(_ turns: Int) {
    for _ in 0..<turns { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
  }

  @Test func aParentsSecondEvaluationSettles() async throws {
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 20, now: now))
        let themes = storeWithACustomAccent()
        let probe = ParentProbe()
        let window = show(ParentOfTheRoot(probe: probe, environment: environment, themes: themes),
                          frameName: "dev.openhuman.tests.window-root-observation-settles")
        defer {
            window.orderOut(nil)
            window.setFrameAutosaveName("")
        }
        try await until {
            probe.attached && environment.router.list?.state == .loaded && environment.actions.contains(.themeAccent("sunset"))
        }
        let settled = probe.evaluations

        probe.generation += 1
        try await until { probe.evaluations > settled }
        // A bound on run-loop turns and on evaluations: nothing here depends on how long a turn takes
        turnTheRunLoop(40)

        #expect(probe.evaluations <= settled + 2, "one change re-evaluates the parent once, and it stays settled")
        #expect(probe.evaluations <= ParentProbe.evaluationCap, "the parent's body ran away")
    }

    @Test func anAccentInTheLibraryIsACommandOnceTheWindowIsUp() async throws {
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 20, now: now))
        let themes = storeWithACustomAccent()
        var attached = false
        let window = show(MainWindowRoot(environment: environment, themes: themes) { _ in attached = true },
                          frameName: "dev.openhuman.tests.window-root-observation-accent")
        defer {
            window.orderOut(nil)
            window.setFrameAutosaveName("")
        }
        try await until { attached && environment.actions.contains(.themeAccent("sunset")) }
        #expect(environment.router.perform(.themeAccent("sunset"), source: .menu))
        #expect(themes.preferences.accentID == "sunset")
    }

    @Test func anAccentLoadedWhileTheWindowIsOpenBecomesACommand() async throws {
        let directory = TemporaryDirectory("oh-window-root-themes", isDirectory: true)
        defer { directory.cleanup() }
        let folder = ThemeFolder(url: directory.url)
        try folder.create()
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 20, now: now))
        let themes = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light)), folder: folder)
        var attached = false
        let window = show(MainWindowRoot(environment: environment, themes: themes) { _ in attached = true },
                          frameName: "dev.openhuman.tests.window-root-observation-reload")
        defer {
            window.orderOut(nil)
            window.setFrameAutosaveName("")
        }
        try await until { attached }
        #expect(!environment.actions.contains(.themeAccent("sunset")))

        try accentData.write(to: folder.accentsURL.appendingPathComponent("sunset.json"))
        await themes.reloadThemes()

        try await until { environment.actions.contains(.themeAccent("sunset")) }
        #expect(environment.router.perform(.themeAccent("sunset"), source: .menu))
        #expect(themes.preferences.accentID == "sunset")
    }
}
