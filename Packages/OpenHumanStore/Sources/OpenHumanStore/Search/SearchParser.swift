import Foundation

struct SearchParseOptions: Sendable {
    var now: Date
    var calendar: Calendar
    init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }
}

indirect enum SearchParseNode: Equatable {
    case leaf(SearchTerm, position: Int)
    case not(SearchParseNode, position: Int)
    case or([SearchParseNode], position: Int)
    case and([SearchParseNode], position: Int)

    var term: SearchTerm? {
        switch self {
        case let .leaf(term, _): return term
        case let .not(inner, _): return inner.term.map { .not($0) }
        case let .or(children, _):
            let terms = children.compactMap(\.term)
            return terms.count > 1 ? .or(terms) : terms.first
        case let .and(children, _):
            let terms = children.compactMap(\.term)
            return terms.count > 1 ? .and(terms) : terms.first
        }
    }
}

enum SearchParser {
    static let maxLength = 2048
    static let maxDepth = 24
    static let maxLeaves = 64

    static let operators: Set<String> = [
        "from", "to", "cc", "bcc", "deliveredto", "subject", "label", "category", "in", "is", "has", "filename",
        "before", "after", "older_than", "newer_than", "larger", "smaller", "size", "list", "rfc822msgid",
    ]

    static func parse(_ text: String, options: SearchParseOptions = SearchParseOptions()) throws -> SearchQuery {
        let nodes = try parseNodes(text, options: options)
        var terms: [SearchTerm] = []
        for node in nodes {
            guard let term = node.term else { continue }
            if case let .and(inner) = term, case .and = node { terms += inner } else { terms.append(term) }
        }
        guard !terms.isEmpty else { throw StoreError.invalidQuery("empty query", position: 0) }
        return SearchQuery(text: text, terms: terms)
    }

    static func parseNodes(_ text: String, options: SearchParseOptions = SearchParseOptions()) throws -> [SearchParseNode] {
        var parser = Parser(scalars: Array(text.unicodeScalars), options: options)
        return try parser.run()
    }

    static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.map {
            $0.properties.generalCategory == .control ? " " : $0
        })
        return SearchTextNormalizer.normalizeField(String(scalars))
    }

    private enum Kind: Equatable { case word, phrase, lparen, rparen, lbrace, rbrace, minus }

    private struct Token {
        var kind: Kind
        var text: String
        var start: Int
        var end: Int
    }

    private static func isBreak(_ s: Unicode.Scalar) -> Bool {
        s == "(" || s == ")" || s == "{" || s == "}" || s == "\""
    }

    private static func lex(_ scalars: [Unicode.Scalar]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s.properties.isWhitespace || s.properties.generalCategory == .control { i += 1; continue }
            switch s {
            case "(": tokens.append(Token(kind: .lparen, text: "(", start: i, end: i + 1)); i += 1
            case ")": tokens.append(Token(kind: .rparen, text: ")", start: i, end: i + 1)); i += 1
            case "{": tokens.append(Token(kind: .lbrace, text: "{", start: i, end: i + 1)); i += 1
            case "}": tokens.append(Token(kind: .rbrace, text: "}", start: i, end: i + 1)); i += 1
            case "\"":
                var j = i + 1
                var body = String.UnicodeScalarView()
                while j < scalars.count, scalars[j] != "\"" { body.append(scalars[j]); j += 1 }
                let end = j < scalars.count ? j + 1 : j
                tokens.append(Token(kind: .phrase, text: String(body), start: i, end: end))
                i = end
            case "-" where i + 1 < scalars.count && !scalars[i + 1].properties.isWhitespace:
                tokens.append(Token(kind: .minus, text: "-", start: i, end: i + 1)); i += 1
            case "-":
                i += 1
            default:
                var j = i
                var body = String.UnicodeScalarView()
                while j < scalars.count, !scalars[j].properties.isWhitespace, scalars[j].properties.generalCategory != .control,
                      !isBreak(scalars[j]) {
                    body.append(scalars[j]); j += 1
                }
                tokens.append(Token(kind: .word, text: String(body), start: i, end: j))
                i = j
            }
        }
        return tokens
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        let options: SearchParseOptions
        var tokens: [Token] = []
        var index = 0
        var depth = 0
        var leaves = 0

        init(scalars: [Unicode.Scalar], options: SearchParseOptions) {
            self.scalars = scalars
            self.options = options
        }

        var current: Token? { index < tokens.count ? tokens[index] : nil }

        mutating func run() throws -> [SearchParseNode] {
            guard scalars.count <= SearchParser.maxLength else {
                throw StoreError.invalidQuery("query too long", position: SearchParser.maxLength)
            }
            tokens = SearchParser.lex(scalars)
            let nodes = try parseSequence(context: nil, closer: nil)
            if let stray = current {
                throw StoreError.invalidQuery("unexpected \(stray.text)", position: stray.start)
            }
            return nodes
        }

        func fail(_ message: String, _ position: Int) -> StoreError { .invalidQuery(message, position: position) }

        mutating func parseSequence(context: String?, closer: Kind?) throws -> [SearchParseNode] {
            var nodes: [SearchParseNode] = []
            while let token = current {
                if token.kind == closer { break }
                if token.kind == .rparen || token.kind == .rbrace { break }
                if token.kind == .word, token.text == "AND" { index += 1; continue }
                if let node = try parseOr(context: context) { nodes.append(node) }
            }
            return nodes
        }

        mutating func parseOr(context: String?) throws -> SearchParseNode? {
            let start = current?.start ?? 0
            let first = try parseUnary(context: context)
            guard let token = current, token.kind == .word, token.text == "OR" else { return first }
            var children: [SearchParseNode] = []
            if let first { children.append(first) } else { throw fail("OR needs a term before it", token.start) }
            while let t = current, t.kind == .word, t.text == "OR" {
                index += 1
                guard let next = try parseUnary(context: context) else { throw fail("OR needs a term after it", t.start) }
                children.append(next)
            }
            return .or(children, position: start)
        }

        mutating func parseUnary(context: String?) throws -> SearchParseNode? {
            guard let token = current else { return nil }
            switch token.kind {
            case .minus:
                index += 1
                guard let operand = try parseUnary(context: context) else { return nil }
                return .not(operand, position: token.start)
            case .lparen:
                let children = try group(open: token, close: .rparen, context: context) { p in
                    try p.parseSequence(context: context, closer: .rparen)
                }
                return .and(children, position: token.start)
            case .lbrace:
                let children = try group(open: token, close: .rbrace, context: context) { p in
                    var items: [SearchParseNode] = []
                    while let t = p.current, t.kind != .rbrace, t.kind != .rparen {
                        if t.kind == .word, t.text == "OR" || t.text == "AND" { p.index += 1; continue }
                        if let node = try p.parseUnary(context: context) { items.append(node) }
                    }
                    return items
                }
                return .or(children, position: token.start)
            case .rparen, .rbrace:
                return nil
            case .phrase:
                index += 1
                return try leaf(text: token.text, context: context, position: token.start)
            case .word:
                if token.text == "OR" { return nil }
                return try parseWord(token, context: context)
            }
        }

        mutating func group(open: Token, close: Kind, context: String?,
                            body: (inout Parser) throws -> [SearchParseNode]) throws -> [SearchParseNode] {
            index += 1
            depth += 1
            defer { depth -= 1 }
            guard depth <= SearchParser.maxDepth else { throw fail("query nested too deeply", open.start) }
            let children = try body(&self)
            guard let end = current, end.kind == close else {
                throw fail("unclosed \(open.text)", open.start)
            }
            index += 1
            return children
        }

        mutating func parseWord(_ token: Token, context: String?) throws -> SearchParseNode? {
            index += 1
            if token.text == "NOT" {
                guard let operand = try parseUnary(context: context) else { throw fail("NOT needs a term", token.start) }
                return .not(operand, position: token.start)
            }
            if token.text == "AROUND" || token.text.hasPrefix("AROUND_") {
                throw fail("AROUND is not supported", token.start)
            }
            guard context == nil, let colon = token.text.firstIndex(of: ":") else {
                return try leaf(text: token.text, context: context, position: token.start)
            }
            let name = token.text[..<colon].lowercased()
            guard SearchParser.operators.contains(name) else {
                return try leaf(text: token.text, context: context, position: token.start)
            }
            let inline = String(token.text[token.text.index(after: colon)...])
            if !inline.isEmpty { return try operatorNode(name, inline, position: token.start) }
            guard let next = current, next.start == token.end else { throw fail("\(name): needs a value", token.start) }
            switch next.kind {
            case .phrase:
                index += 1
                return try operatorNode(name, next.text, position: token.start)
            case .lparen:
                let children = try group(open: next, close: .rparen, context: name) { p in
                    try p.parseSequence(context: name, closer: .rparen)
                }
                return .and(children, position: token.start)
            default:
                throw fail("\(name): needs a value", token.start)
            }
        }

        mutating func leaf(text: String, context: String?, position: Int) throws -> SearchParseNode? {
            leaves += 1
            guard leaves <= SearchParser.maxLeaves else { throw fail("query has too many terms", position) }
            if let context { return try operatorNode(context, text, position: position) }
            let cleaned = SearchParser.clean(text)
            guard !cleaned.isEmpty else { return nil }
            return .leaf(.text(cleaned, field: nil), position: position)
        }

        func operatorNode(_ name: String, _ rawValue: String, position: Int) throws -> SearchParseNode? {
            let value = SearchParser.clean(rawValue)
            guard !value.isEmpty else { throw fail("\(name): needs a value", position) }
            if let term = try SearchOperators.term(name: name, value: value, options: options, position: position) {
                return .leaf(term, position: position)
            }
            return .leaf(.text("\(name):\(value)", field: nil), position: position)
        }
    }
}

enum SearchOperators {
    static let categories: [String: String] = [
        "primary": "CATEGORY_PERSONAL", "personal": "CATEGORY_PERSONAL", "social": "CATEGORY_SOCIAL",
        "promotions": "CATEGORY_PROMOTIONS", "updates": "CATEGORY_UPDATES", "forums": "CATEGORY_FORUMS",
    ]

    static func term(name: String, value: String, options: SearchParseOptions, position: Int) throws -> SearchTerm? {
        let lower = value.lowercased()
        switch name {
        case "from": return .address(.from, value)
        case "to", "deliveredto": return .address(.to, value)
        case "cc": return .address(.cc, value)
        case "bcc": return .address(.bcc, value)
        case "subject": return .text(value, field: .subject)
        case "label": return .label(value)
        case "category": return categories[lower].map { .label($0) }
        case "filename": return .filename(value)
        case "list": return .listID(value)
        case "rfc822msgid": return .rfc822msgid(value.trimmingCharacters(in: CharacterSet(charactersIn: "<>")))
        case "in":
            switch lower {
            case "anywhere": return .anywhere
            case "draft", "drafts": return .mailbox(.drafts)
            case "all", "allmail": return .mailbox(.allMail)
            default:
                if let box = SystemMailbox(rawValue: lower) ?? SystemMailbox(rawValue: lower.replacingOccurrences(of: "-", with: "")) {
                    return .mailbox(box)
                }
                return .label(value)
            }
        case "is":
            switch lower {
            case "unread": return .isFlag(.unread)
            case "read": return .isFlag(.read)
            case "starred": return .isFlag(.starred)
            case "important": return .isFlag(.important)
            case "draft": return .isFlag(.draft)
            case "snoozed": return .isFlag(.snoozed)
            case "event", "events": return .isFlag(.event)
            default: return nil
            }
        case "has":
            switch lower {
            case "attachment": return .has(.attachment)
            case "invite", "calendar": return .has(.invite)
            case "userlabels": return .has(.userLabels)
            case "nouserlabels": return .not(.has(.userLabels))
            default: return nil
            }
        case "before": return .before(try date(value, options: options, position: position))
        case "after": return .after(try date(value, options: options, position: position))
        case "older_than": return .before(try relativeDate(value, options: options, position: position))
        case "newer_than": return .after(try relativeDate(value, options: options, position: position))
        case "larger": return .larger(try size(value, position: position))
        case "smaller": return .smaller(try size(value, position: position))
        case "size":
            let n = try size(value, position: position)
            let (above, overflow) = n.addingReportingOverflow(1)
            guard !overflow else { throw StoreError.invalidQuery("invalid size \(value)", position: position) }
            return .and([.larger(n - 1), .smaller(above)])
        default: return nil
        }
    }

    static func date(_ value: String, options: SearchParseOptions, position: Int) throws -> Date {
        let bad = StoreError.invalidQuery("invalid date \(value)", position: position)
        if value.allSatisfy(\.isASCIIDigit), value.count >= 9, value.count <= 11, let seconds = Int64(value) {
            return Date(timeIntervalSince1970: Double(seconds))
        }
        let parts = value.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "-" })
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isASCIIDigit) }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), parts[0].count == 4
        else { throw bad }
        guard let date = options.calendar.date(from: DateComponents(year: y, month: m, day: d)) else { throw bad }
        let back = options.calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { throw bad }
        return date
    }

    static func relativeDate(_ value: String, options: SearchParseOptions, position: Int) throws -> Date {
        let bad = StoreError.invalidQuery("invalid relative date \(value)", position: position)
        guard let unit = value.last, "dmy".contains(unit.lowercased()), value.count >= 2, value.count <= 7,
              let n = Int(value.dropLast()), n >= 0 else { throw bad }
        let component: Calendar.Component = unit.lowercased() == "d" ? .day : unit.lowercased() == "m" ? .month : .year
        guard let date = options.calendar.date(byAdding: component, value: -n, to: options.now) else { throw bad }
        return Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    static func size(_ value: String, position: Int) throws -> Int {
        let bad = StoreError.invalidQuery("invalid size \(value)", position: position)
        var digits = value
        var factor = 1
        if let unit = digits.last, !unit.isASCIIDigit {
            switch unit.lowercased() {
            case "k": factor = 1 << 10
            case "m": factor = 1 << 20
            case "g": factor = 1 << 30
            default: throw bad
            }
            digits.removeLast()
        }
        guard !digits.isEmpty, digits.count <= 10, digits.allSatisfy(\.isASCIIDigit), let n = Int(digits) else { throw bad }
        let (bytes, overflow) = n.multipliedReportingOverflow(by: factor)
        guard !overflow else { throw bad }
        return bytes
    }
}

private extension Character {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}
