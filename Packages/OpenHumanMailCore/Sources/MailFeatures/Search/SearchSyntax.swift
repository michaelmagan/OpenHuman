import Foundation
import MailModel

public enum SearchOperator: String, CaseIterable, Sendable, Hashable {
    case from, to, subject, has, `is`, before, after, label, `in`

    public var insertion: String {
        switch self {
        case .has: "has:attachment"
        case .is: "is:unread"
        default: rawValue + ":"
        }
    }

    public var summary: String {
        switch self {
        case .from: "Sender"
        case .to: "Recipient"
        case .subject: "Words in the subject"
        case .has: "Has an attachment"
        case .is: "Unread mail"
        case .before: "Before a date, such as 2026/10/01"
        case .after: "On or after a date"
        case .label: "Has a label"
        case .in: "In a place, such as inbox or sent"
        }
    }

    public static let offered: [SearchOperator] = [.from, .to, .subject, .has, .is, .before, .after, .label, .in]
}

public struct SearchToken: Hashable, Sendable {
    public let text: String
    public let range: Range<String.Index>
    public let `operator`: SearchOperator?
    public let value: String
    public let isNegated: Bool
    public let isValid: Bool

    public var isChip: Bool { `operator` != nil }
}

public enum SearchSyntax {
    public static func tokens(_ text: String) -> [SearchToken] {
        var result: [SearchToken] = []
        var start: String.Index?
        var inQuote = false
        var depth = 0
        var index = text.startIndex
        func close(at end: String.Index) {
            guard let s = start else { return }
            result.append(token(String(text[s..<end]), range: s..<end))
            start = nil
        }
        while index < text.endIndex {
            let c = text[index]
            if c == "\"" { inQuote.toggle() }
            else if !inQuote, c == "(" { depth += 1 }
            else if !inQuote, c == ")" { depth = max(0, depth - 1) }
            if c.isWhitespace && !inQuote && depth == 0 {
                close(at: index)
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        close(at: text.endIndex)
        return result
    }

    static func token(_ word: String, range: Range<String.Index>) -> SearchToken {
        var body = Substring(word)
        let negated = body.hasPrefix("-") && body.count > 1
        if negated { body = body.dropFirst() }
        guard let colon = body.firstIndex(of: ":"),
              let op = SearchOperator(rawValue: body[..<colon].lowercased()) else {
            return SearchToken(text: word, range: range, operator: nil, value: "", isNegated: negated, isValid: true)
        }
        var value = String(body[body.index(after: colon)...])
        if value.hasPrefix("\"") { value.removeFirst() }
        if value.hasSuffix("\"") { value.removeLast() }
        return SearchToken(text: word, range: range, operator: op, value: value, isNegated: negated,
                           isValid: isValid(op, value))
    }

    static func isValid(_ op: SearchOperator, _ value: String) -> Bool {
        switch op {
        case .before, .after:
            return value.isEmpty || isDate(value)
        default:
            return true
        }
    }

    static func isDate(_ value: String) -> Bool {
        if value.count >= 9, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber) { return true }
        let parts = value.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "-" })
        guard parts.count == 3, parts[0].count == 4, (1...2).contains(parts[1].count), (1...2).contains(parts[2].count),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), (1...12).contains(m), (1...31).contains(d)
        else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return false }
        return cal.component(.day, from: date) == d && cal.component(.month, from: date) == m
    }
}

public struct SearchSuggestion: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable, Hashable {
        case recent
        case person
        case label
        case `operator`(SearchOperator)
        case saved
    }

    public enum Group: String, Sendable, Hashable, CaseIterable {
        case saved = "Saved"
        case recent = "Recent"
        case people = "People"
        case labels = "Labels"
        case operators = "Operators"
    }

    public var id: String { "\(kind)-\(replacement)" }
    public let kind: Kind
    public let title: String
    public let detail: String?
    public let replacement: String
    public var email: String? = nil

    public var group: Group {
        switch kind {
        case .saved: .saved
        case .recent: .recent
        case .person: .people
        case .label: .labels
        case .operator: .operators
        }
    }
}

/// A completion shown after the caret: `remainder` continues the typed word; `detail` follows a ⇥ and names what
/// Tab puts in when the remainder alone does not say it (a person's address).
public struct SearchGhost: Equatable, Sendable {
    public let remainder: String
    public let detail: String?

    public init(remainder: String, detail: String?) {
        self.remainder = remainder
        self.detail = detail
    }
}

public struct SearchSuggestions: Sendable {
    public static let maxRows = 8
    public static let maxRecent = 4
    /// The people an empty field offers: those written to most.
    public static let maxPeople = 4

    public struct Person: Sendable, Hashable {
        public let name: String?
        public let email: String

        public init(name: String?, email: String) {
            self.name = name
            self.email = email
        }
    }

    public static let maxSaved = 4

    public static let isValues: [(value: String, summary: String)] = [
        ("unread", "Unread mail"), ("read", "Read mail"), ("starred", "Starred mail"), ("important", "Important mail"),
        ("snoozed", "Snoozed conversations"),
        ("event", "Calendar invitations, calendar notices and event mail"),
    ]

    public static func make(text: String, recents: [String], labels: [String], people: [Person],
                            saved: [SavedSearch] = []) -> [SearchSuggestion] {
        let current = currentWord(text)
        guard let word = current else {
            let savedRows = text.isEmpty ? saved.prefix(maxSaved).map(savedSuggestion) : []
            let savedQueries = Set(saved.map(\.query))
            let frequent = text.isEmpty ? people.prefix(maxPeople).map { personSuggestion($0, prefix: "", name: "from") } : []
            let recent = text.isEmpty ? recents.filter { !savedQueries.contains($0) }.prefix(maxRecent).map {
                SearchSuggestion(kind: .recent, title: $0, detail: nil, replacement: $0)
            } : []
            let ops = SearchOperator.offered.map(operatorSuggestion)
            return Array((savedRows + frequent + recent + ops).prefix(maxRows))
        }
        let prefix = String(text[text.startIndex..<word.range.lowerBound])
        var negation = ""
        var body = word.text
        if body.hasPrefix("-") { negation = "-"; body.removeFirst() }
        if let colon = body.firstIndex(of: ":") {
            let name = body[..<colon].lowercased()
            var value = String(body[body.index(after: colon)...])
            if value.hasPrefix("\"") { value.removeFirst() }
            switch name {
            case "from", "to":
                let matches = people.filter { matches(value, $0) }.prefix(maxRows).map { person in
                    personSuggestion(person, prefix: prefix + negation, name: String(name))
                }
                return Array(matches)
            case "is":
                let typed = value.lowercased()
                return Array(isValues.filter { typed.isEmpty || $0.value.hasPrefix(typed) }.prefix(maxRows).map {
                    SearchSuggestion(kind: .operator(.is), title: "is:" + $0.value, detail: $0.summary,
                                     replacement: prefix + negation + "is:" + $0.value + " ")
                })
            case "label":
                let matches = labels.filter { value.isEmpty || $0.localizedCaseInsensitiveContains(value) }.prefix(maxRows).map {
                    SearchSuggestion(kind: .label, title: $0, detail: nil,
                                     replacement: prefix + negation + "label:" + quoted($0) + " ")
                }
                return Array(matches)
            default:
                return []
            }
        }
        let lowered = body.lowercased()
        var result: [SearchSuggestion] = []
        for op in SearchOperator.offered where op.rawValue.hasPrefix(lowered) {
            result.append(operatorSuggestion(op, prefix: prefix + negation))
        }
        if prefix.isEmpty, negation.isEmpty {
            for search in saved where result.count < maxRows
                && (search.name.localizedCaseInsensitiveContains(body) || search.query.localizedCaseInsensitiveContains(body)) {
                result.append(savedSuggestion(search))
            }
        }
        for person in people where matches(body, person) && result.count < maxRows {
            result.append(personSuggestion(person, prefix: prefix + negation, name: "from"))
        }
        for label in labels where label.localizedCaseInsensitiveContains(body) && result.count < maxRows {
            result.append(SearchSuggestion(kind: .label, title: label, detail: "Label",
                                           replacement: prefix + negation + "label:" + quoted(label) + " "))
        }
        return Array(result.prefix(maxRows))
    }

    /// Whether accepting the suggestion completes the word being typed (Tab), rather than running a search.
    public static func completes(_ suggestion: SearchSuggestion) -> Bool {
        switch suggestion.kind {
        case .recent, .saved: false
        case .person, .label, .operator: true
        }
    }

    /// The dim text after the caret for a completion: the rest of the word when the completion continues what was
    /// typed ("fro" → "m:"), the rest of a person's name with the address it will use ("from:mi" → "chael Ruiz",
    /// "dana@example.com"), and otherwise only what Tab puts in.
    public static func ghost(text: String, suggestion: SearchSuggestion) -> SearchGhost? {
        guard completes(suggestion), let word = currentWord(text) else { return nil }
        var replacement = suggestion.replacement
        while replacement.last?.isWhitespace == true { replacement.removeLast() }
        if replacement.count > text.count, replacement.lowercased().hasPrefix(text.lowercased()) {
            return SearchGhost(remainder: String(replacement.dropFirst(text.count)), detail: nil)
        }
        var typed = Substring(word.text)
        if typed.hasPrefix("-") { typed = typed.dropFirst() }
        if let colon = typed.firstIndex(of: ":") { typed = typed[typed.index(after: colon)...] }
        if typed.hasPrefix("\"") { typed = typed.dropFirst() }
        if suggestion.kind == .person, let email = suggestion.email {
            let name = suggestion.detail == nil ? nil : suggestion.title
            if let name, !typed.isEmpty, name.count > typed.count, name.lowercased().hasPrefix(typed.lowercased()) {
                return SearchGhost(remainder: String(name.dropFirst(typed.count)), detail: email)
            }
            return SearchGhost(remainder: "", detail: email)
        }
        if !typed.isEmpty, suggestion.title.count > typed.count, suggestion.title.lowercased().hasPrefix(typed.lowercased()) {
            return SearchGhost(remainder: String(suggestion.title.dropFirst(typed.count)), detail: nil)
        }
        return SearchGhost(remainder: "", detail: suggestion.title)
    }

    public static func currentWord(_ text: String) -> SearchToken? {
        guard let last = text.last, !last.isWhitespace else { return nil }
        return SearchSyntax.tokens(text).last
    }

    private static func operatorSuggestion(_ op: SearchOperator) -> SearchSuggestion { operatorSuggestion(op, prefix: "") }

    private static func personSuggestion(_ person: Person, prefix: String, name: String) -> SearchSuggestion {
        SearchSuggestion(kind: .person, title: person.name ?? person.email, detail: person.name == nil ? nil : person.email,
                         replacement: prefix + name + ":" + person.email + " ", email: person.email)
    }

    private static func savedSuggestion(_ search: SavedSearch) -> SearchSuggestion {
        SearchSuggestion(kind: .saved, title: search.name, detail: search.query == search.name ? nil : search.query,
                         replacement: search.query)
    }

    private static func operatorSuggestion(_ op: SearchOperator, prefix: String) -> SearchSuggestion {
        SearchSuggestion(kind: .operator(op), title: op.insertion, detail: op.summary, replacement: prefix + op.insertion)
    }

    private static func matches(_ typed: String, _ person: Person) -> Bool {
        typed.isEmpty || person.email.localizedCaseInsensitiveContains(typed)
            || (person.name?.localizedCaseInsensitiveContains(typed) ?? false)
    }

    static func quoted(_ value: String) -> String {
        value.contains(where: { $0.isWhitespace || $0 == "(" || $0 == ")" }) ? "\"\(value)\"" : value
    }
}
