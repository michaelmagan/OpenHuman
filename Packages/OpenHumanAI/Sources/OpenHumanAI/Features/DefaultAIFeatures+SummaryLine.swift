import Foundation

public struct ThreadLineSummary: Sendable, Hashable {
    public var text: String
    public var providerID: AIProviderID?
    public var fromCache: Bool
    public var traceID: UUID?

    public init(text: String, providerID: AIProviderID? = nil, fromCache: Bool = false, traceID: UUID? = nil) {
        self.text = text
        self.providerID = providerID
        self.fromCache = fromCache
        self.traceID = traceID
    }
}

extension AIPolicy {
    public static let threadLineWords = 14
    public static let reservedThreadLineTokens = 48
    public static let threadLineMessages = 3
    public static let threadLineMessageCharacters = 1_500
}

extension OutputGuard {
    public static func threadLine(_ raw: String) -> String? {
        let firstLine = raw.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        var text = firstLine
        for mark in ["**", "__", "`", "\"", "“", "”", "‘", "’", "#"] { text = text.replacingOccurrences(of: mark, with: "") }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " -*•>:"))
        if let end = text.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            text = String(text[..<end.lowerBound])
        }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let kept = words.prefix(AIPolicy.threadLineWords).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;:-"))
        guard !kept.isEmpty else { return nil }
        return kept + "."
    }
}

extension DefaultAIFeatures {
    public func summarizeLine(_ thread: AIThreadInput) async throws -> ThreadLineSummary {
        guard let newest = thread.messages.last else { throw AIError.unavailable(.other("The thread has no messages")) }
        return try await withWritingModel(.summarize, thread: thread, trigger: .automatic) { engine in
            try await summarizeLine(thread, newest: newest, engine: engine)
        }
    }

    private func summarizeLine(_ thread: AIThreadInput, newest: AIMessageInput, engine: Engine) async throws -> ThreadLineSummary {
        guard engine.capabilities.dataLocation == .onDevice else { throw AIError.unavailable(.onDeviceOnly) }
        let key = threadLineKey(thread, newest: newest, engine: engine)
        if let key, let hit = await cache.get(key), case .text(let text) = hit.payload {
            let traceID = await traceCacheHit(nil, engine: engine, task: .summarize, hit: hit, text: text)
            return ThreadLineSummary(text: text, providerID: engine.provider.id, fromCache: true, traceID: traceID)
        }
        let output = OutputSpec.text(maxTokens: AIPolicy.reservedThreadLineTokens)
        let messages = thread.messages.suffix(AIPolicy.threadLineMessages).flatMap { message in
            [senderPart(message), bodyPart(message, text: Self.followUpCapped(message.bodyText,
                                                                              AIPolicy.threadLineMessageCharacters))]
        }
        let made: (line: String?, traceID: UUID) = try await withOverflowRetry { shrink in
            let nonce = makeNonce()
            var prepared = try await prepare(.summarizeLine, engine: engine, nonce: nonce, trusted: [],
                                             untrusted: [subjectPart(thread)] + messages, output: output, shrink: shrink)
            var kept = messages
            while kept.count > 2, await engine.tokens(of: prepared.request.untrusted, nonce: nonce) > prepared.budget {
                kept.removeFirst(2)
                prepared.request.untrusted = [subjectPart(thread)] + kept
            }
            let used = try await requireFits(prepared, engine: engine)
            var capper = StreamCapper(maxTokens: output.maxTokens)
            let outcome = try await run(prepared, engine: engine, untrustedTokens: used) { delta in
                _ = capper.accept(delta)
                return !capper.truncated
            }
            guard !OutputGuard.isSuspicious(outcome.text, nonce: nonce) else {
                await amendTrace(prepared, finalText: nil, steps: [AITraceStep(.flaggedSuspicious)])
                return (nil, prepared.traceID)
            }
            let line = OutputGuard.threadLine(outcome.text)
            await amendTrace(prepared, finalText: line, steps: [])
            return (line, prepared.traceID)
        }
        guard let line = made.line else { throw AIError.invalidOutput("no line") }
        if let key {
            await cache.put(key, cachedResult(.text(line), engine: engine, model: nil), ttl: engine.ttl(nil))
        }
        return ThreadLineSummary(text: line, providerID: engine.provider.id, traceID: made.traceID)
    }

    func threadLineKey(_ thread: AIThreadInput, newest: AIMessageInput, engine: Engine) -> AICacheKey? {
        guard let modelVersion = engine.modelVersion, let promptDigest = try? prompts.digest(.summarizeLine),
              let promptID = prompts.templates[PromptName.summarizeLine.rawValue]?.id else { return nil }
        let components = [prompts.languageRule(engine.settings.outputLanguage), "line", thread.threadKey,
                          newest.messageKey]
        return AICacheKey(providerID: engine.provider.id, modelVersion: modelVersion, promptID: promptID,
                          promptDigest: promptDigest, task: .summarize, inputsDigest: Digest.sha256Hex(components),
                          threadKey: thread.threadKey)
    }
}

extension AIFeatures {
    public func summarizeLine(_ thread: AIThreadInput) async throws -> ThreadLineSummary {
        throw AIError.unavailable(.disabledBySettings)
    }
}
