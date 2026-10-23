import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class ImportanceActionHandler: ActionHandler {
    public static let ids: [ActionID] = [.alwaysImportantSender, .alwaysImportantDomain, .neverImportant,
                                         .neverImportantDomain, .removeFromSplit, .notAPitch, .explainPlacement,
                                         .moveToImportant, .moveToOther]

    public private(set) var lastExplanation: (thread: ThreadKey, explanation: ImportanceExplanation)?

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private let feedback: ActionFeedback

    init(environment: AppEnvironment, feedback: ActionFeedback) {
        self.environment = environment
        self.feedback = feedback
    }

    public func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        environment?.importance == nil ? .hidden : .enabled
    }

    public func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let port = environment?.importance, let thread = request.context.focusedThread else { return .notHandled }
        let c = request.context
        if request.id == .explainPlacement { return explain(thread, port: port) }
        if request.id == .moveToImportant || request.id == .moveToOther {
            guard let environment else { return .notHandled }
            let (row, _) = AutoLabelActionHandler.row(of: thread, router: request.router)
            let mover = ImportanceMover(environment: environment, port: port, feedback: feedback,
                                        list: ImportanceMover.list(for: thread, router: request.router))
            return .started(mover.start(ImportanceMover.Move(thread: thread, toImportant: request.id == .moveToImportant,
                                                             location: c.location, sender: c.sender,
                                                             domain: c.senderDomain, row: row)))
        }
        let account = c.account ?? thread.account
        let change: ImportanceChange
        let title: LocalizedStringResource
        switch request.id {
        case .alwaysImportantSender:
            guard let sender = c.sender else { return .notHandled }
            change = ImportanceChange(kind: .alwaysSender, account: account, value: sender, thread: thread)
            title = "Always important from \(sender)"
        case .alwaysImportantDomain:
            guard let domain = c.senderDomain else { return .notHandled }
            change = ImportanceChange(kind: .alwaysDomain, account: account, value: domain, thread: thread)
            title = "Always important from \(domain)"
        case .neverImportant:
            guard let sender = c.sender else { return .notHandled }
            change = ImportanceChange(kind: .neverSender, account: account, value: sender, thread: thread)
            title = "Never important from \(sender)"
        case .neverImportantDomain:
            guard let domain = c.senderDomain else { return .notHandled }
            change = ImportanceChange(kind: .neverDomain, account: account, value: domain, thread: thread)
            title = "Never important from \(domain)"
        case .removeFromSplit:
            guard case .split(let split) = c.location, let sender = c.sender else { return .notHandled }
            change = ImportanceChange(kind: .excludeFromSplit, account: account, value: sender, split: split,
                                      thread: thread)
            title = "Removed from \(splitName(split, account: account, router: request.router))"
        case .notAPitch:
            guard let sender = c.sender else { return .notHandled }
            change = ImportanceChange(kind: .notPitch, account: account, value: sender, thread: thread)
            title = "Not a pitch: \(sender)"
        default:
            return .notHandled
        }
        guard let undo = environment?.undo else { return .notHandled }
        let feedback = self.feedback
        let pitchLabel = request.id == .notAPitch && c.targets.autoLabel == "Pitch"
            ? environment?.autoLabels : nil
        let (row, labels) = AutoLabelActionHandler.row(of: thread, router: request.router)
        let ask: DomainWideRuleAsking = environment?.domainWideRuleAsking ?? { @Sendable _ in .cancel }
        let sender = c.sender
        return .started(Task {
            guard let resolved = await Self.narrowed(change, title: title, sender: sender, ask: ask) else { return }
            let applied = resolved.0
            do {
                try await undo.perform(resolved.1, threads: [thread], via: port) { try await port.apply(applied) }
                if let pitchLabel { _ = try? await pitchLabel.markWrong(thread, row: row, labels: labels) }
            } catch {
                feedback.failed("Couldn't change the importance rule")
            }
        })
    }

    // A domain rule for a common domain asks first, and can narrow to the sender's own address
    static func narrowed(_ change: ImportanceChange, title: LocalizedStringResource, sender: String?,
                         ask: DomainWideRuleAsking) async -> (ImportanceChange, LocalizedStringResource)? {
        guard let effect = domainWideEffect(change.kind) else { return (change, title) }
        switch await DomainWideRules.resolve(domain: change.value, address: sender, effect: effect, ask: ask) {
        case .entireDomain?:
            return (change, title)
        case .thisAddressOnly(let address)?:
            let always = change.kind == .alwaysDomain
            let narrow = ImportanceChange(kind: always ? .alwaysSender : .neverSender, account: change.account,
                                          value: address, thread: change.thread)
            return (narrow, always ? "Always important from \(address)" : "Never important from \(address)")
        case nil:
            return nil
        }
    }

    nonisolated static func domainWideEffect(_ kind: ImportanceRuleKind) -> DomainWideRuleEffect? {
        switch kind {
        case .alwaysDomain: .alwaysImportant
        case .neverDomain: .neverImportant
        default: nil
        }
    }

    private func explain(_ thread: ThreadKey, port: any ImportanceRulesPort) -> ActionPerformance {
        .started(Task { [weak self] in
            guard let self else { return }
            do {
                let explanation = try await port.explain(thread)
                self.lastExplanation = (thread, explanation)
                self.environment?.notices.post(explanation.line, style: .info)
            } catch {
                self.feedback.failed("Couldn't explain why this conversation is here")
            }
        })
    }

    nonisolated static func senderRuleWinsText(_ explanation: ImportanceExplanation) -> String {
        "\(explanation.line). A rule for the sender wins; change it in Settings › Importance."
    }

    private func splitName(_ split: SplitKey, account: AccountID, router: AppRouter?) -> String {
        router?.accounts.first { $0.id == account }?.splits.first { $0.id == split }?.name ?? "this split"
    }
}
