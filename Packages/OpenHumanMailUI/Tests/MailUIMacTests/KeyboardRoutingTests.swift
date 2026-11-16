import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import Testing
import WebKit
@testable import MailUIMac

@MainActor
@Suite(.timeLimit(.minutes(2))) struct KeyboardRoutingTests {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 500, height: 400), styleMask: [.titled],
                          backing: .buffered, defer: false)

    init() { window.isReleasedWhenClosed = false }

    struct Fixture {
        let env: AppEnvironment
        let router: AppRouter
        let keys: KeyRouter
    }

    func fixture(options: FakeMailStore.Options = .init(remoteAck: .immediate),
                 flags: FeatureFlags = FeatureFlags()) async -> Fixture {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 10, now: Date(timeIntervalSince1970: 1_791_000_000)),
                                      options: options, featureFlags: flags, notices: NoticeCenter(autoExpire: false))
        let router = AppRouter(environment: env)
        router.start()
        await untilObserved { router.list?.rows.count == 10 }
        let keys = KeyRouter.catalog(env.actions.descriptors)
        let target = window
        keys.isMailWindow = { $0 === target }
        keys.activeScopes = { router.mode == .reader ? [.reader, .global] : [.list, .global] }
        keys.perform = { action, _ in router.perform(action) }
        return Fixture(env: env, router: router, keys: keys)
    }

    func key(_ chars: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], at time: TimeInterval = 100,
             repeat isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: time,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: isARepeat, keyCode: code)!
    }

    @Test func eInTheListMarksDone() async {
        let f = await fixture()
        let first = f.router.list?.cursor
        #expect(f.keys.route(key("e", code: 14)) == nil, "consumed")
        await f.env.actions.lastTask?.value
        #expect(f.env.notices.toasts.contains { $0.message == "Marked done" })
        await untilObserved { f.router.list?.rows.count == 9 }
        #expect(f.router.list?.row(for: first!) == nil)
        #expect(f.keys.route(key("⌫", code: 51)) == nil, "⌫ trashes")
        await f.env.actions.lastTask?.value
        await untilObserved { f.router.list?.rows.count == 8 }
    }

    @Test func eWhileTypingDoesNothing() async {
        let f = await fixture()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        #expect(KeyRouter.isTextInput(window.firstResponder))
        #expect(f.keys.route(key("e", code: 14)) != nil)
        let composer = NSTextView(frame: NSRect(x: 0, y: 30, width: 200, height: 100))
        window.contentView?.addSubview(composer)
        #expect(window.makeFirstResponder(composer))
        #expect(f.keys.route(key("e", code: 14)) != nil)
        #expect(f.keys.route(key("#", code: 20, modifiers: .shift)) != nil)
        #expect(f.keys.route(key("z", code: 6, modifiers: .command)) != nil, "⌘Z is the text view's own undo")
        final class Composing: NSTextView { override func hasMarkedText() -> Bool { true } }
        let ime = Composing(frame: NSRect(x: 0, y: 140, width: 200, height: 40))
        ime.isEditable = false
        window.contentView?.addSubview(ime)
        #expect(window.makeFirstResponder(ime))
        #expect(f.keys.route(key("e", code: 14)) != nil)
        #expect(f.keys.route(key("k", code: 40, modifiers: .command)) != nil, "IME composition gets everything")
        #expect(f.router.list?.rows.count == 10)
        #expect(f.env.notices.toasts.isEmpty)
    }

    @Test func gIWorksAndTimesOutAtOneSecond() async {
        let f = await fixture()
        var hints: [SequenceHint?] = []
        f.keys.onPendingHint = { hints.append($0) }
        f.router.go(to: .system(.starred))
        #expect(f.keys.route(key("g", code: 5, at: 200)) == nil)
        #expect(hints.last??.text == "G…")
        #expect(hints.last??.completions.contains { $0.title == "Go to Inbox" && $0.keys == ["I"] } == true)
        #expect(f.keys.route(key("i", code: 34, at: 200.99)) == nil)
        #expect(f.router.location != .system(.starred), "G I went back to the inbox")
        #expect(hints.last == .some(nil), "the hint goes away")
        f.router.go(to: .system(.starred))
        #expect(f.keys.route(key("g", code: 5, at: 300)) == nil)
        #expect(f.keys.route(key("i", code: 34, at: 301.01)) == nil)
        #expect(f.router.location == .system(.starred))
    }

    @Test func commandKWorksEverywhere() async {
        let f = await fixture()
        let palette = f.env.actions.palette
        #expect(f.keys.route(key("k", code: 40, modifiers: .command)) == nil)
        #expect(palette.isOpen)
        palette.close()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        #expect(f.keys.route(key("k", code: 40, modifiers: .command)) == nil, "also while typing")
        #expect(palette.isOpen)
        palette.close()
        f.router.perform(.openThread)
        let web = WKWebView(frame: NSRect(x: 0, y: 40, width: 200, height: 100))
        window.contentView?.addSubview(web)
        _ = window.makeFirstResponder(web)
        #expect(f.keys.route(key("k", code: 40, modifiers: .command)) == nil, "and in the reader")
        #expect(palette.isOpen)
        #expect(palette.context?.scope == .reader, "the palette captured the reader's context")
    }

    @Test func aWebViewFocusedReaderStillGetsJAndK() async throws {
        let f = await fixture()
        let rows = try #require(f.router.list?.rows.map(\.id))
        #expect(f.router.perform(.openThread))
        #expect(f.router.reader?.thread == rows[0])
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView?.addSubview(web)
        _ = window.makeFirstResponder(web)
        #expect(f.keys.route(key("j", code: 38)) == nil)
        #expect(f.router.reader?.thread == rows[1])
        #expect(f.keys.route(key("k", code: 40)) == nil)
        #expect(f.router.reader?.thread == rows[0])
        #expect(f.keys.route(key("e", code: 14)) == nil, "e in a conversation: done and next")
        #expect(f.router.reader?.thread == rows[1])
    }

    @Test func heldKeysRepeatOnlyForMoving() async {
        let f = await fixture()
        var performed: [ActionID] = []
        let perform = f.keys.perform
        f.keys.perform = { action, scope in
            performed.append(action)
            return perform(action, scope)
        }
        #expect(f.keys.route(key("j", code: 38)) == nil)
        #expect(f.keys.route(key("j", code: 38, repeat: true)) == nil)
        #expect(f.router.list?.cursorIndex == 2, "j repeats")
        #expect(f.keys.route(key("e", code: 14)) == nil)
        #expect(f.keys.route(key("e", code: 14, repeat: true)) == nil, "the repeat is consumed…")
        #expect(f.keys.route(key("e", code: 14, repeat: true)) == nil)
        #expect(performed == [.nextThread, .nextThread, .markDone], "…and marks nothing else done")
        await f.env.actions.lastTask?.value
        await untilObserved { f.router.list?.rows.count == 9 }
    }

    @Test func overlayScopesComeFirst() async {
        let f = await fixture()
        let all = KeyRouter.catalog()
        all.isMailWindow = f.keys.isMailWindow
        all.activeScopes = f.keys.activeScopes
        var performed: [ActionID] = []
        all.perform = { action, _ in performed.append(action); return true }
        #expect(all.route(key("s", code: 1)) == nil)
        all.pushScope(.review)
        #expect(all.scopeStack == [.review, .list, .global])
        #expect(all.route(key("s", code: 1)) == nil)
        all.popScope(.review)
        #expect(all.route(key("s", code: 1)) == nil)
        #expect(performed == [.toggleStar, .reviewSkip, .toggleStar])
    }

    @Test func aDisabledModuleHasNoKeys() async {
        let f = await fixture(flags: FeatureFlags().with(.snooze, false))
        var hints: [SequenceHint?] = []
        f.keys.onPendingHint = { hints.append($0) }
        let snoozeKey = ActionCatalog.remindOnH ? "H" : "h"
        #expect(f.keys.route(key(snoozeKey, code: 4, modifiers: ActionCatalog.remindOnH ? .shift : [])) != nil)
        #expect(f.keys.route(key("g", code: 5, at: 10)) == nil)
        #expect(hints.last??.completions.contains { $0.keys == ["Z"] } == false)
        #expect(f.keys.route(key("z", code: 6, at: 10.2)) != nil)
        #expect(f.router.location == .system(.inbox))
        let on = await fixture()
        #expect(on.keys.bindings[.list]?[.char(snoozeKey)] == .snooze)
    }

    @Test func commandFIsSearchInTheListAndFindInAConversation() async throws {
        let f = await fixture()
        let commandF = KeyChord(.character("f"), modifiers: .command)
        #expect(f.keys.bindings[.list]?[commandF] == .search)
        #expect(f.keys.bindings[.reader]?[commandF] == .findInConversation)
        #expect(f.keys.bindings[.global]?[commandF] == nil, "never everywhere: the composer's ⌘F is the text's")
        #expect(f.router.perform(.openThread))
        await untilObserved { f.router.reader?.state == .loaded }
        let reader = try #require(f.router.reader)
        #expect(f.keys.route(key("f", code: 3, modifiers: .command)) == nil, "consumed: the find bar opens")
        #expect(reader.findRequest == 1)
    }

    @Test func theAddedKeysAreInTheTable() async {
        let f = await fixture()
        let table = KeyTable.build(f.env.actions.descriptors)
        #expect(table.bindings[.list]?[KeyChord(.character("u"), modifiers: .command)] == .unsubscribe)
        #expect(table.bindings[.reader]?[KeyChord(.character("u"), modifiers: .command)] == .unsubscribe)
        #expect(table.bindings[.list]?[.char("M")] == .toggleMute && table.bindings[.list]?[.char("m")] == .toggleMute)
        #expect(table.bindings[.list]?[.named(.left)] == .focusLabelSidebar)
        #expect(table.bindings[.global]?[KeyChord(.character("n"), modifiers: .command)] == .compose)
        #expect(table.sequences[.global]?[.char("g")]?[.char("h")] == .goReminders)
        #expect(table.sequences[.global]?[.char("g")]?[.char("m")] == .goMuted)
        #expect(table.sequences[.global]?[.char("g")]?[.char("e")] == .goDone)
        let shiftReturnAction: ActionID = ActionCatalog.returnRepliesAll ? .reply : .replyAll
        #expect(table.bindings[.reader]?[.named(.returnKey)] == .openMessageOrReply, "↵ opens a closed message first")
        #expect(table.bindings[.reader]?[KeyChord(.named(.returnKey), modifiers: .shift)] == shiftReturnAction)
        #expect(table.bindings[.list]?[.named(.returnKey)] == .openThread, "↵ in the list still opens")
        #expect(table.nonRepeating.contains(.compose) && table.nonRepeating.contains(.search))
        #expect(!table.nonRepeating.contains(.nextThread) && !table.nonRepeating.contains(.nextMessage))
    }

    @Test func aHeldSlashOpensTheSearchOnce() async {
        let f = await fixture()
        var performed: [ActionID] = []
        f.keys.perform = { action, _ in
            performed.append(action)
            return true
        }
        #expect(f.keys.route(key("/", code: 44)) == nil)
        #expect(f.keys.route(key("/", code: 44, repeat: true)) == nil)
        #expect(f.keys.route(key("/", code: 44, repeat: true)) == nil)
        #expect(performed == [.search])
    }
}

extension KeyboardRoutingTests {
    @Test func aHeldGPrefixStillCompletesTheSequence() async {
        let f = await fixture()
        var performed: [ActionID] = []
        f.keys.perform = { action, _ in
            performed.append(action)
            return true
        }
        #expect(f.keys.route(key("g", code: 5, at: 10)) == nil)
        #expect(f.keys.route(key("g", code: 5, at: 10.5, repeat: true)) == nil)
        #expect(f.keys.route(key("g", code: 5, at: 11.4, repeat: true)) == nil)
        #expect(f.keys.route(key("e", code: 14, at: 11.6)) == nil)
        #expect(performed == [.goDone])
    }

    @Test func aRepeatedReturnIsConsumedWhileAnOverlayShows() async {
        let f = await fixture()
        var performed: [ActionID] = []
        f.keys.perform = { action, _ in
            performed.append(action)
            return true
        }
        f.keys.pushScope(.palette)
        #expect(f.keys.route(key("\r", code: 36, repeat: true)) == nil)
        #expect(performed.isEmpty)
    }
}

@MainActor
@Suite struct RealTriageKeyTests {
    func event(_ keyCode: CGKeyCode, _ flags: CGEventFlags = []) throws -> NSEvent {
        let source = CGEventSource(stateID: .privateState)
        let cg = try #require(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true))
        cg.flags = flags
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test func shiftedSymbolsLettersAndDeleteMatchTheCatalog() throws {
        let table = KeyTable.build(ActionCatalog.all)
        func action(_ e: NSEvent, _ scope: ActionScope = .list) -> ActionID? { KeyChord(event: e).flatMap { table.bindings[scope]?[$0] } }
        #expect(try action(event(51)) == .trash, "⌫ is key code 51")
        #expect(try action(event(20, .maskShift)) == .trash, "⇧3 is #")
        #expect(try action(event(18, .maskShift)) == .spam, "⇧1 is !")
        #expect(try action(event(44, .maskShift), .global) == .shortcutHelp, "⇧/ is ?")
        #expect(try action(event(4, .maskShift)) == (ActionCatalog.remindOnH ? .snooze : .remind), "⇧H")
        #expect(try action(event(4)) == (ActionCatalog.remindOnH ? .remind : .snooze), "h")
        #expect(try action(event(14, .maskShift)) == .moveToInbox, "⇧E")
        #expect(try action(event(38, .maskShift)) == .extendSelectionDown, "⇧J")
        #expect(try action(event(0, .maskCommand)) == SelectAllShortcuts.commandA, "⌘A")
        #expect(try action(event(0, [.maskCommand, .maskShift])) == SelectAllShortcuts.commandShiftA, "⌘⇧A")
        #expect(try action(event(40, .maskCommand), .global) == .commandPalette, "⌘K")
        #expect(try action(event(36, .maskCommand), .composer) == .send, "⌘↵ (the composer's own handler performs it)")
    }

    @Test func reviewKeysAreBoundInTheReviewScope() throws {
        let table = KeyTable.build(ActionCatalog.all)
        func action(_ e: NSEvent, _ scope: ActionScope = .review) -> ActionID? { KeyChord(event: e).flatMap { table.bindings[scope]?[$0] } }
        #expect(try action(event(0)) == .reviewKeep, "a")
        #expect(try action(event(1)) == .reviewSkip, "s")
        #expect(try action(event(38)) == .reviewNext, "j")
        #expect(try action(event(40)) == .reviewPrevious, "k")
        #expect(try action(event(14)) == .reviewEdit, "e")
        #expect(try action(event(36)) == .reviewEdit, "↩")
        #expect(try action(event(51)) == .reviewDiscard, "⌫")
        #expect(try action(event(20, .maskShift)) == .reviewDiscard, "#")
        #expect(try action(event(36, .maskCommand)) == .reviewSend, "⌘↵")
        #expect(try action(event(0), .list) != .reviewKeep, "the list's keys are not the review queue's")
    }
}

