import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

/// A model that copies the prompt's block format into its answer must never put those tags in front of the user.
@Suite struct ScaffoldingEchoTests {
    static func wrapped(_ text: String, nonce: String, kind: String = "draft") -> String {
        "<email_data nonce=\"\(nonce)\" id=\"draft\" kind=\"\(kind)\">\n\(text)\n</email_data nonce=\"\(nonce)\">"
    }

    static func echoing(_ text: String, chunkSize: Int = 3) -> ScriptedProvider {
        ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { request, _ in
            .text(wrapped(text, nonce: request.nonce), chunkSize: chunkSize)
        }
    }

    static func assertClean(_ text: String) {
        #expect(!text.contains("<"), "\(text)")
        #expect(!text.lowercased().contains("email_data"), "\(text)")
        #expect(!text.contains("nonce"), "\(text)")
    }

    func deltas(_ events: [RewriteEvent]) -> [String] {
        events.compactMap { if case .textDelta(let text) = $0 { return text } else { return nil } }
    }

    @Test func composeAndRewriteStreamNoTags() async throws {
        let features = makeFeatures([Self.echoing("Hi Dana,\n\nFriday works.\n\nSam")])
        for draft in ["", "thx fri ok"] {
            let events = try await collect(features.rewriteEvents(draft, instruction: "Reply yes", context: nil))
            var shown = ""
            for delta in deltas(events) {
                shown += delta
                Self.assertClean(shown)
            }
            #expect(shown == "Hi Dana,\n\nFriday works.\n\nSam")
        }
    }

    @Test func anAnswerOfOnlyTagsLeavesNoText() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { request, _ in
            .text(Self.wrapped("", nonce: request.nonce), chunkSize: 4)
        }
        let events = try await collect(makeFeatures([provider]).rewriteEvents("draft", instruction: "x", context: nil))
        #expect(deltas(events).joined().isEmpty)
    }

    @Test func replyOptionsCarryNoTags() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { request, _ in
            let open = "<email_data nonce=\\\"\(request.nonce)\\\">"
            return .text(
                #"{"options":[{"label":"Yes","body":"\#(open)Yes, that works.</email_data>"},"#
                    + #"{"label":"No","body":"Sorry, I can't."},{"label":"<context>Ask","body":"What time?"}]}"#)
        }
        let result = try await makeFeatures([provider]).replyOptionsResult(SyntheticThreads.short(), userName: "Sam")
        #expect(result.options.map(\.body) == ["Yes, that works.", "Sorry, I can't.", "What time?"])
        #expect(result.options.map(\.label) == ["Yes", "No", "Ask"])
        for option in result.options { Self.assertClean(option.label + option.body) }
    }

    @Test func aReplyOptionThatWasOnlyTagsComesBackEmpty() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in
            .text(#"{"options":[{"label":"Yes","body":"<email_data nonce=\"x\"></email_data>"},"#
                + #"{"label":"No","body":"Sorry."},{"label":"Ask","body":"When?"}]}"#)
        }
        let result = try await makeFeatures([provider]).replyOptionsResult(SyntheticThreads.short(), userName: "Sam")
        #expect(result.options.map(\.body) == ["", "Sorry.", "When?"], "the app drops empty options")
    }

    @Test func askInboxStreamsNoTags() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { request, _ in
            .text(Self.wrapped("The budget was approved.", nonce: request.nonce, kind: "excerpt") + "\nSources: m1",
                  chunkSize: 3)
        }
        let candidates = SyntheticThreads.short().messages
        let events = try await collect(makeFeatures([provider]).askInbox("budget", candidates: candidates))
        var shown = ""
        for case .textDelta(let delta) in events {
            shown += delta
            Self.assertClean(shown)
        }
        #expect(shown.trimmingCharacters(in: .whitespacesAndNewlines) == "The budget was approved.")
    }

    @Test func schedulingRepliesCarryNoTags() async throws {
        let features = makeFeatures([Self.echoing("Hi Dana,\n\n- Tue 2 PM\n\nBest")])
        let input = SchedulingDraftInput(
            thread: SyntheticThreads.short(), instruction: "Offer these times:\n- Tue 2 PM", timeLines: ["- Tue 2 PM"])
        let result = try await features.draftSchedulingReply(input)
        Self.assertClean(result.body)
        #expect(result.body == "Hi Dana,\n\n- Tue 2 PM\n\nBest")
    }

    @Test func theTraceKeepsTheRawAnswerAndShowsTheCleanOne() async throws {
        let sink = RecordingTraceSink()
        let features = DefaultAIFeatures(
            registry: ProviderRegistry(providers: [Self.echoing("Thanks!")]), settings: { AISettings() }, traces: sink,
            now: { fixedNow })
        _ = try await collect(features.rewriteEvents("draft", instruction: "x", context: nil))
        let trace = try #require(await sink.traces.first)
        #expect(trace.outputText?.contains("email_data") == true)
        #expect(trace.finalText == "Thanks!")
        #expect(trace.steps.contains { $0.kind == .promptTagsRemoved })
    }
}
