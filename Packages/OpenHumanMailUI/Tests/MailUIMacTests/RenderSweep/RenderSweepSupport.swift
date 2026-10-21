import AppKit
import Foundation
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI
import Testing
@testable import MailUIMac

struct SweepTheme: Sendable, CustomTestStringConvertible {
    let name: String
    let slug: String
    let preferences: ThemePreferences
    var increaseContrast = false
    var reduceMotion = false

    var testDescription: String { name }
    var isDark: Bool { preferences.mode == .dark }

    @MainActor func makeStore() -> ThemeStore {
        ThemeStore(preferencesStore: MemoryThemePreferencesStore(preferences), systemAppearance: isDark ? .dark : .light,
                   increaseContrast: increaseContrast, reduceMotion: reduceMotion)
    }

    static let selectionVariable = "OH_SWEEP_THEMES"

    static func selected(_ all: [SweepTheme],
                         slugs: String? = ProcessInfo.processInfo.environment[selectionVariable]) -> [SweepTheme] {
        let wanted = Set((slugs ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        return wanted.isEmpty ? all : all.filter { wanted.contains($0.slug) }
    }

    static let builtIns: [SweepTheme] = selected(allBuiltIns)

    static let accessibility: [SweepTheme] = selected(allAccessibility)

    static let allBuiltIns: [SweepTheme] = [
        SweepTheme(name: "Light", slug: "light", preferences: ThemePreferences(mode: .light, lightThemeID: BuiltinThemeID.light)),
        SweepTheme(name: "Dark", slug: "dark", preferences: ThemePreferences(mode: .dark, darkThemeID: BuiltinThemeID.dark)),
        SweepTheme(name: "Paper", slug: "paper", preferences: ThemePreferences(mode: .light, lightThemeID: BuiltinThemeID.paper)),
        SweepTheme(name: "Midnight", slug: "midnight",
                   preferences: ThemePreferences(mode: .dark, darkThemeID: BuiltinThemeID.midnight)),
        SweepTheme(name: "System Light", slug: "system-light",
                   preferences: ThemePreferences(mode: .light, lightThemeID: BuiltinThemeID.systemLight)),
        SweepTheme(name: "System Dark", slug: "system-dark",
                   preferences: ThemePreferences(mode: .dark, darkThemeID: BuiltinThemeID.systemDark)),
    ]

    static let allAccessibility: [SweepTheme] = [
        SweepTheme(name: "Light + Reduce Motion", slug: "light-reduce-motion",
                   preferences: ThemePreferences(mode: .light, lightThemeID: BuiltinThemeID.light), reduceMotion: true),
        SweepTheme(name: "Dark + Reduce Motion", slug: "dark-reduce-motion",
                   preferences: ThemePreferences(mode: .dark, darkThemeID: BuiltinThemeID.dark), reduceMotion: true),
        SweepTheme(name: "Light + Increase Contrast", slug: "light-increase-contrast",
                   preferences: ThemePreferences(mode: .light, lightThemeID: BuiltinThemeID.light), increaseContrast: true),
        SweepTheme(name: "Dark + Increase Contrast", slug: "dark-increase-contrast",
                   preferences: ThemePreferences(mode: .dark, darkThemeID: BuiltinThemeID.dark), increaseContrast: true),
    ]
}

// Refuse any output folder inside a git work tree so renders can never be committed by accident
enum SweepOutput {
    static let variable = "OH_SNAPSHOT_DIR"

    enum Refusal: Error, CustomStringConvertible {
        case notSet
        case insideGitWorkTree(directory: String, workTree: String)

        var description: String {
            switch self {
            case .notSet: "\(SweepOutput.variable) is not set"
            case .insideGitWorkTree(let directory, let workTree):
                "\(directory) is inside the git work tree \(workTree); pick a folder outside every checkout"
            }
        }
    }

    static func gitWorkTree(containing path: String) -> String? {
        var current = ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        while true {
            if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) { return current }
            let parent = (current as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == current { return nil }
            current = parent
        }
    }

    static func checkedDirectory(_ path: String?) throws -> URL {
        guard let raw = path, !raw.isEmpty else { throw Refusal.notSet }
        let expanded = (raw as NSString).expandingTildeInPath
        let absolute = (expanded as NSString).isAbsolutePath
            ? expanded : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        if let tree = gitWorkTree(containing: absolute) {
            throw Refusal.insideGitWorkTree(directory: absolute, workTree: tree)
        }
        try FileManager.default.createDirectory(atPath: absolute, withIntermediateDirectories: true)
        if let tree = gitWorkTree(containing: absolute) {
            throw Refusal.insideGitWorkTree(directory: absolute, workTree: tree)
        }
        return URL(fileURLWithPath: absolute, isDirectory: true)
    }

    static func directory() throws -> URL {
        try checkedDirectory(ProcessInfo.processInfo.environment[variable])
    }
}

struct SweepIndexEntry: Codable, Equatable, Sendable {
    let screen: String
    let theme: String
    let file: String
}

@MainActor
enum SweepIndex {
    static let fileName = "index.json"

    static func record(_ entry: SweepIndexEntry, in directory: URL) throws {
        let url = directory.appendingPathComponent(fileName)
        var entries: [SweepIndexEntry] = []
        if let data = try? Data(contentsOf: url) {
            entries = (try? JSONDecoder().decode([SweepIndexEntry].self, from: data)) ?? []
        }
        entries.removeAll { $0.file == entry.file }
        entries.append(entry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}

@MainActor
func sweepShoot(_ window: NSWindow, screen: String, theme: SweepTheme, settle: Duration = .milliseconds(400)) async throws {
    let directory = try SweepOutput.directory()
    if let root = window.contentView {
        _ = try? await until(timeout: .seconds(60)) {
            SnapshotRenderTests.webViews(in: root).allSatisfy { $0.measuredHeight != nil }
        }
    }
    try await Task.sleep(for: settle)
    let name = "\(screen)--\(theme.slug)"
    try SnapshotRenderTests().snapshot(window, name: name)
    try SweepIndex.record(SweepIndexEntry(screen: screen, theme: theme.name, file: name + ".png"), in: directory)
}

@MainActor
func sweepStandaloneWindow<V: View>(_ view: V, store: ThemeStore, size: NSSize) -> NSWindow {
    let content = view
        .frame(width: size.width, height: size.height)
        .background(store.resolved.bgWindow.color)
        .themed(by: store)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: store.resolved.appearance == .dark ? .darkAqua : .aqua)
    let hosting = NSHostingView(rootView: content)
    hosting.frame = NSRect(origin: .zero, size: size)
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    return window
}

// One named state of one view on its own, the cheapest sweep case; docs/RENDER-SWEEP.md has the template
@MainActor
func sweepShootView<V: View>(_ screen: String, theme: SweepTheme, size: NSSize, settle: Duration = .milliseconds(400),
                             @ViewBuilder _ content: (ThemeStore) -> V) async throws {
    let store = theme.makeStore()
    let window = sweepStandaloneWindow(content(store), store: store, size: size)
    defer { window.orderOut(nil) }
    try await sweepShoot(window, screen: screen, theme: theme, settle: settle)
}

@MainActor
enum SweepWindow {
    static let frameName = "dev.openhuman.tests.render-sweep"
    static let size = NSSize(width: 1360, height: 860)

    static func make(_ environment: AppEnvironment, theme: SweepTheme, size: NSSize = size,
                     selectAllTipPinned: Bool = false, pinnedTip: ActionID? = nil) async throws -> InlineReplyWindow {
        let themes = theme.makeStore()
        var attached: MainContentViewController?
        let hosting = NSHostingView(rootView: MainWindowRoot(environment: environment, themes: themes) { attached = $0 }
            .environment(\.selectAllTipPinned, selectAllTipPinned)
            .environment(\.pinnedShortcutTip, pinnedTip))
        let frame = NSRect(origin: NSPoint(x: -6000, y: -6000), size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered,
                              defer: false)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        #expect(window.setFrameAutosaveName(frameName), "the frame name \(frameName) is free")
        window.contentView = hosting
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        try await until { attached != nil && environment.router.list?.state == .loaded }
        let content = try #require(attached)
        content.keyRouter.isMailWindow = { $0 === window }
        return InlineReplyWindow(environment: environment, window: window, content: content)
    }

    static func environment(heldSends: FakeMailStore.Options.HeldSends = .realTime, liveConnectivity: Bool = false,
                            calendar: Bool = false) -> AppEnvironment {
        AppEnvironment.fake(corpus: .small,
                            options: .init(remoteAck: .immediate, heldSends: heldSends, liveConnectivity: liveConnectivity),
                            featureFlags: FeatureFlags(), calendar: calendar ? FakeCalendar.sample() : nil)
    }
}

extension InlineReplyWindow {
    func longestConversation() async throws -> (ThreadKey, [MessageSummary]) {
        let account = try #require(router.accounts.first?.account)
        let rows = try await environment.data.threadPage(.system(.inbox), account: account.id, after: nil, limit: 500).rows
        var best: (ThreadKey, [MessageSummary])?
        for row in rows {
            var messages: [MessageSummary] = []
            for try await detail in environment.data.threadDetail(row.id) {
                messages = detail?.messages ?? []
                break
            }
            guard messages.count >= 3, messages.count > (best?.1.count ?? 0) else { continue }
            best = (row.id, messages)
        }
        return try #require(best)
    }

    func cursorAndHover(steps: Int = 2, offset: Int = 3) async throws {
        for _ in 0..<steps { router.perform(.nextThread) }
        try await Task.sleep(for: .milliseconds(150))
        guard let root = window.contentView, let table = subviews(of: ThreadTableView.self, in: root).first else { return }
        table.layoutSubtreeIfNeeded()
        var row = max(table.selectedRow, 0) + offset
        while row < table.numberOfRows {
            if let rowView = table.rowView(atRow: row, makeIfNecessary: false) as? ThreadRowBackgroundView, !rowView.isSelected,
               let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                  trackingNumber: 0, userData: nil) {
                rowView.mouseEntered(with: event)
                return
            }
            row += 1
        }
    }

    func hoverCursorRow() async throws {
        guard let root = window.contentView, let table = subviews(of: ThreadTableView.self, in: root).first else { return }
        table.layoutSubtreeIfNeeded()
        guard table.selectedRow >= 0,
              let rowView = table.rowView(atRow: table.selectedRow, makeIfNecessary: false) as? ThreadRowBackgroundView,
              let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 trackingNumber: 0, userData: nil) else { return }
        rowView.mouseEntered(with: event)
        try await Task.sleep(for: .milliseconds(50))
    }
}
