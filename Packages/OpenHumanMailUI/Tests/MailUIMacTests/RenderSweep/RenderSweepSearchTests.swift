import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func searchDropDownOverResults(_ theme: SweepTheme) async throws {
        SearchDropdownPanel.drawsMaterial = true
        defer { SearchDropdownPanel.drawsMaterial = false }
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        #expect(w.router.perform(.search))
        try await until { OverlayFocusKeeper.control(of: w.window.firstResponder) is NSTextField }
        let editor = try #require(w.window.firstResponder as? NSTextView)
        editor.insertText("e", replacementRange: editor.selectedRange())
        let model = w.environment.overlays.search
        try await until { model.shownQuery == "e" && w.router.list?.state == .loaded && !model.suggestions.isEmpty }
        try await sweepShootWithChildWindows(w.window, screen: "search-dropdown-open", theme: theme)
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        try await until { model.text.isEmpty && model.suggestions.count >= 6 }
        try await sweepShootWithChildWindows(w.window, screen: "search-dropdown-operators", theme: theme)
        editor.insertText("from:dana subject:\"q4 budget\" -label:Receipts e", replacementRange: editor.selectedRange())
        try await until { model.text.hasSuffix(" e") }
        try await sweepShootWithChildWindows(w.window, screen: "search-operator-pills", theme: theme)
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func searchResultOpened(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        #expect(w.router.perform(.search))
        try await until { OverlayFocusKeeper.control(of: w.window.firstResponder) is NSTextField }
        let editor = try #require(w.window.firstResponder as? NSTextView)
        editor.insertText("e", replacementRange: editor.selectedRange())
        let model = w.environment.overlays.search
        try await until { model.shownQuery == "e" && w.router.list?.state == .loaded && w.router.list?.rows.isEmpty == false }
        #expect(w.router.showsSearchResultsHeader)
        let result = try #require(w.router.list?.rows.first?.id)
        _ = try await w.open(result)
        #expect(!w.router.showsSearchResultsHeader, "the conversation shows no search-only lines")
        try await sweepShoot(w.window, screen: "search-result-opened", theme: theme)
        #expect(w.router.perform(.backToList))
        try await until { w.router.mode == .list }
        #expect(w.router.showsSearchResultsHeader && model.shownQuery == "e")
        #expect(w.router.list?.cursor == result)
    }

    // The suggestions panel is a child window and its glass draws nothing in a capture, so these renders ask for the
    // material and draw the panel over the window capture
    @Test(arguments: SweepTheme.lightAndDark)
    func searchSuggestionsPanel(_ theme: SweepTheme) async throws {
        SearchDropdownPanel.drawsMaterial = true
        defer { SearchDropdownPanel.drawsMaterial = false }
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let model = w.environment.overlays.search
        model.liveDelay = nil
        #expect(w.router.perform(.search))
        for query in ["in:sent", "subject:budget", "has:attachment invoice"] {
            model.text = query
            model.submit()
        }
        model.text = ""
        #expect(w.router.perform(.search))
        try await until { OverlayFocusKeeper.control(of: w.window.firstResponder) is NSTextField }
        let editor = try #require(w.window.firstResponder as? NSTextView)
        try await until { !model.people.isEmpty && model.suggestions.first?.kind == .person && panelShown(w) }
        try await sweepShootWithChildWindows(w.window, screen: "search-panel-people-recents", theme: theme)

        editor.insertText("fro", replacementRange: editor.selectedRange())
        try await until { model.text == "fro" && model.completion?.title == "from:" && panelShown(w) }
        try await sweepShootWithChildWindows(w.window, screen: "search-panel-operator-ghost", theme: theme)

        editor.selectAll(nil)
        let person = try #require(model.people.first { $0.name != nil } ?? model.people.first)
        let typed = "from:" + String((person.name ?? person.email).prefix(2)).lowercased()
        editor.insertText(typed, replacementRange: editor.selectedRange())
        try await until {
            model.text == typed && model.suggestions.first?.kind == .person
                && model.contactPreview.contact?.email == model.suggestions.first?.email && panelShown(w)
        }
        try await sweepShootWithChildWindows(w.window, screen: "search-panel-person-preview", theme: theme)
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func searchSuggestionsPanelNarrow(_ theme: SweepTheme) async throws {
        SearchDropdownPanel.drawsMaterial = true
        defer { SearchDropdownPanel.drawsMaterial = false }
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme, size: NSSize(width: 640, height: 720))
        defer { w.close() }
        w.router.isLabelSidebarVisible = false
        let model = w.environment.overlays.search
        #expect(w.router.perform(.search))
        try await until { OverlayFocusKeeper.control(of: w.window.firstResponder) is NSTextField }
        let editor = try #require(w.window.firstResponder as? NSTextView)
        editor.insertText("su", replacementRange: editor.selectedRange())
        try await until { model.text == "su" && panelShown(w) }
        try await sweepShootWithChildWindows(w.window, screen: "search-panel-narrow", theme: theme)
    }
}

@MainActor
private func panelShown(_ w: InlineReplyWindow) -> Bool {
    (w.window.childWindows ?? []).contains { ($0 as? SearchDropdownPanelWindow)?.owner?.isVisible == true }
}

/// The window capture with its visible child panels drawn over it where they float.
@MainActor
func sweepShootWithChildWindows(_ window: NSWindow, screen: String, theme: SweepTheme,
                          settle: Duration = .milliseconds(400)) async throws {
    let directory = try SweepOutput.directory()
    try await Task.sleep(for: settle) // flake-ok: render settle before an off-screen capture, not a wait for a test result
    let base = try #require(NSImage(data: try sweepCapture(window)))
    let root = try sweepCaptureRoot(window)
    let size = root.bounds.size
    let composed = NSImage(size: size)
    composed.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: size))
    for child in window.childWindows ?? [] where child.isVisible {
        guard let content = child.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            continue
        }
        content.layoutSubtreeIfNeeded()
        content.cacheDisplay(in: content.bounds, to: rep)
        let origin = NSPoint(x: child.frame.minX - window.frame.minX, y: child.frame.minY - window.frame.minY)
        rep.draw(in: NSRect(origin: origin, size: child.frame.size), from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: false, hints: nil)
    }
    composed.unlockFocus()
    let tiff = try #require(composed.tiffRepresentation)
    let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    let name = "\(screen)--\(theme.slug)"
    try png.write(to: directory.appendingPathComponent(name + ".png"))
    try SweepIndex.record(SweepIndexEntry(screen: screen, theme: theme.name, file: name + ".png"), in: directory)
}
