import Foundation

extension DefaultAIFeatures {
    public static let maxStyleExamples = 3
    public static let styleExampleCharacters = 600

    public func rewriteEvents(_ text: String, instruction: String, context: AIThreadInput?)
        -> AsyncThrowingStream<RewriteEvent, Error>
    {
        eventStream { continuation in
            let engine = try await self.resolveModel(
                .rewrite, trigger: .user, accountKeys: [context?.accountKey], threadKey: context?.threadKey)
            let writing = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let promptName: PromptName = writing ? .composeWrite : .rewrite
            var summary: UntrustedPart?
            if let context, !context.messages.isEmpty, let key = self.threadSummaryKey(context, engine: engine),
                let hit = await self.cache.get(key), case .text(let text) = hit.payload
            {
                summary = UntrustedPart(kind: .summary, id: context.threadKey, text: text)
            }
            let draft = writing ? [] : [UntrustedPart(kind: .draft, id: "draft", text: text)]
            let preferences = engine.settings.userPreferencesText.map { [TrustedPart(kind: .userPreferences, text: $0)] }
            let trusted = [
                TrustedPart(kind: .userInstruction, text: String(instruction.prefix(AIPolicy.userInstructionCharacterCap)))
            ] + (preferences ?? [])
            let styleParts = Self.styleParts(context?.styleExamples ?? [], dataLocation: engine.capabilities.dataLocation)
            var started = false
            var emitted = false
            try await self.withOverflowRetry(emitted: { emitted }) { shrink in
                let nonce = self.makeNonce()
                let sizing = try await self.prepare(
                    promptName, engine: engine, nonce: nonce, trusted: trusted, untrusted: draft,
                    output: .text(maxTokens: AIPolicy.generationMinimumOutputTokens), shrink: shrink)
                let limit = Int(Double(sizing.budget) * AIPolicy.rewriteSelectionBudgetFraction)
                let draftShare = await engine.tokens(of: draft, nonce: nonce)
                guard draftShare <= limit else { throw AIError.contextOverflow(counted: draftShare, limit: limit) }
                let conversation = await self.conversationParts(
                    context, summary: summary, after: draft, engine: engine, nonce: nonce, limit: limit)
                var parts = conversation.parts + draft
                for example in styleParts {
                    if await engine.tokens(of: parts + [example], nonce: nonce) <= sizing.budget { parts.append(example) }
                }
                let inputTokens = sizing.fixedTokens + (await engine.tokens(of: parts, nonce: nonce))
                let output = OutputSpec.text(
                    maxTokens: AIPolicy.generationOutputBudget(
                        contextTokens: engine.capabilities.contextTokens, inputTokens: inputTokens))
                let prepared = try await self.prepare(
                    promptName, engine: engine, nonce: nonce, trusted: trusted, untrusted: parts, output: output,
                    shrink: 1)
                let used = try await self.requireFits(prepared, engine: engine)
                if !started {
                    continuation.yield(.started(engine.provenance(prepared)))
                    started = true
                }
                var scaffolding = PromptScaffoldingFilter(nonce: nonce)
                var capper = StreamCapper(maxTokens: output.maxTokens)
                let outcome = try await self.run(prepared, engine: engine, untrustedTokens: used) { delta in
                    let shown = capper.accept(scaffolding.feed(delta))
                    if !shown.isEmpty {
                        emitted = true
                        continuation.yield(.textDelta(shown))
                    }
                    return !capper.truncated
                }
                let tail = capper.accept(scaffolding.finish())
                if !tail.isEmpty { continuation.yield(.textDelta(tail)) }
                let suspicious = OutputGuard.isSuspicious(outcome.text, nonce: nonce)
                var steps = conversation.steps
                if scaffolding.removedAny { steps.append(AITraceStep(.promptTagsRemoved)) }
                if suspicious { steps.append(AITraceStep(.flaggedSuspicious)) }
                await self.amendTrace(prepared, finalText: capper.text, steps: steps)
                continuation.yield(.completed(outcome.report(suspicious: suspicious, truncated: capper.truncated)))
            }
        }
    }

    func conversationParts(
        _ thread: AIThreadInput?, summary: UntrustedPart?, after tail: [UntrustedPart], engine: Engine, nonce: String,
        limit: Int
    ) async -> (parts: [UntrustedPart], steps: [AITraceStep]) {
        guard let thread, !thread.messages.isEmpty else { return ([], []) }
        let subject = thread.subject.isEmpty ? [] : [subjectPart(thread)]
        func pair(_ message: AIMessageInput, _ body: String) -> [UntrustedPart] {
            [senderPart(message), bodyPart(message, text: body)]
        }
        let whole = subject + thread.messages.flatMap { pair($0, cappedBody($0)) }
        if await engine.tokens(of: whole + tail, nonce: nonce) <= limit { return (whole, []) }

        var head = subject
        var steps = [AITraceStep(.conversationShortened)]
        if let summary, await engine.tokens(of: subject + [summary] + tail, nonce: nonce) <= limit {
            head.append(summary)
            steps.append(AITraceStep(.summaryUsedForConversation))
        }
        if await engine.tokens(of: head + tail, nonce: nonce) > limit { head = [] }
        var newestFirst: [[UntrustedPart]] = []
        func assembled(_ pairs: [[UntrustedPart]]) -> [UntrustedPart] { head + pairs.reversed().flatMap { $0 } }
        for message in thread.messages.reversed() {
            let candidate = pair(message, cappedBody(message))
            if await engine.tokens(of: assembled(newestFirst + [candidate]) + tail, nonce: nonce) <= limit {
                newestFirst.append(candidate)
                continue
            }
            if newestFirst.isEmpty {
                let kept = newestFirst
                let body = try? await Chunker.truncate(cappedBody(message)) { text in
                    await engine.tokens(of: assembled(kept + [pair(message, text)]) + tail, nonce: nonce) <= limit
                }
                if let body, body != AIPolicy.truncationMarker,
                    await engine.tokens(of: assembled([pair(message, body)]) + tail, nonce: nonce) <= limit
                {
                    newestFirst.append(pair(message, body))
                }
            }
            break
        }
        let kept = newestFirst.count
        steps[0].detail = "\(kept) of \(thread.messages.count) messages"
        return (assembled(newestFirst), steps)
    }

    static func styleParts(_ examples: [String], dataLocation: AIDataLocation) -> [UntrustedPart] {
        guard dataLocation == .onDevice else { return [] }
        let kept = examples.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return kept.prefix(maxStyleExamples).enumerated().map { index, example in
            UntrustedPart(kind: .styleExample, id: "style-\(index + 1)", text: String(example.prefix(styleExampleCharacters)))
        }
    }
}
