import AppKit
import MailActions

@MainActor
public protocol TextInputHost: AnyObject {}

public struct KeyChord: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        case character(String)
        case named(NamedKey)
    }

    public enum NamedKey: UInt16, Hashable, Sendable {
        case returnKey = 36, tab = 48, escape = 53, keypadEnter = 76, down = 125, up = 126, left = 123, right = 124
        case delete = 51
    }

    public let key: Key
    public let modifiers: NSEvent.ModifierFlags

    public init(_ key: Key, modifiers: NSEvent.ModifierFlags = []) {
        self.key = key
        switch key {
        case .character(let c):
            var kept: NSEvent.ModifierFlags = [.command, .option, .control]
            if KeyBinding.isDigit(c), !modifiers.intersection([.command, .control]).isEmpty { kept.insert(.shift) }
            self.modifiers = modifiers.intersection(kept)
        case .named:
            self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
        }
    }

    public static func char(_ c: String) -> KeyChord { KeyChord(.character(c)) }
    public static func named(_ k: NamedKey) -> KeyChord { KeyChord(.named(k)) }

    public static func == (a: KeyChord, b: KeyChord) -> Bool { a.key == b.key && a.modifiers.rawValue == b.modifiers.rawValue }
    public func hash(into h: inout Hasher) {
        h.combine(key)
        h.combine(modifiers.rawValue)
    }

    public init?(event: NSEvent) {
        let modifiers = event.modifierFlags
        if let named = NamedKey(rawValue: event.keyCode) {
            self.init(.named(named), modifiers: modifiers)
        } else if !modifiers.intersection([.command, .control]).isEmpty, let digit = Self.digitKeys[event.keyCode] {
            self.init(.character(digit), modifiers: modifiers)
        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            self.init(.character(chars), modifiers: modifiers)
        } else {
            return nil
        }
    }

    static let digitKeys: [UInt16: String] = [
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
    ]
}

@MainActor
public final class KeyRouter {
    public var bindings: [ActionScope: [KeyChord: ActionID]]
    public var sequences: [ActionScope: [KeyChord: [KeyChord: ActionID]]] = [:]
    public var nonRepeating: Set<ActionID> = []
    public var whileTyping: [KeyChord: ActionID] = [:]
    public var hints: [ActionScope: [KeyChord: SequenceHint]] = [:]
    public var onPendingHint: ((SequenceHint?) -> Void)?
    public private(set) var overlayScopes: [ActionScope] = []
    public var sequenceTimeout: TimeInterval = 1
    public var onPendingSequence: ((KeyChord?) -> Void)?
    public var activeScopes: () -> [ActionScope] = { [.global] }
    public var perform: (ActionID, ActionScope) -> Bool = { _, _ in false }
    public var isMailWindow: (NSWindow) -> Bool = { $0.isMainWindow || $0.canBecomeMain }
    public var didRoute: ((KeyChord, ActionID?) -> Void)?
    public var translation = KeyTranslation.system
    public var editingKeyHandler: ((NSEvent) -> Bool)?
    /// Sees a key before the focused field editor does, in any window, so a field can answer keys its editor would
    /// swallow, such as ⌫ at the search field's pills. Returning true consumes the key.
    public var fieldEditorKeyHandler: ((NSEvent, NSTextView) -> Bool)?
    static let editingKeyCodes: Set<UInt16> = [51, 117]

    private var monitor: Any?
    private var held: (chord: KeyChord, scopes: [ActionScope])?
    private var pending: (prefix: KeyChord, at: TimeInterval, scopes: [ActionScope])?
    private var pendingExpiry: Task<Void, Never>?

    public init(bindings: [ActionScope: [KeyChord: ActionID]] = KeyRouter.sliceBindings) {
        self.bindings = bindings
    }

    public static let sliceBindings: [ActionScope: [KeyChord: ActionID]] = [
        .list: [
            .char("j"): .nextThread, .named(.down): .nextThread,
            .char("k"): .previousThread, .named(.up): .previousThread,
            .named(.returnKey): .openThread, .named(.keypadEnter): .openThread, .char("o"): .openThread,
        ],
        .reader: [
            .char("j"): .nextThread, .char("k"): .previousThread,
            .named(.escape): .backToList,
        ],
    ]

    public func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.route(event) == nil }
            return consumed ? nil : event
        }
    }

    public func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        endSequence()
    }

    public func pushScope(_ scope: ActionScope) {
        overlayScopes.append(scope)
        endSequence()
    }

    public func popScope(_ scope: ActionScope) {
        if let index = overlayScopes.lastIndex(of: scope) { overlayScopes.remove(at: index) }
    }

    public var scopeStack: [ActionScope] { overlayScopes.reversed() + activeScopes() }

    public func route(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown else { return event }
        if let window = event.window ?? NSApp.keyWindow {
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, !editor.hasMarkedText(),
               let fieldEditorKeyHandler, fieldEditorKeyHandler(event, editor) {
                endSequence()
                held = nil
                return nil
            }
            guard isMailWindow(window), window.attachedSheet == nil, !(window is NSPanel) else { return event }
            if Self.hasMarkedText(window.firstResponder) { return event }
            if event.isARepeat, event.keyCode == 36 || event.keyCode == 76,
               !overlayScopes.isEmpty || (window.firstResponder as? NSTextView)?.isFieldEditor == true { return nil }
            if Self.isTextInput(window.firstResponder) { return routeWhileTyping(event) }
        }
        if Self.editingKeyCodes.contains(event.keyCode), overlayScopes.isEmpty, let editingKeyHandler, editingKeyHandler(event) {
            endSequence()
            held = nil
            return nil
        }
        guard let chord = KeyChord(event: event) else { return event }
        if event.isARepeat {
            if let held, held.chord == chord, held.scopes != scopeStack { return nil }
        } else {
            held = nil
        }
        if let waiting = pending {
            if event.isARepeat, chord == waiting.prefix {
                pending = (waiting.prefix, event.timestamp, waiting.scopes)
                return nil
            }
            endSequence()
            if event.timestamp - waiting.at <= sequenceTimeout {
                if chord == KeyChord.named(.escape) { return nil }
                for candidate in candidates(chord, event) {
                    for scope in waiting.scopes {
                        if let action = sequences[scope]?[waiting.prefix]?[candidate] {
                            return dispatch(action, scope, chord, event)
                        }
                    }
                }
            }
        }
        let scopes = scopeStack
        for candidate in candidates(chord, event) {
            for scope in scopes {
                if let action = bindings[scope]?[candidate] {
                    return dispatch(action, scope, chord, event)
                }
                if sequences[scope]?[candidate] != nil {
                    beginSequence(candidate, at: event.timestamp, scopes: scopes)
                    return nil
                }
            }
        }
        didRoute?(chord, nil)
        return event
    }

    private func routeWhileTyping(_ event: NSEvent) -> NSEvent? {
        guard let chord = KeyChord(event: event) else { return event }
        if event.isARepeat {
            if let held, held.chord == chord { return nil }
        } else {
            held = nil
        }
        guard !event.modifierFlags.intersection([.command, .control]).isEmpty,
              let action = candidates(chord, event).compactMap({ whileTyping[$0] }).first else { return event }
        if event.isARepeat, nonRepeating.contains(action) { return nil }
        let scopes = scopeStack
        guard perform(action, .global) else { return event }
        if !event.isARepeat { held = (chord, scopes) }
        return nil
    }

    private func candidates(_ chord: KeyChord, _ event: NSEvent) -> [KeyChord] {
        [chord] + translation.alternates(for: event, chord)
    }

    private func dispatch(_ action: ActionID, _ scope: ActionScope, _ chord: KeyChord, _ event: NSEvent) -> NSEvent? {
        if event.isARepeat, nonRepeating.contains(action) { return nil }
        didRoute?(chord, action)
        let scopes = scopeStack
        let handled = perform(action, scope)
        if !event.isARepeat { held = handled ? (chord, scopes) : nil }
        return handled ? nil : event
    }

    private func beginSequence(_ prefix: KeyChord, at time: TimeInterval, scopes: [ActionScope]) {
        pending = (prefix, time, scopes)
        onPendingSequence?(prefix)
        onPendingHint?(scopes.lazy.compactMap { [hints] in hints[$0]?[prefix] }.first)
        let timeout = sequenceTimeout
        pendingExpiry?.cancel()
        pendingExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.endSequence()
        }
    }

    private func endSequence() {
        pendingExpiry?.cancel()
        pendingExpiry = nil
        guard pending != nil else { return }
        pending = nil
        onPendingSequence?(nil)
        onPendingHint?(nil)
    }

    public static func isTextInput(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if let text = responder as? NSTextView { return text.isEditable }
        if responder is NSSearchField || responder is NSTokenField || responder is NSTextField {
            return (responder as? NSTextField)?.isEditable ?? true
        }
        return responder is TextInputHost
    }

    public static func hasMarkedText(_ responder: NSResponder?) -> Bool {
        (responder as? NSTextInputClient)?.hasMarkedText() ?? false
    }
}
