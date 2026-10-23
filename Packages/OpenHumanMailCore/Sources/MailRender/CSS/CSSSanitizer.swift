import Foundation

indirect enum CSSComponent: Equatable {
    case token(CSSToken)
    case block(CSSToken, [CSSComponent])
    case function(String, [CSSComponent])
}

struct CSSDeclaration: Equatable {
    var name: String
    var value: [CSSComponent]
    var lowerName: String { name.lowercased() }
}

indirect enum CSSItem: Equatable {
    case style(selector: [CSSToken], declarations: [CSSDeclaration])
    case group(keyword: String, prelude: [CSSToken], items: [CSSItem])
    case keyframes(keyword: String, prelude: [CSSToken], frames: [CSSKeyframe])
}

struct CSSKeyframe: Equatable {
    var selector: [CSSToken]
    var declarations: [CSSDeclaration]
}

public struct CSSSanitizeStats: Equatable, Sendable {
    public var remoteReferences = 0
    public var blockedRemote = 0
    public var trackers = 0
    public var dropped = 0
    public var hasDarkMediaQuery = false
    public var inlineContentIDs: [String] = []
    public var trackerHosts: [String] = []
    public init() {}
}

public struct CSSSanitizer {
    public var allowRemoteImages: Bool
    public var scopeSelectors: Bool
    public var trackerHosts: Set<String>
    var composeURLs = false
    public private(set) var stats = CSSSanitizeStats()
    private static let maxNesting = 8

    public init(allowRemoteImages: Bool, scopeSelectors: Bool = false, trackerHosts: Set<String> = TrackerList.hosts) {
        self.allowRemoteImages = allowRemoteImages
        self.scopeSelectors = scopeSelectors
        self.trackerHosts = trackerHosts
    }

    public mutating func sanitizeDeclarations(_ css: String) -> String {
        CSSSerializer.serialize(CSSWriter.tokens(declarations(css)))
    }

    public mutating func sanitizeStylesheet(_ css: String) -> String {
        CSSSerializer.serialize(CSSWriter.tokens(stylesheet(css)))
    }

    mutating func declarations(_ css: String) -> [CSSDeclaration] {
        sanitizedDeclarations(Self.parseComponents(CSSTokenizer.tokenize(css)))
    }

    mutating func stylesheet(_ css: String) -> [CSSItem] {
        sanitizedItems(Self.parseComponents(CSSTokenizer.tokenize(css)), nesting: 0)
    }

    static func parseComponents(_ tokens: [CSSToken]) -> [CSSComponent] {
        var index = 0
        return parseList(tokens, &index, closing: nil, depth: 0)
    }

    private static func parseList(_ tokens: [CSSToken], _ i: inout Int, closing: CSSToken?, depth: Int) -> [CSSComponent] {
        var out: [CSSComponent] = []
        while i < tokens.count {
            let t = tokens[i]
            i += 1
            if let closing, t == closing { return out }
            switch t {
            case .function(let name) where depth < 64:
                out.append(.function(name, parseList(tokens, &i, closing: .closeParen, depth: depth + 1)))
            case .openParen where depth < 64:
                out.append(.block(t, parseList(tokens, &i, closing: .closeParen, depth: depth + 1)))
            case .openSquare where depth < 64:
                out.append(.block(t, parseList(tokens, &i, closing: .closeSquare, depth: depth + 1)))
            case .openCurly where depth < 64:
                out.append(.block(t, parseList(tokens, &i, closing: .closeCurly, depth: depth + 1)))
            case .function, .openParen, .openSquare, .openCurly:
                out.append(.token(.badString))
            case .closeParen, .closeSquare, .closeCurly:
                continue
            default:
                out.append(.token(t))
            }
        }
        return out
    }

    private mutating func sanitizedItems(_ components: [CSSComponent], nesting: Int) -> [CSSItem] {
        var out: [CSSItem] = []
        var i = 0
        while i < components.count {
            let c = components[i]
            switch c {
            case .token(.whitespace), .token(.cdo), .token(.cdc), .token(.semicolon):
                i += 1
            case .token(.atKeyword(let name)):
                var prelude: [CSSComponent] = []
                var block: [CSSComponent]?
                i += 1
                while i < components.count {
                    let p = components[i]
                    i += 1
                    if case .token(.semicolon) = p { break }
                    if case .block(.openCurly, let inner) = p { block = inner; break }
                    prelude.append(p)
                }
                if let item = sanitizedAtRule(name.lowercased(), prelude: prelude, block: block, nesting: nesting) {
                    out.append(item)
                }
            default:
                var prelude: [CSSComponent] = []
                var block: [CSSComponent]?
                while i < components.count {
                    let p = components[i]
                    i += 1
                    if case .block(.openCurly, let inner) = p { block = inner; break }
                    prelude.append(p)
                }
                guard let block else { stats.dropped += 1; continue }
                guard preludeIsSafe(prelude), let selector = scopedSelector(trimmed(prelude)) else {
                    stats.dropped += 1
                    continue
                }
                let declarations = sanitizedDeclarations(block)
                if !declarations.isEmpty { out.append(.style(selector: selector, declarations: declarations)) }
            }
        }
        return out
    }

    private mutating func sanitizedAtRule(_ name: String, prelude: [CSSComponent], block: [CSSComponent]?,
                                          nesting: Int) -> CSSItem? {
        switch name {
        case "media", "supports":
            guard let block, nesting < Self.maxNesting, preludeIsSafe(prelude) else { stats.dropped += 1; return nil }
            let tokens = flatten(trimmed(prelude))
            if name == "media", Self.isDarkMediaQuery(tokens) { stats.hasDarkMediaQuery = true }
            return .group(keyword: name, prelude: tokens, items: sanitizedItems(block, nesting: nesting + 1))
        case "keyframes", "-webkit-keyframes":
            guard let block, preludeIsSafe(prelude) else { stats.dropped += 1; return nil }
            return .keyframes(keyword: name, prelude: flatten(trimmed(prelude)), frames: sanitizedKeyframes(block))
        default:
            stats.dropped += 1
            return nil
        }
    }

    private mutating func sanitizedKeyframes(_ components: [CSSComponent]) -> [CSSKeyframe] {
        var frames: [CSSKeyframe] = []
        var prelude: [CSSComponent] = []
        for c in components {
            if case .block(.openCurly, let inner) = c {
                let selector = flatten(trimmed(prelude))
                let ok = !selector.isEmpty && selector.allSatisfy {
                    switch $0 {
                    case .percentage, .comma, .whitespace: return true
                    case .ident(let k): return ["from", "to"].contains(k.lowercased())
                    default: return false
                    }
                }
                if ok { frames.append(CSSKeyframe(selector: selector, declarations: sanitizedDeclarations(inner))) } else { stats.dropped += 1 }
                prelude = []
            } else {
                prelude.append(c)
            }
        }
        return frames
    }

    static func isDarkMediaQuery(_ tokens: [CSSToken]) -> Bool {
        let idents = tokens.compactMap { t -> String? in if case .ident(let s) = t { return s.lowercased() }; return nil }
        return idents.contains("prefers-color-scheme") && idents.contains("dark")
    }

    private func preludeIsSafe(_ prelude: [CSSComponent]) -> Bool {
        for token in flatten(prelude) {
            switch token {
            case .url, .badURL, .badString, .atKeyword: return false
            case .function(let f) where Self.urlFunctions.contains(f.lowercased()): return false
            case .ident(let s), .hash(let s), .string(let s), .function(let s):
                if s.lowercased().hasPrefix("oh-") { return false }
            default: continue
            }
        }
        return true
    }

    func scopedSelector(_ prelude: [CSSComponent]) -> [CSSToken]? {
        guard scopeSelectors else { return flatten(prelude) }
        var selectors: [[CSSComponent]] = [[]]
        for c in prelude {
            if case .token(.comma) = c { selectors.append([]) } else { selectors[selectors.count - 1].append(c) }
        }
        var out: [CSSToken] = []
        for raw in selectors {
            let selector = trimmed(raw)
            guard !selector.isEmpty else { return nil }
            if !out.isEmpty { out.append(.comma) }
            out += scoped(selector)
        }
        return out
    }

    private static let scopeClass: [CSSToken] = [.delim("."), .ident("oh-body")]

    private func scoped(_ s: [CSSComponent]) -> [CSSToken] {
        func isRootCompoundStart(_ i: Int) -> Int? {
            guard i < s.count else { return nil }
            if case .token(.ident(let n)) = s[i], ["html", "body"].contains(n.lowercased()) { return i + 1 }
            if case .token(.colon) = s[i], i + 1 < s.count, case .token(.ident(let n)) = s[i + 1], n.lowercased() == "root" {
                return i + 2
            }
            return nil
        }
        func isBoundary(_ c: CSSComponent) -> Bool {
            switch c {
            case .token(.whitespace), .token(.delim(">")), .token(.delim("+")), .token(.delim("~")): return true
            default: return false
            }
        }
        var i = 0
        var attached: [CSSComponent] = []
        var stripped = false
        while let afterType = isRootCompoundStart(i) {
            stripped = true
            var k = afterType
            while k < s.count, !isBoundary(s[k]) { k += 1 }
            let rest = Array(s[afterType..<k])
            if !rest.isEmpty { attached += rest; i = k; break }
            var m = k
            while m < s.count, case .token(.whitespace) = s[m] { m += 1 }
            if m < s.count, case .token(.delim(let d)) = s[m], [">", "+", "~"].contains(d) {
                m += 1
                while m < s.count, case .token(.whitespace) = s[m] { m += 1 }
            }
            if isRootCompoundStart(m) != nil { i = m; continue }
            i = k
            break
        }
        if stripped {
            return Self.scopeClass + flatten(attached) + flatten(Array(s[i...]))
        }
        return Self.scopeClass + [.whitespace] + flatten(s)
    }

    private static let forbiddenProperties: Set<String> = [
        "behavior", "-ms-behavior", "-moz-binding", "binding", "-webkit-user-modify", "user-modify",
    ]
    static let urlFunctions: Set<String> = [
        "url", "src", "image", "image-set", "-webkit-image-set", "cross-fade", "-webkit-cross-fade",
        "element", "-moz-element", "paint", "expression", "-webkit-canvas", "-webkit-named-image",
    ]
    private static let filterProperties: Set<String> = ["filter", "-webkit-filter", "backdrop-filter", "-webkit-backdrop-filter"]
    private static let absoluteUnits: Set<String> = ["px", "pt", "pc", "in", "cm", "mm", "q"]

    // Lengths that follow the viewport's height are given at a fixed one. Why: the reader's viewport is as tall as the
    // message, so `height: 100vh` with anything below it makes the message taller on every layout, without end.
    // Container units are here too: without a sized container they follow the viewport.
    static let fixedViewportHeight = 600.0
    private static let viewportHeightUnits: Set<String> = ["vh", "svh", "lvh", "dvh", "vb", "svb", "lvb", "dvb", "cqh", "cqb"]
    private static let viewportMinUnits: Set<String> = ["vmin", "svmin", "lvmin", "dvmin", "cqmin"]
    private static let viewportMaxUnits: Set<String> = ["vmax", "svmax", "lvmax", "dvmax", "cqmax"]

    private mutating func sanitizedDeclarations(_ components: [CSSComponent]) -> [CSSDeclaration] {
        var out: [CSSDeclaration] = []
        var current: [CSSComponent] = []
        for c in components {
            if case .token(.semicolon) = c {
                if let d = sanitizedDeclaration(current) { out.append(d) }
                current = []
                continue
            }
            current.append(c)
        }
        if let d = sanitizedDeclaration(current) { out.append(d) }
        return out
    }

    private mutating func sanitizedDeclaration(_ parts: [CSSComponent]) -> CSSDeclaration? {
        let parts = trimmed(parts)
        guard !parts.isEmpty else { return nil }
        guard case .token(.ident(let rawName)) = parts[0] else { stats.dropped += 1; return nil }
        var i = 1
        while i < parts.count, case .token(.whitespace) = parts[i] { i += 1 }
        guard i < parts.count, case .token(.colon) = parts[i] else { stats.dropped += 1; return nil }
        var value = trimmed(Array(parts[(i + 1)...]))
        let name = rawName.lowercased()

        if Self.forbiddenProperties.contains(name) { stats.dropped += 1; return nil }
        if value.contains(where: { if case .block(.openCurly, _) = $0 { return true }; return false }) {
            stats.dropped += 1
            return nil
        }
        let flat = flatten(value)
        for token in flat {
            switch token {
            case .badURL, .badString, .atKeyword:
                stats.dropped += 1
                return nil
            case .function(let f):
                let lower = f.lowercased()
                if Self.urlFunctions.contains(lower) && lower != "url" { stats.dropped += 1; return nil }
                if lower == "attr" && name != "content" { stats.dropped += 1; return nil }
                if Self.filterProperties.contains(name), lower == "invert" || lower == "hue-rotate" {
                    stats.dropped += 1
                    return nil
                }
            default:
                continue
            }
        }
        if name == "position", flat.contains(where: {
            if case .ident(let v) = $0 { return ["fixed", "sticky", "-webkit-sticky"].contains(v.lowercased()) }
            return false
        }) {
            stats.dropped += 1
            return nil
        }
        if name == "z-index" {
            let numbers = flat.compactMap { t -> Double? in if case .number(let n) = t { return Double(n) }; return nil }
            if let n = numbers.first {
                let clamped = Int(min(max(n, -1), 100))
                value = [.token(.number(String(clamped)))]
            }
        }
        guard let rewritten = rewriteURLs(value) else { stats.dropped += 1; return nil }
        return CSSDeclaration(name: rawName, value: clampedNumbers(rewritten))
    }

    private func clampedNumbers(_ components: [CSSComponent]) -> [CSSComponent] {
        components.map { c in
            switch c {
            case .token(.dimension(let n, let unit)):
                guard let v = Double(n) else { return c }
                let limit = Self.absoluteUnits.contains(unit.lowercased()) ? 10_000.0 : 1_000.0
                let inRange = v.isFinite && abs(v) <= limit
                if let fixed = Self.atFixedViewport(inRange ? v : (v.isFinite && v < 0 ? -limit : limit), unit: unit) {
                    return fixed
                }
                guard !inRange else { return c }
                return .token(.dimension(Self.number(v.isFinite ? (v < 0 ? -limit : limit) : limit), unit: unit))
            case .token(.percentage(let n)):
                guard let v = Double(n), !v.isFinite || abs(v) > 10_000 else { return c }
                return .token(.percentage(Self.number(v < 0 ? -10_000 : 10_000)))
            case .token(.number(let n)):
                guard let v = Double(n), !v.isFinite || abs(v) > 1_000_000 else { return c }
                return .token(.number(Self.number(v < 0 ? -1_000_000 : 1_000_000)))
            case .function(let f, let args):
                return .function(f, clampedNumbers(args))
            case .block(let open, let inner):
                return .block(open, clampedNumbers(inner))
            default:
                return c
            }
        }
    }

    private static func number(_ v: Double) -> String { String(Int(v)) }

    static func atFixedViewport(_ v: Double, unit: String) -> CSSComponent? {
        let lower = unit.lowercased()
        let height = CSSToken.dimension(decimal(v * fixedViewportHeight / 100), unit: "px")
        if viewportHeightUnits.contains(lower) { return .token(height) }
        let isMin = viewportMinUnits.contains(lower)
        guard isMin || viewportMaxUnits.contains(lower) else { return nil }
        let width = CSSToken.dimension(decimal(v), unit: lower.hasPrefix("cq") ? "cqi" : "vw")
        return .function(isMin ? "min" : "max", [.token(width), .token(.comma), .token(height)])
    }

    private static func decimal(_ v: Double) -> String {
        let rounded = (v * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    private mutating func rewriteURLs(_ components: [CSSComponent]) -> [CSSComponent]? {
        var out: [CSSComponent] = []
        for c in components {
            switch c {
            case .token(.url(let raw)):
                guard let kept = checkedImageURL(raw) else { return nil }
                out.append(.token(.url(kept)))
            case .function(let f, let args) where f.lowercased() == "url":
                let strings = args.compactMap { a -> String? in if case .token(.string(let s)) = a { return s }; return nil }
                guard strings.count == 1, let kept = checkedImageURL(strings[0]) else { return nil }
                out.append(.token(.url(kept)))
            case .function(let f, let args):
                guard let inner = rewriteURLs(args) else { return nil }
                out.append(.function(f, inner))
            case .block(let open, let inner):
                guard let inner = rewriteURLs(inner) else { return nil }
                out.append(.block(open, inner))
            default:
                out.append(c)
            }
        }
        return out
    }

    private mutating func checkedImageURL(_ raw: String) -> String? {
        switch URLPolicy.classify(raw, context: composeURLs ? .composeImage : .image) {
        case .allow(let url):
            if let id = InlineParts.contentID(fromString: url) { stats.inlineContentIDs.append(id) }
            return url
        case .remote(let url):
            stats.remoteReferences += 1
            if TrackerList.isTracker(url: url, in: trackerHosts) {
                stats.trackers += 1
                if let host = URLPolicy.httpParts(url)?.host { stats.trackerHosts.append(host) }
                stats.blockedRemote += 1
                return nil
            }
            if allowRemoteImages { return url }
            stats.blockedRemote += 1
            return nil
        case .reject:
            return nil
        }
    }

    func trimmed(_ c: [CSSComponent]) -> [CSSComponent] {
        var c = c[...]
        while let f = c.first, case .token(.whitespace) = f { c = c.dropFirst() }
        while let l = c.last, case .token(.whitespace) = l { c = c.dropLast() }
        return Array(c)
    }

    func flatten(_ components: [CSSComponent]) -> [CSSToken] { CSSWriter.flatten(components) }
}

enum CSSWriter {
    static func tokens(_ declarations: [CSSDeclaration]) -> [CSSToken] {
        var out: [CSSToken] = []
        for d in declarations {
            if !out.isEmpty { out.append(.semicolon) }
            out += [.ident(d.name), .colon] + flatten(d.value)
        }
        return out
    }

    static func tokens(_ items: [CSSItem]) -> [CSSToken] {
        var out: [CSSToken] = []
        for item in items {
            switch item {
            case .style(let selector, let declarations):
                out += selector + [.openCurly] + tokens(declarations) + [.closeCurly]
            case .group(let keyword, let prelude, let inner):
                out += [.atKeyword(keyword), .whitespace] + prelude + [.openCurly] + tokens(inner) + [.closeCurly]
            case .keyframes(let keyword, let prelude, let frames):
                out += [.atKeyword(keyword), .whitespace] + prelude + [.openCurly]
                for f in frames { out += f.selector + [.openCurly] + tokens(f.declarations) + [.closeCurly] }
                out.append(.closeCurly)
            }
        }
        return out
    }

    static func flatten(_ components: [CSSComponent]) -> [CSSToken] {
        var out: [CSSToken] = []
        for c in components {
            switch c {
            case .token(let t): out.append(t)
            case .function(let name, let args): out.append(.function(name)); out += flatten(args); out.append(.closeParen)
            case .block(let open, let inner):
                out.append(open)
                out += flatten(inner)
                switch open {
                case .openParen: out.append(.closeParen)
                case .openSquare: out.append(.closeSquare)
                default: out.append(.closeCurly)
                }
            }
        }
        return out
    }
}
