import AppKit
import Carbon
import MailActions

@MainActor
public struct KeyTranslation {
    public var applyingModifiers: @MainActor (NSEvent, NSEvent.ModifierFlags) -> String?
    public var asciiCharacter: @MainActor (UInt16, Bool) -> String?

    public init(applyingModifiers: @escaping @MainActor (NSEvent, NSEvent.ModifierFlags) -> String?,
                asciiCharacter: @escaping @MainActor (UInt16, Bool) -> String?) {
        self.applyingModifiers = applyingModifiers
        self.asciiCharacter = asciiCharacter
    }

    public static let system = KeyTranslation(
        applyingModifiers: { event, modifiers in event.characters(byApplyingModifiers: modifiers) },
        asciiCharacter: { keyCode, shift in ASCIIKeyLayout.shared.character(keyCode: keyCode, shift: shift) })

    public func alternates(for event: NSEvent, _ chord: KeyChord) -> [KeyChord] {
        guard case .character(let typed) = chord.key else { return [] }
        let flags = event.modifierFlags
        var result: [KeyChord] = []
        if flags.contains(.option), flags.intersection([.command, .control]).isEmpty,
           let symbol = applyingModifiers(event, flags.intersection([.shift, .option])), Self.isSymbol(symbol) {
            result.append(KeyChord(.character(symbol), modifiers: flags.subtracting(.option)))
        }
        // Why: a layout that reports ⌘⇧. as "." would reach AppKit's ⌘. cancel; the ASCII layout names it ">"
        if flags.contains(.shift), !flags.intersection([.command, .control]).isEmpty, Self.isSymbol(typed),
           let shifted = asciiCharacter(event.keyCode, true), shifted != typed, Self.isSymbol(shifted) {
            result.append(KeyChord(.character(shifted), modifiers: flags))
        }
        if !typed.unicodeScalars.allSatisfy(\.isASCII),
           let ascii = asciiCharacter(event.keyCode, flags.contains(.shift)), ascii != typed,
           ascii.count == 1, ascii.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) {
            result.append(KeyChord(.character(ascii), modifiers: flags))
        }
        return result
    }

    static func isSymbol(_ text: String) -> Bool {
        guard text.count == 1, let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else { return false }
        let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
        return scalar.isASCII && scalar.value > 0x20 && scalar.value < 0x7F && !scalar.properties.isAlphabetic && !isDigit
    }
}

@MainActor
public final class ASCIIKeyLayout {
    public static let shared = ASCIIKeyLayout()

    private var sourceID: String?
    private var cache: [Int: String] = [:]
    private var misses: Set<Int> = []

    public init() {}

    public func character(keyCode: UInt16, shift: Bool) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        let id = Self.stringProperty(source, kTISPropertyInputSourceID)
        if id != sourceID {
            sourceID = id
            cache = [:]
            misses = []
        }
        let slot = Int(keyCode) * 2 + (shift ? 1 : 0)
        if let known = cache[slot] { return known }
        if misses.contains(slot) { return nil }
        guard let typed = Self.translate(keyCode, shift: shift, source: source) else {
            misses.insert(slot)
            return nil
        }
        cache[slot] = typed
        return typed
    }

    public func keyCode(typing character: String) -> UInt16? {
        let wanted = character.lowercased()
        return (UInt16(0)...127).first { self.character(keyCode: $0, shift: false)?.lowercased() == wanted }
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func translate(_ keyCode: UInt16, shift: Bool, source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        var deadKeyState: UInt32 = 0
        let capacity = 4
        var length = 0
        var characters = [UniChar](repeating: 0, count: Int(capacity))
        let modifierState = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifierState, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, capacity, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: Int(length))
    }
}
