import Foundation

extension DefaultAIFeatures {
    public func replyOptionsResult(_ thread: AIThreadInput, userName: String) async throws -> ReplyOptionsResult {
        guard let last = thread.messages.last else {
            throw AIError.unavailable(.other("The thread has no message to reply to"))
        }
        return try await withWritingModel(.replyOptions, thread: thread, trigger: thread.trigger) { engine in
            try await replyOptions(thread, answering: last, userName: userName, engine: engine)
        }
    }

    private func replyOptions(_ thread: AIThreadInput, answering last: AIMessageInput, userName: String, engine: Engine)
        async throws -> ReplyOptionsResult
    {
        let trusted = [
            TrustedPart(kind: .userName, text: String(userName.prefix(AIPolicy.userNameCharacterCap))),
            TrustedPart(kind: .today, text: today()),
        ]
        let output = OutputSpec.json(schema: OutputGuard.replyOptionsSchema, maxTokens: AIPolicy.reservedReplyOptionsTokens)
        return try await withOverflowRetry { shrink in
            let nonce = makeNonce()
            var prepared = try await prepare(
                .replyOptions, engine: engine, nonce: nonce, trusted: trusted, untrusted: [], output: output,
                shrink: shrink)
            if AIModelDefaults.writingModels.contains(engine.provider.id),
               let schema = output.schema, let reminder = try? prompts.repairSuffix(schema: schema),
               let window = engine.capabilities.contextTokens {
                // Leave room for both the chat template and the longer system turn on a repair request.
                let fixed = await engine.count(prepared.request.system + "\n\n" + reminder)
                    + (await engine.count(Untrusted.renderTrusted(trusted, nonce: nonce)))
                let available = window - fixed - output.maxTokens - 32
                guard available > 0 else { throw AIError.contextOverflow(counted: fixed + output.maxTokens + 32, limit: window) }
                prepared.budget = Int(Double(available) * shrink)
            }
            let whole = threadParts(thread)
            if await engine.tokens(of: whole, nonce: nonce) <= prepared.budget {
                prepared.request.untrusted = whole
            } else if AIModelDefaults.writingModels.contains(engine.provider.id) {
                let budget = prepared.budget
                prepared.request.untrusted = try await recentReplyParts(thread, last: last) { parts in
                    await engine.tokens(of: parts, nonce: nonce) <= budget
                }
            } else {
                let summary = try await produceSummary(thread, engine: engine)
                let head = [
                    subjectPart(thread), UntrustedPart(kind: .summary, id: thread.threadKey, text: summary),
                    senderPart(last),
                ]
                let budget = prepared.budget
                let lastShare = Int(Double(budget) * AIPolicy.replyLastMessageBudgetFraction)
                let body = try await Chunker.truncate(cappedBody(last)) { text in
                    let part = self.bodyPart(last, text: text)
                    guard await engine.tokens(of: [part], nonce: nonce) <= lastShare else { return false }
                    return await engine.tokens(of: head + [part], nonce: nonce) <= budget
                }
                prepared.request.untrusted = head + [bodyPart(last, text: body)]
            }
            let used = try await requireFits(prepared, engine: engine)
            let sources = prepared.request.untrusted.map(\.text)

            let key = cacheKey(prepared, engine: engine, extra: Self.replyKeyComponents(answering: last))
            if let key, let hit = await cache.get(key), case .json(let data) = hit.payload,
                let options = try? JSONDecoder().decode([ReplyOption].self, from: data)
            {
                await record(prepared, engine: engine, untrustedTokens: used, usage: nil, outcome: .cached)
                await traceCacheHit(prepared, engine: engine, task: .replyOptions, hit: hit,
                                    text: String(decoding: data, as: UTF8.self))
                var provenance = hit.provenance
                provenance.traceID = prepared.traceID
                provenance.feature = engine.feature
                provenance.promptID = prepared.request.promptID
                provenance.promptOverrideRevision = prepared.overrideRevision
                return ReplyOptionsResult(options: options, provenance: provenance,
                                          report: AIOutputReport(traceID: prepared.traceID, model: hit.model))
            }
            let (options, outcome, raw) = try await structuredAnswer(prepared, engine: engine, untrustedTokens: used) {
                try OutputGuard.replyOptions(from: $0, sources: sources)
            }
            let suspicious =
                OutputGuard.isSuspicious(raw, nonce: nonce)
                || options.contains { OutputGuard.isSuspicious($0.label + "\n" + $0.body, nonce: nonce) }
            if !suspicious, let key, let data = try? JSONEncoder().encode(options) {
                await cache.put(
                    key, cachedResult(.json(data), engine: engine, model: outcome.model),
                    ttl: engine.ttl(AIPolicy.replyOptionsTTL))
            }
            let traced = PreparedRequest(
                request: prepared.request, promptDigest: prepared.promptDigest, fixedTokens: prepared.fixedTokens,
                budget: prepared.budget, traceID: outcome.traceID ?? prepared.traceID,
                overrideRevision: prepared.overrideRevision)
            if suspicious { await amendTrace(traced, finalText: nil, steps: [AITraceStep(.flaggedSuspicious)]) }
            return ReplyOptionsResult(
                options: options, provenance: engine.provenance(traced, model: outcome.model),
                report: outcome.report(suspicious: suspicious))
        }
    }

    /// Keep the newest complete turns, shortening the message being answered only when it alone exceeds the budget.
    private func recentReplyParts(_ thread: AIThreadInput, last: AIMessageInput,
                                  fits: ([UntrustedPart]) async -> Bool) async throws -> [UntrustedPart] {
        let subject = subjectPart(thread)
        let sender = senderPart(last)
        let body = try await Chunker.truncate(cappedBody(last)) { text in
            await fits([subject, sender, self.bodyPart(last, text: text)])
        }
        var kept = [sender, bodyPart(last, text: body)]
        for message in thread.messages.dropLast().reversed() {
            let candidate = [senderPart(message), bodyPart(message, text: cappedBody(message))] + kept
            guard await fits([subject] + candidate) else { break }
            kept = candidate
        }
        return [subject] + kept
    }

    static func replyKeyComponents(answering message: AIMessageInput) -> [String] {
        ["replyTo", message.messageKey]
    }

    func structuredAnswer<T>(
        _ prepared: PreparedRequest, engine: Engine, untrustedTokens: Int, parse: (Data) throws -> T
    ) async throws -> (T, RunOutcome, String) {
        guard let schema = prepared.request.output.schema else { throw AIError.invalidOutput("no schema") }
        let extract = prepared.request.task == .replyOptions ? OutputGuard.replyJSON(from:) : OutputGuard.extractJSON(from:)
        let first = try await run(prepared, engine: engine, untrustedTokens: untrustedTokens)
        if let value = Self.parse(first, extract: extract, parse: parse) { return value }

        var repaired = prepared
        repaired.traceID = makeTraceID()
        repaired.parentTraceID = prepared.traceID
        do {
            repaired.request.system += "\n\n" + (try prompts.repairSuffix(schema: schema))
        } catch {
            throw AIError.invalidOutput("repair prompt unavailable")
        }
        let second: RunOutcome
        do {
            second = try await run(repaired, engine: engine, untrustedTokens: untrustedTokens)
        } catch let error as AIError where prepared.request.task == .replyOptions && AIModelDefaults.writingModels.contains(engine.provider.id) {
            switch error {
            case .contextOverflow, .providerFailed, .unavailable:
                throw AIError.invalidOutput("the model could not repair its reply")
            default: throw error
            }
        }
        await amendTrace(repaired, finalText: nil, steps: [AITraceStep(.repairedJSON)])
        if let value = Self.parse(second, extract: extract, parse: parse) { return value }
        throw AIError.invalidOutput("the model did not return valid JSON")
    }

    private static func parse<T>(_ outcome: RunOutcome, extract: (String) -> Data?, parse: (Data) throws -> T) -> (T, RunOutcome, String)? {
        guard let data = outcome.structured ?? extract(outcome.text),
            let value = try? parse(data)
        else { return nil }
        return (value, outcome, String(decoding: data, as: UTF8.self))
    }
}
