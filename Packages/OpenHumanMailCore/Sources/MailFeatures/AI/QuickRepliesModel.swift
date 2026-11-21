import Foundation
import MailModel
import Observation
import OpenHumanAI

public struct QuickReply: Identifiable, Hashable, Sendable {
    public let id: Int
    public let label: String
    public let body: String
    public let linkHostsAddedByAI: [String]
}

@MainActor @Observable
public final class QuickRepliesModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
        case unavailable(String)
    }

    public enum Failure: Equatable, Sendable {
        case empty
        case error(AIError)
        case notOffered
        case excluded(QuickReplyExclusion)
    }

    public let thread: ThreadKey
    public private(set) var target: MessageKey?
    public private(set) var phase: Phase = .idle
    public private(set) var options: [QuickReply] = []
    public private(set) var badge: AIProviderBadge?
    public private(set) var isSuspicious = false
    public private(set) var selection: Int?
    public private(set) var failure: Failure?
    public private(set) var fromCache = false
    public internal(set) var hiddenInComposer: Bool {
        get { center?.hiddenQuickReplies.contains(thread) ?? false }
        set { center?.setQuickRepliesHidden(newValue, in: thread) }
    }

    @ObservationIgnored private weak var center: AICenter?

    public var aiCenter: AICenter? { center }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requested: Set<AITrigger> = []
    @ObservationIgnored private var running: AITrigger?

    init(thread: ThreadKey, target: MessageKey?, center: AICenter) {
        self.thread = thread
        self.target = target
        self.center = center
    }

    func pin(_ message: MessageKey) {
        if target == nil { target = message }
    }

    isolated deinit {
        task?.cancel()
    }

    public var isOffered: Bool {
        guard let center, center.settings.enabled, center.settings.draftReplies != .off else { return false }
        if case .unavailable = phase { return false }
        return true
    }

    public var selectedOption: QuickReply? { selection.flatMap { options.indices.contains($0) ? options[$0] : nil } }

    public func request(trigger: AITrigger) {
        guard let center else { return }
        let settings = center.settings
        guard settings.enabled, settings.draftReplies != .off else {
            phase = .unavailable(String(localized: "Quick replies are off in Settings › AI"))
            failure = .notOffered
            return
        }
        if trigger == .automatic, !settings.writesRepliesAutomatically { return }
        switch phase {
        case .ready, .loading:
            return
        case .unavailable where trigger == .automatic, .failed where trigger == .automatic:
            return
        default:
            break
        }
        guard !requested.contains(trigger) || trigger == .user else { return }
        requested.insert(trigger)
        run(trigger: trigger)
    }

    public func retry() {
        guard phase != .loading else { return }
        run(trigger: .user)
    }

    public func retryAutomatic() {
        guard let center, phase != .loading else { return }
        let settings = center.settings
        guard settings.enabled, settings.writesRepliesAutomatically else { return }
        requested.insert(.automatic)
        run(trigger: .automatic)
    }

    private func run(trigger: AITrigger) {
        guard let center else { return }
        task?.cancel()
        running = trigger
        phase = .loading
        failure = nil
        isSuspicious = false
        let thread = self.thread
        let target = self.target
        task = Task { [weak self] in
            let loaded = await center.context(for: thread, upTo: target, trigger: trigger)
            // Why: a cancelled load comes back empty too, and that is not a conversation that went away
            guard !Task.isCancelled else { return }
            guard let context = loaded else {
                self?.fail(String(localized: "This conversation is no longer here."), trigger: trigger, failure: .notOffered)
                return
            }
            if let answered = context.messageKeys.last { self?.pin(answered) }
            if context.lastIsFromMe {
                self?.failure = .notOffered
                self?.phase = .unavailable(context.isNewest ? String(localized: "The newest message is yours")
                                                            : String(localized: "This message is yours"))
                return
            }
            if let excluded = center.exclusion(for: thread, context: context) {
                self?.failure = .excluded(excluded)
                self?.phase = .unavailable(excluded.text)
                return
            }
            do {
                let result = try await center.features.replyOptionsResult(context.input,
                                                                        userName: center.userName(thread.account))
                guard !Task.isCancelled, let self else { return }
                self.options = Self.usable(result.options)
                self.badge = AIProviderBadge(provenance: result.provenance)
                self.fromCache = result.provenance.fromCache
                self.isSuspicious = result.report.suspicious
                self.selection = nil
                self.failure = self.options.isEmpty ? .empty : nil
                self.phase = self.options.isEmpty ? .failed(String(localized: "No replies came back")) : .ready
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(AIWording.failure(error), trigger: trigger,
                           failure: (error as? AIError).map(Failure.error) ?? .error(.providerFailed("")))
            }
        }
    }

    private func fail(_ text: String, trigger: AITrigger, failure: Failure) {
        options = []
        selection = nil
        self.failure = failure
        phase = trigger == .automatic ? .unavailable(text) : .failed(text)
    }

    static func usable(_ options: [ReplyOption]) -> [QuickReply] {
        var seen: Set<String> = []
        var kept: [QuickReply] = []
        for option in options {
            let body = option.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, seen.insert(body.lowercased()).inserted else { continue }
            let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
            kept.append(QuickReply(id: kept.count,
                                   label: label.isEmpty ? body.split(whereSeparator: \.isWhitespace).prefix(3)
                                       .joined(separator: " ") : label,
                                   body: body, linkHostsAddedByAI: option.linkHostsAddedByAI))
        }
        return kept
    }

    public func selectNext() {
        guard !options.isEmpty else { return }
        selection = selection.map { ($0 + 1) % options.count } ?? 0
    }

    public func selectPrevious() {
        guard !options.isEmpty else { return }
        selection = selection.map { ($0 - 1 + options.count) % options.count } ?? options.count - 1
    }

    public func select(_ index: Int) {
        guard options.indices.contains(index) else { return }
        selection = index
    }

    public func cancel() {
        task?.cancel()
        if phase == .loading { phase = .idle }
    }

    func settled() async {
        await task?.value
    }

    public func cancelAutomatic() {
        guard running == .automatic, phase == .loading else { return }
        cancel()
        requested.remove(.automatic)
    }

    func reset() {
        cancel()
        phase = .idle
        options = []
        selection = nil
        badge = nil
        isSuspicious = false
        failure = nil
        fromCache = false
        requested = []
    }
}
