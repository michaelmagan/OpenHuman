import Foundation

/// Removes the prompt's own scaffolding from model output: the `email_data`, `user_instruction` and `context`
/// tags (opening or closing, any attributes, case or look-alike brackets) and the request's nonce. Small models
/// sometimes copy the block format of their input into the answer; none of it may reach a draft or a preview.
///
/// It works on a stream: text that could still turn into a tag or the nonce is held back until it is decided,
/// so a tag split across chunks never shows. Whitespace next to a removed piece is merged so a tag on a line of
/// its own leaves no blank line, and whitespace before the first or after the last removed piece is dropped.
public struct PromptScaffoldingFilter: Sendable {
    static let maxTagScalars = 512
    static let openers: Set<Unicode.Scalar> = ["<", "\u{2039}"]
    static let closers: Set<Unicode.Scalar> = [">", "\u{203A}"]

    private let nonce: [Unicode.Scalar]
    private var held: [Unicode.Scalar] = []
    private var space: [Unicode.Scalar] = []
    private var spaceBefore: [Unicode.Scalar] = []
    private var removedSinceContent = false
    private var emittedContent = false
    public private(set) var removedAny = false

    public init(nonce: String?) {
        self.nonce = Array((nonce ?? "").lowercased().unicodeScalars)
    }

    public static func strip(_ text: String, nonce: String?) -> String {
        var filter = PromptScaffoldingFilter(nonce: nonce)
        return filter.feed(text) + filter.finish()
    }

    public mutating func feed(_ delta: String) -> String {
        held.append(contentsOf: delta.unicodeScalars)
        return drain(final: false)
    }

    public mutating func finish() -> String {
        var out = drain(final: true)
        if !removedSinceContent { out.unicodeScalars.append(contentsOf: space) }
        space = []
        spaceBefore = []
        return out
    }

    private enum Decision {
        case content
        case remove(Int)
        case wait
    }

    private mutating func drain(final: Bool) -> String {
        var out = String.UnicodeScalarView()
        var index = 0
        while index < held.count {
            let scalar = held[index]
            if scalar.properties.isWhitespace {
                space.append(scalar)
                index += 1
                continue
            }
            switch decide(at: index, final: final) {
            case .wait:
                held.removeFirst(index)
                return String(out)
            case .remove(let count):
                if removedSinceContent {
                    if Self.weight(space) > Self.weight(spaceBefore) { spaceBefore = space }
                } else {
                    spaceBefore = space
                }
                space = []
                removedSinceContent = true
                removedAny = true
                index += count
            case .content:
                if removedSinceContent {
                    if emittedContent {
                        let joined = space.isEmpty
                            ? (Self.isClosingPunctuation(scalar) ? [] : spaceBefore)
                            : (Self.weight(space) >= Self.weight(spaceBefore) ? space : spaceBefore)
                        out.append(contentsOf: joined)
                    }
                } else {
                    out.append(contentsOf: space)
                }
                space = []
                spaceBefore = []
                removedSinceContent = false
                emittedContent = true
                out.append(scalar)
                index += 1
            }
        }
        held.removeAll(keepingCapacity: true)
        return String(out)
    }

    private func decide(at start: Int, final: Bool) -> Decision {
        let scalar = held[start]
        if Self.openers.contains(scalar) || Self.foldsToOpener(scalar) {
            switch tag(at: start) {
            case .notTag: break
            case .tag(let count): return .remove(count)
            case .needMore(let nameMatched):
                if !final { return .wait }
                if nameMatched { return .remove(held.count - start) }
            }
        }
        if let first = nonce.first, Self.lowered(scalar) == first {
            var offset = 0
            while offset < nonce.count {
                let at = start + offset
                guard at < held.count else { return final ? .content : .wait }
                guard Self.lowered(held[at]) == nonce[offset] else { return .content }
                offset += 1
            }
            return .remove(nonce.count)
        }
        return .content
    }

    private enum TagMatch {
        case notTag
        case tag(Int)
        case needMore(nameMatched: Bool)
    }

    private static let names: [[[Unicode.Scalar]]] = Untrusted.protectedNames

    private func tag(at start: Int) -> TagMatch {
        let window = Array(held[start..<min(held.count, start + Self.maxTagScalars)])
        let folded = FoldedText(window)
        let scalars = folded.scalars
        guard !scalars.isEmpty else { return .needMore(nameMatched: false) }
        var cursor = 1
        func skipSpaces() {
            while cursor < scalars.count, scalars[cursor].properties.isWhitespace { cursor += 1 }
        }
        skipSpaces()
        // Why: "< context" can be prose, so a spaced opener counts only once its closing bracket is on the same line
        let spaced = cursor > 1
        if cursor < scalars.count, scalars[cursor] == "/" {
            cursor += 1
            skipSpaces()
        }
        guard cursor < scalars.count else { return .needMore(nameMatched: false) }
        var matchedEnd: Int?
        var partial = false
        for words in Self.names {
            switch Self.match(words, in: scalars, at: cursor) {
            case .matched(let end): matchedEnd = end
            case .partial: partial = true
            case .mismatch: break
            }
            if matchedEnd != nil { break }
        }
        guard let nameEnd = matchedEnd else { return partial ? .needMore(nameMatched: false) : .notTag }
        guard nameEnd < scalars.count else { return .needMore(nameMatched: !spaced) }
        let boundary = scalars[nameEnd]
        guard boundary.properties.isWhitespace || Self.closers.contains(boundary) || boundary == "/" else { return .notTag }
        var end = nameEnd
        while end < scalars.count {
            if Self.closers.contains(scalars[end]) { return .tag(folded.origin[end] + 1) }
            if scalars[end] == "\n" { return spaced ? .notTag : .tag(folded.origin[end]) }
            end += 1
        }
        if window.count >= Self.maxTagScalars { return spaced ? .notTag : .tag(window.count) }
        return .needMore(nameMatched: !spaced)
    }

    private enum NameMatch {
        case matched(Int)
        case partial
        case mismatch
    }

    private static func match(_ words: [[Unicode.Scalar]], in scalars: [Unicode.Scalar], at start: Int) -> NameMatch {
        var cursor = start
        for (wordIndex, word) in words.enumerated() {
            if wordIndex > 0 {
                while cursor < scalars.count,
                    scalars[cursor] == "_" || scalars[cursor] == "-" || scalars[cursor].properties.isWhitespace
                {
                    cursor += 1
                }
            }
            for letter in word {
                guard cursor < scalars.count else { return .partial }
                guard scalars[cursor] == letter else { return .mismatch }
                cursor += 1
            }
        }
        return .matched(cursor)
    }

    private static func foldsToOpener(_ scalar: Unicode.Scalar) -> Bool {
        !scalar.isASCII && FoldedText([scalar]).scalars.first.map { openers.contains($0) } == true
    }

    private static func lowered(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        (65...90).contains(scalar.value) ? Unicode.Scalar(UInt8(scalar.value + 32)) : scalar
    }

    private static func isClosingPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        ".,!?;:)]}\u{2026}".unicodeScalars.contains(scalar)
    }

    private static func weight(_ run: [Unicode.Scalar]) -> Int {
        run.reduce(0) { $0 + ($1 == "\n" ? 1_000 : 1) }
    }
}
