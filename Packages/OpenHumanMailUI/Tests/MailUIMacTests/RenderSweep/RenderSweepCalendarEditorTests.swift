import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI
import Testing
@testable import MailUIMac

// The suggestion list lives in a child panel, which a window snapshot leaves out; this draws each one back in
@MainActor
func sweepShootWithPanels(_ window: NSWindow, screen: String, theme: SweepTheme) async throws {
    try await sweepShoot(window, screen: screen, theme: theme)
    let panels = (window.childWindows ?? []).compactMap { $0 as? CompletionPanelWindow }
    guard !panels.isEmpty, let root = window.contentView else { return }
    let url = try SweepOutput.directory().appendingPathComponent("\(screen)--\(theme.slug).png")
    let base = try #require(NSImage(contentsOf: url))
    let rootOnScreen = window.convertToScreen(root.convert(root.bounds, to: nil))
    var layers: [(NSImage, NSRect)] = []
    for panel in panels {
        guard let content = panel.contentView else { continue }
        content.layoutSubtreeIfNeeded()
        let rep = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(rep)
        let origin = NSPoint(x: panel.frame.minX - rootOnScreen.minX, y: panel.frame.minY - rootOnScreen.minY)
        layers.append((image, NSRect(origin: origin, size: panel.frame.size)))
    }
    let composed = NSImage(size: root.bounds.size)
    composed.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: root.bounds.size))
    for (image, rect) in layers { image.draw(in: rect) }
    composed.unlockFocus()
    let tiff = try #require(composed.tiffRepresentation)
    let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try png.write(to: url)
}

extension SweepTheme {
    static let calendarEditor: [SweepTheme] = builtIns.filter { ["light", "dark", "paper"].contains($0.slug) }
}

extension RenderSweepTests {
    @Test(arguments: SweepTheme.calendarEditor)
    func calendarEditorScreens(_ theme: SweepTheme) async throws {
        let (environment, now) = CalendarWindowSweep.environment()
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let model = try #require(environment.calendarWindow)
        let sidebar = try #require(environment.calendarSidebar)
        model.now = { now }
        sidebar.now = { now }
        await model.open(.week, source: .keyboard)
        try await until { model.state == .loaded && model.events.count > 10 }
        let root = try #require(w.window.contentView)
        let prefix = try await CalendarEditorProbe.contactPrefix(sidebar)

        let meet = try await CalendarEditorProbe.waitForField("calendar.window.meetSuggestions", in: root)
        try await CalendarEditorProbe.type(prefix, into: meet, in: w.window)
        _ = try await CalendarEditorProbe.shownPanel(of: w.window)
        try await sweepShootWithPanels(w.window, screen: "calendar-window-meet-suggestions", theme: theme)
        try await CalendarEditorProbe.type("", into: meet, in: w.window)
        try await until { CalendarEditorProbe.panel(of: w.window) == nil }
        w.window.makeFirstResponder(nil)

        let review = try #require(model.events.first { $0.id == "review" })
        model.openEvent(review)
        let guests = try await CalendarEditorProbe.waitForField("calendar.guestSuggestions", in: root)
        try await sweepShoot(w.window, screen: "calendar-editor-guests-before-typing", theme: theme)
        try await CalendarEditorProbe.type(prefix, into: guests, in: w.window)
        _ = try await CalendarEditorProbe.shownPanel(of: w.window)
        try await sweepShootWithPanels(w.window, screen: "calendar-editor-guest-suggestions", theme: theme)
        try await CalendarEditorProbe.type("", into: guests, in: w.window)
        try await until { CalendarEditorProbe.panel(of: w.window) == nil }
        w.window.makeFirstResponder(nil)

        try await until {
            CalendarEditorProbe.textEditors(in: root).filter { !$0.isHiddenOrHasHiddenAncestor }.count == 1
        }
        let notes = try #require(CalendarEditorProbe.textEditors(in: root).first { !$0.isHiddenOrHasHiddenAncestor })
        try await CalendarEditorProbe.typeLines(["Agenda", "1. Review the mock-ups", "2. Agree the launch date",
                                                 "3. Owners and next steps"], into: notes, in: w.window)
        try await until { (model.card?.form?.notes ?? "").split(separator: "\n").count == 4 }
        try await sweepShoot(w.window, screen: "calendar-editor-notes-lines", theme: theme)
        w.window.makeFirstResponder(nil)
        model.closeCard()
        await model.close()
    }
}
