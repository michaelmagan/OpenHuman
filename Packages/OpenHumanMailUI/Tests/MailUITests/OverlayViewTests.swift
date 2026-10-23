#if os(macOS)
import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI

private let fixedNow = Date(timeIntervalSince1970: 1_791_000_000)

@MainActor
private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 1000, height: 700), name: String,
                           theme: ResolvedTheme = .light) throws -> NSHostingView<some View> {
    let hosting = NSHostingView(rootView: view.environment(\.theme, theme).environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
        .environment(\.nativeOverlaySurface, .material)
        .background(theme.bgWindow.color))
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.appearance = NSAppearance(named: theme.appearance == .dark ? .darkAqua : .aqua)
    hosting.layoutSubtreeIfNeeded()
    if let dir = ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] {
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    return hosting
}

@MainActor
private struct Rig {
    let env: AppEnvironment
    let router: AppRouter
    let center: OverlayCenter

    init(corpus: FakeCorpus = .rich(threadCount: 60, now: fixedNow)) async {
        env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate))
        router = env.router
        center = env.overlays
        center.now = { fixedNow }
        center.timeZone = TimeZone(identifier: "UTC")!
        center.locale = Locale(identifier: "en_US_POSIX")
        router.start()
        while router.active?.list?.state != .loaded { await Task.yield() }
        router.go(to: .system(.inbox))
        while router.active?.list?.state != .loaded || router.list?.rows.isEmpty != false { await Task.yield() }
    }
}

@MainActor
@Test func paletteLaysOutWithGroupsAndKeycaps() async throws {
    let rig = await Rig()
    rig.router.perform(.commandPalette)
    guard case .palette(let palette) = rig.center.overlay else { Issue.record("no palette"); return }
    _ = try host(OverlayHostView(center: rig.center), name: "palette-suggested")
    palette.query = "snooze"
    let hosting = try host(OverlayHostView(center: rig.center), name: "palette-snooze")
    #expect(!palette.entries.isEmpty && hosting.frame.width == 1000)
    palette.query = "qzxqzx"
    _ = try host(OverlayHostView(center: rig.center), name: "palette-empty")
}

@MainActor
@Test func paletteFieldFollowsTheAppAppearance() async throws {
    let rig = await Rig()
    rig.router.perform(.commandPalette)
    guard case .palette(let palette) = rig.center.overlay else { Issue.record("no palette"); return }
    palette.query = "snooze"
    for theme in [ResolvedTheme.light, .dark] {
        let hosting = try host(OverlayHostView(center: rig.center), name: "palette-field-\(theme.themeID)", theme: theme)
        let fields = textFields(in: hosting)
        #expect(!fields.isEmpty, "the palette's query field is an NSTextField")
        let expected: NSAppearance.Name = theme.appearance == .dark ? .darkAqua : .aqua
        for field in fields {
            #expect(field.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected, "\(theme.themeID)")
            #expect(field.font?.pointSize == NativeMetrics.Overlay.paletteFieldTextSize)
            #expect(field.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == false, "the system font")
        }
    }
}

@MainActor
private func textFields(in view: NSView) -> [NSTextField] {
    if let field = view as? NSTextField { return [field] }
    return view.subviews.flatMap { textFields(in: $0) }
}

@MainActor
@Test func snoozeAndRemindCardsLayOutIncludingTheMonthGrid() async throws {
    let rig = await Rig()
    rig.router.perform(.snooze)
    guard case .time(let snooze) = rig.center.overlay else { Issue.record("no picker"); return }
    _ = try host(OverlayHostView(center: rig.center), name: "snooze-picker")
    snooze.text = "fri 3pm"
    _ = try host(OverlayHostView(center: rig.center), name: "snooze-parsed")
    snooze.text = "gibberish"
    _ = try host(OverlayHostView(center: rig.center), name: "snooze-hint")
    snooze.text = ""
    snooze.chooseNumber(snooze.rows.last { $0.number != nil }?.number ?? 6)
    #expect(snooze.datePick != nil)
    _ = try host(OverlayHostView(center: rig.center), name: "snooze-pick-a-date")

    rig.center.dismiss()
    rig.router.perform(.remind)
    guard case .time(let remind) = rig.center.overlay else { Issue.record("no remind picker"); return }
    remind.apply(snooze: nil, reminder: ReminderItem(id: "r", thread: remind.targets[0], subject: "s",
                                                     dueAt: fixedNow.addingTimeInterval(86_400), kind: .ifNoReply))
    _ = try host(OverlayHostView(center: rig.center), name: "remind-existing")
}

@MainActor
@Test func labelPickerAndShortcutSheetLayOut() async throws {
    let rig = await Rig()
    rig.router.perform(.label)
    guard case .label(let picker) = rig.center.overlay else { Issue.record("no label picker"); return }
    #expect(!picker.rows.isEmpty)
    _ = try host(OverlayHostView(center: rig.center), name: "label-picker")
    picker.query = "Brand New"
    _ = try host(OverlayHostView(center: rig.center), name: "label-picker-create")
    rig.center.dismiss()
    rig.router.perform(.shortcutHelp)
    _ = try host(OverlayHostView(center: rig.center), size: NSSize(width: 1100, height: 760), name: "shortcut-sheet")
    guard case .shortcuts(let sheet) = rig.center.overlay else { Issue.record("no sheet"); return }
    #expect(sheet.allLines.count > 40)
}

@MainActor
@Test func searchFieldLaysOutWithSuggestions() async throws {
    let rig = await Rig()
    let search = rig.center.search
    search.open()
    _ = try host(SearchFieldView(search: search).padding(), size: NSSize(width: 700, height: 360), name: "search-empty")
    search.text = "from:dana before:yesterday"
    let hosting = try host(SearchFieldView(search: search).padding(), size: NSSize(width: 700, height: 360), name: "search-invalid-date")
    #expect(search.tokens.contains { !$0.isValid })
    #expect(hosting.fittingSize.height > 0)
}

@MainActor
@Test func searchPillsLayOutRestingSelectedAndWithTheirRemoveControl() throws {
    let token = try #require(SearchQueryTokens.split("from:dana.sample@example.com ").tokens.first)
    let resting = try host(SearchTokenPill(token: token).padding(), size: NSSize(width: 320, height: 40), name: "search-pill")
    let removable = try host(SearchTokenPill(token: token, remove: {}).padding(), size: NSSize(width: 320, height: 40),
                             name: "search-pill-removable")
    let selected = try host(SearchTokenPill(token: token, isSelected: true, remove: {}).padding(),
                            size: NSSize(width: 320, height: 40), name: "search-pill-selected")
    #expect(removable.fittingSize.width == resting.fittingSize.width, "the remove control takes no room of its own")
    #expect(selected.fittingSize.width == resting.fittingSize.width, "nor does showing it on a selected pill")
}

@MainActor
@Test func noOverlayMeansNothingToDraw() async throws {
    let rig = await Rig()
    #expect(!rig.center.isShowing)
    rig.router.perform(.shortcutHelp)
    #expect(rig.center.isShowing)
    rig.center.dismiss()
    #expect(!rig.center.isShowing)
}
#endif
