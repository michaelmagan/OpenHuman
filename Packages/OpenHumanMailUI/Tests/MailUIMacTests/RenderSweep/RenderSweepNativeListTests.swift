import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    static let nativeListChips = [ThreadRowChip(kind: .label, title: "Clients", color: "#fb4c2f"),
                                  ThreadRowChip(kind: .category, title: "Updates")]

    @Test(arguments: SweepTheme.builtInsAndIncreaseContrast)
    func listNativeRows(_ theme: SweepTheme) async throws {
        let states: [ListPolishRow.State] = [.idle, .unread, .hover, .cursor, .cursorHover, .checked, .cursorChecked, .muted]
        let rows = states.map { ListPolishRow(subject: "Row state: \($0)", unread: $0 == .unread, chips: Self.nativeListChips, state: $0) }
        for density in ThemeDensity.allCases {
            var preferences = theme.preferences
            preferences.density = density
            let variant = SweepTheme(name: "\(theme.name), \(density.rawValue)", slug: "\(theme.slug)-\(density.rawValue)",
                                     preferences: preferences)
            let window = ListPolishWindow(rows: rows, theme: variant)
            defer { window.close() }
            try await sweepShoot(window.window, screen: "list-native-rows", theme: variant)
        }
        let inactive = ListPolishWindow(rows: rows, theme: theme, emphasized: false)
        defer { inactive.close() }
        try await sweepShoot(inactive.window, screen: "list-native-rows-inactive", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func listSelectionKeyAndInactiveWindow(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let list = try #require(w.content.tableView.listController)
        try await w.cursorAndHover(steps: 3, offset: 2)
        list.selectionEmphasisOverride = true
        try await sweepShoot(w.window, screen: "list-selection-key", theme: theme)
        list.selectionEmphasisOverride = false
        try await sweepShoot(w.window, screen: "list-selection-inactive", theme: theme)
    }

    @Test(arguments: SweepTheme.selected(SweepTheme.allBuiltIns, slugs: "light,dark,system-light,system-dark"))
    func listNativeSelectMode(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let model = try #require(w.router.list)
        w.content.tableView.listController?.selectionEmphasisOverride = true
        for row in model.rows.dropFirst(1).prefix(3) { model.selection.toggle(row.id) }
        model.setCursor(model.rows[2].id)
        try await w.cursorAndHover(steps: 0, offset: 3)
        try await sweepShoot(w.window, screen: "list-native-select-mode", theme: theme)
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func splitInboxPicker(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let state = try #require(w.router.active)
        for (features, screen) in [(NativeFeatures.macOS26, "split-picker-26"), (.macOS27, "split-picker-27")] {
            let picker = SplitInboxPicker(router: w.router, state: state, features: features).padding()
            let window = sweepStandaloneWindow(picker, store: theme.makeStore(), size: NSSize(width: 720, height: 64))
            defer { window.close() }
            try await sweepShoot(window, screen: screen, theme: theme)
        }
    }
}
