import Foundation
import MailModel
import Observation
import OpenHumanCore

public enum RecipientParser {
    public static func parse(_ text: String) -> [EmailAddress] {
        split(text).compactMap(parseOne)
    }

    public static func parseOne(_ raw: String) -> EmailAddress? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            let email = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            var name = text[..<open].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            return EmailAddress(name: name.isEmpty ? nil : name, email: email)
        }
        let bare = text.hasPrefix("mailto:") ? String(text.dropFirst(7)) : text
        return EmailAddress(name: nil, email: bare)
    }

    static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for ch in text {
            switch ch {
            case "\"": inQuotes.toggle(); current.append(ch)
            case "<" where !inQuotes: inAngle = true; current.append(ch)
            case ">" where !inQuotes: inAngle = false; current.append(ch)
            case ",", ";", "\n", "\r":
                if inQuotes || inAngle {
                    current.append(ch)
                } else {
                    parts.append(current)
                    current = ""
                }
            default: current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    public static func isValid(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64, email.count <= 254 else { return false }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else {
            return false
        }
        return !email.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 0x20 || $0 == "<" || $0 == ">"
            || $0 == "," || $0 == ";" || $0 == "\"" }
    }

    public static func displayName(_ address: EmailAddress) -> String {
        if let name = address.name, !name.isEmpty { return name }
        return address.email
    }
}

@MainActor @Observable
public final class RecipientFieldModel {
    public enum Kind: String, Sendable { case to, cc, bcc }

    public let kind: Kind
    public private(set) var tokens: [EmailAddress]
    public var text = "" { didSet { if !applying { textChanged() } } }
    public private(set) var suggestions: [EmailAddress] = []
    public private(set) var suggestionCursor = 0
    public private(set) var focusRequest = 0
    @ObservationIgnored public var focusHandled = 0
    @ObservationIgnored public var onChange: (@MainActor ([EmailAddress]) -> Void)?

    @ObservationIgnored private let suggest: (@Sendable (String) async -> [EmailAddress])?
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var applying = false

    public static let maxSuggestions = 6

    public init(kind: Kind, tokens: [EmailAddress] = [], debounce: Duration = .milliseconds(80),
                suggest: (@Sendable (String) async -> [EmailAddress])? = nil) {
        self.kind = kind
        self.tokens = tokens
        self.debounce = debounce
        self.suggest = suggest
    }

    isolated deinit { suggestTask?.cancel() }

    public var title: String {
        switch kind {
        case .to: String(localized: "To")
        case .cc: String(localized: "Cc")
        case .bcc: String(localized: "Bcc")
        }
    }

    public var invalidTokens: [EmailAddress] { tokens.filter { !RecipientParser.isValid($0.email) } }

    public var collapsedText: String { tokens.map(RecipientParser.displayName).joined(separator: ", ") }

    public func requestFocus() { focusRequest += 1 }

    public func setTokens(_ new: [EmailAddress], notify: Bool = false) {
        guard new != tokens else { return }
        tokens = new
        if notify { onChange?(tokens) }
    }

    @discardableResult
    public func commit() -> Bool {
        if !suggestions.isEmpty, suggestions.indices.contains(suggestionCursor), !text.isEmpty {
            accept(suggestions[suggestionCursor])
            return true
        }
        return commitText()
    }

    @discardableResult
    public func commitText() -> Bool {
        let parsed = RecipientParser.parse(text)
        guard !parsed.isEmpty else { return false }
        add(parsed)
        return true
    }

    public func accept(_ suggestion: EmailAddress) {
        add([suggestion])
    }

    public func remove(_ address: EmailAddress) {
        guard let index = tokens.firstIndex(of: address) else { return }
        tokens.remove(at: index)
        onChange?(tokens)
    }

    public func removeLast() {
        guard text.isEmpty, !tokens.isEmpty else { return }
        tokens.removeLast()
        onChange?(tokens)
    }

    public func moveSuggestion(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        suggestionCursor = min(max(suggestionCursor + delta, 0), suggestions.count - 1)
    }

    public func selectSuggestion(_ index: Int) {
        guard suggestions.indices.contains(index), index != suggestionCursor else { return }
        suggestionCursor = index
    }

    // Escape closes the list and keeps the typed text; the next keystroke looks people up again
    public func dismissSuggestions() {
        suggestTask?.cancel()
        suggestions = []
        suggestionCursor = 0
    }

    public func settle() async { await suggestTask?.value }

    private func add(_ addresses: [EmailAddress]) {
        for address in addresses where !tokens.contains(where: { $0.email.caseInsensitiveCompare(address.email) == .orderedSame }) {
            tokens.append(address)
        }
        suggestTask?.cancel()
        suggestions = []
        suggestionCursor = 0
        setTextQuietly("")
        onChange?(tokens)
    }

    private func setTextQuietly(_ value: String) {
        applying = true
        text = value
        applying = false
    }

    private func textChanged() {
        if text.contains(",") || text.contains(";") || text.contains("\n") {
            let pieces = RecipientParser.split(text)
            let rest = pieces.last ?? ""
            let done = RecipientParser.parse(pieces.dropLast().joined(separator: ","))
            if !done.isEmpty {
                add(done)
                setTextQuietly(rest.trimmingCharacters(in: .whitespaces))
                return
            }
        }
        let prefix = text.trimmingCharacters(in: .whitespaces)
        suggestTask?.cancel()
        guard let suggest, prefix.count >= 1 else {
            suggestions = []
            return
        }
        let debounce = self.debounce
        suggestTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let found = await suggest(prefix)
            guard !Task.isCancelled, let self else { return }
            let existing = Set(self.tokens.map { $0.email.lowercased() })
            self.suggestions = Array(found.filter { !existing.contains($0.email.lowercased()) }.prefix(Self.maxSuggestions))
            self.suggestionCursor = 0
        }
    }
}
