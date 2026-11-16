import Foundation

public struct ShortcutLine: Hashable, Sendable, Identifiable {
    public var id: ActionID { action }
    public let action: ActionID
    public let title: String
    public let keys: [String]
    public var places: [String] = []

    public init(action: ActionID, title: String, keys: [String], places: [String] = []) {
        self.action = action
        self.title = title
        self.keys = keys
        self.places = places
    }

    public var place: String? { places.first }

    public static func placeName(of scopes: Set<ActionScope>) -> String {
        if scopes.contains(.global) { return "Everywhere" }
        let names: [(ActionScope, String)] = [(.list, "list"), (.reader, "conversation"), (.composer, "composer"),
                                              (.review, "review queue"), (.palette, "palette"),
                                              (.calendar, "calendar"), (.sidebar, "sidebar")]
        let parts = names.filter { scopes.contains($0.0) }.map(\.1)
        let text = switch parts.count {
        case 0: "Everywhere"
        case 1: parts[0]
        default: parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

public struct SequenceHint: Hashable, Sendable {
    public let prefix: String
    public let completions: [ShortcutLine]

    public var text: String { prefix + "…" }

    public static func make(prefix: KeyBinding.Chord, scopes: [ActionScope],
                            descriptors: [ActionDescriptor]) -> SequenceHint {
        var lines: [ShortcutLine] = []
        for descriptor in descriptors {
            for binding in descriptor.defaultBindings where binding.chords.count == 2 && binding.chords[0] == prefix {
                guard !descriptor.scopes(of: binding).isDisjoint(with: scopes) else { continue }
                lines.append(ShortcutLine(action: descriptor.id, title: descriptor.title,
                                          keys: [KeyBinding.display(binding.chords[1])]))
            }
        }
        return SequenceHint(prefix: KeyBinding.display(prefix),
                            completions: lines.sorted { ($0.keys.first ?? "") < ($1.keys.first ?? "") })
    }
}

public struct ShortcutSheet: Hashable, Sendable {
    public struct Section: Hashable, Sendable, Identifiable {
        public var id: String { title }
        public let title: String
        public let lines: [ShortcutLine]

        public init(title: String, lines: [ShortcutLine]) {
            self.title = title
            self.lines = lines
        }
    }

    public let sections: [Section]

    public init(descriptors: [ActionDescriptor]) {
        var navigate: [ShortcutLine] = [], act: [ShortcutLine] = [], write: [ShortcutLine] = []
        for descriptor in descriptors where !descriptor.defaultBindings.isEmpty {
            let places = descriptor.defaultBindings.map {
                descriptor.id == .instantIntro ? "Composer" : ShortcutLine.placeName(of: descriptor.scopes(of: $0))
            }
            let line = ShortcutLine(action: descriptor.id, title: descriptor.title,
                                    keys: descriptor.defaultBindings.map(\.description), places: places)
            switch descriptor.category {
            case .navigation, .account, .view: navigate.append(line)
            case .compose, .ai: write.append(line)
            case .thread, .app: act.append(line)
            }
        }
        sections = [Section(title: "Navigate", lines: navigate), Section(title: "Act", lines: act),
                    Section(title: "Write", lines: write)]
    }

    public func filtered(_ text: String) -> [Section] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { section in
            let lines = section.lines.filter { line in
                line.title.lowercased().contains(needle) || line.keys.contains { $0.lowercased() == needle }
                    || (needle.count >= 3 && line.places.contains { $0.lowercased().contains(needle) })
            }
            return lines.isEmpty ? nil : Section(title: section.title, lines: lines)
        }
    }
}
