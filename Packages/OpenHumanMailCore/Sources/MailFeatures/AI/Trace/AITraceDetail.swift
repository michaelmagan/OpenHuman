import Foundation
import OpenHumanAI

public enum AITraceWording {
    public static func feature(_ feature: AIFeature) -> String {
        switch feature {
        case .summarize: String(localized: "Conversation summary")
        case .replyOptions: String(localized: "Quick replies")
        case .rewrite: String(localized: "Write and rewrite (⌘J in a draft)")
        case .classify: String(localized: "Triage and auto labels")
        case .askInbox: String(localized: "Ask AI (⌘J in the mail list)")
        case .searchPlan: String(localized: "Search as a sentence")
        case .followUp: String(localized: "Follow-up check")
        case .scheduling: String(localized: "Scheduling replies")
        }
    }

    public static let oneLineSummary = String(localized: "One-line summary")

    public static func title(_ trace: AITraceRecord) -> String {
        if trace.feature == .summarize, trace.promptID?.name == "summarize.line" { return oneLineSummary }
        return feature(trace.feature)
    }

    public static func model(_ trace: AITraceRecord) -> String {
        guard let model = trace.model, !model.isEmpty, model != trace.providerName else {
            return modelName(trace.providerID, displayName: trace.providerName)
        }
        return "\(model) · \(modelName(trace.providerID, displayName: trace.providerName))"
    }

    public static func modelName(_ id: AIProviderID, displayName: String) -> String {
        id == .appleSystem || id == .appleSystemClassifier ? String(localized: "Apple on-device model") : displayName
    }

    public static func duration(milliseconds: Int) -> String {
        milliseconds < 1_000 ? String(localized: "\(milliseconds) ms")
            : String(format: "%.1f s", Double(milliseconds) / 1_000)
    }

    public static func tokens(_ trace: AITraceRecord) -> String? {
        let input = trace.usage?.inputTokens ?? trace.countedInputTokens
        guard let input else { return nil }
        let read = String(localized: "\(input) tokens in")
        guard let output = trace.usage?.outputTokens else { return read }
        return read + " · " + String(localized: "\(output) out")
    }

    public static func outcome(_ trace: AITraceRecord) -> String {
        switch trace.outcome {
        case .completed: String(localized: "Done")
        case .cached: String(localized: "From cache")
        case .cancelled: String(localized: "Stopped")
        case .failed: String(localized: "Failed")
        }
    }

    public static func rating(_ rating: Int?) -> String? {
        switch rating {
        case .some(let value) where value > 0: String(localized: "Thumbs up")
        case .some(let value) where value < 0: String(localized: "Thumbs down")
        default: nil
        }
    }

    public static func step(_ step: AITraceStep) -> String {
        let text = switch step.kind {
        case .stoppedAtOutputLimit: String(localized: "Stopped at the output limit")
        case .flaggedSuspicious: String(localized: "Flagged: the email may hold instructions aimed at AI tools")
        case .blockedBySecretGate: String(localized: "Held back text that looked like a password or code")
        case .sourcesLineRemoved: String(localized: "Removed the Sources line")
        case .citationsFiltered: String(localized: "Dropped citations to emails it wasn't given")
        case .repairedJSON: String(localized: "Repaired the model's structured answer")
        case .summaryUsedForConversation: String(localized: "Used the saved summary instead of the whole conversation")
        case .conversationShortened: String(localized: "Shortened the conversation to fit the model")
        case .promptTagsRemoved: String(localized: "Removed prompt tags the model copied into its answer")
        }
        guard let detail = step.detail, !detail.isEmpty else { return text }
        return text + ": " + detail
    }

    public static func happensBeforeTheModel(_ kind: AITraceStep.Kind) -> Bool {
        kind == .conversationShortened || kind == .summaryUsedForConversation
    }

    public static func steps(_ steps: [AITraceStep]) -> String? {
        guard !steps.isEmpty else { return nil }
        let before = steps.filter { happensBeforeTheModel($0.kind) }
        let after = steps.filter { !happensBeforeTheModel($0.kind) }
        var lines: [String] = []
        if !before.isEmpty { lines += [String(localized: "Before the model")] + before.map { "• " + step($0) } }
        if !after.isEmpty { lines += [String(localized: "After the model")] + after.map { "• " + step($0) } }
        return lines.joined(separator: "\n")
    }

    public static func promptTitle(_ name: String) -> String {
        PromptCatalog.entries.first { $0.id == name }?.title ?? name
    }

    public static func prompt(_ trace: AITraceRecord) -> String? {
        guard let id = trace.promptID else { return nil }
        let base = String(localized: "\(promptTitle(id.name)) prompt, version \(id.version)")
        guard let revision = trace.overrideRevision else { return base + " · " + String(localized: "not edited") }
        return base + " · " + String(localized: "your edit, revision \(revision)")
    }

    public static func why(_ route: FeatureRoute, name: (AIProviderID) -> String) -> String {
        switch route.selection {
        case .unavailable(.onDeviceOnly, let id?) where route.origin == .yourChoice:
            return String(localized: "You chose \(name(id)), which runs off this Mac, but this account allows AI on this Mac only.")
        case .unavailable(let reason, let id):
            return AIWording.reason(reason, providerName: id.map(name))
        case .selected(let candidate):
            let where_ = candidate.dataLocation.leavesDevice ? String(localized: "leaves this Mac")
                                                              : String(localized: "on this Mac")
            let origin = switch route.origin {
            case .yourChoice: String(localized: "Your choice")
            case .mailDefault: String(localized: "Mail's default")
            case .firstReady: String(localized: "No default model set up here")
            }
            return origin + " · " + where_
        }
    }

    public static func traceWhy(_ route: FeatureRoute, name: (AIProviderID) -> String) -> String {
        guard case .selected = route.selection else { return why(route, name: name) }
        switch route.origin {
        case .yourChoice: return String(localized: "You chose it for this feature.")
        case .mailDefault: return String(localized: "Mail's default for this feature.")
        case .firstReady: return String(localized: "No default model is set up for this feature here.")
        }
    }

    public static func snippet(_ trace: AITraceRecord, limit: Int = 140) -> String? {
        let text = trace.finalText ?? trace.outputText ?? ""
        guard let line = text.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

public struct AITraceDetail: Identifiable, Hashable, Sendable {
    public struct Fact: Hashable, Sendable {
        public let key: String
        public let label: String
        public let value: String
    }

    public struct Section: Identifiable, Hashable, Sendable {
        public static let collapsedLines = 8
        static let collapsedCharacters = collapsedLines * 90

        public let id: String
        public let title: String
        public let text: String

        public var lineCount: Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }

        public var collapses: Bool {
            (id == "prompt" || id == "input") && (lineCount > Self.collapsedLines || text.count > Self.collapsedCharacters)
        }

        public var isPlainText: Bool { id == "steps" || id == "text" }
    }

    public let id: UUID
    public let date: Date
    public let title: String
    public let model: String
    public let badge: AIProviderBadge
    public let rating: Int?
    public let failed: Bool
    public let promptName: String?
    public let facts: [Fact]
    public let sections: [Section]

    public init(_ trace: AITraceRecord, why: String? = nil) {
        id = trace.id
        date = trace.createdAt
        title = AITraceWording.title(trace)
        model = AITraceWording.model(trace)
        var badge = AIProviderBadge(providerName: trace.providerName, location: trace.dataLocation,
                                    fromCache: trace.cache == .hit)
        badge.traceID = trace.id
        self.badge = badge
        rating = trace.rating
        failed = trace.outcome == .failed
        promptName = trace.promptID?.name

        var facts = [Fact(key: "model", label: String(localized: "Model"), value: model),
                     Fact(key: "where", label: String(localized: "Where"), value: badge.title)]
        if let why { facts.append(Fact(key: "why", label: String(localized: "Why this model"), value: why)) }
        if let prompt = AITraceWording.prompt(trace) { facts.append(Fact(key: "prompt", label: String(localized: "Prompt"), value: prompt)) }
        var timing: [String] = []
        if let latency = trace.latencyMilliseconds { timing.append(AITraceWording.duration(milliseconds: latency)) }
        if let first = trace.firstTokenMilliseconds {
            timing.append(String(localized: "first words after \(AITraceWording.duration(milliseconds: first))"))
        }
        if !timing.isEmpty { facts.append(Fact(key: "time", label: String(localized: "Time"), value: timing.joined(separator: ", "))) }
        if let tokens = AITraceWording.tokens(trace) { facts.append(Fact(key: "tokens", label: String(localized: "Tokens"), value: tokens)) }
        facts.append(Fact(key: "result", label: String(localized: "Result"), value: trace.cache == .hit
            ? String(localized: "From cache, no model call") : AITraceWording.outcome(trace)))
        if let rating = AITraceWording.rating(trace.rating) {
            facts.append(Fact(key: "rating", label: String(localized: "Your rating"), value: rating))
        }
        self.facts = facts

        var sections: [Section] = []
        func add(_ id: String, _ title: String, _ text: String?) {
            guard let text, !text.isEmpty else { return }
            sections.append(Section(id: id, title: title, text: text))
        }
        if trace.outcome == .failed || trace.errorText != nil {
            let kind = trace.errorKind.map { "[\($0)] " } ?? ""
            add("error", String(localized: "Error"), kind + (trace.errorText ?? AITraceWording.outcome(trace)))
        }
        if trace.finalText != trace.outputText { add("final", String(localized: "Shown to you"), trace.finalText) }
        add("output", String(localized: "Model output"), trace.outputText)
        add("steps", String(localized: "What Mail did"), AITraceWording.steps(trace.steps))
        add("prompt", String(localized: "Prompt as sent"), trace.systemText)
        add("input", String(localized: "Input as sent, with the email text"), trace.inputText)
        if trace.systemText == nil, trace.inputText == nil, trace.outputText == nil {
            add("text", String(localized: "Text"), String(localized: "Mail didn't keep the text of this request."))
        }
        self.sections = sections
    }

    public var whyThisFacts: [Fact] { facts.filter { $0.key != "where" } }

    public var plainText: String {
        let head = ([title] + facts.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
        return ([head] + sections.map { "\($0.title)\n\($0.text)" }).joined(separator: "\n\n")
    }
}
