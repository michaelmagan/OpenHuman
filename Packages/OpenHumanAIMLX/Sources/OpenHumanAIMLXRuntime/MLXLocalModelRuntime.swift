import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import OpenHumanAI
import OpenHumanAIMLX
import OpenHumanAIModelStore

public struct MLXLocalModelRuntime: LocalModelRuntime {
    public struct Limits: Sendable, Hashable {
        public var cacheLimitBytes: Int
        public var maxKVTokens: Int

        public var writingKVTokens: Int

        public init(cacheLimitBytes: Int = 64 * 1_048_576, maxKVTokens: Int = 4_096,
                    writingKVTokens: Int = LocalWritingModels.contextTokens) {
            self.cacheLimitBytes = cacheLimitBytes
            self.maxKVTokens = maxKVTokens
            self.writingKVTokens = writingKVTokens
        }
    }

    public let limits: Limits

    public init(limits: Limits = Limits()) { self.limits = limits }

    public func load(modelDirectory: URL, manifest: ModelManifest) async throws -> any LocalModelSession {
        let bridge: any MLXLMCommon.Tokenizer
        let count: @Sendable (String) -> Int
        let isGemma = LocalWritingModels.all.contains { $0.id == manifest.id }
        let maxKVTokens = isGemma ? min(limits.writingKVTokens, LocalWritingModels.contextTokens) : limits.maxKVTokens
        let url = modelDirectory.appendingPathComponent("tokenizer.json")
        if isGemma {
            let tokenizer = try GemmaTokenizer(data: Data(contentsOf: url))
            bridge = GemmaBridge(base: tokenizer)
            count = { tokenizer.encode($0).count }
        } else {
            guard let tokenizer = try? ByteLevelBPETokenizer(contentsOf: url, eosToken: Qwen3ChatTemplate.eosToken) else {
                throw AIError.providerFailed("The classifier model's tokenizer could not be read.")
            }
            bridge = MLXTokenizerBridge(base: tokenizer)
            count = { tokenizer.encode($0, allowSpecialTokens: false).count }
        }
        Memory.cacheLimit = limits.cacheLimitBytes
        let container: ModelContainer
        do {
            container = try await LLMModelFactory.shared.loadContainer(
                from: modelDirectory, using: FixedTokenizerLoader(tokenizer: bridge))
        } catch {
            throw AIError.providerFailed("The local model could not be loaded (\(type(of: error))).")
        }
        return MLXLocalModelSession(
            container: container, count: count, contextSize: isGemma ? maxKVTokens : manifest.declaredContextTokens,
            maxKVTokens: maxKVTokens, enforceBudget: isGemma)
    }
}

final class MLXLocalModelSession: LocalModelSession {
    private let container: ModelContainer
    private let count: @Sendable (String) -> Int
    private let enforceBudget: Bool
    let contextSize: Int?
    private let maxKVTokens: Int

    init(container: ModelContainer, count: @escaping @Sendable (String) -> Int, contextSize: Int?,
         maxKVTokens: Int, enforceBudget: Bool) {
        self.container = container
        self.count = count
        self.enforceBudget = enforceBudget
        self.contextSize = contextSize
        self.maxKVTokens = maxKVTokens
    }

    func countTokens(_ text: String) async -> Int? { count(text) }

    func generate(system: String, input: String, maxTokens: Int, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        let container = self.container
        let maxKV = maxKVTokens
        let enforceBudget = self.enforceBudget
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let userInput = UserInput(chat: [.system(system), .user(input)])
                    let prepared = try await container.prepare(input: userInput)
                    if enforceBudget {
                        let used = prepared.text.tokens.size + maxTokens
                        guard used <= maxKV else { throw AIError.contextOverflow(counted: used, limit: maxKV) }
                    }
                    let parameters = GenerateParameters(
                        maxTokens: maxTokens, maxKVSize: maxKV, temperature: Float(temperature ?? 0))
                    let stream = try await container.generate(input: prepared, parameters: parameters)
                    for await event in stream {
                        try Task.checkCancellation()
                        if case .chunk(let text) = event { continuation.yield(text) }
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func unload() async { Memory.clearCache() }
}

struct FixedTokenizerLoader: TokenizerLoader {
    let tokenizer: any MLXLMCommon.Tokenizer
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer { tokenizer }
}

struct MLXTokenizerBridge: MLXLMCommon.Tokenizer {
    let base: ByteLevelBPETokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { base.encode(text, allowSpecialTokens: true) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { base.id(for: token) }
    func convertIdToToken(_ id: Int) -> String? { base.token(for: id) }
    var bosToken: String? { nil }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { nil }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        let turns = messages.compactMap { message -> (role: String, content: String)? in
            guard let role = message["role"] as? String, role == "system" || role == "user",
                  let content = message["content"] as? String else { return nil }
            return (role, content)
        }
        return try Qwen3ChatTemplate.encode(turns, tokenizer: base)
    }
}

private struct GemmaBridge: MLXLMCommon.Tokenizer {
    let base: GemmaTokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { base.encode(text) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { base.decode(tokenIds, skipSpecial: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { base.id(for: token) }
    func convertIdToToken(_ id: Int) -> String? { base.piece(for: id) }
    var bosToken: String? { "<bos>" }
    var eosToken: String? { "<eos>" }
    var unknownToken: String? { "<unk>" }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        guard messages.count == 2, messages[0]["role"] as? String == "system",
              messages[1]["role"] as? String == "user", let system = messages[0]["content"] as? String,
              let user = messages[1]["content"] as? String else {
            throw AIError.providerFailed("Unsupported conversation format.")
        }
        return base.chat(system: system, user: user)
    }
}
