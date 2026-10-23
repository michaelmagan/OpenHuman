import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

private let now = Date(timeIntervalSince1970: 1_791_000_000)

@MainActor
@Suite(.serialized)
struct ShellWindowTests {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1000, height: 700), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)

    init() { window.isReleasedWhenClosed = false }

    func key(_ chars: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], at time: TimeInterval = 100) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: time,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func catalogTableRoutesTheShellKeys() {
        let router = KeyRouter.catalog()
        let target = window
        router.isMailWindow = { $0 === target }
        var scopes: [ActionScope] = [.list, .global]
        router.activeScopes = { scopes }
        var performed: [ActionID] = []
        var inlineRowReady = false
        let inlineKeys: Set<ActionID> = [.aiUseInlineReply, .aiNextInlineReply, .aiPreviousInlineReply]
        router.perform = { action, _ in
            if inlineKeys.contains(action), !inlineRowReady { return false }
            performed.append(action)
            return true
        }
        var hints: [KeyChord?] = []
        router.onPendingSequence = { hints.append($0) }

        #expect(router.route(key("e", code: 14)) == nil)
        #expect(router.route(key("#", code: 20, modifiers: .shift)) == nil)
        #expect(router.route(key("\t", code: 48)) == nil)
        #expect(router.route(key("\u{19}", code: 48, modifiers: .shift)) == nil)
        #expect(router.route(key("1", code: 18, modifiers: .control)) == nil)
        #expect(router.route(key("z", code: 6, modifiers: .command)) == nil)
        #expect(router.route(key("Z", code: 6, modifiers: [.command, .shift])) == nil)
        #expect(router.route(key("s", code: 1, modifiers: [.control, .command])) == nil)
        #expect(performed == [.markDone, .trash, .nextSplit, .previousSplit, .switchToAccount(1), .undo, .redo,
                              .toggleLabelSidebar])

        performed = []
        #expect(router.route(key("g", code: 5, at: 200)) == nil)
        #expect(hints.last == .char("g"))
        #expect(router.route(key("i", code: 34, at: 200.6)) == nil)
        #expect(hints.last == .some(nil))
        #expect(performed == [.goInbox])
        #expect(router.route(key("g", code: 5, at: 300)) == nil)
        #expect(router.route(key("q", code: 12, at: 301.5)) != nil)
        #expect(router.route(key("g", code: 5, at: 400)) == nil)
        #expect(router.route(key("\u{1B}", code: 53, at: 400.2)) == nil)
        #expect(router.route(key("g", code: 5, at: 500)) == nil)
        #expect(router.route(key("j", code: 38, at: 500.2)) == nil)
        #expect(performed == [.goInbox, .nextThread])

        performed = []
        scopes = [.reader, .global]
        #expect(router.route(key("\u{F701}", code: 125)) == nil)
        #expect(router.route(key("\u{F700}", code: 126)) == nil)
        #expect(router.route(key("\u{1B}", code: 53)) == nil)
        #expect(router.route(key("\t", code: 48)) != nil, "⇥ passes through without suggested replies")
        #expect(router.route(key("\u{F702}", code: 123)) != nil, "← passes through without suggested replies")
        #expect(performed == [.nextMessage, .previousMessage, .backToList])
        performed = []
        inlineRowReady = true
        #expect(router.route(key("\t", code: 48)) == nil)
        #expect(router.route(key("\u{F703}", code: 124)) == nil)
        #expect(router.route(key("\u{F702}", code: 123)) == nil)
        #expect(performed == [.aiUseInlineReply, .aiNextInlineReply, .aiPreviousInlineReply])
        inlineRowReady = false
        performed = []
        scopes = [.list, .global]
        #expect(router.route(key("\u{F701}", code: 125)) == nil)
        #expect(router.route(key("\u{F700}", code: 126)) == nil)
        #expect(performed == [.nextThread, .previousThread])
    }

    @Test func switchingAccountsKeepsEachListsScrollPosition() async throws {
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 400, now: now))
        let content = MainContentViewController(environment: environment)
        let router = content.router
        window.setContentSize(NSSize(width: 1000, height: 400))
        window.contentView = content.view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        content.keyRouter.isMailWindow = { [window] in $0 === window }
        try await until { router.accounts.count == 2 && router.list?.state == .loaded }
        router.go(to: .system(.allMail))
        try await until { (router.list?.rows.count ?? 0) >= 100 && content.tableView.numberOfRows >= 100 }
        let rows = try #require(router.list?.rows.map(\.id))
        router.list?.setCursor(rows[45])
        try await until { content.tableView.selectedRow == 45 }
        let scroll = try #require(content.tableView.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 40 * content.tableView.rowHeight))
        scroll.reflectScrolledClipView(scroll.contentView)
        let workTop = try #require(content.topVisibleKey)
        #expect(router.list?.index(of: workTop) == 40)

        #expect(content.keyRouter.route(key("2", code: 19, modifiers: .control)) == nil)
        try await until { router.active?.account.alias == "Personal" && router.list?.state == .loaded }
        try await until { content.tableView.numberOfRows == router.list?.rows.count }
        #expect(content.topVisibleKey != workTop)

        #expect(content.keyRouter.route(key("1", code: 18, modifiers: .control)) == nil)
        try await until { content.topVisibleKey == workTop }
        #expect(router.location == .system(.allMail))
        #expect(router.list?.cursor == rows[45])
    }

    @Test func aThemeChangeKeepsThePlace() async throws {
        let environment = AppEnvironment.fake(corpus: .make(threadCount: 30, now: now))
        let content = MainContentViewController(router: AppRouter(environment: environment))
        let router = content.router
        window.contentView = content.view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await until { router.list?.rows.count == 30 && content.tableView.numberOfRows == 30 }
        router.perform(.nextThread)
        router.perform(.nextThread)
        router.perform(.openThread)
        let open = try #require(router.reader?.thread)
        let oldTable = content.tableView
        content.apply(theme: .dark)
        #expect(content.theme == .dark)
        #expect(content.tableView === oldTable, "the list re-styles in place, no reload")
        #expect(content.tableView.backgroundColor == ThemeTokens.dark.bgWindow.nsColor)
        #expect(router.reader?.thread == open)
        #expect(router.mode == .reader)
        try await until { content.tableView.numberOfRows == 30 }
        router.perform(.backToList)
        #expect(router.list?.cursorIndex == 2)
        try await until { content.tableView.selectedRow == 2 }
    }

    @Test func windowHooksFollowTheThemeAndRememberTheFrame() {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        MainWindowHooks.configure(window, theme: .dark)
        #expect(window.appearance?.name == .darkAqua)
        #expect(window.frameAutosaveName == MainWindowHooks.frameAutosaveName,
                "held by \(NSApp.windows.filter { $0 !== window && $0.frameAutosaveName == MainWindowHooks.frameAutosaveName }.map(\.frame))")
        MainWindowHooks.configure(window, theme: .light)
        #expect(window.appearance?.name == .aqua)
        window.setFrameAutosaveName("")
    }

    @Test func theHookViewClaimsTheFrameNameOnlyWhenItReachesTheWindow() {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        #expect(window.setFrameAutosaveName("dev.openhuman.tests.window-hook-view"))
        let view = WindowHookView(theme: .light, router: AppEnvironment.fake(corpus: .small).router)
        window.contentView = view
        #expect(window.frameAutosaveName == "dev.openhuman.tests.window-hook-view" && window.appearance?.name == .aqua)
        window.setFrameAutosaveName("")
        view.theme = .dark
        view.applyToWindow()
        #expect(window.appearance?.name == .darkAqua)
        #expect(window.frameAutosaveName.isEmpty, "a later update does not take the main frame name")
    }

    @Test func theWindowRootFollowsTheThemeStore() async throws {
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 60, now: now))
        let themes = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light)))
        var attached: MainContentViewController?
        let hosting = NSHostingView(rootView: MainWindowRoot(environment: environment, themes: themes) { attached = $0 })
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        #expect(window.setFrameAutosaveName("dev.openhuman.tests.shell-window-root"))
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await until { attached != nil && environment.router.list?.state == .loaded }
        let content = try #require(attached)
        try await until { window.appearance?.name == .aqua }
        #expect(content.theme == themes.resolved.tokens)

        themes.preferences.mode = .dark
        try await until { window.appearance?.name == .darkAqua }
        try await until { content.theme == themes.resolved.tokens }
        #expect(themes.resolved.appearance == .dark)
        #expect(content.tableView.backgroundColor == themes.resolved.tokens.bgWindow.nsColor)

        environment.router.go(to: .system(.allMail))
        themes.preferences.mode = .light
        try await until { window.appearance?.name == .aqua && content.theme == themes.resolved.tokens }
        window.setFrameAutosaveName("")
    }

    @Test func theWindowRootInstallsTheThemeCommands() async throws {
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 20, now: now))
        let themes = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light)))
        _ = MainWindowRoot(environment: environment, themes: themes)
        #expect(environment.actions.contains(.themeDark))
        #expect(environment.router.perform(.themeDark, source: .menu))
        #expect(themes.preferences.mode == .dark)
        #expect(environment.router.perform(.themeAccent("pine"), source: .menu))
        #expect(themes.resolved.accentID == "pine")
        #expect(environment.router.isEnabled(.themeSystem))
        #expect(!MailCommands.menuDescriptors(.view).contains { $0.id.rawValue.hasPrefix("theme.") })
        #expect([AppearanceMode.light, .dark, .system].map(\.menuTitle) == ["Light", "Dark", "System"])
    }

    @Test func menuKeyEquivalentsAreOnlyCommandAndControlChords() {
        func shortcut(_ id: ActionID) -> KeyboardShortcut? {
            ActionCatalog.descriptor(id).flatMap(MailCommands.keyboardShortcut(for:))
        }
        #expect(shortcut(.switchToAccount(2)) == KeyboardShortcut("2", modifiers: .control))
        #expect(shortcut(.toggleLabelSidebar) == KeyboardShortcut("s", modifiers: [.control, .command]))
        #expect(shortcut(.markDone) == nil, "single keys are never key equivalents")
        #expect(shortcut(.goInbox) == nil)
        #expect(shortcut(.undo) == nil, "⌘Z stays the Edit menu's text undo; the key router handles mail undo")
        #expect(shortcut(.redo) == nil)
        #expect(shortcut(.search) == nil, "⌘F is the list's Search only; a key equivalent would take it everywhere")
        #expect(shortcut(.findInConversation) == nil && shortcut(.unsubscribe) == nil)
        for id in ActionCatalog.formatIDs { #expect(shortcut(id) == nil, "\(id): the body's own key") }
        #expect(shortcut(.compose) == KeyboardShortcut("n", modifiers: .command), "File › New message")
        #expect(MailCommands.messageMenuComposeDescriptors.map(\.id) == [.reply, .replyAll, .forward])
        #expect(MailCommands.formatMenuDescriptors.map(\.id) == ActionCatalog.formatIDs)
        #expect(MailCommands.fileMenuIDs == [.compose, .composeInWindow])
        let listed = Set([ActionCategory.compose, .thread, .app, .navigation, .view].flatMap { MailCommands.menuDescriptors($0) }
            .map(\.id))
        for descriptor in ActionCatalog.all where descriptor.id.accountPosition == nil && descriptor.appearsInMenu {
            #expect(listed.contains(descriptor.id), "\(descriptor.id) is in no menu")
        }
    }

    @Test func singleKeyHintsAreRightAlignedInMenuTitles() throws {
        let hints = MenuShortcutHints()
        let menu = NSMenu(title: "Message")
        let done = menu.addItem(withTitle: "Mark done", action: nil, keyEquivalent: "")
        let inbox = menu.addItem(withTitle: "Go to Inbox", action: nil, keyEquivalent: "")
        let sidebar = menu.addItem(withTitle: "Label Sidebar", action: nil, keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.control, .command]
        let other = menu.addItem(withTitle: "Something else", action: nil, keyEquivalent: "")
        let main = NSMenu(title: "Main")
        main.addItem(withTitle: "Message", action: nil, keyEquivalent: "").submenu = menu
        hints.apply(to: main)
        #expect(done.attributedTitle?.string == "Mark done\tE")
        #expect(inbox.attributedTitle?.string == "Go to Inbox\tG I")
        let style = try #require(done.attributedTitle?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.tabStops.first?.alignment == .right)
        #expect(sidebar.attributedTitle == nil, "key-equivalent items keep AppKit's own shortcut column")
        #expect(other.attributedTitle == nil)
        #expect(hints.hint(for: "Trash") == "#, ⌫", "every key of the action (message focus)")
        let (replyReturn, replyAllReturn) = ActionCatalog.returnRepliesAll ? ("⇧↵", "↵") : ("↵", "⇧↵")
        #expect(hints.hint(for: "Reply") == "R, \(replyReturn)" && hints.hint(for: "Reply all") == "A, \(replyAllReturn)")
        #expect(hints.hint(for: "Undo Last Action") == "⌘Z, Z" && hints.hint(for: "Redo Last Action") == "⇧⌘Z")
        #expect(hints.hint(for: "Search") == "/, ⌘F" && hints.hint(for: "Unsubscribe…") == "⌘U")
        #expect(hints.hint(for: "Bold") == "⌘B" && hints.hint(for: "Numbered list") == "⇧⌘7")
        #expect(hints.hint(for: "Find in conversation") == "⌘F")
    }
}

@MainActor
@Suite struct RealKeyEventTests {
    func event(_ keyCode: CGKeyCode, _ flags: CGEventFlags) throws -> NSEvent {
        let source = CGEventSource(stateID: .privateState)
        let cg = try #require(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true))
        cg.flags = flags
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test func shiftCommandZIsCapitalZAndShiftTabKeepsShift() throws {
        let redo = try event(6, [.maskCommand, .maskShift])
        #expect(redo.charactersIgnoringModifiers == "Z")
        #expect(KeyChord(event: redo) == KeyChord(.character("Z"), modifiers: .command))
        let undo = try event(6, [.maskCommand])
        #expect(KeyChord(event: undo) == KeyChord(.character("z"), modifiers: .command))
        let backTab = try event(48, [.maskShift])
        #expect(KeyChord(event: backTab) == KeyChord(.named(.tab), modifiers: .shift))
        let control1 = try event(18, [.maskControl])
        #expect(control1.charactersIgnoringModifiers == "1")
        #expect(KeyChord(event: control1) == KeyChord(.character("1"), modifiers: .control))
        let table = CatalogKeyTable.build()
        #expect(table.bindings[.global]?[KeyChord(event: redo)!] == .redo)
        #expect(table.bindings[.list]?[KeyChord(event: backTab)!] == .previousSplit)
        #expect(table.bindings[.global]?[KeyChord(event: control1)!] == .switchToAccount(1))
    }

    @Test func plusAndMinusReachTheImportanceActions() throws {
        let plus = try event(24, [.maskShift])
        #expect(plus.charactersIgnoringModifiers == "+")
        let plusChord = try #require(KeyChord(event: plus))
        #expect(plusChord == KeyChord(.character("+")), "⇧ is part of the character, as for # and !")
        let table = CatalogKeyTable.build()
        for scope in [ActionScope.list, .reader] {
            #expect(table.bindings[scope]?[plusChord] == .alwaysImportantSender)
            #expect(table.bindings[scope]?[KeyChord(.character("-"))] == .neverImportantDomain)
        }
        let zoomIn = try #require(KeyChord(event: try event(24, [.maskCommand])))
        #expect(table.bindings[.reader]?[zoomIn] == nil && table.bindings[.global]?[zoomIn] == nil)
    }
}
