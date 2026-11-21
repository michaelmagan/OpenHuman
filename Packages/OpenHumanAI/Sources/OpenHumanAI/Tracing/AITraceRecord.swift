import Foundation

public enum AITraceCacheUse: String, Sendable, Hashable, Codable, CaseIterable {
    case hit, miss, none
}

public enum AITraceOutcome: String, Sendable, Hashable, Codable, CaseIterable {
    case completed, cached, failed, cancelled
}

public struct AITraceStep: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case stoppedAtOutputLimit
        case flaggedSuspicious
        case blockedBySecretGate
        case sourcesLineRemoved
        case citationsFiltered
        case repairedJSON
        case summaryUsedForConversation
        case conversationShortened
        case promptTagsRemoved
    }

    public var kind: Kind
    public var detail: String?

    public init(_ kind: Kind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }
}

public struct AITracePart: Sendable, Hashable, Codable {
    public var kind: String
    public var id: String?
    public var characters: Int
    public var trusted: Bool

    public init(kind: String, id: String?, characters: Int, trusted: Bool) {
        self.kind = kind
        self.id = id
        self.characters = characters
        self.trusted = trusted
    }
}

public struct AITraceParameters: Sendable, Hashable, Codable {
    public var temperature: Double?
    public var outputLimit: Int?
    public var inputBudget: Int?

    public init(temperature: Double? = nil, outputLimit: Int? = nil, inputBudget: Int? = nil) {
        self.temperature = temperature
        self.outputLimit = outputLimit
        self.inputBudget = inputBudget
    }
}

public struct AITraceRecord: Sendable, Hashable, Codable, Identifiable {
    public static let nonceStandIn = "\u{2039}nonce\u{203A}"

    public var id: UUID
    public var createdAt: Date
    public var feature: AIFeature
    public var task: AITask
    public var trigger: AITrigger
    public var accountKeys: [String]
    public var threadKey: String?
    public var parentID: UUID?
    public var groupID: UUID?
    public var promptID: PromptID?
    public var promptDigest: String?
    public var overrideRevision: Int?
    public var providerID: AIProviderID
    public var providerName: String
    public var model: String?
    public var modelVersion: String?
    public var dataLocation: AIDataLocation
    public var parameters: AITraceParameters
    public var systemText: String?
    public var inputText: String?
    public var inputParts: [AITracePart]
    public var outputText: String?
    public var finalText: String?
    public var steps: [AITraceStep]
    public var countedInputTokens: Int?
    public var contextTokens: Int?
    public var usage: AIUsage?
    public var latencyMilliseconds: Int?
    public var firstTokenMilliseconds: Int?
    public var cache: AITraceCacheUse
    public var outcome: AITraceOutcome
    public var errorKind: String?
    public var errorText: String?
    public var rating: Int?

    public init(
        id: UUID, createdAt: Date, feature: AIFeature, task: AITask, trigger: AITrigger, accountKeys: [String] = [],
        threadKey: String? = nil, parentID: UUID? = nil, groupID: UUID? = nil, promptID: PromptID? = nil,
        promptDigest: String? = nil, overrideRevision: Int? = nil, providerID: AIProviderID, providerName: String,
        model: String? = nil, modelVersion: String? = nil, dataLocation: AIDataLocation,
        parameters: AITraceParameters = AITraceParameters(), systemText: String? = nil, inputText: String? = nil,
        inputParts: [AITracePart] = [], outputText: String? = nil, finalText: String? = nil, steps: [AITraceStep] = [],
        countedInputTokens: Int? = nil, contextTokens: Int? = nil, usage: AIUsage? = nil,
        latencyMilliseconds: Int? = nil, firstTokenMilliseconds: Int? = nil, cache: AITraceCacheUse = .none,
        outcome: AITraceOutcome, errorKind: String? = nil, errorText: String? = nil, rating: Int? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.feature = feature
        self.task = task
        self.trigger = trigger
        self.accountKeys = accountKeys
        self.threadKey = threadKey
        self.parentID = parentID
        self.groupID = groupID
        self.promptID = promptID
        self.promptDigest = promptDigest
        self.overrideRevision = overrideRevision
        self.providerID = providerID
        self.providerName = providerName
        self.model = model
        self.modelVersion = modelVersion
        self.dataLocation = dataLocation
        self.parameters = parameters
        self.systemText = systemText
        self.inputText = inputText
        self.inputParts = inputParts
        self.outputText = outputText
        self.finalText = finalText
        self.steps = steps
        self.countedInputTokens = countedInputTokens
        self.contextTokens = contextTokens
        self.usage = usage
        self.latencyMilliseconds = latencyMilliseconds
        self.firstTokenMilliseconds = firstTokenMilliseconds
        self.cache = cache
        self.outcome = outcome
        self.errorKind = errorKind
        self.errorText = errorText
        self.rating = rating
    }

    public var leftDevice: Bool { dataLocation.leavesDevice }

    public var textBytes: Int {
        [systemText, inputText, outputText, finalText, errorText].reduce(0) { $0 + ($1?.utf8.count ?? 0) }
    }

    public mutating func removeText() {
        systemText = nil
        inputText = nil
        outputText = nil
        finalText = nil
        errorText = nil
    }
}

extension AIDataLocation {
    public var traceValue: String {
        switch self {
        case .onDevice: "onDevice"
        case .appleCloud: "appleCloud"
        case .thirdParty(let vendor): "thirdParty:" + vendor
        }
    }

    public init?(traceValue: String) {
        switch traceValue {
        case "onDevice": self = .onDevice
        case "appleCloud": self = .appleCloud
        default:
            guard traceValue.hasPrefix("thirdParty:") else { return nil }
            self = .thirdParty(vendor: String(traceValue.dropFirst("thirdParty:".count)))
        }
    }
}

extension AIError {
    public var traceKind: String {
        switch self {
        case .unavailable: "unavailable"
        case .contextOverflow: "contextOverflow"
        case .invalidOutput: "invalidOutput"
        case .refused: "refused"
        case .timeout: "timeout"
        case .cancelled: "cancelled"
        case .providerFailed: "providerFailed"
        case .outputBlocked: "outputBlocked"
        }
    }
}
