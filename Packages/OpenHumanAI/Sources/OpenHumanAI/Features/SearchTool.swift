import Foundation
import Synchronization

public struct AISearchToolQuery: Sendable, Hashable {
    public var keywords: [String]
    public var sender: String
    public var withinDays: Int

    public init(keywords: [String], sender: String = "", withinDays: Int = 0) {
        self.keywords = keywords
        self.sender = sender
        self.withinDays = withinDays
    }
}

public struct AISearchToolHit: Sendable, Hashable {
    public let id: String
    public let sender: String
    public let subject: String
    public let date: Date?
    public let snippet: String

    public init(id: String, sender: String, subject: String, date: Date?, snippet: String) {
        self.id = id
        self.sender = sender
        self.subject = subject
        self.date = date
        self.snippet = snippet
    }
}

public protocol AISearchToolBackend: Sendable {
    func search(_ query: AISearchToolQuery) async throws -> [AISearchToolHit]
}

public final class AISearchToolSession: Sendable {
    private struct State {
        var calls = 0
        var hits: [AISearchToolHit] = []
    }

    private let backend: any AISearchToolBackend
    private let nonce: String
    private let state = Mutex(State())

    public init(backend: any AISearchToolBackend, nonce: String) {
        self.backend = backend
        self.nonce = nonce
    }

    public var hits: [AISearchToolHit] { state.withLock { $0.hits } }
    public var calls: Int { state.withLock { $0.calls } }

    public func call(_ raw: AISearchToolQuery) async throws -> String {
        let allowed = state.withLock { state -> Bool in
            guard state.calls < AIPolicy.searchToolMaxCalls else { return false }
            state.calls += 1
            return true
        }
        guard allowed else { return "No more searches are allowed for this question." }
        let query = Self.clean(raw)
        guard !query.keywords.isEmpty || !query.sender.isEmpty || query.withinDays > 0 else {
            return "The search needs a word, a sender or a time window."
        }
        let found = try await backend.search(query)
        let hits = Array(found.prefix(AIPolicy.searchToolMaxHits))
        state.withLock { state in
            for hit in hits where !state.hits.contains(where: { $0.id == hit.id }) { state.hits.append(hit) }
        }
        guard !hits.isEmpty else { return "Nothing matched." }
        let parts = hits.map { hit in
            let line = "From: \(hit.sender)\nSubject: \(hit.subject)\n\(String(hit.snippet.prefix(AIPolicy.searchToolSnippetCharacters)))"
            return UntrustedPart(kind: .excerpt, id: Self.attributeSafe(hit.id), text: line, date: hit.date)
        }
        return Untrusted.render(parts, nonce: nonce)
    }

    static func clean(_ query: AISearchToolQuery) -> AISearchToolQuery {
        let words = query.keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map { String($0.prefix(AIPolicy.searchPlanKeywordCharacters)) }
        return AISearchToolQuery(
            keywords: Array(words.prefix(AIPolicy.searchToolMaxKeywords)),
            sender: String(query.sender.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)),
            withinDays: min(max(query.withinDays, 0), AIPolicy.searchToolMaxDays))
    }

    private static func attributeSafe(_ id: String) -> String {
        String(id.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" || $0 == ".") }.prefix(40))
    }
}

public struct SearchToolResult: Sendable, Hashable {
    public var hits: [AISearchToolHit]
    public var summary: String
    public var provenance: AIProvenance
    public var report: AIOutputReport

    public init(hits: [AISearchToolHit], summary: String, provenance: AIProvenance, report: AIOutputReport) {
        self.hits = hits
        self.summary = summary
        self.provenance = provenance
        self.report = report
    }
}

extension DefaultAIFeatures {
    public func searchWithTool(_ text: String, accountKey: String?, backend: any AISearchToolBackend) async throws
        -> SearchToolResult
    {
        let question = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AIPolicy.searchQuestionCharacterCap))
        guard !question.isEmpty else { throw AIError.invalidOutput("empty search") }
        let engine = try await resolveModel(.searchPlan, trigger: .user, accountKeys: [accountKey], threadKey: nil)
        guard engine.capabilities.dataLocation == .onDevice else { throw AIError.unavailable(.onDeviceOnly) }
        let trusted = [
            TrustedPart(kind: .userQuestion, text: question),
            TrustedPart(kind: .today, text: searchToday()),
        ]
        let nonce = makeNonce()
        var prepared = try await prepare(.searchTool, engine: engine, nonce: nonce, trusted: trusted, untrusted: [],
                                         output: .text(maxTokens: AIPolicy.reservedSearchToolTokens), shrink: 1)
        let session = AISearchToolSession(backend: backend, nonce: nonce)
        prepared.request.searchTool = session
        let used = try await requireFits(prepared, engine: engine)
        let outcome = try await run(prepared, engine: engine, untrustedTokens: used)
        var provenance = engine.provenance
        provenance.model = outcome.model
        let summary = String(PromptScaffoldingFilter.strip(outcome.text, nonce: nonce)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        return SearchToolResult(
            hits: session.hits, summary: summary, provenance: provenance,
            report: AIOutputReport(suspicious: OutputGuard.isSuspicious(outcome.text, nonce: nonce), usage: outcome.usage))
    }
}
