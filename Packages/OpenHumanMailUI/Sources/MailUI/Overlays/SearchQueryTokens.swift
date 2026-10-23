import Foundation
import MailFeatures
import MailTheme
import SwiftUI

struct SearchQueryToken: Hashable, Sendable {
    let name: String
    let value: String
    let isNegated: Bool

    var raw: String { (isNegated ? "-" : "") + name + ":" + value }

    var displayValue: String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { return String(value.dropFirst().dropLast()) }
        return value
    }

    var shortValue: String {
        let value = displayValue
        guard value.count > 28 else { return value }
        return String(value.prefix(16)) + "…" + String(value.suffix(11))
    }

    var displayName: String { (isNegated ? "−" : "") + name.lowercased() + ":" }

    var spokenLabel: String { spokenName + " " + displayValue + ", search filter" }

    var removeLabel: String { "Remove " + spokenName + " filter" }

    private var spokenName: String {
        (isNegated ? "not " : "") + name.lowercased().replacingOccurrences(of: "_", with: " ")
    }
}

public enum SearchQueryTokens {
    static let known: Set<String> = [
        "from", "to", "cc", "bcc", "subject", "label", "has", "is", "in", "before", "after", "older", "newer",
        "older_than", "newer_than", "filename", "category", "list", "larger", "smaller", "deliveredto",
    ]

    static func split(_ text: String) -> (tokens: [SearchQueryToken], rest: String) {
        var tokens: [SearchQueryToken] = []
        var index = text.startIndex
        while true {
            var start = index
            while start < text.endIndex, text[start].isWhitespace { start = text.index(after: start) }
            guard let (token, end) = token(in: text, at: start), end < text.endIndex, text[end].isWhitespace else {
                return (tokens, tokens.isEmpty ? text : String(text[start...]))
            }
            tokens.append(token)
            index = end
        }
    }

    /// The text the field shows after the pills.
    public static func rest(of text: String) -> String { split(text).rest }

    /// How many pills the field shows for the query.
    public static func pillCount(_ text: String) -> Int { split(text).tokens.count }

    static func join(_ tokens: [SearchQueryToken], rest: String) -> String {
        guard !tokens.isEmpty else { return rest }
        return tokens.map(\.raw).joined(separator: " ") + " " + rest
    }

    public static func removing(_ pills: IndexSet, from text: String) -> String {
        let parts = split(text)
        return join(parts.tokens.enumerated().filter { !pills.contains($0.offset) }.map(\.element), rest: parts.rest)
    }

    /// What a key does in a field with pills, the way a token field works. With the caret at the start of the text, ⌫
    /// and ← select the pill before it; ⌫ or ⌦ removes the selected pills; → walks back to the text; Esc lets go of the
    /// selected pills and keeps them; ⌘A takes the pills along with the text. `caret` is the field editor's selection in
    /// the text after the pills. A selection counts only while the caret is where selecting put it, so a click into the
    /// text lets it go. Nil leaves the key to the text.
    public static func edit(_ key: SearchFieldKey, text: String, selected: IndexSet,
                            caret editorCaret: NSRange) -> SearchPillEdit? {
        let parts = split(text)
        let count = parts.tokens.count
        guard count > 0 else { return nil }
        let start = NSRange(location: 0, length: 0)
        let whole = NSRange(location: 0, length: (parts.rest as NSString).length)
        let location = min(max(editorCaret.location, 0), whole.length)
        let caret = NSRange(location: location, length: min(max(editorCaret.length, 0), whole.length - location))
        let all = IndexSet(integersIn: 0..<count)
        var live = selected.filteredIndexSet { $0 < count }
        if !(caret == start || (live == all && caret == whole)) { live = [] }
        let letGo = selected.isEmpty ? nil : SearchPillEdit(text: text, selected: [], caret: nil, consumesKey: false)
        guard let first = live.first, let last = live.last else {
            switch key {
            case .deleteBackward where caret == start, .left where caret == start:
                return SearchPillEdit(text: text, selected: [count - 1], caret: start, consumesKey: true)
            case .selectAll:
                return SearchPillEdit(text: text, selected: all, caret: whole, consumesKey: true)
            default:
                return letGo
            }
        }
        let kept = parts.tokens.enumerated().filter { !live.contains($0.offset) }.map(\.element)
        switch key {
        case .deleteBackward, .deleteForward:
            let rest = (parts.rest as NSString).replacingCharacters(in: caret, with: "")
            return SearchPillEdit(text: join(kept, rest: rest), selected: [], caret: start, consumesKey: true)
        case .typing(let typed):
            let rest = (parts.rest as NSString).replacingCharacters(in: caret, with: typed)
            let after = NSRange(location: caret.location + (typed as NSString).length, length: 0)
            return SearchPillEdit(text: join(kept, rest: rest), selected: [], caret: after, consumesKey: true)
        case .left:
            let to = live.count == 1 ? max(first - 1, 0) : first
            return SearchPillEdit(text: text, selected: [to], caret: start, consumesKey: true)
        case .right:
            if live.count == 1, last < count - 1 {
                return SearchPillEdit(text: text, selected: [last + 1], caret: start, consumesKey: true)
            }
            let end = live.count == 1 ? start : NSRange(location: whole.length, length: 0)
            return SearchPillEdit(text: text, selected: [], caret: end, consumesKey: true)
        case .selectAll:
            return SearchPillEdit(text: text, selected: all, caret: whole, consumesKey: true)
        case .escape:
            return SearchPillEdit(text: text, selected: [], caret: start, consumesKey: true)
        case .other:
            return letGo
        }
    }

    private static func token(in text: String, at start: String.Index) -> (SearchQueryToken, String.Index)? {
        var i = start
        var negated = false
        if i < text.endIndex, text[i] == "-" {
            negated = true
            i = text.index(after: i)
        }
        let nameStart = i
        while i < text.endIndex, text[i].isLetter || text[i] == "_" { i = text.index(after: i) }
        guard i > nameStart, i < text.endIndex, text[i] == ":" else { return nil }
        let name = String(text[nameStart..<i])
        guard known.contains(name.lowercased()) else { return nil }
        i = text.index(after: i)
        guard i < text.endIndex, !text[i].isWhitespace else { return nil }
        let valueStart = i
        switch text[i] {
        case "\"":
            i = text.index(after: i)
            while i < text.endIndex, text[i] != "\"" { i = text.index(after: i) }
            guard i < text.endIndex, text.distance(from: valueStart, to: i) > 1 else { return nil }
            i = text.index(after: i)
        case "(":
            var depth = 0
            repeat {
                if text[i] == "(" { depth += 1 } else if text[i] == ")" { depth -= 1 }
                i = text.index(after: i)
            } while depth > 0 && i < text.endIndex
            guard depth == 0 else { return nil }
        default:
            while i < text.endIndex, !text[i].isWhitespace, text[i] != "(", text[i] != ")" { i = text.index(after: i) }
            if i < text.endIndex, !text[i].isWhitespace { return nil }
        }
        let token = SearchQueryToken(name: name, value: String(text[valueStart..<i]), isNegated: negated)
        return (token, i)
    }
}

/// A key the search field's pills answer.
public enum SearchFieldKey: Equatable, Sendable {
    case deleteBackward, deleteForward, left, right, selectAll, escape
    case typing(String)
    case other
}

/// The field after a key: the query, the pills left selected, where the caret goes in the text after the pills (nil
/// leaves it), and whether the key stops there or goes on to the text.
public struct SearchPillEdit: Equatable {
    public let text: String
    public let selected: IndexSet
    public let caret: NSRange?
    public let consumesKey: Bool
}

/// Changes to the pills from a key or a click. Removing pills can be undone.
@MainActor
public enum SearchPills {
    public static func select(_ pill: Int, in search: SearchModel) {
        search.selectedPills = [pill]
        search.focusField()
    }

    public static func remove(_ pill: Int, from search: SearchModel, undoManager: UndoManager?) {
        setText(SearchQueryTokens.removing([pill], from: search.text), of: search, undoManager: undoManager)
        search.focusField()
    }

    public static func setText(_ text: String, of search: SearchModel, undoManager: UndoManager?) {
        let before = search.text
        guard text != before else { return }
        search.text = text
        registerUndo(restoring: before, redo: text, of: search, undoManager: undoManager)
    }

    private static func registerUndo(restoring text: String, redo: String, of search: SearchModel,
                                     undoManager: UndoManager?) {
        guard let undoManager else { return }
        let box = SearchPillUndoBox(search)
        undoManager.registerUndo(withTarget: box) { [box, weak undoManager] _ in
            MainActor.assumeIsolated {
                guard let search = box.search else { return }
                search.text = text
                registerUndo(restoring: redo, redo: text, of: search, undoManager: undoManager)
            }
        }
        undoManager.setActionName(String(localized: "Remove Filter"))
    }
}

final class SearchPillUndoBox {
    weak var search: SearchModel?
    init(_ search: SearchModel) { self.search = search }
}

struct SearchTokenPill: View {
    static let removeSize: CGFloat = 14

    let token: SearchQueryToken
    var isSelected = false
    var select: () -> Void = {}
    var remove: (() -> Void)?
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let showsRemove = remove != nil && (hovering || isSelected)
        // The value gives way when the field is short of room; the operator's name always shows
        HStack(spacing: 2) {
            Text(token.displayName)
                .fontWeight(.semibold)
                .foregroundStyle(isSelected ? theme.accentOnFill.color : theme.accentText.color)
                .fixedSize()
            Text(token.shortValue)
                .foregroundStyle(isSelected ? theme.accentOnFill.color : theme.textPrimary.color)
                .lineLimit(1)
        }
        .font(theme.typeLabel.swiftUIFont)
        // The remove control lies over the end of the value, which fades out under it, so it takes no room of its own
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                if showsRemove {
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.removeSize / 2)
                    Color.clear.frame(width: Self.removeSize / 2)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .overlay(alignment: .trailing) {
            if let remove, showsRemove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isSelected ? theme.accentOnFill.color : theme.textSecondary.color)
                        .frame(width: Self.removeSize, height: Self.removeSize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 3)
                .help(token.removeLabel)
                .accessibilityHidden(true)
            }
        }
        .background(RoundedRectangle(cornerRadius: theme.radiusPill)
            .fill(isSelected ? theme.accentFill.color : theme.accentFill.color.opacity(0.16)))
        .contentShape(RoundedRectangle(cornerRadius: theme.radiusPill))
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(token.spokenLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
        .accessibilityAction(named: Text(token.removeLabel)) { remove?() }
    }
}
