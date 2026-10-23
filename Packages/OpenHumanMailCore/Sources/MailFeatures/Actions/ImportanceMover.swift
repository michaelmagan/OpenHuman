import Foundation
import MailActions
import MailModel
import OpenHumanCore

struct ImportanceAndFlagUndo: MailUndoing {
    struct Steps: Codable { var importance: Data; var flag: Data? }

    let importance: any MailUndoing
    let commands: any MailUndoing

    static func token(importance: UndoToken, flag: UndoToken?) throws -> UndoToken {
        UndoToken(payload: try JSONEncoder().encode(Steps(importance: importance.payload, flag: flag?.payload)))
    }

    func undo(_ token: UndoToken) async throws -> UndoToken? {
        let steps = try JSONDecoder().decode(Steps.self, from: token.payload)
        var flagBack: UndoToken?
        if let flag = steps.flag { flagBack = try await commands.undo(UndoToken(payload: flag)) }
        guard let back = try await importance.undo(UndoToken(payload: steps.importance)) else { return nil }
        return try Self.token(importance: back, flag: flagBack)
    }
}

// Both command pairs share this so a move always pins locally and sets Gmail's mark as one undo entry
@MainActor
final class ImportanceMover {
    struct Move: Sendable {
        var thread: ThreadKey
        var toImportant: Bool
        var location: MailLocation?
        var sender: String?
        var domain: String?
        var row: ThreadRow?
    }

    typealias AfterMove = @MainActor @Sendable (ThreadRow?) async -> Void

    nonisolated static let gmailImportant = GmailLabelID("IMPORTANT")

    private weak var environment: AppEnvironment?
    private weak var list: ThreadListModel?
    private let port: any ImportanceRulesPort
    private let feedback: ActionFeedback

    init(environment: AppEnvironment, port: any ImportanceRulesPort, feedback: ActionFeedback, list: ThreadListModel?) {
        self.environment = environment
        self.port = port
        self.feedback = feedback
        self.list = list
    }

    static func list(for thread: ThreadKey, router: AppRouter?) -> ThreadListModel? {
        (router?.accounts.first { $0.id == thread.account } ?? router?.active)?.list
    }

    func start(_ move: Move, afterMove: AfterMove? = nil) -> Task<Void, Never> {
        let placement = list?.applyOptimisticImportance(move.thread, toImportant: move.toImportant, changesGmail: false)
        return Task { await self.run(move, placement: placement, afterMove: afterMove) }
    }

    private func run(_ move: Move, placement: OptimisticTicket?, afterMove: AfterMove?) async {
        guard let environment else { return }
        let commands = await Self.read(AppSettings.importanceSendsToGmail, environment) ? environment.commands : nil
        var row = move.row
        if row == nil {
            row = (try? await environment.data.localThread(move.thread.account, gmailThreadID: move.thread.gmailThreadID)) ?? nil
        }
        let toImportant = move.toImportant
        let thread = move.thread
        let writes = commands != nil && (toImportant || row?.isImportant ?? true)
        let mark = writes ? list?.applyOptimisticImportance(thread, toImportant: toImportant, changesGmail: true) : nil
        let title = Self.title(toImportant: toImportant, inInbox: move.location?.isInboxLike ?? true,
                               onThisMac: commands == nil)
        let change = ImportanceChange(kind: toImportant ? .alwaysThread : .neverThread, account: thread.account,
                                      value: thread.gmailThreadID.rawValue, thread: thread)
        let port = self.port
        var labelsMissing = false
        let work: () async throws -> UndoToken = {
            let rule = try await port.apply(change)
            guard let commands else { return rule }
            guard writes else { return try ImportanceAndFlagUndo.token(importance: rule, flag: nil) }
            let label = Self.gmailImportant
            do {
                let flag = try await commands.apply(.modifyLabels([thread], add: toImportant ? [label] : [],
                                                                  remove: toImportant ? [] : [label]))
                return try ImportanceAndFlagUndo.token(importance: rule, flag: flag.changesNothing ? nil : flag)
            } catch MailPortError.notFound(_) {
                labelsMissing = true
                return try ImportanceAndFlagUndo.token(importance: rule, flag: nil)
            } catch {
                _ = try? await port.undo(rule)
                throw error
            }
        }
        let undoer: any MailUndoing = commands.map { ImportanceAndFlagUndo(importance: port, commands: $0) } ?? port
        do {
            if let undo = environment.undo {
                try await undo.perform(title, threads: [thread], via: undoer, work)
            } else {
                _ = try await work()
            }
        } catch {
            if let mark { list?.revertOptimistic(mark) }
            if let placement { list?.revertOptimistic(placement) }
            feedback.failed(Self.failure(toImportant)) { [self] in await self.start(move, afterMove: afterMove).value }
            return
        }
        if labelsMissing {
            if let mark { list?.revertOptimistic(mark) }
            environment.notices.post(Self.labelsNotSyncedText, style: .info)
        }
        if let explanation = try? await port.explain(thread), explanation.isImportant != toImportant {
            if let placement { list?.revertOptimistic(placement) }
            let told: Bool? = writes && !labelsMissing ? toImportant : nil
            environment.notices.post(Self.ruleWinsText(explanation, gmail: told), style: .info)
        }
        await afterMove?(row)
        await offerRule(move)
    }

    private func offerRule(_ move: Move) async {
        guard let environment, await Self.read(AppSettings.classificationSuggestRules, environment),
              let sender = move.sender, let domain = move.domain else { return }
        let undo = environment.undo
        let port = self.port
        let feedback = self.feedback
        let thread = move.thread
        let ask = environment.domainWideRuleAsking
        func choice(_ title: String, _ kind: ImportanceRuleKind, _ value: String, _ done: LocalizedStringResource)
            -> NoticeCenter.Choice {
            NoticeCenter.Choice(title) {
                let proposed = ImportanceChange(kind: kind, account: thread.account, value: value, thread: thread)
                guard let resolved = await ImportanceActionHandler.narrowed(proposed, title: done, sender: sender,
                                                                            ask: ask) else { return }
                let change = resolved.0
                do {
                    if let undo {
                        try await undo.perform(resolved.1, threads: [thread], via: port) { try await port.apply(change) }
                    } else {
                        _ = try await port.apply(change)
                    }
                } catch {
                    feedback.failed("Couldn't change the importance rule")
                }
            }
        }
        let important = move.toImportant
        let prefix = important ? "Always important" : "Never important"
        environment.notices.postChoice(
            "\(prefix) for:",
            choice("This sender", important ? .alwaysSender : .neverSender, sender, "\(prefix) from \(sender)"),
            choice("This domain", important ? .alwaysDomain : .neverDomain, domain, "\(prefix) from \(domain)"))
    }

    private static func read(_ key: AppSettingKey<Bool>, _ environment: AppEnvironment) async -> Bool {
        (try? await environment.settings?.get(key)) ?? key.defaultValue
    }

    nonisolated static func title(toImportant: Bool, inInbox: Bool, onThisMac: Bool) -> LocalizedStringResource {
        switch (toImportant, inInbox, onThisMac) {
        case (true, true, false): "Moved to Important"
        case (false, true, false): "Moved to Other"
        case (true, false, false): "Marked important"
        case (false, false, false): "Marked not important"
        case (true, true, true): "Moved to Important on this Mac"
        case (false, true, true): "Moved to Other on this Mac"
        case (true, false, true): "Marked important on this Mac"
        case (false, false, true): "Marked not important on this Mac"
        }
    }

    nonisolated static func failure(_ toImportant: Bool) -> String {
        toImportant ? "Couldn't move to Important" : "Couldn't move to Other"
    }

    nonisolated static let labelsNotSyncedText = "Moved on this Mac only: Gmail's labels haven't finished syncing, "
        + "so its Important mark wasn't changed."

    nonisolated static func ruleWinsText(_ explanation: ImportanceExplanation, gmail: Bool?) -> String {
        let text = ImportanceActionHandler.senderRuleWinsText(explanation)
        guard let gmail else { return text }
        return text + (gmail ? " Gmail now marks it important." : " Gmail's Important mark was removed.")
    }
}
