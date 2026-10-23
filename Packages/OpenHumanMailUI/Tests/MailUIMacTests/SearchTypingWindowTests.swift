import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct SearchTypingWindowTests {
    static let frameName = "dev.openhuman.tests.search-typing"

    private func open(in w: InlineReplyWindow) async throws -> NSTextField {
        #expect(w.router.perform(.search))
        try await until { w.content.searchField(in: w.window) != nil }
        let field = try #require(w.content.searchField(in: w.window))
        try await until { hasTheKeys(field, in: w) }
        return field
    }

    private func hasTheKeys(_ field: NSTextField, in w: InlineReplyWindow) -> Bool {
        OverlayFocusKeeper.control(of: w.window.firstResponder) === field
    }

    private func type(_ text: String, into field: NSTextField, in w: InlineReplyWindow) throws {
        for character in text {
            #expect(try !typingKey(String(character), in: w), "the router passes typed letters on")
            #expect(hasTheKeys(field, in: w))
        }
    }

    private func expectNoAction(in w: InlineReplyWindow) {
        #expect(w.environment.undo?.canUndo != true)
        #expect(w.environment.notices.toasts.isEmpty)
        #expect(!w.environment.overlays.isShowing)
        #expect(w.environment.composeIfStarted?.sessions.isEmpty != false)
        #expect(w.router.mode == .list)
        #expect(w.router.reader == nil)
    }

    @Test(arguments: ["all", "inbox", "label"])
    func typingOnlyEditsTheField(location: String) async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        switch location {
        case "all": w.router.go(to: .system(.allMail))
        case "inbox": w.router.go(to: .system(.inbox))
        default:
            let label = try #require(w.router.active?.labels.first { $0.kind == .user })
            w.router.go(to: .label(label.labelID))
        }
        try await until { w.router.list?.state == .loaded && (w.router.list?.rows.count ?? 0) >= 2 }
        let list = try #require(w.router.list)
        list.setCursor(list.rows[0].id)
        #expect(list.toggleCheck(list.rows[1].id))
        let cursor = list.cursor
        let checked = list.selection.checked
        let location = w.router.location
        let rows = list.rows.map(\.id)
        w.environment.overlays.search.liveDelay = nil
        let field = try await open(in: w)
        try type("er#jkslcz", into: field, in: w)
        #expect(w.environment.overlays.search.text == "er#jkslcz")
        #expect((w.window.firstResponder as? NSTextView)?.string.hasSuffix("er#jkslcz") == true)
        #expect(list.cursor == cursor)
        #expect(list.selection.checked == checked)
        #expect(w.router.location == location)
        #expect(list.rows.map(\.id) == rows)
        expectNoAction(in: w)
    }

    @Test func resultsLoadingKeepsTheKeysInTheField() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        w.router.go(to: .system(.allMail))
        try await until { w.router.list?.state == .loaded }
        let search = w.environment.overlays.search
        search.liveDelay = .milliseconds(1)
        let field = try await open(in: w)
        try type("re", into: field, in: w)
        try await until { search.shownQuery == "re" }
        try type("jek", into: field, in: w)
        try await until { search.shownQuery == "rejek" && w.router.list?.state == .loaded }
        #expect(hasTheKeys(field, in: w))
        #expect(search.text == "rejek")
        expectNoAction(in: w)
    }

    @Test func syncRefreshKeepsTheKeysInTheField() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        w.router.go(to: .system(.allMail))
        try await until { w.router.list?.state == .loaded }
        w.environment.overlays.search.liveDelay = nil
        let field = try await open(in: w)
        let rows = w.router.list?.rows.map(\.id)
        let store = try #require(w.environment.data as? FakeMailStore)
        let account = try #require(w.router.active?.account.id)
        store.deliverMessage(account: account, from: EmailAddress(name: "Sender", email: "sender@example.com"),
                             subject: "A new conversation")
        try await until { w.router.list?.rows.map(\.id) != rows }
        #expect(hasTheKeys(field, in: w))
        try type("e", into: field, in: w)
        #expect(w.environment.overlays.search.text == "e")
        expectNoAction(in: w)
    }

    @Test func themeChangeKeepsTheKeysInTheField() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        w.environment.overlays.search.liveDelay = nil
        let field = try await open(in: w)
        let preferences = MemoryThemePreferencesStore(ThemePreferences(mode: .dark))
        let theme = ThemeStore(preferencesStore: preferences).resolved.tokens
        #expect(theme != w.content.theme)
        w.content.apply(theme: theme)
        // The render that the theme change runs must leave the keys in the field.
        try await until { hasTheKeys(field, in: w) }
        #expect(hasTheKeys(field, in: w))
        try type("e", into: field, in: w)
        #expect(w.environment.overlays.search.text == "e")
        expectNoAction(in: w)
    }

    @Test func listShortcutsStillMoveAndMarkDone() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        try await until {
            w.window.firstResponder === w.content.tableView && w.router.list?.cursor != nil
                && (w.router.list?.rows.count ?? 0) >= 2
        }
        let list = try #require(w.router.list)
        list.setCursor(list.rows[0].id)
        let next = list.rows[1].id
        #expect(!w.environment.overlays.search.isOpen)
        _ = try typingKey("j", in: w)
        try await until { list.cursor == next }
        _ = try typingKey("e", in: w)
        try await until { !list.rows.contains { $0.id == next } && w.environment.undo?.canUndo == true }
    }
}

@MainActor
@discardableResult
func typingKey(_ character: String, in w: InlineReplyWindow) throws -> Bool {
    let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "#": 20,
        "o": 31, "u": 32, "i": 34, "p": 35, "\r": 36, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, " ": 49
    ]
    let code = try #require(codes[character])
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: character == "#" ? .shift : [], timestamp: 100,
        windowNumber: w.window.windowNumber, context: nil, characters: character,
        charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
    let consumed = w.content.keyRouter.route(event) == nil
    if !consumed { w.window.sendEvent(event) }
    return consumed
}
