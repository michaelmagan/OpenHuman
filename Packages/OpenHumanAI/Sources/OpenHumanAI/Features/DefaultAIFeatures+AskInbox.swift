import Foundation

extension DefaultAIFeatures {
    public func askInbox(_ question: String, candidates: [AIMessageInput]) -> AsyncThrowingStream<AskInboxEvent, Error> {
        eventStream { continuation in
            let candidates = Array(candidates.prefix(AIPolicy.askInboxMaxCandidates))
            let engine = try await self.resolveModel(
                .askInbox, trigger: .user, accountKeys: candidates.map(\.accountKey), threadKey: nil)
            let question = String(question.prefix(AIPolicy.userInstructionCharacterCap))
            let keywords = ExcerptWindow.keywords(in: question)
            let trusted = [
                TrustedPart(kind: .userQuestion, text: question), TrustedPart(kind: .today, text: self.today()),
            ]
            var started = false
            var emitted = false
            try await self.withOverflowRetry(emitted: { emitted }) { shrink in
                let nonce = self.makeNonce()
                let sizing = try await self.prepare(
                    .askInbox, engine: engine, nonce: nonce, trusted: trusted, untrusted: [],
                    output: .text(maxTokens: AIPolicy.generationMinimumOutputTokens), shrink: shrink)
                let limit = Int(Double(sizing.budget) * AIPolicy.askInboxInputBudgetFraction)
                let width = await self.askExcerptWidth(candidates, keywords: keywords, engine: engine, nonce: nonce,
                                                       limit: limit)
                var parts: [UntrustedPart] = []
                var included = Set<String>()
                for candidate in candidates {
                    let candidateParts = self.askParts(candidate, keywords: keywords, width: width)
                    if await engine.tokens(of: parts + candidateParts, nonce: nonce) <= limit {
                        parts += candidateParts
                        included.insert(candidate.messageKey)
                    }
                }
                if parts.isEmpty, let first = candidates.first {
                    let alone = await engine.tokens(of: [self.senderPart(first)], nonce: nonce)
                    throw AIError.contextOverflow(counted: alone, limit: limit)
                }
                let inputTokens = sizing.fixedTokens + (await engine.tokens(of: parts, nonce: nonce))
                let output = OutputSpec.text(
                    maxTokens: AIPolicy.generationOutputBudget(
                        contextTokens: engine.capabilities.contextTokens, inputTokens: inputTokens))
                let prepared = try await self.prepare(
                    .askInbox, engine: engine, nonce: nonce, trusted: trusted, untrusted: parts, output: output,
                    shrink: 1)
                let used = try await self.requireFits(prepared, engine: engine)
                if !started {
                    continuation.yield(.started(engine.provenance(prepared)))
                    started = true
                }
                var scaffolding = PromptScaffoldingFilter(nonce: nonce)
                var sources = SourcesLineFilter()
                var capper = StreamCapper(maxTokens: output.maxTokens)
                let outcome = try await self.run(prepared, engine: engine, untrustedTokens: used) { delta in
                    let shown = capper.accept(sources.feed(scaffolding.feed(delta)))
                    if !shown.isEmpty {
                        emitted = true
                        continuation.yield(.textDelta(shown))
                    }
                    return true
                }
                let tail = capper.accept(sources.feed(scaffolding.finish()) + sources.finish())
                if !tail.isEmpty { continuation.yield(.textDelta(tail)) }
                let citations = OutputGuard.filterCitations(sources.cited, allowed: included)
                continuation.yield(.citations(citations))
                let suspicious = OutputGuard.isSuspicious(outcome.text, nonce: nonce)
                var steps: [AITraceStep] = []
                if scaffolding.removedAny { steps.append(AITraceStep(.promptTagsRemoved)) }
                if outcome.text.range(of: SourcesLineFilter.marker, options: .caseInsensitive) != nil {
                    steps.append(AITraceStep(.sourcesLineRemoved))
                }
                if citations.count < sources.cited.count {
                    steps.append(AITraceStep(.citationsFiltered, detail: "\(sources.cited.count - citations.count)"))
                }
                if capper.truncated { steps.append(AITraceStep(.stoppedAtOutputLimit)) }
                if suspicious { steps.append(AITraceStep(.flaggedSuspicious)) }
                await self.amendTrace(prepared, finalText: capper.text, steps: steps)
                continuation.yield(.completed(outcome.report(suspicious: suspicious, truncated: capper.truncated)))
            }
        }
    }

    func askParts(_ candidate: AIMessageInput, keywords: [String], width: Int) -> [UntrustedPart] {
        var parts: [UntrustedPart] = []
        if let subject = candidate.subject, !subject.isEmpty {
            parts.append(
                UntrustedPart(kind: .subject, id: candidate.messageKey, text: String(subject.prefix(AIPolicy.subjectCharacterCap))))
        }
        parts.append(senderPart(candidate))
        parts.append(
            UntrustedPart(kind: .excerpt, id: candidate.messageKey,
                          text: ExcerptWindow.best(in: candidate.bodyText, keywords: keywords, width: width),
                          date: candidate.date))
        return parts
    }

    func askExcerptWidth(_ candidates: [AIMessageInput], keywords: [String], engine: Engine, nonce: String, limit: Int)
        async -> Int
    {
        let floor = AIPolicy.askInboxExcerptCharacters
        let longest = candidates.map(\.bodyText.count).max() ?? 0
        guard longest > floor else { return floor }
        func fits(_ width: Int) async -> Bool {
            let parts = candidates.flatMap { askParts($0, keywords: keywords, width: width) }
            return await engine.tokens(of: parts, nonce: nonce) <= limit
        }
        if await fits(longest) { return longest }
        guard await fits(floor) else { return floor }
        var low = floor
        var high = longest
        while high - low > AIPolicy.askInboxExcerptStep {
            let middle = (low + high) / 2
            if await fits(middle) { low = middle } else { high = middle }
        }
        return low
    }
}
