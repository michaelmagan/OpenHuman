import AppKit
import MailActions
import Testing
import WebKit
@testable import MailUIMac

@MainActor
struct KeyRouterTests {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
    let router = KeyRouter()
    var performed: [(ActionID, ActionScope)] { recorder.calls }
    let recorder = Recorder()

    final class Recorder {
        var calls: [(ActionID, ActionScope)] = []
        var answer = true
    }

    init() {
        window.isReleasedWhenClosed = false
        let recorder = recorder
        let window = window
        router.isMailWindow = { $0 === window }
        router.activeScopes = { [.list, .global] }
        router.perform = { action, scope in
            recorder.calls.append((action, scope))
            return recorder.answer
        }
    }

    func key(_ chars: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in target: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: (target ?? window).windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func jAndArrowsMoveInTheList() {
        #expect(router.route(key("j", code: 38)) == nil)
        #expect(router.route(key("\u{F701}", code: 125)) == nil)
        #expect(router.route(key("k", code: 40)) == nil)
        #expect(router.route(key("\u{F700}", code: 126)) == nil)
        #expect(performed.map(\.0) == [.nextThread, .nextThread, .previousThread, .previousThread])
        #expect(performed.allSatisfy { $0.1 == .list })
    }

    @Test func returnAndOOpen() {
        #expect(router.route(key("\r", code: 36)) == nil)
        #expect(router.route(key("o", code: 31)) == nil)
        #expect(performed.map(\.0) == [.openThread, .openThread])
    }

    @Test func escapeInTheReaderGoesBackButPassesInTheList() {
        #expect(router.route(key("\u{1B}", code: 53)) != nil)
        router.activeScopes = { [.reader, .global] }
        #expect(router.route(key("\u{1B}", code: 53)) == nil)
        #expect(performed.map(\.0) == [.backToList])
    }

    func repeated(_ chars: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: true, keyCode: code)!
    }

    @Test func aHeldKeyNeverCrossesScopes() {
        let recorder = recorder
        var scopes: [ActionScope] = [.list, .global]
        router.activeScopes = { scopes }
        router.bindings[.reader, default: [:]][.named(.returnKey)] = .reply
        router.perform = { action, scope in
            recorder.calls.append((action, scope))
            if action == .openThread { scopes = [.reader, .global] }
            return true
        }
        #expect(router.route(key("\r", code: 36)) == nil)
        #expect(router.route(repeated("\r", code: 36)) == nil, "the repeat is consumed")
        #expect(router.route(repeated("\r", code: 36)) == nil)
        #expect(performed.map(\.0) == [.openThread], "no reply from the held key")
        #expect(router.route(key("\r", code: 36)) == nil)
        #expect(performed.map(\.0) == [.openThread, .reply], "a new press replies")
        #expect(router.route(key("j", code: 38)) == nil)
        #expect(router.route(repeated("j", code: 38)) == nil)
        #expect(performed.map(\.0) == [.openThread, .reply, .nextThread, .nextThread], "j repeats within a scope")
    }

    @Test func unhandledActionPassesTheEventOn() {
        recorder.answer = false
        #expect(router.route(key("j", code: 38)) != nil)
        #expect(performed.count == 1)
    }

    @Test func commandChordsAndUnboundKeysPassThrough() {
        #expect(router.route(key("j", code: 38, modifiers: .command)) != nil)
        #expect(router.route(key("z", code: 6)) != nil)
        #expect(performed.isEmpty)
    }

    @Test func editableTextViewGetsEveryKey() {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(text)
        #expect(window.makeFirstResponder(text))
        #expect(router.route(key("j", code: 38)) != nil)
        #expect(router.route(key("\u{1B}", code: 53)) != nil)
        #expect(performed.isEmpty)
    }

    @Test func readOnlyTextViewAndWebViewStillRoute() {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        text.isEditable = false
        window.contentView?.addSubview(text)
        #expect(window.makeFirstResponder(text))
        #expect(router.route(key("j", code: 38)) == nil)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(web)
        _ = window.makeFirstResponder(web)
        #expect(!KeyRouter.isTextInput(web), "WKWebView is not a text input even though it is an NSTextInputClient")
        #expect(router.route(key("k", code: 40)) == nil)
        #expect(performed.map(\.0) == [.nextThread, .previousThread])
    }

    @Test func markedTextPassesThrough() {
        final class Composing: NSTextView { override func hasMarkedText() -> Bool { true } }
        let text = Composing(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        text.isEditable = false
        window.contentView?.addSubview(text)
        #expect(window.makeFirstResponder(text))
        #expect(router.route(key("j", code: 38)) != nil)
        #expect(performed.isEmpty)
    }

    @Test func otherWindowsAreIgnored() {
        let other = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 100, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        #expect(router.route(key("j", code: 38, in: other)) != nil)
        #expect(performed.isEmpty)
    }

    @Test func textInputHostMarkerCounts() {
        final class Host: NSView, TextInputHost { override var acceptsFirstResponder: Bool { true } }
        let host = Host(frame: .zero)
        window.contentView?.addSubview(host)
        #expect(window.makeFirstResponder(host))
        #expect(router.route(key("j", code: 38)) != nil)
    }

    @Test func aHeldKeyNeverTypesIntoTheFieldItOpened() {
        let recorder = recorder
        let window = window
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(field)
        router.bindings[.global, default: [:]][.char("c")] = .compose
        router.nonRepeating = [.compose]
        router.perform = { action, scope in
            recorder.calls.append((action, scope))
            _ = window.makeFirstResponder(field)
            return true
        }
        #expect(router.route(key("c", code: 8)) == nil)
        #expect(window.firstResponder === field)
        #expect(router.route(repeated("c", code: 8)) == nil, "the repeat does not type c into the field")
        #expect(router.route(repeated("c", code: 8)) == nil)
        #expect(performed.map(\.0) == [.compose])
        #expect(router.route(key("c", code: 8)) != nil, "a new press in the field types")
        #expect(router.route(repeated("c", code: 8)) != nil, "and so do its repeats")
        #expect(performed.map(\.0) == [.compose])
    }

    @Test func keysTypedIntoAFieldRepeatAsUsual() {
        router.bindings[.list, default: [:]][.named(.delete)] = .trash
        #expect(router.route(key("\u{7F}", code: 51)) == nil, "⌫ trashes in the list")
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        #expect(router.route(key("\u{7F}", code: 51)) != nil)
        #expect(router.route(repeated("\u{7F}", code: 51)) != nil, "holding ⌫ deletes text")
        #expect(performed.map(\.0) == [.trash])
    }

    @Test func aHeldCommandKOpensThePaletteOnce() {
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(field)
        let commandK = KeyChord(.character("k"), modifiers: .command)
        router.bindings[.global, default: [:]][commandK] = .commandPalette
        router.whileTyping[commandK] = .commandPalette
        router.nonRepeating = [.commandPalette]
        func held(_ isARepeat: Bool) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: "k",
                             charactersIgnoringModifiers: "k", isARepeat: isARepeat, keyCode: 40)!
        }
        #expect(router.route(held(false)) == nil)
        #expect(window.makeFirstResponder(field), "the palette's field takes the focus")
        #expect(router.route(held(true)) == nil && router.route(held(true)) == nil)
        #expect(performed.map(\.0) == [.commandPalette])
        #expect(router.route(held(false)) == nil, "typing in a field: ⌘K still works")
        #expect(router.route(held(true)) == nil)
        #expect(performed.map(\.0) == [.commandPalette, .commandPalette])
    }

    @Test func capsLockDoesNotTurnAKeyIntoItsShiftedBinding() {
        router.bindings[.list, default: [:]][.char("J")] = .extendSelectionDown
        let commandK = KeyChord(.character("k"), modifiers: .command)
        router.bindings[.global, default: [:]][commandK] = .commandPalette
        #expect(router.route(key("J", code: 38, modifiers: .capsLock)) == nil, "Caps Lock reports J for the J key")
        #expect(router.route(key("J", code: 38, modifiers: [.capsLock, .shift])) == nil, "⇧ still makes it ⇧J")
        #expect(router.route(key("K", code: 40, modifiers: [.capsLock, .command])) == nil)
        #expect(performed.map(\.0) == [.nextThread, .extendSelectionDown, .commandPalette])
    }

    @Test func optionSymbolsAndOtherScriptsFindTheirBinding() {
        router.bindings[.list, default: [:]][.char("#")] = .trash
        router.bindings[.list, default: [:]][.char("e")] = .markDone
        router.bindings[.list, default: [:]][.char("E")] = .moveToInbox
        router.translation = KeyTranslation(
            applyingModifiers: { event, modifiers in
                guard modifiers.contains(.option) else { return event.charactersIgnoringModifiers }
                return event.keyCode == 20 ? "#" : "é"
            },
            asciiCharacter: { keyCode, shift in keyCode == 14 ? (shift ? "E" : "e") : nil })
        #expect(router.route(key("3", code: 20, modifiers: .option)) == nil, "⌥3 types # on this layout")
        #expect(router.route(key("у", code: 14)) == nil, "the E key on a Russian input source")
        #expect(router.route(key("У", code: 14, modifiers: .shift)) == nil, "⇧ is kept: ⇧E")
        #expect(router.route(key("e", code: 14, modifiers: .option)) != nil, "⌥E makes é, which nothing binds")
        #expect(performed.map(\.0) == [.trash, .markDone, .moveToInbox])
    }

    @Test func digitsInCommandChordsAreTheirKeys() throws {
        let numbered = KeyChord(.character("7"), modifiers: [.command, .shift])
        #expect(KeyChord(event: key("&", code: 26, modifiers: [.command, .shift])) == numbered, "US")
        #expect(KeyChord(event: key("7", code: 26, modifiers: [.command, .shift])) == numbered, "French")
        #expect(KeyChord(event: key("&", code: 18, modifiers: .control)) == KeyChord(.character("1"), modifiers: .control),
                "⌃ and the 1 key on a layout that types & there")
        #expect(KeyChord(event: key("1", code: 83, modifiers: .control)) == KeyChord(.character("1"), modifiers: .control),
                "the keypad's 1")
        #expect(KeyChord(event: key("#", code: 20, modifiers: .shift)) == .char("#"), "without ⌘ or ⌃ the character counts")
        #expect(KeyChord(event: key("!", code: 18, modifiers: .shift)) == .char("!"))
        let table = KeyTable.build(ActionCatalog.all)
        #expect(table.bindings[.global]?[KeyChord(event: key("&", code: 18, modifiers: .control))!] == .switchToAccount(1))
    }
}
