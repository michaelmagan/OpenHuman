import Foundation

public enum OutputGuard {
    public static func isSuspicious(_ text: String, nonce: String) -> Bool {
        let folded = FoldedText.fold(text)
        if folded.contains("email_data") || folded.contains("user_instruction") { return true }
        return Untrusted.containsNonce(text, nonce: nonce)
    }

    public static func cap(_ text: String, maxTokens: Int) -> (text: String, truncated: Bool) {
        guard TokenHeuristic.count(text) > maxTokens else { return (text, false) }
        let ellipsis = "\u{2026}"
        let characters = Array(text)
        var low = 0
        var high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            if TokenHeuristic.count(String(characters[0..<mid]) + ellipsis) <= maxTokens { low = mid } else { high = mid - 1 }
        }
        var cut = String(characters[0..<low])
        if let space = cut.lastIndex(where: \.isWhitespace), cut.distance(from: space, to: cut.endIndex) < max(12, low / 5) {
            cut = String(cut[..<space])
        }
        while let last = cut.last, last.isWhitespace { cut.removeLast() }
        return (cut + ellipsis, true)
    }

    public static func capCharacters(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(max(0, maxCharacters - 1))) + "\u{2026}"
    }

    public static func extractJSON(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return Data(text[start...end].utf8)
    }

    public static func validate(_ data: Data, schema: JSONSchema) throws -> JSONValue {
        let value: JSONValue
        do {
            value = try JSONValue.parse(data)
        } catch {
            throw AIError.invalidOutput("not JSON")
        }
        let errors = schema.validate(value)
        guard errors.isEmpty else { throw AIError.invalidOutput(errors.prefix(3).joined(separator: "; ")) }
        return value
    }

    public static let replyOptionsSchema: JSONSchema = .object(
        properties: [
            "options": .array(
                items: .object(
                    properties: [
                        "label": .string(maxLength: 60),
                        "body": .string(maxLength: AIPolicy.replyOptionBodyCharacters),
                    ],
                    required: ["label", "body"]),
                minItems: AIPolicy.replyOptionCount, maxItems: AIPolicy.replyOptionCount)
        ],
        required: ["options"])

    public static let triageSchema: JSONSchema = .object(
        properties: [
            "category": .string(enumValues: TriageCategory.allCases.map(\.rawValue)),
            "priority": .integer(minimum: 0, maximum: 3),
            "reason": .string(),
        ],
        required: ["category", "priority", "reason"])

    public static func replyOptions(from data: Data, sources: [String], nonce: String? = nil) throws -> [ReplyOption] {
        let value = try validate(data, schema: replyOptionsSchema)
        guard case .array(let items)? = value["options"] else { throw AIError.invalidOutput("options missing") }
        return items.map { item in
            let body = PromptScaffoldingFilter.strip(item["body"]?.stringValue ?? "", nonce: nonce)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ReplyOption(
                label: label(PromptScaffoldingFilter.strip(item["label"]?.stringValue ?? "", nonce: nonce)),
                body: body,
                linkHostsAddedByAI: linkHostsNotIn(body, sources: sources))
        }
    }

    public static func triage(from data: Data, nonce: String, providerID: AIProviderID?) throws -> (TriageResult, Bool) {
        let value = try validate(data, schema: triageSchema)
        guard let raw = value["category"]?.stringValue, let category = TriageCategory(rawValue: raw),
            let priority = value["priority"]?.integerValue
        else { throw AIError.invalidOutput("triage fields") }
        return checkedTriage(
            TriageResult(category: category, priority: priority, reason: value["reason"]?.stringValue ?? "",
                         providerID: providerID),
            nonce: nonce)
    }

    public static func checkedTriage(_ result: TriageResult, nonce: String?) -> (TriageResult, Bool) {
        let reason = result.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let suspicious = isSuspicious(reason, nonce: nonce ?? "")
        let priority = min(3, max(0, result.priority))
        return (
            TriageResult(
                category: result.category, priority: priority,
                reason: suspicious ? "" : capCharacters(reason, maxCharacters: AIPolicy.triageReasonCharacters),
                providerID: result.providerID),
            suspicious
        )
    }

    static func label(_ raw: String) -> String {
        let words = raw.split(whereSeparator: \.isWhitespace).prefix(AIPolicy.replyOptionLabelWords)
        return capCharacters(words.joined(separator: " "), maxCharacters: AIPolicy.replyOptionLabelCharacters)
    }

    public static func filterCitations(_ cited: [String], allowed: Set<String>) -> [String] {
        var seen = Set<String>()
        return cited.filter { allowed.contains($0) && seen.insert($0).inserted }
    }

    public static func linkHostsNotIn(_ text: String, sources: [String]) -> [String] {
        let haystack = sources.joined(separator: "\n").lowercased()
        var hosts: [String] = []
        for host in linkHosts(in: text) {
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if !haystack.contains(bare), !hosts.contains(host) { hosts.append(host) }
        }
        return hosts
    }

    static func linkHosts(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                let host = url.host()?.lowercased(), !host.isEmpty
            else { return nil }
            return host
        }
    }

    public static func requireNoSecrets(_ text: String, request: AIRequest) throws {
        let sources = request.untrusted.map(\.text) + request.trusted.map(\.text)
        let findings = SecretScanner.scan(text, ignoringTextsIn: sources)
        if let first = findings.first {
            throw AIError.outputBlocked(
                "The answer looked like it contained a private key, access token or local file path (\(first.kind.rawValue)), so it was not shown.")
        }
    }
}
