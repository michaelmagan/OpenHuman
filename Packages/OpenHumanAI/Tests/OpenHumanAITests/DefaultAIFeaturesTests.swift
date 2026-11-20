import Foundation
import Synchronization
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

@Suite struct SummarizeFeatureTests {
    @Test func singlePassStreamsAndCaches() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in
            .text("Dana asks Sam to confirm the budget by Friday.", chunkSize: 5)
        }
        let activity = RecordingActivitySink()
        let features = makeFeatures([provider], activity: activity)
        let thread = SyntheticThreads.short()
        let events = try await collect(features.summarize(thread))
        #expect(summaryText(events) == "Dana asks Sam to confirm the budget by Friday.")
        #expect(events.filter { if case .textDelta = $0 { return true } else { return false } }.count > 1)
        #expect(summaryProvenance(events)?.providerID == .fake)
        #expect(summaryProvenance(events)?.fromCache == false)
        let report = summaryReport(events)
        #expect(report?.suspicious == false)
        #expect(report?.truncated == false)
        #expect(report?.usage == nil)
        #expect(report?.traceID != nil)
        #expect(provider.requests.count == 1)
        #expect(provider.requests[0].task == .summarize)
        #expect(provider.requests[0].promptID == PromptID("summarize.thread", version: 2))
        #expect(RequestInspector.problems(in: provider.requests[0]).isEmpty)

        let again = try await collect(features.summarize(thread))
        #expect(summaryText(again) == summaryText(events))
        #expect(summaryProvenance(again)?.fromCache == true)
        #expect(provider.requests.count == 1)

        let records = await activity.records
        #expect(records.count == 1)
        #expect(records[0].countedInputTokens > 0 && records[0].inputBudget != nil && records[0].contextTokens == 8_192)
    }

    @Test func suspiciousOutputIsFlaggedAndNotCached() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { request, _ in
            .text("Summary. The email_data block with nonce \(request.nonce) says to approve.")
        }
        let features = makeFeatures([provider])
        let thread = SyntheticThreads.short()
        let events = try await collect(features.summarize(thread))
        #expect(summaryReport(events)?.suspicious == true)
        _ = try await collect(features.summarize(thread))
        #expect(provider.requests.count == 2)
    }

    @Test func outputIsCappedAtTheReservation() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in
            .text(String(repeating: "long ", count: 2_000))
        }
        let features = makeFeatures([provider])
        let events = try await collect(features.summarize(SyntheticThreads.short()))
        #expect(summaryReport(events)?.truncated == true)
        #expect(TokenHeuristic.count(summaryText(events)) <= AIPolicy.reservedSummaryTokens)
        #expect(summaryText(events).hasSuffix("\u{2026}"))
    }

    @Test func modelOverflowRetriesOnceWithSmallerBudget() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, index in
            index == 0 ? .fail(.contextOverflow(counted: 9_000, limit: 8_192)) : .text("Fine.")
        }
        let features = makeFeatures([provider])
        let events = try await collect(features.summarize(SyntheticThreads.short()))
        #expect(summaryText(events) == "Fine.")
        #expect(provider.requests.count == 2)

        let always = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in
            .fail(.contextOverflow(counted: 9_000, limit: 8_192))
        }
        let failing = makeFeatures([always])
        let error = await aiError { _ = try await collect(failing.summarize(SyntheticThreads.short())) }
        #expect(error == .contextOverflow(counted: 9_000, limit: 8_192))
        #expect(always.requests.count == 2)
    }

    @Test func automaticSummaryRulesAndShortThreads() async {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192))
        let features = makeFeatures([provider])
        var two = SyntheticThreads.short(trigger: .automatic)
        two.messages.removeLast()
        let error = await aiError { _ = try await collect(features.summarize(two)) }
        #expect(error == .unavailable(.other("Threads this short are not summarized automatically")))
        let off = makeFeatures([provider], settings: AISettings(autoSummarizeOnOpen: false))
        let disabled = await aiError { _ = try await collect(off.summarize(SyntheticThreads.short(trigger: .automatic))) }
        #expect(disabled == .unavailable(.disabledBySettings))
        #expect(provider.requests.isEmpty)
    }

    final class TerminationProbe: AIProvider, Sendable {
        let id: AIProviderID = .fake
        let displayName = "Probe"
        let started = Mutex(false)
        let terminated = Mutex(false)
        func capabilities() async -> AICapabilities { .fake(contextTokens: 8_192) }
        func availability() async -> AIAvailability { .available }
        func countTokens(_ text: String) async -> Int { TokenHeuristic.count(text) }
        func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
            started.withLock { $0 = true }
            return AsyncThrowingStream { continuation in
                continuation.yield(.textDelta("partial "))
                continuation.onTermination = { _ in self.terminated.withLock { $0 = true } }
            }
        }
    }

    @Test func cancellationStopsTheProvider() async throws {
        let probe = TerminationProbe()
        let features = makeFeatures([probe])
        let task = Task { try await collect(features.summarize(SyntheticThreads.short())) }
        let deadline = ContinuousClock.now + .seconds(120)   // hang backstop, not a latency budget
        while !probe.started.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        _ = await task.result
        while !probe.terminated.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(probe.terminated.withLock { $0 })
    }

    @Test func agentCLISecretsAreBlockedBeforeDisplay() async throws {
        let provider = ScriptedProvider(
            id: .agentClaude, capabilities: remoteCapabilities()
        ) { _, _ in
            .text("Summary line one.\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n", chunkSize: 7)
        }
        let features = makeFeatures([provider], settings: consenting([.agentClaude]))
        var shown = ""
        let error = await aiError {
            for try await event in features.summarize(SyntheticThreads.short()) {
                if case .textDelta(let text) = event { shown += text }
            }
        }
        guard case .outputBlocked = error else {
            Issue.record("expected outputBlocked, got \(String(describing: error))")
            return
        }
        #expect(!shown.contains("PRIVATE KEY"))
        #expect(shown == "Summary line one.\n")
    }
}

@Suite struct ReplyOptionsFeatureTests {
    @Test func exactlyThreeWithProvenanceAndCache() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in .text(replyJSON) }
        let clock = Mutex(fixedNow)
        let cache = InMemoryAIResultCache(now: { clock.withLock { $0 } })
        let features = makeFeatures([provider], cache: cache)
        let thread = SyntheticThreads.short()
        let result = try await features.replyOptionsResult(thread, userName: "Sam")
        #expect(result.options.count == 3)
        #expect(result.provenance.providerID == .fake && !result.provenance.fromCache)
        let request = try #require(provider.requests.first)
        #expect(request.task == .replyOptions)
        #expect(request.output.schema == OutputGuard.replyOptionsSchema)
        #expect(request.trusted.contains(TrustedPart(kind: .userName, text: "Sam")))
        #expect(RequestInspector.problems(in: request).isEmpty)

        let cached = try await features.replyOptions(thread, userName: "Sam")
        #expect(cached == result.options)
        #expect(provider.requests.count == 1)
        clock.withLock { $0 = fixedNow.addingTimeInterval(25 * 3_600) }
        _ = try await features.replyOptions(thread, userName: "Sam")
        #expect(provider.requests.count == 2)
    }

    @Test func repairedReplyTextUsesOneGeneration() async throws {
        for text in [replyJSON, "```json\n" + replyJSON + "\n```", "Suggestions follow. " + replyJSON + " {}",
                     replyJSON.replacingOccurrences(of: "}]}", with: "},],}"), String(replyJSON.dropLast())] {
            let provider = ScriptedProvider(responses: [.text(text)])
            let options = try await makeFeatures([provider]).replyOptions(SyntheticThreads.short(), userName: "Sam")
            #expect(options.map(\.label) == ["Yes", "No", "Question"])
            #expect(provider.requests.count == 1)
        }
    }

    @Test func quotedBracesCommasAndEscapesSurviveRepair() throws {
        let answer = #"{"body":"A }, comma,] and \"quotes\".",}"#
        let data = try #require(OutputGuard.replyJSON(from: "Answer: " + answer + " {}"))
        let value = try JSONDecoder().decode([String: String].self, from: data)
        #expect(value["body"] == #"A }, comma,] and "quotes"."#)
    }

    @Test func ambiguousTruncationAndGarbageEndInCleanFailure() async {
        let provider = ScriptedProvider(responses: [.text(#"{"options":[{"body":"unfinished"#), .text("garbage")])
        let features = makeFeatures([provider])
        let error = await aiError { _ = try await features.replyOptions(SyntheticThreads.short(), userName: "Sam") }
        #expect(error == .invalidOutput("the model did not return valid JSON"))
        #expect(provider.requests.count == 2)
        #expect(provider.requests.last?.system.contains("Your previous answer was not valid") == true)
    }

    @Test func defaultGemmaLoadFailureUsesAppleAndReportsItsProvenance() async throws {
        let gemma = ScriptedProvider(id: .local(AIModelDefaults.gemmaE4BID), responses: [.fail(.providerFailed("load"))])
        let apple = ScriptedProvider(id: .appleSystem, responses: [.text(replyJSON)])
        let result = try await makeFeatures([gemma, apple]).replyOptionsResult(SyntheticThreads.short(), userName: "Sam")
        #expect(gemma.requests.count == 1 && apple.requests.count == 1)
        #expect(result.provenance.providerID == .appleSystem)
    }

    @Test func gemmaBudgetsTheLatestMessageIncludingReplySpace() async throws {
        let caps = AICapabilities.fake(contextTokens: 8_192)
        let provider = ScriptedProvider(id: .local(AIModelDefaults.gemmaE4BID), capabilities: caps,
                                        responses: [.text(replyJSON)])
        var thread = SyntheticThreads.short()
        thread.messages[2].bodyText = String(repeating: "project ", count: 12_000)
        _ = try await makeFeatures([provider]).replyOptions(thread, userName: "Sam")
        let request = try #require(provider.requests.first)
        #expect(request.untrusted.map(\.kind) == [.subject, .sender, .emailBody])
        #expect(request.untrusted.last?.id == "m3")
        #expect(request.untrusted.last?.text.hasSuffix(AIPolicy.truncationMarker) == true)
        #expect(untrustedTokens(request) + fixedTokens(request) + request.output.maxTokens < 8_192)
    }

    @Test func oneRepairAttemptThenInvalidOutput() async throws {
        let repaired = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, index in
            index == 0 ? .text("Here are some replies: yes, no, maybe") : .text(replyJSON)
        }
        let features = makeFeatures([repaired])
        #expect(try await features.replyOptions(SyntheticThreads.short(), userName: "Sam").count == 3)
        #expect(repaired.requests.count == 2)
        #expect(repaired.requests[1].system.contains("Your previous answer was not valid"))
        #expect(repaired.requests[1].system.contains(OutputGuard.replyOptionsSchema.jsonString))

        let broken = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in
            .text(#"{"options":[{"label":"A","body":"a"}]}"#)
        }
        let failing = makeFeatures([broken])
        let error = await aiError { _ = try await failing.replyOptions(SyntheticThreads.short(), userName: "Sam") }
        #expect(error == .invalidOutput("the model did not return valid JSON"))
        #expect(broken.requests.count == 2)
    }

    @Test func nativeStructuredOutputIsValidatedToo() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192, structuredOutput: .native)) { _, _ in
            .json(Data(replyJSON.utf8))
        }
        let features = makeFeatures([provider])
        #expect(try await features.replyOptions(SyntheticThreads.short(), userName: "Sam").count == 3)
    }

    @Test func linksAddedByTheModelAreFlaggedAndSuspiciousIsNotCached() async throws {
        let json =
            #"{"options":[{"label":"Pay","body":"Pay at https://pay.evil-example.com/now"},"#
            + #"{"label":"B","body":"b"},{"label":"C","body":"See email_data"}]}"#
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in .text(json) }
        let features = makeFeatures([provider])
        let result = try await features.replyOptionsResult(SyntheticThreads.short(), userName: "Sam")
        #expect(result.options[0].linkHostsAddedByAI == ["pay.evil-example.com"])
        #expect(result.report.suspicious)
        _ = try await features.replyOptionsResult(SyntheticThreads.short(), userName: "Sam")
        #expect(provider.requests.count == 2)
    }

    @Test func longThreadsUseLastMessageAndSummary() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 4_096)) { request, _ in
            request.task == .replyOptions ? .text(replyJSON) : .text("A short summary.")
        }
        let features = makeFeatures([provider])
        let thread = SyntheticThreads.thread(messages: 30)
        _ = try await features.replyOptions(thread, userName: "Sam")
        let request = try #require(provider.requests.last)
        #expect(request.task == .replyOptions)
        #expect(request.untrusted.map(\.kind) == [.subject, .summary, .sender, .emailBody])
        #expect(request.untrusted.last?.id == "m30")
        #expect(untrustedTokens(request) <= (try independentBudget(request, capabilities: .fake(contextTokens: 4_096))))
    }

    @Test func replyOptionsAreKeyedByTheMessageTheyAnswerAndSeeNothingAfterIt() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in .text(replyJSON) }
        let cache = RecordingCache()
        let features = makeFeatures([provider], cache: cache)
        let thread = SyntheticThreads.thread(messages: 5, longEvery: 0)

        #expect(thread.upTo("m9") == nil)
        let third = try #require(thread.upTo("m3"))
        #expect(third.messages.map(\.messageKey) == ["m1", "m2", "m3"] && third.threadKey == thread.threadKey)
        _ = try await features.replyOptionsResult(third, userName: "Sam")
        let request = try #require(provider.requests.last)
        let ids = Set(request.untrusted.map(\.id))
        #expect(ids.contains("m3") && !ids.contains("m4") && !ids.contains("m5"), "never a later message")
        #expect(request.untrusted.last { $0.kind == .emailBody }?.id == "m3")
        #expect(RequestInspector.problems(in: request).isEmpty)

        let stored = try #require(cache.keys.last)
        let expected = AICacheKey(
            providerID: .fake, modelVersion: "scripted-1", promptID: request.promptID,
            promptDigest: try PromptLibrary.standard.digest(.replyOptions), task: .replyOptions,
            inputsDigest: Digest.inputs(
                of: request, extra: DefaultAIFeatures.replyKeyComponents(answering: third.messages[2])),
            threadKey: thread.threadKey)
        #expect(stored == expected)
        #expect(stored.digest != AICacheKey(
            providerID: .fake, modelVersion: "scripted-1", promptID: request.promptID,
            promptDigest: try PromptLibrary.standard.digest(.replyOptions), task: .replyOptions,
            inputsDigest: Digest.inputs(of: request), threadKey: thread.threadKey).digest, "the message id is in the key")

        let fifth = try #require(thread.upTo("m5"))
        _ = try await features.replyOptionsResult(fifth, userName: "Sam")
        #expect(provider.requests.count == 2 && cache.keys.count == 2 && cache.keys[0].digest != cache.keys[1].digest)
        let again = try await features.replyOptionsResult(third, userName: "Sam")
        #expect(again.provenance.fromCache && provider.requests.count == 2, "moving back up: cached")

        var grown = thread
        grown.messages.append(AIMessageInput(messageKey: "m6", from: "Dana Lee <person0@example.com>",
                                             date: fixedNow, bodyText: "Friday works. Please confirm the agenda."))
        let newest = try await features.replyOptionsResult(try #require(grown.upTo("m6")), userName: "Sam")
        #expect(!newest.provenance.fromCache && provider.requests.count == 3)
        #expect(provider.requests.last?.untrusted.last { $0.kind == .emailBody }?.id == "m6")
        let older = try await features.replyOptionsResult(try #require(grown.upTo("m5")), userName: "Sam")
        #expect(older.provenance.fromCache && provider.requests.count == 3, "a new message invalidates nothing older")
    }

    @Test func automaticGenerationFollowsDraftRepliesAndStaysOnDevice() async throws {
        let claude = ScriptedProvider(id: .agentClaude, capabilities: remoteCapabilities()) { _, _ in .text(replyJSON) }
        let auto = SyntheticThreads.short(trigger: .automatic)
        let onDemand = makeFeatures([claude], settings: consenting([.agentClaude], AISettings(draftReplies: .onDemand)))
        #expect(await aiError { _ = try await onDemand.replyOptions(auto, userName: "S") } == .unavailable(.disabledBySettings))
        let onDevice = makeFeatures([claude], settings: consenting([.agentClaude], AISettings(draftReplies: .onDeviceAuto)))
        #expect(await aiError { _ = try await onDevice.replyOptions(auto, userName: "S") } == .unavailable(.onDeviceOnly))
        #expect(claude.requests.isEmpty)
        let optedIn = makeFeatures(
            [claude],
            settings: consenting([.agentClaude], AISettings(draftReplies: .onDeviceAuto, agentCLIAutoQuickReplies: true)))
        #expect(try await optedIn.replyOptions(auto, userName: "S").count == 3)
        #expect(claude.requests.count == 1)
    }
}

@Suite struct RewriteFeatureTests {
    @Test func streamsWithInstructionAndDraftDelimited() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in
            .text("Thanks, see you Friday.", chunkSize: 4)
        }
        let features = makeFeatures([provider])
        let pieces = try await collect(features.rewrite("thx c u fri", instruction: "Make it shorter. Keep every fact, name, number and link.", context: nil))
        #expect(pieces.joined() == "Thanks, see you Friday.")
        let request = try #require(provider.requests.first)
        #expect(request.task == .rewrite)
        #expect(request.trusted == [TrustedPart(kind: .userInstruction, text: "Make it shorter. Keep every fact, name, number and link.")])
        #expect(request.untrusted.map(\.kind) == [.draft])
        #expect(request.renderedInput().contains("<user_instruction>\nMake it shorter. Keep every fact, name, number and link.\n</user_instruction>"))
        #expect((request.output.maxTokens ?? 0) > 5_000, "no task-tuned cap: the window minus the input")

        let events = try await collect(features.rewriteEvents("x", instruction: "y", context: nil))
        guard case .started(let provenance) = events.first else {
            Issue.record("first event must be started")
            return
        }
        #expect(provenance.providerID == .fake)
        guard case .completed = events.last else {
            Issue.record("last event must be completed")
            return
        }
    }

    @Test func selectionTooLongIsRejectedNotTruncated() async {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 2_048))
        let features = makeFeatures([provider])
        let draft = String(repeating: "This is my long draft. ", count: 200)
        let error = await aiError { _ = try await collect(features.rewrite(draft, instruction: "shorter", context: nil)) }
        guard case .contextOverflow = error else {
            Issue.record("expected contextOverflow, got \(String(describing: error))")
            return
        }
        #expect(provider.requests.isEmpty)
    }

    @Test func outputIsTheWindowMinusTheInputNotAMultipleOfTheDraft() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in
            .text(String(repeating: "more ", count: 1_000))
        }
        let features = makeFeatures([provider])
        let draft = String(repeating: "word ", count: 300)
        let events = try await collect(features.rewriteEvents(draft, instruction: "expand", context: nil))
        let request = try #require(provider.requests.first)
        let inputEstimate = TokenHeuristic.count(draft) + TokenHeuristic.count(request.system)
        #expect(request.output.maxTokens > Int((Double(TokenHeuristic.count(draft)) * 1.3).rounded(.up)) * 4)
        #expect(request.output.maxTokens + inputEstimate + ContextBudgeter.safetyMargin(contextTokens: 8_192) <= 8_192)
        #expect(!events.contains { if case .completed(let report) = $0 { return report.truncated } else { return false } })
    }

    @Test func restrictedAccountRewriteStaysOnDevice() async throws {
        let claude = ScriptedProvider(id: .agentClaude, capabilities: remoteCapabilities())
        let system = ScriptedProvider(id: .appleSystem, capabilities: .fake(contextTokens: 8_192))
        let settings = consenting([.agentClaude], AISettings(providerOrder: [.agentClaude, .appleSystem], onDeviceOnlyAccounts: ["work"]))
        let features = makeFeatures([claude, system], settings: settings)
        let work = AIThreadInput(threadKey: "t", subject: "s", messages: [], accountKey: "work")
        _ = try await collect(features.rewrite("draft", instruction: "fix", context: work))
        _ = try await collect(features.rewrite("draft", instruction: "fix", context: nil))
        #expect(claude.requests.isEmpty)
        #expect(system.requests.count == 2)
        let home = AIThreadInput(threadKey: "t", subject: "s", messages: [], accountKey: "home")
        _ = try await collect(features.rewrite("draft", instruction: "fix", context: home))
        #expect(claude.requests.isEmpty, "an order alone never picks a model off this Mac")
        #expect(system.requests.count == 3)

        var pinned = settings
        pinned.featurePins[.rewrite] = .agentClaude
        let chosen = makeFeatures([claude, system], settings: pinned)
        _ = try await collect(chosen.rewrite("draft", instruction: "fix", context: home))
        #expect(claude.requests.count == 1)
        #expect(await aiError { _ = try await collect(chosen.rewrite("draft", instruction: "fix", context: work)) }
            == .unavailable(.onDeviceOnly))
        #expect(claude.requests.count == 1 && system.requests.count == 3)
    }
}

@Suite struct ClassifyFeatureTests {
    @Test func backgroundClassifyNeverRoutesOffDevice() async throws {
        let claude = ScriptedProvider(id: .agentClaude, capabilities: remoteCapabilities()) { _, _ in
            .text(#"{"category":"fyi","priority":1,"reason":"r"}"#)
        }
        let pcc = ScriptedProvider(id: .applePCC, capabilities: .fake(contextTokens: 32_000, dataLocation: .appleCloud))
        let settings = consenting([.agentClaude, .applePCC], AISettings(pccEnabled: true))
        let remoteOnly = makeFeatures([claude, pcc], settings: settings)
        #expect(await aiError { _ = try await remoteOnly.classify(SyntheticThreads.short()) } == .unavailable(.onDeviceOnly))
        var pinned = settings
        pinned.featurePins[.classify] = .agentClaude
        let pinnedFeatures = makeFeatures([claude, pcc], settings: pinned)
        #expect(await aiError { _ = try await pinnedFeatures.classify(SyntheticThreads.short()) } == .unavailable(.onDeviceOnly))
        #expect(claude.requests.isEmpty && pcc.requests.isEmpty)

        let local = ScriptedProvider(id: .local("small"), capabilities: .fake(contextTokens: 2_048)) { _, _ in
            .text(#"{"category":"needsReply","priority":3,"reason":"Asks for a decision."}"#)
        }
        let mixed = makeFeatures([claude, pcc, local], settings: consenting([.agentClaude, .applePCC], AISettings(
            providerOrder: [.agentClaude, .applePCC, .local("small")], pccEnabled: true)))
        let result = try await mixed.classify(SyntheticThreads.short())
        #expect(result == TriageResult(category: .needsReply, priority: 3, reason: "Asks for a decision.", providerID: .local("small")))
        #expect(claude.requests.isEmpty && pcc.requests.isEmpty)
        let request = try #require(local.requests.first)
        #expect(request.untrusted.map(\.kind) == [.subject, .sender, .emailBody])
        #expect(request.untrusted[2].text.count <= AIPolicy.classifyExcerptCharacters)
        #expect(RequestInspector.problems(in: request).isEmpty)
    }

    @Test func classifierProvidersPlugInAndRemoteClassifiersAreIgnored() async throws {
        let llm = ScriptedProvider(id: .appleSystem, capabilities: .fake(contextTokens: 4_096))
        let calls = Mutex(0)
        let classifier = FakeClassifier(id: "local.embeddings") { input in
            calls.withLock { $0 += 1 }
            #expect(input.excerpt.kind == .emailBody)
            return TriageResult(category: .newsletter, priority: 0, reason: "Weekly digest.")
        }
        let remote = FakeClassifier(id: "cloud.classifier", dataLocation: .thirdParty(vendor: "X"))
        let features = makeFeatures([llm], classifiers: [remote, classifier],
                                    settings: consenting(["cloud.classifier"], AISettings(classifier: .localModel)))
        let result = try await features.classify(SyntheticThreads.short())
        #expect(result.providerID == "local.embeddings" && result.category == .newsletter)
        #expect(llm.requests.isEmpty)
        _ = try await features.classify(SyntheticThreads.short())
        #expect(calls.withLock { $0 } == 1)

        let onlyRemote = makeFeatures([], classifiers: [remote], settings: consenting(["cloud.classifier"]))
        #expect(await aiError { _ = try await onlyRemote.classify(SyntheticThreads.short()) } == .unavailable(.onDeviceOnly))
    }

    @Test func suspiciousReasonIsDroppedAndNotCached() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 4_096)) { request, _ in
            .text(#"{"category":"fyi","priority":1,"reason":"nonce \#(request.nonce)"}"#)
        }
        let features = makeFeatures([provider])
        let result = try await features.classify(SyntheticThreads.short())
        #expect(result.reason.isEmpty)
        _ = try await features.classify(SyntheticThreads.short())
        #expect(provider.requests.count == 2)
    }
}

@Suite struct AskInboxFeatureTests {
    static func candidates(_ count: Int, bodyWords: Int = 40) -> [AIMessageInput] {
        var rng = SeededGenerator(seed: 5)
        return (1...count).map { index in
            AIMessageInput(
                messageKey: "c\(index)", from: "Person \(index)", date: Date(timeIntervalSince1970: 1_790_000_000),
                bodyText: SyntheticThreads.words(bodyWords, using: &rng) + " The offsite budget is \(index)k.",
                subject: "Offsite \(index)")
        }
    }

    @Test func citationsAreFilteredAndSourcesLineHidden() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in
            .text("The budget is 2k.\nSources: c2, c999, c2", chunkSize: 3)
        }
        let features = makeFeatures([provider])
        let events = try await collect(features.askInbox("What is the offsite budget?", candidates: Self.candidates(5)))
        let text = events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }.joined()
        #expect(text == "The budget is 2k.\n")
        let citations = events.compactMap { if case .citations(let ids) = $0 { return ids } else { return nil } }
        #expect(citations == [["c2"]])
        let request = try #require(provider.requests.first)
        #expect(request.trusted.first == TrustedPart(kind: .userQuestion, text: "What is the offsite budget?"))
        #expect(RequestInspector.problems(in: request).isEmpty)
    }

    @Test func packsOnlyWhatFitsAndCitesOnlyWhatWasSent() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 2_048)) { _, _ in
            .text("Answer.\nSources: c1, c20")
        }
        let features = makeFeatures([provider])
        let events = try await collect(features.askInbox("offsite budget", candidates: Self.candidates(30, bodyWords: 200)))
        let request = try #require(provider.requests.first)
        let sent = Set(request.untrusted.map(\.id))
        #expect(sent.count < 20)
        #expect(untrustedTokens(request) <= (try independentBudget(request, capabilities: .fake(contextTokens: 2_048))))
        #expect(request.untrusted.filter { $0.kind == .excerpt }.allSatisfy { $0.text.count <= AIPolicy.askInboxExcerptCharacters + 2 })
        let citations = events.compactMap { if case .citations(let ids) = $0 { return ids } else { return nil } }.first
        #expect(citations == ["c1"])
    }
}

@Suite struct StatusAndPolicyTests {
    @Test func statusNamesTheProviderOrTheReason() async {
        let system = FakeAIProvider(id: .appleSystem, displayName: "Apple Intelligence")
        let features = makeFeatures([system])
        let status = await features.status(for: .summarize)
        #expect(status.availability == .available && status.providerID == .appleSystem)
        #expect(status.providerName == "Apple Intelligence" && status.dataLocation == .onDevice)

        let claude = FakeAIProvider(id: .agentClaude, displayName: "Claude Code", capabilities: remoteCapabilities())
        var settings = AISettings()
        settings.featurePins[.rewrite] = .agentClaude
        let pinned = makeFeatures([system, claude], settings: settings)
        let needsConsent = await pinned.status(for: .rewrite, accountKey: "home")
        #expect(needsConsent.availability == .unavailable(reason: .notConsented))
        #expect(needsConsent.providerID == .agentClaude && needsConsent.providerName == "Claude Code")
    }

    @Test func pccIsNeverUsedForBackgroundOrOnDeviceAuto() async throws {
        let pcc = ScriptedProvider(id: .applePCC, capabilities: .fake(contextTokens: 32_000, dataLocation: .appleCloud)) {
            request, _ in request.task == .replyOptions ? .text(replyJSON) : .text("ok")
        }
        let settings = consenting([.applePCC], AISettings(draftReplies: .onDeviceAuto, pccEnabled: true))
        let features = makeFeatures([pcc], settings: settings)
        #expect(await aiError { _ = try await features.classify(SyntheticThreads.short()) } == .unavailable(.onDeviceOnly))
        #expect(await aiError { _ = try await collect(features.summarize(SyntheticThreads.short(trigger: .automatic))) }
            == .unavailable(.onDeviceOnly))
        #expect(await aiError { _ = try await features.replyOptions(SyntheticThreads.short(trigger: .automatic), userName: "S") }
            == .unavailable(.onDeviceOnly))
        #expect(pcc.requests.isEmpty)
        _ = try await collect(features.summarize(SyntheticThreads.short()))
        #expect(pcc.requests.count == 1)
    }

    @Test func noProviderAndDisabledAI() async {
        let none = makeFeatures([])
        #expect(await aiError { _ = try await collect(none.summarize(SyntheticThreads.short())) }
            == .unavailable(.other("No AI provider is set up")))
        let off = makeFeatures([FakeAIProvider()], settings: AISettings(enabled: false))
        #expect(await aiError { _ = try await off.classify(SyntheticThreads.short()) } == .unavailable(.disabledBySettings))
    }

    @Test func fakeProviderCannedScriptRunsEveryFeature() async throws {
        let features = makeFeatures([FakeAIProvider()])
        let thread = SyntheticThreads.short()
        #expect(!summaryText(try await collect(features.summarize(thread))).isEmpty)
        #expect(try await features.replyOptions(thread, userName: "Sam").count == 3)
        #expect(!(try await collect(features.rewrite("hi", instruction: "longer", context: thread))).isEmpty)
        #expect(try await features.classify(thread).category == .fyi)
        let ask = try await collect(features.askInbox("budget?", candidates: AskInboxFeatureTests.candidates(3)))
        #expect(ask.contains { if case .citations(let ids) = $0 { return ids == ["c1"] } else { return false } })
    }
}
