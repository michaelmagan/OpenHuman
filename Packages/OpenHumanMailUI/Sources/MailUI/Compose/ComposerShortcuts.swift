import MailActions
import MailFeatures
import SwiftUI

struct ComposerShortcuts: View {
    let session: ComposeSession
    let manager: ComposeManager
    let onClose: () -> Void

    var body: some View {
        ZStack {
            ForEach(Self.shortcuts(manager.actionDescriptors)) { item in
                Button("") {
                    guard manager.ownsShortcutKeys(session) else { return }
                    manager.perform(item.action, in: session, source: .keyboard)
                }
                    .keyboardShortcut(item.shortcut)
                    .buttonStyle(.plain)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    struct Item: Identifiable, Equatable {
        let id: Int
        let action: ActionID
        let shortcut: KeyboardShortcut
    }

    static let editorOwned: Set<ActionID> = Set(ActionCatalog.formatIDs + [.closeComposer])

    /// ⌘⌫ discards only from the start of the body, which only the body knows; ⌘⇧. discards from any field.
    static func isEditorOwned(_ id: ActionID, _ binding: KeyBinding) -> Bool {
        editorOwned.contains(id) || (id == .discardDraft && binding.chords.first?.key == .named(.delete))
    }

    static func shortcuts(_ descriptors: [ActionDescriptor]) -> [Item] {
        var items: [Item] = []
        for descriptor in descriptors where descriptor.scopes.contains(.composer) {
            for binding in descriptor.defaultBindings where binding.chords.count == 1
                && !isEditorOwned(descriptor.id, binding) {
                let modifiers = binding.chords[0].modifiers
                guard modifiers.contains(.command), !modifiers.contains(.control),
                      let shortcut = binding.keyboardShortcut else { continue }
                items.append(Item(id: items.count, action: descriptor.id, shortcut: shortcut))
            }
        }
        return items
    }
}

extension KeyBinding {
    public var keyboardShortcut: KeyboardShortcut? {
        guard isMenuKeyEquivalent else { return nil }
        let chord = chords[0]
        var modifiers: EventModifiers = []
        if chord.modifiers.contains(.command) { modifiers.insert(.command) }
        if chord.modifiers.contains(.option) { modifiers.insert(.option) }
        if chord.modifiers.contains(.control) { modifiers.insert(.control) }
        if chord.modifiers.contains(.shift) { modifiers.insert(.shift) }
        switch chord.key {
        case .character(let character):
            guard let first = character.first, character.count == 1 else { return nil }
            if first.isUppercase { modifiers.insert(.shift) }
            return KeyboardShortcut(KeyEquivalent(Character(first.lowercased())), modifiers: modifiers)
        case .named(let named):
            let key: KeyEquivalent = switch named {
            case .enter: .return
            case .tab: .tab
            case .escape: .escape
            case .delete: .delete
            case .up: .upArrow
            case .down: .downArrow
            case .left: .leftArrow
            case .right: .rightArrow
            }
            return KeyboardShortcut(key, modifiers: modifiers)
        }
    }
}
