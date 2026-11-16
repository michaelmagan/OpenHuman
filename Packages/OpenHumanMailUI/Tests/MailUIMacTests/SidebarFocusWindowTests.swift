import AppKit
import MailActions
import MailFeatures
import MailModel
@testable import MailUI
import Testing
@testable import MailUIMac

/// ← in the list gives the sidebar the keys: ↑ ↓ and J K move its highlight, Return opens it, and Esc goes back to
/// the list without opening anything.
@MainActor
@Suite(.serialized) struct SidebarFocusWindowTests {
    static let frameName = "dev.openhuman.tests.sidebar-focus"

    enum Key {
        case left, right, up, down, enter, escape, j, k, e
        case controlCommandS

        var event: (chars: String, code: UInt16, modifiers: NSEvent.ModifierFlags) {
            switch self {
            case .left: ("\u{F702}", 123, [])
            case .right: ("\u{F703}", 124, [])
            case .up: ("\u{F700}", 126, [])
            case .down: ("\u{F701}", 125, [])
            case .enter: ("\r", 36, [])
            case .escape: ("\u{1B}", 53, [])
            case .j: ("j", 38, [])
            case .k: ("k", 40, [])
            case .e: ("e", 14, [])
            case .controlCommandS: ("s", 1, [.control, .command])
            }
        }
    }

    /// Delivers a key the way the app does: the key router first, then the first responder if the router passed it on.
    /// Returns whether the router consumed it.
    @discardableResult
    func press(_ key: Key, in w: InlineReplyWindow) -> Bool {
        let (chars, code, modifiers) = key.event
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.window.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code)!
        guard let passed = w.content.keyRouter.route(event) else { return true }
        w.window.firstResponder?.keyDown(with: passed)
        return false
    }

    func listHasTheKeys(_ w: InlineReplyWindow) async throws {
        w.window.makeFirstResponder(w.content.tableView)
        try await until { w.window.firstResponder === w.content.tableView }
    }

    func enterSidebar(_ w: InlineReplyWindow) async throws -> NSTableView {
        #expect(press(.left, in: w), "← in the list is the sidebar's")
        let sidebar = try #require(w.content.sidebarTable())
        try await until { w.window.firstResponder === sidebar && w.router.sidebarHasKeys }
        #expect(w.content.keyRouter.scopeStack == [.sidebar, .global])
        return sidebar
    }

    @Test func upAndDownMoveTheHighlightAndReturnOpensIt() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, exclusive: true)
        defer { w.close() }
        try await listHasTheKeys(w)
        let start = try #require(w.router.active?.location)
        let sidebar = try await enterSidebar(w)
        let first = sidebar.selectedRow
        #expect(first >= 0, "the current place is selected when the sidebar takes the keys")

        #expect(!press(.down, in: w), "↓ is the sidebar list's own")
        try await until { w.router.sidebarHighlight != nil }
        #expect(sidebar.selectedRow > first, "↓ moved the selection")
        #expect(w.router.active?.location == start, "moving does not open anything")
        #expect(w.window.firstResponder === sidebar)

        #expect(press(.j, in: w), "j moves down in the sidebar")
        try await until { sidebar.selectedRow > first + 1 }
        #expect(press(.k, in: w), "k moves up")
        try await until { sidebar.selectedRow == first + 1 }
        #expect(!press(.up, in: w))
        try await until { sidebar.selectedRow == first }
        #expect(w.router.sidebarHighlight == nil, "back on the current place: nothing to open")
        #expect(!press(.down, in: w))
        try await until { w.router.sidebarHighlight != nil }
        let target = try #require(w.router.sidebarHighlight)
        #expect(w.router.active?.location == start)

        #expect(press(.enter, in: w), "Return opens the highlighted row")
        try await until { MailSidebarModel.current(w.router) == target }
        try await until { w.window.firstResponder === w.content.tableView }
        #expect(!w.router.sidebarHasKeys && w.router.sidebarHighlight == nil)
        #expect(w.content.keyRouter.scopeStack == [.list, .global], "the list has its keys back")
        #expect(w.router.active?.location != start)
    }

    @Test func escLeavesWithoutOpeningAndRightStaysTheSidebars() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, exclusive: true)
        defer { w.close() }
        let start = try #require(w.router.active?.location)
        try await listHasTheKeys(w)
        let sidebar = try await enterSidebar(w)
        #expect(!press(.right, in: w), "→ is the sidebar list's own: it unfolds a nested label")
        #expect(w.window.firstResponder === sidebar && w.router.sidebarHasKeys)
        #expect(!press(.down, in: w))
        try await until { w.router.sidebarHighlight != nil }
        #expect(press(.escape, in: w), "Esc leaves the sidebar")
        try await until { w.window.firstResponder === w.content.tableView }
        #expect(w.router.active?.location == start, "Esc opens nothing")
        #expect(w.router.sidebarHighlight == nil && !w.router.sidebarHasKeys)
        #expect(MailSidebarModel.shown(w.router) == MailSidebarModel.current(w.router), "the selection is back")
    }

    @Test func leftShowsAHiddenSidebarAndHidingItGivesTheListTheKeys() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, exclusive: true)
        defer { w.close() }
        try await listHasTheKeys(w)
        #expect(press(.controlCommandS, in: w))
        #expect(!w.router.isLabelSidebarVisible)
        let sidebar = try await enterSidebar(w)
        #expect(w.router.isLabelSidebarVisible, "← shows the sidebar")
        let rows = w.router.list?.rows.count
        #expect(!press(.e, in: w), "the list's e (Done) does not act while the sidebar has the keys")
        #expect(w.router.list?.rows.count == rows && w.environment.notices.toasts.isEmpty)

        #expect(press(.controlCommandS, in: w), "⌃⌘S still hides it")
        try await until { w.window.firstResponder === w.content.tableView }
        #expect(!w.router.sidebarHasKeys)
        #expect(w.window.firstResponder !== sidebar)
    }

    @Test func aClickOnARowOpensItAndGivesTheListTheKeys() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, exclusive: true)
        defer { w.close() }
        let account = try #require(w.router.active?.id)
        w.router.sidebarHasKeys = true
        MailSidebarModel.choose(.location(account, .system(.starred)), router: w.router, byPointer: true)
        #expect(w.router.active?.location == .system(.starred), "a click opens the row")
        #expect(w.router.sidebarHighlight == nil)
        MailSidebarModel.choose(.location(account, .system(.sent)), router: w.router, byPointer: false)
        #expect(w.router.active?.location == .system(.starred), "a key only highlights")
        #expect(w.router.sidebarHighlight == .location(account, .system(.sent)))
        w.router.sidebarHasKeys = false
        #expect(w.router.sidebarHighlight == nil, "losing the keys drops the highlight")
        MailSidebarModel.choose(.location(account, .system(.sent)), router: w.router, byPointer: false)
        #expect(w.router.active?.location == .system(.sent), "without the keys a selection opens at once")
    }
}
