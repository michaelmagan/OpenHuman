import Foundation
import MailActions
import MailModel
import OpenHumanCore

@MainActor
final class BlockActionHandler: ActionHandler {
    static let ids: [ActionID] = [.blockSender, .blockDomain, .goBlocked]

    private weak var environment: AppEnvironment?
    private let feedback: ActionFeedback
    private let center: BlockCenter?
    private let undoer: BlockUndoer?

    init(environment: AppEnvironment) {
        self.environment = environment
        feedback = ActionFeedback(environment: environment)
        if let settings = environment.settings, let commands = environment.commands {
            let center = BlockCenter(settings: settings, data: environment.data)
            self.center = center
            undoer = BlockUndoer(rules: center.ruleUndoer, mail: commands)
        } else {
            center = nil
            undoer = nil
        }
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard let environment else { return .hidden }
        if id == .goBlocked { return environment.settingsNavigator.canOpen ? .enabled : .hidden }
        return center == nil ? .hidden : .enabled
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let environment else { return .notHandled }
        if request.id == .goBlocked {
            environment.settingsNavigator.open(BlockedSettingsModel.pageID)
            return .done
        }
        let c = request.context
        guard center != nil, let thread = c.focusedThread else { return .notHandled }
        let account = c.account ?? thread.account
        let rule: BlockRule?
        switch request.id {
        case .blockSender: rule = c.sender.flatMap { BlockRule(kind: .sender, value: $0, createdAt: Date()) }
        case .blockDomain: rule = c.senderDomain.flatMap { BlockRule(kind: .domain, value: $0, createdAt: Date()) }
        default: return .notHandled
        }
        guard let rule else { return .notHandled }
        let place = BlockedPlace(router: request.router, advances: request.source != .intent)
        let sender = c.sender
        return .started(Task { [weak self] in
            guard let self, let chosen = await self.choose(rule, sender: sender) else { return }
            await self.begin(chosen.rule, account: account, thread: thread, place: place,
                             allowingCommonDomain: chosen.wholeDomain)
        })
    }

    func choose(_ rule: BlockRule, sender: String?) async -> (rule: BlockRule, wholeDomain: Bool)? {
        guard rule.kind == .domain, let environment else { return (rule, false) }
        let address = sender.flatMap(BlockMatcher.normalizedAddress)
        switch await DomainWideRules.resolve(domain: rule.value, address: address, effect: .block,
                                             ask: environment.domainWideRuleAsking) {
        case .entireDomain?: return (rule, true)
        case .thisAddressOnly(let address)?:
            return BlockRule(kind: .sender, value: address, createdAt: rule.createdAt).map { (rule: $0, wholeDomain: false) }
        case nil: return nil
        }
    }

    func begin(_ rule: BlockRule, account: AccountID, thread: ThreadKey, place: BlockedPlace,
               allowingCommonDomain: Bool = false) async {
        guard let environment, let center else { return }
        if await center.rules(account).contains(where: { $0.id == rule.id }) {
            environment.notices.post("Already blocked: \(rule.value)", style: .info, duration: NoticeCenter.infoDuration)
            return
        }
        if await center.hasSentTo(rule, account: account) {
            environment.notices.postChoice(
                "You've written to \(rule.value). Block it anyway?",
                NoticeCenter.Choice("Block anyway") { [weak self] in
                    await self?.commit(rule, account: account, thread: thread, place: place,
                                       allowingCommonDomain: allowingCommonDomain)
                },
                NoticeCenter.Choice("Cancel") {},
                duration: nil)
            return
        }
        await commit(rule, account: account, thread: thread, place: place, allowingCommonDomain: allowingCommonDomain)
    }

    func commit(_ rule: BlockRule, account: AccountID, thread: ThreadKey, place: BlockedPlace,
                allowingCommonDomain: Bool = false) async {
        guard let environment, let center, let undoer, let undo = environment.undo,
              let commands = environment.commands else { return }
        let fallback = await center.defaultDisposition()
        let move: MailCommand = (rule.disposition ?? fallback) == .trash ? .trash([thread]) : .markDone([thread])
        let hidden = place.hide(thread, move)
        if let reopens = hidden.reopens { environment.actions.threadActions?.keepDraft(of: reopens.thread) }
        let entry: UndoCoordinator.Entry
        do {
            entry = try await undo.perform("Blocked \(rule.value)", threads: [thread], via: undoer,
                                           reopens: hidden.reopens) {
                let ruleToken = try await center.add(rule, account: account, allowingCommonDomain: allowingCommonDomain)
                do {
                    let moved = try await commands.apply(move)
                    return undoer.begin(rule: ruleToken, moved: moved)
                } catch {
                    if !ruleToken.changesNothing { _ = try? await center.ruleUndoer.undo(ruleToken) }
                    throw error
                }
            }
        } catch {
            hidden.restore()
            feedback.failed("Couldn't block \(rule.value)")
            return
        }
        await offerCleanup(rule, account: account, thread: thread, token: entry.token)
    }


    static let cleanupLimit = ThreadActionHandler.sweepLimit

    func cleanupTargets(_ rule: BlockRule, account: AccountID, excluding thread: ThreadKey) async -> [ThreadKey] {
        guard let environment, let query = BlockMatcher.cleanupQuery(kind: rule.kind, value: rule.value) else { return [] }
        do {
            for try await page in environment.data.search(query, accounts: [account], limit: Self.cleanupLimit) {
                return page.hits.map(\.row).filter { row in
                    row.id != thread && BlockMatcher.coversAny(rule, senders: row.participants.filter { !$0.isMe }.map(\.email))
                }.map(\.id)
            }
        } catch {}
        return []
    }

    private func offerCleanup(_ rule: BlockRule, account: AccountID, thread: ThreadKey, token: UndoToken) async {
        guard let environment, let center else { return }
        let targets = await cleanupTargets(rule, account: account, excluding: thread)
        guard !targets.isEmpty else { return }
        let archive = NoticeCenter.Choice("Archive all") { [weak self] in
            await self?.cleanUp(.markDone(targets), token: token, who: rule.value)
        }
        let trash = NoticeCenter.Choice("Move to Trash") { [weak self] in
            await self?.cleanUp(.trash(targets), token: token, who: rule.value)
        }
        let fallback = await center.defaultDisposition()
        let trashFirst = (rule.disposition ?? fallback) == .trash
        let count = targets.count == 1 ? "1 conversation" : "\(targets.count) conversations"
        environment.notices.postChoice("Blocked \(rule.value). Clean up \(count) from them?",
                                       trashFirst ? trash : archive, trashFirst ? archive : trash)
    }

    func cleanUp(_ command: MailCommand, token: UndoToken, who: String) async {
        guard let environment, let commands = environment.commands, let undoer else { return }
        guard undoer.isApplied(token) else {
            environment.notices.post("The block was undone, so nothing was cleaned up.", style: .info,
                                     duration: NoticeCenter.infoDuration)
            return
        }
        do {
            let cleanup = try await commands.apply(command)
            if !undoer.attach(cleanup: cleanup, to: token) { _ = try? await commands.undo(cleanup) }
        } catch {
            feedback.failed("Couldn't clean up the mail from \(who)")
            return
        }
        let n = command.threads.count
        let what = n == 1 ? "1 conversation" : "\(n) conversations"
        var verb = "Archived \(what)"
        if case .trash = command { verb = "Moved \(what) to Trash" }
        environment.notices.post("\(verb). ⌘Z takes this back along with the block.", style: .info,
                                 duration: NoticeCenter.infoDuration)
    }
}

@MainActor
struct BlockedPlace {
    weak var router: AppRouter?
    let advances: Bool

    func hide(_ thread: ThreadKey, _ command: MailCommand) -> HiddenThread {
        let state = router?.accounts.first { $0.id == thread.account } ?? router?.active
        var reopens: UndoCoordinator.Entry.Reopen?
        if advances, let router, let state { reopens = ThreadActionHandler.advance(past: [thread], in: state, router: router) }
        let list = state?.list
        return HiddenThread(reopens: reopens, ticket: list?.applyOptimistic(command), list: list, state: state,
                            router: router)
    }
}

@MainActor
struct HiddenThread {
    let reopens: UndoCoordinator.Entry.Reopen?
    let ticket: OptimisticTicket?
    weak var list: ThreadListModel?
    weak var state: AccountState?
    weak var router: AppRouter?

    func restore() {
        if let ticket { list?.revertOptimistic(ticket) }
        guard let reopens, let state, state.reader?.thread == reopens.shown else { return }
        state.reopenAfterUndo(reopens.thread)
        router?.setNeedsPersist()
    }
}

public struct BlockModule: FeatureModule {
    public static let id = FeatureModuleID.block
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.actions(ActionCatalog.descriptors(module: Self.id), handler: BlockActionHandler(environment: env))
        registry.settingsPage(SettingsPageDescriptor(id: BlockedSettingsModel.pageID, title: "Blocked", symbol: "nosign"))
    }
}
