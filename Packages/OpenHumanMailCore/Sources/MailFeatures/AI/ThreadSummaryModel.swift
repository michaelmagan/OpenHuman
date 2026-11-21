import Foundation
import MailModel
import Observation
import OpenHumanAI

@MainActor @Observable
public final class ThreadSummaryModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case streaming
        case done
        case failed(String)
        case unavailable(String)
    }

    public let thread: ThreadKey
    public private(set) var phase: Phase = .idle
    public private(set) var text = ""
    public private(set) var badge: AIProviderBadge?
    public private(set) var isSuspicious = false
    public private(set) var summarizedCount = 0

    @ObservationIgnored private weak var center: AICenter?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastTrigger: AITrigger?

    init(thread: ThreadKey, center: AICenter) {
        self.thread = thread
        self.center = center
    }

    isolated deinit {
        task?.cancel()
    }

    public var showsLine: Bool {
        switch phase {
        case .loading, .streaming, .done, .failed: true
        case .idle, .unavailable: false
        }
    }

    public func offersSummarize(messageCount: Int) -> Bool {
        guard let center, center.settings.enabled, messageCount >= AIPolicy.autoSummarizeMinimumMessages else {
            return false
        }
        switch phase {
        case .idle, .unavailable: return true
        default: return false
        }
    }

    public func appeared(messageCount: Int) {
        guard let center, center.settings.enabled, center.settings.autoSummarizeOnOpen,
              messageCount >= AIPolicy.autoSummarizeMinimumMessages else { return }
        switch phase {
        case .idle:
            summarize(trigger: .automatic, messageCount: messageCount)
        case .done where messageCount > summarizedCount && lastTrigger == .automatic:
            summarize(trigger: .automatic, messageCount: messageCount)
        default:
            break
        }
    }

    public func summarize(trigger: AITrigger = .user, messageCount: Int? = nil) {
        guard let center else { return }
        task?.cancel()
        lastTrigger = trigger
        phase = .loading
        isSuspicious = false
        let thread = self.thread
        task = Task { [weak self] in
            let loaded = await center.context(for: thread, trigger: trigger)
            // Why: a cancelled load comes back empty too, and that is not a conversation that went away
            guard !Task.isCancelled else { return }
            guard let context = loaded else {
                self?.finish(failure: String(localized: "This conversation is no longer here."), trigger: trigger)
                return
            }
            var text = ""
            var scaffolding = PromptScaffoldingFilter(nonce: nil)
            do {
                for try await event in center.features.summarize(context.input) {
                    guard !Task.isCancelled, let self else { return }
                    switch event {
                    case .started(let provenance):
                        self.badge = AIProviderBadge(provenance: provenance)
                    case .textDelta(let delta):
                        text += scaffolding.feed(delta)
                        // Why: held whitespace shows with its chunk, so the end of the stream adds no text
                        let shown = text + scaffolding.pendingWhitespace
                        guard !shown.isEmpty else { continue }
                        if self.text != shown { self.text = shown }
                        self.phase = .streaming
                    case .completed(let report):
                        self.isSuspicious = report.suspicious
                    }
                }
                guard let self, !Task.isCancelled else { return }
                text += scaffolding.finish()
                if self.text != text { self.text = text }
                self.summarizedCount = messageCount ?? context.messageKeys.count
                self.phase = text.isEmpty ? .failed(String(localized: "The model returned no summary")) : .done
            } catch {
                guard !Task.isCancelled else { return }
                self?.finish(failure: AIWording.failure(error), trigger: trigger)
            }
        }
    }

    private func finish(failure: String, trigger: AITrigger) {
        text = ""
        phase = trigger == .automatic ? .unavailable(failure) : .failed(failure)
    }

    public func cancelAutomatic() {
        guard lastTrigger == .automatic, phase == .loading || phase == .streaming else { return }
        cancel()
    }

    public func cancel() {
        task?.cancel()
        if phase == .loading || phase == .streaming { phase = .idle }
    }

    func settled() async {
        await task?.value
    }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        text = ""
        badge = nil
        isSuspicious = false
        summarizedCount = 0
    }
}
