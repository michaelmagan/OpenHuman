import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class BlockedSettingsModel {
    nonisolated public static let pageID = "blocked"
    nonisolated public static let emptyText = "Nothing is blocked. Block a sender or a domain from a conversation (⌥⌘B, ⌥⇧⌘B) or add one here."
    nonisolated public static let unblockNote = "Unblocking only stops the rule. Mail already filed stays where it is: search for it, or open All mail."

    public struct LastChange: Hashable, Sendable {
        public let title: String
        let entryID: UUID?
        let token: UndoToken?
    }

    public private(set) var accounts: [Account] = []
    public var account: AccountID? {
        didSet { if account != oldValue { accountChanged() } }
    }
    public private(set) var rules: [BlockRule] = []
    public private(set) var hasLoaded = false
    public private(set) var defaultDisposition: BlockDisposition = .archive
    public var query = ""
    public var newValue = ""
    public private(set) var pendingConfirmation: BlockRule?
    @ObservationIgnored private var pendingAllowsCommonDomain = false
    public private(set) var errorMessage: String?
    public private(set) var lastChange: LastChange?
    public private(set) var isWorking = false
    public let availability: SettingsAvailability

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private let center: BlockCenter?
    @ObservationIgnored private let undo: UndoCoordinator?
    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private var accountsTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    public init(environment: AppEnvironment) {
        self.environment = environment
        data = environment.data
        undo = environment.undo
        availability = SettingsAvailability(environment: environment)
        center = environment.settings.map { BlockCenter(settings: $0, data: environment.data) }
    }

    isolated deinit {
        accountsTask?.cancel()
        for task in tasks { task.cancel() }
    }

    public var canEdit: Bool { center != nil }

    public var editNote: String? { center == nil ? "Blocking isn't available here." : nil }

    public var visibleRules: [BlockRule] { BlockRuleList.filtered(rules, query: query) }

    public func dispositionText(_ rule: BlockRule) -> String {
        rule.disposition?.title ?? "Default (\(defaultDisposition.title))"
    }

    public func start() {
        guard accountsTask == nil else { return }
        let data = self.data
        accountsTask = Task { [weak self] in
            do {
                for try await list in data.accounts() {
                    guard !Task.isCancelled, let self else { return }
                    self.accounts = list
                    if self.account == nil || !list.contains(where: { $0.id == self.account }) { self.account = list.first?.id }
                }
            } catch {}
        }
        if let center {
            tasks.append(Task { [weak self] in
                for await value in center.observeDefaultDisposition() {
                    guard !Task.isCancelled, let self else { return }
                    self.defaultDisposition = value
                }
            })
        }
    }

    private func accountChanged() {
        for task in tasks.dropFirst() { task.cancel() }
        tasks = Array(tasks.prefix(1))
        rules = []
        hasLoaded = false
        cancelPending()
        errorMessage = nil
        guard let account, let center else { return }
        tasks.append(Task { [weak self] in
            for await list in center.observeRules(account) {
                guard !Task.isCancelled, let self else { return }
                self.rules = list
                self.hasLoaded = true
            }
        })
    }


    public func addTyped() async {
        guard canEdit, let account, let center else { return }
        errorMessage = nil
        guard let rule = BlockRuleList.parse(newValue, now: Date()) else {
            errorMessage = "Enter an address like name@example.com, or a domain like example.com."
            return
        }
        if rules.contains(where: { $0.id == rule.id }) {
            errorMessage = "\(rule.value) is already blocked."
            return
        }
        isWorking = true
        defer { isWorking = false }
        let wholeDomain = rule.kind == .domain
        if wholeDomain {
            let ask: DomainWideRuleAsking = environment?.domainWideRuleAsking ?? { @Sendable _ in .cancel }
            guard await DomainWideRules.allowsEntireDomain(rule.value, effect: .block, ask: ask) else { return }
        }
        if await center.hasSentTo(rule, account: account) {
            pendingConfirmation = rule
            pendingAllowsCommonDomain = wholeDomain
            return
        }
        await commit(rule, account: account, allowingCommonDomain: wholeDomain)
    }

    public func confirmPending() async {
        guard let rule = pendingConfirmation, let account else { return }
        let wholeDomain = pendingAllowsCommonDomain
        cancelPending()
        isWorking = true
        defer { isWorking = false }
        await commit(rule, account: account, allowingCommonDomain: wholeDomain)
    }

    public func cancelPending() {
        pendingConfirmation = nil
        pendingAllowsCommonDomain = false
    }

    private func commit(_ rule: BlockRule, account: AccountID, allowingCommonDomain: Bool) async {
        guard let center else { return }
        await perform("Blocked \(rule.value)") {
            try await center.add(rule, account: account, allowingCommonDomain: allowingCommonDomain)
        }
        if lastChange != nil { newValue = "" }
    }

    public func unblock(_ rule: BlockRule) async {
        guard canEdit, let account, let center else { return }
        isWorking = true
        defer { isWorking = false }
        await perform("Unblocked \(rule.value)") { try await center.remove(ids: [rule.id], account: account) }
    }

    public func setDisposition(_ disposition: BlockDisposition?, of rule: BlockRule) async {
        guard canEdit, let account, let center else { return }
        isWorking = true
        defer { isWorking = false }
        await perform("Changed what happens to mail from \(rule.value)") {
            try await center.setDisposition(disposition, ofRule: rule.id, account: account)
        }
    }

    public func setDefault(_ value: BlockDisposition) async {
        guard canEdit, let center else { return }
        errorMessage = nil
        do { try await center.setDefaultDisposition(value) } catch { errorMessage = "The setting couldn't be saved." }
    }

    public func showMail(_ rule: BlockRule) {
        guard let environment, let query = BlockMatcher.showQuery(kind: rule.kind, value: rule.value) else { return }
        if let account { environment.router.switchAccount(to: account) }
        let search = environment.overlays.search
        search.open()
        search.text = query
        search.submit()
    }

    private func perform(_ title: String, _ change: () async throws -> UndoToken) async {
        errorMessage = nil
        do {
            let token = try await change()
            guard !token.changesNothing else { return }
            let undoer = center?.ruleUndoer
            if let undo, let undoer {
                let entry = UndoCoordinator.Entry(title: LocalizedStringResource(stringLiteral: title), token: token,
                                                  undoer: undoer)
                undo.push(entry)
                lastChange = LastChange(title: title, entryID: entry.id, token: nil)
            } else {
                lastChange = LastChange(title: title, entryID: nil, token: token)
            }
        } catch {
            errorMessage = "The change couldn't be saved."
        }
    }

    public var canUndoLastChange: Bool {
        guard let lastChange else { return false }
        if let id = lastChange.entryID { return undo?.stack.contains { $0.id == id } == true }
        return lastChange.token != nil
    }

    public func undoLastChange() async {
        guard let lastChange else { return }
        if let id = lastChange.entryID {
            await undo?.undo(entryID: id)
        } else if let token = lastChange.token, let undoer = center?.ruleUndoer {
            _ = try? await undoer.undo(token)
        }
        self.lastChange = nil
    }
}
