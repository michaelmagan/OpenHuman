import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

/// A model whose stream ends without `.finished`, or fails part way, after the chunks it was given.
private struct ChunkedProvider: AIProvider {
    let id: AIProviderID = .fake
    let displayName = "Chunked model"
    let chunks: [String]
    let failsAtEnd: Bool

    func capabilities() async -> AICapabilities { .fake(contextTokens: 8_192) }
    func availability() async -> AIAvailability { .available }
    func countTokens(_ text: String) async -> Int { TokenHeuristic.count(text) }
    func modelVersion() async -> String? { nil }
    func consentFingerprint() async -> String? { nil }

    func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<AIEvent, Error>.makeStream()
        continuation.yield(.started(providerID: id, model: "chunked"))
        for chunk in chunks { continuation.yield(.textDelta(chunk)) }
        continuation.finish(throwing: failsAtEnd ? AIError.providerFailed("dropped") : nil)
        return stream
    }
}

/// The scaffolding filter holds back only what could still turn into a prompt tag or the nonce: whitespace at the
/// end of a chunk, an opening bracket, or the nonce's first letters. None of it may be lost when the answer ends.
@Suite struct ScaffoldingHoldBackTests {
    static let chunks = ["Dana confirms the budget ", "by Friday. "]

    func deltas(_ events: [SummaryEvent]) -> [String] {
        events.compactMap { if case .textDelta(let text) = $0 { return text } else { return nil } }
    }

    @Test func aStreamThatEndsWithoutFinishedStillShowsItsLastWord() async throws {
        let provider = ChunkedProvider(chunks: Self.chunks, failsAtEnd: false)
        let events = try await collect(makeFeatures([provider]).summarize(SyntheticThreads.short()))
        let shown = deltas(events)
        #expect(shown.first == "Dana confirms the budget", "only the trailing space waits for the next chunk")
        #expect(shown.joined() == Self.chunks.joined(), "the end of the stream releases the rest")
    }

    @Test func aStreamThatFailsHasShownEverythingButTrailingWhitespace() async throws {
        let provider = ChunkedProvider(chunks: Self.chunks, failsAtEnd: true)
        var shown = ""
        var failed = false
        do {
            for try await case .textDelta(let delta) in makeFeatures([provider]).summarize(SyntheticThreads.short()) {
                shown += delta
            }
        } catch {
            failed = true
        }
        #expect(failed)
        #expect(shown == "Dana confirms the budget by Friday.", "the last word showed before the failure")
    }

    @Test func onlyAmbiguousTextWaitsForTheNextChunk() {
        var filter = PromptScaffoldingFilter(nonce: "Zq9rT2bX7mLp")
        #expect(filter.feed("by Friday") == "by Friday", "a word that is not the nonce's start shows at once")
        #expect(filter.feed(". Z") == ".", "the nonce's first letter waits")
        #expect(filter.feed("ebra <") == " Zebra", "and shows once it is not the nonce; a bracket waits")
        #expect(filter.finish() == " <", "the end releases what was held")
    }
}
