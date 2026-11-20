import Foundation

struct MapStep: Sendable, Hashable {
    let messageIndex: Int
    let chunkIndex: Int
    let chunkCount: Int
    let trusted: [TrustedPart]
    let parts: [UntrustedPart]
    let budget: Int
}

enum SummaryPlan: Sendable {
    case singlePass(PreparedRequest)
    case mapReduce([MapStep])
}

extension DefaultAIFeatures {
    public func summarize(_ thread: AIThreadInput) -> AsyncThrowingStream<SummaryEvent, Error> {
        eventStream { continuation in
            guard !thread.messages.isEmpty else { throw AIError.unavailable(.other("The thread has no messages")) }
            if thread.trigger == .automatic, thread.messages.count < AIPolicy.autoSummarizeMinimumMessages {
                throw AIError.unavailable(.other("Threads this short are not summarized automatically"))
            }
            var emitted = false
            _ = try await self.withWritingModel(.summarize, thread: thread, trigger: thread.trigger, emittedText: { emitted }) { engine in
                var pendingStart: SummaryEvent?
                return try await self.produceSummary(thread, engine: engine) { event in
                    if case .started = event, AIModelDefaults.writingModels.contains(engine.provider.id) {
                        pendingStart = event
                        return
                    }
                    if let start = pendingStart {
                        continuation.yield(start)
                        pendingStart = nil
                    }
                    if case .textDelta(let text) = event, !text.isEmpty { emitted = true }
                    continuation.yield(event)
                }
            }
        }
    }

    func produceSummary(_ thread: AIThreadInput, engine: Engine, emit: ((SummaryEvent) -> Void)? = nil)
        async throws -> String
    {
        let key = threadSummaryKey(thread, engine: engine)
        if let key, let hit = await cache.get(key), case .text(let text) = hit.payload {
            let traceID = await traceCacheHit(nil, engine: engine, task: .summarize, hit: hit, text: text)
            var provenance = hit.provenance
            provenance.traceID = traceID
            provenance.feature = engine.feature
            emit?(.started(provenance))
            emit?(.textDelta(text))
            emit?(.completed(AIOutputReport(traceID: traceID, model: hit.model)))
            return text
        }
        let firstRoot = makeTraceID()
        var started = engine.provenance
        started.traceID = firstRoot
        started.feature = engine.feature
        emit?(.started(started))
        let nonce = makeNonce()
        var emittedText = false
        var attempts = 0
        let (text, report) = try await withOverflowRetry(emitted: { emittedText }) { shrink in
            let root = attempts == 0 ? firstRoot : makeTraceID()
            attempts += 1
            var suspicious = false
            var final: PreparedRequest
            switch try await planSummary(thread, engine: engine, nonce: nonce, shrink: shrink) {
            case .singlePass(let prepared):
                final = prepared
            case .mapReduce(let steps):
                var items: [UntrustedPart] = []
                for step in steps {
                    let (summary, flagged) = try await runMapStep(
                        step, engine: engine, nonce: nonce, shrink: shrink, parent: root)
                    suspicious = suspicious || flagged
                    let body = step.parts[step.parts.count - 1]
                    items.append(
                        UntrustedPart(
                            kind: .summary, id: step.chunkCount > 1 ? "\(body.id).\(step.chunkIndex + 1)" : body.id,
                            text: summary, date: body.date))
                }
                final = try await finalReduce(
                    items, thread: thread, engine: engine, nonce: nonce, shrink: shrink, suspicious: &suspicious,
                    parent: root)
            }
            final.traceID = root
            let used = try await requireFits(final, engine: engine)
            var capper = StreamCapper(maxTokens: final.request.output.maxTokens)
            let outcome = try await run(final, engine: engine, untrustedTokens: used) { delta in
                let shown = capper.accept(delta)
                if !shown.isEmpty {
                    emittedText = true
                    emit?(.textDelta(shown))
                }
                return !capper.truncated
            }
            suspicious = suspicious || OutputGuard.isSuspicious(outcome.text, nonce: nonce)
            if suspicious { await amendTrace(final, finalText: nil, steps: [AITraceStep(.flaggedSuspicious)]) }
            return (capper.text, outcome.report(suspicious: suspicious, truncated: capper.truncated))
        }
        if !report.suspicious, let key {
            await cache.put(key, cachedResult(.text(text), engine: engine, model: nil), ttl: engine.ttl(nil))
        }
        emit?(.completed(report))
        return text
    }

    func threadSummaryKey(_ thread: AIThreadInput, engine: Engine) -> AICacheKey? {
        guard let modelVersion = engine.modelVersion,
            let promptDigest = try? Digest.sha256Hex(
                [PromptName.summarizeThread, .summarizeChunk, .summarizeReduce].map { try prompts.digest($0) }),
            let promptID = prompts.templates[PromptName.summarizeThread.rawValue]?.id
        else { return nil }
        var components = [prompts.languageRule(engine.settings.outputLanguage)]
        for part in threadParts(thread) {
            components += [part.kind.rawValue, part.id, part.date.map { "\($0.timeIntervalSince1970)" } ?? "-", part.text]
        }
        return AICacheKey(
            providerID: engine.provider.id, modelVersion: modelVersion, promptID: promptID, promptDigest: promptDigest,
            task: .summarize, inputsDigest: Digest.sha256Hex(components), threadKey: thread.threadKey)
    }

    func planSummary(_ thread: AIThreadInput, engine: Engine, nonce: String, shrink: Double) async throws -> SummaryPlan {
        let parts = threadParts(thread)
        let single = try await prepare(
            .summarizeThread, engine: engine, nonce: nonce, trusted: [], untrusted: parts,
            output: .text(maxTokens: AIPolicy.reservedSummaryTokens), shrink: shrink)
        if await engine.tokens(of: parts, nonce: nonce) <= single.budget { return .singlePass(single) }
        return .mapReduce(try await mapSteps(thread, engine: engine, nonce: nonce, shrink: shrink))
    }

    static func position(part: Int, of count: Int) -> String { "Part \(part) of \(count) of one email." }

    func mapSteps(_ thread: AIThreadInput, engine: Engine, nonce: String, shrink: Double) async throws -> [MapStep] {
        let longestPosition = [TrustedPart(kind: .position, text: Self.position(part: 9_999, of: 9_999))]
        let probe = try await prepare(
            .summarizeChunk, engine: engine, nonce: nonce, trusted: longestPosition, untrusted: [],
            output: .text(maxTokens: AIPolicy.reservedChunkSummaryTokens), shrink: shrink)
        let budget = probe.budget
        var steps: [MapStep] = []
        for (index, message) in thread.messages.enumerated() {
            let body = cappedBody(message)
            if body.allSatisfy(\.isWhitespace) { continue }
            let sender = senderPart(message)
            let chunks = try await Chunker.split(body) { chunk in
                await engine.tokens(of: [sender, self.bodyPart(message, text: chunk)], nonce: nonce) <= budget
            }
            for (chunkIndex, chunk) in chunks.enumerated() {
                let trusted =
                    chunks.count > 1
                    ? [TrustedPart(kind: .position, text: Self.position(part: chunkIndex + 1, of: chunks.count))] : []
                steps.append(
                    MapStep(
                        messageIndex: index, chunkIndex: chunkIndex, chunkCount: chunks.count, trusted: trusted,
                        parts: [sender, bodyPart(message, text: chunk)], budget: budget))
            }
        }
        guard !steps.isEmpty else { throw AIError.unavailable(.other("The thread has no text to summarize")) }
        return steps
    }

    func runMapStep(_ step: MapStep, engine: Engine, nonce: String, shrink: Double, parent: UUID? = nil)
        async throws -> (String, Bool)
    {
        var prepared = try await prepare(
            .summarizeChunk, engine: engine, nonce: nonce, trusted: step.trusted, untrusted: step.parts,
            output: .text(maxTokens: AIPolicy.reservedChunkSummaryTokens), shrink: shrink)
        prepared.parentTraceID = parent
        return try await summarizeOnce(prepared, engine: engine)
    }

    func summarizeOnce(_ prepared: PreparedRequest, engine: Engine) async throws -> (String, Bool) {
        let used = try await requireFits(prepared, engine: engine)
        let key = cacheKey(prepared, engine: engine)
        if let key, let hit = await cache.get(key), case .text(let text) = hit.payload {
            await record(prepared, engine: engine, untrustedTokens: used, usage: nil, outcome: .cached)
            await traceCacheHit(prepared, engine: engine, task: prepared.request.task, hit: hit, text: text)
            return (text, false)
        }
        var capper = StreamCapper(maxTokens: prepared.request.output.maxTokens)
        let outcome = try await run(prepared, engine: engine, untrustedTokens: used) { delta in
            _ = capper.accept(delta)
            return !capper.truncated
        }
        let text = capper.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let suspicious = OutputGuard.isSuspicious(outcome.text, nonce: prepared.request.nonce)
        if !suspicious, let key {
            await cache.put(key, cachedResult(.text(text), engine: engine, model: outcome.model), ttl: engine.ttl(nil))
        }
        return (text, suspicious)
    }

    func reduceGroups(_ items: [UntrustedPart], subject: UntrustedPart, engine: Engine, nonce: String, budget: Int)
        async throws -> [[UntrustedPart]]
    {
        var groups: [[UntrustedPart]] = []
        var current: [UntrustedPart] = []
        for item in items {
            let candidate = current + [item]
            if candidate.count <= AIPolicy.reduceGroupSize,
                await engine.tokens(of: [subject] + candidate, nonce: nonce) <= budget
            {
                current = candidate
                continue
            }
            if !current.isEmpty { groups.append(current) }
            current = [item]
            let alone = await engine.tokens(of: [subject, item], nonce: nonce)
            if alone > budget { throw AIError.contextOverflow(counted: alone, limit: budget) }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    func finalReduce(
        _ items: [UntrustedPart], thread: AIThreadInput, engine: Engine, nonce: String, shrink: Double,
        suspicious: inout Bool, parent: UUID? = nil
    ) async throws -> PreparedRequest {
        let subject = subjectPart(thread)
        let output = OutputSpec.text(maxTokens: AIPolicy.reservedReduceTokens)
        let probe = try await prepare(
            .summarizeReduce, engine: engine, nonce: nonce, trusted: [], untrusted: [], output: output, shrink: shrink)
        var level = items
        var round = 0
        while true {
            let groups = try await reduceGroups(level, subject: subject, engine: engine, nonce: nonce, budget: probe.budget)
            if groups.count <= 1 {
                return try await prepare(
                    .summarizeReduce, engine: engine, nonce: nonce, trusted: [], untrusted: [subject] + (groups.first ?? []),
                    output: output, shrink: shrink)
            }
            guard groups.count < level.count else {
                throw AIError.contextOverflow(counted: level.count, limit: probe.budget)
            }
            round += 1
            var next: [UntrustedPart] = []
            for (index, group) in groups.enumerated() {
                if group.count == 1 {
                    next.append(group[0])
                    continue
                }
                var prepared = try await prepare(
                    .summarizeReduce, engine: engine, nonce: nonce, trusted: [], untrusted: [subject] + group,
                    output: output, shrink: shrink)
                prepared.parentTraceID = parent
                let (text, flagged) = try await summarizeOnce(prepared, engine: engine)
                suspicious = suspicious || flagged
                next.append(UntrustedPart(kind: .summary, id: "r\(round).\(index + 1)", text: text))
            }
            level = next
        }
    }
}
