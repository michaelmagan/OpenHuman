import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
@testable import MailUI
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct SearchSuggestionsPanelWindowTests {
    static let frameName = "dev.openhuman.tests.search-panel"

    enum Key {
        static let tab = ("\t", UInt16(48))
        static let returnKey = ("\r", UInt16(36))
        static let escape = ("\u{1B}", UInt16(53))
        static let down = ("\u{F701}", UInt16(125))
    }

    private func wait(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        do {
            try await until(timeout: testBackstop, condition)
        } catch {
            Issue.record("timed out waiting for \(what)")
            throw error
        }
    }

    private func draw(_ w: InlineReplyWindow) {
        w.window.contentView?.layoutSubtreeIfNeeded()
        w.window.displayIfNeeded()
    }

    /// Sends a key the way the window gets it: the key router first, then the first responder. True when the router
    /// took it.
    @discardableResult
    private func press(_ key: (String, UInt16), in w: InlineReplyWindow) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 100,
                                     windowNumber: w.window.windowNumber, context: nil, characters: key.0,
                                     charactersIgnoringModifiers: key.0, isARepeat: false, keyCode: key.1)!
        guard w.content.keyRouter.route(event) != nil else { return true }
        w.window.sendEvent(event)
        return false
    }

    private func panel(_ w: InlineReplyWindow) -> SearchDropdownPanel? {
        (w.window.childWindows ?? []).compactMap { ($0 as? SearchDropdownPanelWindow)?.owner }.first { $0.isVisible }
    }

    private func hasTheKeys(_ field: NSTextField, in w: InlineReplyWindow) -> Bool {
        OverlayFocusKeeper.control(of: w.window.firstResponder) === field
    }

    /// Opens search and types `text` into the toolbar field.
    private func open(typing text: String, in w: InlineReplyWindow) async throws -> (NSTextField, NSTextView) {
        let model = w.environment.overlays.search
        #expect(w.router.perform(.search))
        try await wait("the search field") { model.isOpen && w.content.searchField(in: w.window) != nil }
        // The toolbar can rebuild its items while the window settles, so this follows the field shown now
        try await wait("the field to take the keys") {
            w.content.searchField(in: w.window).map { hasTheKeys($0, in: w) } ?? false
        }
        let field = try #require(w.content.searchField(in: w.window))
        let editor = try #require(w.window.firstResponder as? NSTextView)
        if !text.isEmpty { editor.insertText(text, replacementRange: editor.selectedRange()) }
        try await wait("the query “\(text)”") { model.text == text }
        draw(w)
        return (field, editor)
    }

    private func results(for query: String, in w: InlineReplyWindow) async throws {
        try await wait("the results for “\(query)”") {
            w.environment.overlays.search.shownQuery == query && w.router.list?.location == .search(query)
                && w.router.list?.state == .loaded
        }
    }

    @Test func theSuggestionsFloatInAChildPanelUnderTheFieldAndMoveNothing() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        draw(w)
        let scroll = try #require(w.content.tableView.enclosingScrollView)
        let listFrame = scroll.convert(scroll.bounds, to: nil)
        let (field, _) = try await open(typing: "", in: w)
        try await wait("the suggestions panel") { panel(w)?.contentFrame != nil }
        let shown = try #require(panel(w))
        let window = try #require(w.window.childWindows?.first { ($0 as? SearchDropdownPanelWindow)?.owner === shown })
        #expect(!window.canBecomeKey && !window.canBecomeMain, "the field keeps the keys")
        #expect(window.identifier?.rawValue == SearchDropdownPanel.identifier)
        let frame = try #require(shown.contentFrame)
        let fieldFrame = try #require(field.window).convertToScreen(field.convert(field.bounds, to: nil))
        #expect(frame.maxY <= fieldFrame.minY, "under the field")
        #expect(w.window.frame.contains(frame), "inside the window")
        #expect(shown.placement?.showsSide == true, "the tips beside the list in a wide window")
        #expect(hasTheKeys(field, in: w))
        draw(w)
        let after = try #require(w.content.tableView.enclosingScrollView)
        #expect(after.convert(after.bounds, to: nil) == listFrame, "the list does not move")

        #expect(!press(Key.escape, in: w), "Esc goes to the field")
        try await wait("the first Esc to close the suggestions") { panel(w) == nil }
        #expect(w.environment.overlays.search.isOpen, "and keep the search")
        #expect(!press(Key.escape, in: w))
        try await wait("the next Esc to close the empty search") { !w.environment.overlays.search.isOpen }
    }

    /// The main window is never narrow enough to drop the tips with the field still in its toolbar (the toolbar moves
    /// the field into its overflow first), so the panel floats under a field-sized anchor in a narrow plain window.
    @Test func aNarrowWindowDropsTheTipsColumn() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let search = w.environment.overlays.search
        #expect(w.router.perform(.search))
        try await wait("the suggestions") { !search.suggestions.isEmpty }
        let narrow = NSWindow(contentRect: NSRect(x: -6000, y: -5000, width: 620, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        narrow.isReleasedWhenClosed = false
        let anchor = SearchDropdownAnchorView(frame: NSRect(x: 340, y: 760, width: NativeMetrics.Search.fieldWidth,
                                                            height: ShellMetrics.tabHeight))
        narrow.contentView?.addSubview(anchor)
        narrow.orderFrontRegardless()
        defer {
            anchor.panel.hide()
            narrow.orderOut(nil)
            narrow.close()
        }
        anchor.panel.show(SearchDropdownRequest(search: search, isPresented: true, cursor: 0, showsPreview: false,
                                                theme: .light, accept: { _ in }), below: anchor)
        let shown = anchor.panel
        #expect(shown.isVisible)
        #expect(shown.placement?.showsSide == false)
        let frame = try #require(shown.contentFrame)
        #expect(narrow.frame.contains(frame), "it stays inside the window")
    }

    /// Lets the main queue run `count` times.
    private func turns(_ count: Int) async {
        for _ in 0..<count {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { done.resume() }
            }
        }
    }

    /// SwiftUI updates the anchor for every keystroke and every result that loads. The updates only record the
    /// request; the panel follows once on the next turn, and nothing it reads or writes updates the anchor again.
    @Test func manyUpdatesOfTheAnchorBringThePanelUpToDateOnce() async throws {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 10, now: Date(timeIntervalSince1970: 1_791_000_000)),
                                      options: .init(remoteAck: .immediate))
        let router = env.router
        router.start()
        try await wait("the list") { router.list?.state == .loaded }
        // Typed text with its results loaded
        let search = env.overlays.search
        search.liveDelay = nil
        search.open()
        search.text = "re"
        search.submit()
        try await wait("the results for “re”") {
            router.list?.location == .search("re") && router.list?.state == .loaded
        }

        let ticks = AnchorTicks()
        let hosting = NSHostingView(rootView: AnchorTicksHost(search: search, ticks: ticks))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -5000, width: 900, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        hosting.layoutSubtreeIfNeeded()
        let anchor = try #require(subviews(of: SearchDropdownAnchorView.self, in: hosting).first)
        defer { anchor.panel.hide() }
        try await wait("the suggestions panel") { anchor.panel.isVisible }

        let clock = ContinuousClock()
        let start = clock.now
        let shown = anchor.refreshCount
        for _ in 0..<100 {
            ticks.count += 1
            hosting.layoutSubtreeIfNeeded()
        }
        #expect(anchor.refreshCount == shown, "the updates only record the request")
        await turns(5)
        anchor.keysChanged?(true)
        #expect(ticks.reported == 100, "the anchor has the newest request")
        #expect(anchor.refreshCount - shown <= 1, "the panel follows once for all of them")
        let settled = anchor.refreshCount
        await turns(20)
        #expect(anchor.refreshCount == settled, "nothing the panel did updates the anchor again")
        #expect(anchor.panel.isVisible)
        #expect(clock.now - start < .seconds(1))

        // Without SwiftUI: a hundred requests before the next turn are one
        let request = SearchDropdownRequest(search: search, isPresented: true, cursor: 1, showsPreview: false,
                                            theme: .light, accept: { _ in })
        for _ in 0..<100 { anchor.request = request }
        await turns(5)
        #expect(anchor.refreshCount == settled + 1)
        anchor.request = SearchDropdownRequest(search: search, isPresented: false, cursor: 0, showsPreview: false,
                                               theme: .light, accept: { _ in })
        await turns(5)
        #expect(!anchor.panel.isVisible)
    }

    @Test func tabTakesTheGhostCompletionWithTheListOpenOrClosed() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let model = w.environment.overlays.search
        let (field, editor) = try await open(typing: "fro", in: w)
        try await wait("the suggestions panel") { panel(w) != nil }
        #expect(model.completion?.title == "from:")
        #expect(press(Key.tab, in: w), "Tab is the completion's")
        #expect(model.text == "from:")
        #expect(editor.string == "from:" && editor.selectedRange() == NSRange(location: 5, length: 0), "caret at the end")
        #expect(hasTheKeys(field, in: w))

        editor.selectAll(nil)
        editor.insertText("su", replacementRange: editor.selectedRange())
        try await wait("the query “su”") { model.text == "su" }
        #expect(!press(Key.escape, in: w), "Esc closes the list")
        try await wait("the list to close") { panel(w) == nil }
        #expect(model.isOpen && model.text == "su")
        #expect(press(Key.tab, in: w), "the ghost alone still completes")
        #expect(model.text == "subject:")
    }

    @Test func tabTakesTheHighlightedPersonAsAPill() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let model = w.environment.overlays.search
        let (field, editor) = try await open(typing: "", in: w)
        try await wait("the people written to most") { !model.people.isEmpty }
        let person = try #require(model.people.first)
        let typed = "from:" + String(person.email.prefix(2))
        editor.insertText(typed, replacementRange: editor.selectedRange())
        try await wait("the people matching “\(typed)”") {
            model.text == typed && model.suggestions.contains { $0.email == person.email }
        }
        draw(w)
        let index = try #require(model.suggestions.firstIndex { $0.email == person.email })
        for _ in 0..<index { #expect(press(Key.down, in: w) == false) }
        try await wait("the person to be highlighted") { model.completion?.email == person.email }
        #expect(press(Key.tab, in: w))
        #expect(model.text == "from:\(person.email) ")
        try await wait("the pill") {
            draw(w)
            return field.stringValue.isEmpty
        }
        #expect(SearchQueryTokens.pillCount(model.text) == 1)
        #expect(hasTheKeys(field, in: w))
    }

    @Test func returnRunsTheSearchAndSelectsTheFirstResultThenEscLeaves() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let model = w.environment.overlays.search
        let state = try #require(w.router.active)
        let origin = try #require(state.location)
        let (field, _) = try await open(typing: "re", in: w)
        try await results(for: "re", in: w)
        let rows = try #require(w.router.list?.rows)
        try #require(rows.count >= 2)
        w.router.list?.setCursor(rows[1].id)

        #expect(!press(Key.returnKey, in: w), "Return goes to the field")
        try await wait("the results to take the keys") { w.window.firstResponder === w.content.tableView }
        #expect(w.router.list?.cursor == rows.first?.id, "the first result is selected")
        #expect(model.text == "re" && field.stringValue == "re", "the query stays in the field")
        try await wait("the suggestions to close") { panel(w) == nil }
        #expect(press(Key.down, in: w), "the next keys act on the results")
        #expect(w.router.list?.cursor == rows[1].id)

        #expect(press(Key.escape, in: w), "Esc in the results is the list's")
        #expect(!model.isOpen, "and leaves the search")
        #expect(state.location == origin)
        try await wait("the list to keep the keys") { w.window.firstResponder === w.content.tableView }
    }

    @Test func returnWithNoResultsKeepsTheField() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let (field, _) = try await open(typing: "zzqxnomatch", in: w)
        #expect(!press(Key.returnKey, in: w))
        try await results(for: "zzqxnomatch", in: w)
        #expect(w.router.list?.rows.isEmpty == true)
        draw(w)
        #expect(hasTheKeys(field, in: w), "nothing to select: the field keeps the keys")
    }

    @Test func escLeavesAnOpenSearchFromTheListWithNothingTyped() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let model = w.environment.overlays.search
        let origin = try #require(w.router.active?.location)
        _ = try await open(typing: "", in: w)
        #expect(w.window.makeFirstResponder(w.content.tableView), "a click in the list")
        #expect(press(Key.escape, in: w))
        #expect(!model.isOpen && w.router.active?.location == origin)
        #expect(w.window.firstResponder === w.content.tableView)
    }

    @Test func escLeavesTheSearchFromAnEmptyPartOfTheWindow() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let model = w.environment.overlays.search
        let origin = try #require(w.router.active?.location)
        _ = try await open(typing: "re", in: w)
        try await results(for: "re", in: w)
        #expect(w.window.makeFirstResponder(nil), "nothing has the keys")
        #expect(press(Key.escape, in: w))
        #expect(!model.isOpen && w.router.active?.location == origin)
        try await wait("the list to take the keys") { w.window.firstResponder === w.content.tableView }
    }

    @Test func escInAResultGoesBackToTheResultsThenLeaves() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let model = w.environment.overlays.search
        let origin = try #require(w.router.active?.location)
        _ = try await open(typing: "re", in: w)
        try await results(for: "re", in: w)
        let result = try #require(w.router.list?.rows.first?.id)
        _ = try await w.open(result)
        #expect(press(Key.escape, in: w), "Esc in the conversation goes back")
        try await wait("the results") { w.router.mode == .list }
        #expect(model.isOpen && model.shownQuery == "re", "to the results")
        try await wait("the list to take the keys") { w.window.firstResponder === w.content.tableView }
        #expect(press(Key.escape, in: w))
        #expect(!model.isOpen && w.router.active?.location == origin, "the next Esc leaves the search")
    }

    @Test func escWithAnOverlayOpenIsTheOverlays() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let model = w.environment.overlays.search
        _ = try await open(typing: "re", in: w)
        try await results(for: "re", in: w)
        #expect(w.window.makeFirstResponder(w.content.tableView))
        #expect(w.router.perform(.commandPalette))
        #expect(w.environment.overlays.isShowing)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 100,
                                     windowNumber: w.window.windowNumber, context: nil, characters: Key.escape.0,
                                     charactersIgnoringModifiers: Key.escape.0, isARepeat: false, keyCode: Key.escape.1)!
        _ = w.content.keyRouter.route(event)
        #expect(model.isOpen, "the list's Esc is not routed under an overlay")
        w.environment.overlays.dismiss()
    }
}

@MainActor @Observable
private final class AnchorTicks {
    var count = 0
    @ObservationIgnored var reported = -1
}

/// The suggestions anchor under a field-sized frame, rebuilt with an equal request each time `ticks` counts up.
private struct AnchorTicksHost: View {
    let search: SearchModel
    let ticks: AnchorTicks

    var body: some View {
        let count = ticks.count
        VStack(spacing: 0) {
            SearchDropdownPanelAnchor(request: SearchDropdownRequest(
                search: search, isPresented: true, cursor: 0, showsPreview: false, theme: .light, accept: { _ in },
                keysChanged: { [ticks] _ in ticks.reported = count }))
                .frame(width: NativeMetrics.Search.fieldWidth, height: ShellMetrics.tabHeight)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
