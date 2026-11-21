import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class VIPSettingsModel {
    public private(set) var accounts: [Account] = []
    public var account: AccountID? {
        didSet { if account != oldValue { refresh() } }
    }
    public private(set) var suggestions: [VIPSuggestion] = []
    public var vips: [String] { account.map { center.vips(for: $0) } ?? [] }
    public var suggestEnabled: Bool { center.suggestEnabled }
    public private(set) var errorMessage: String?
    public private(set) var notice: String?
    public private(set) var isWorking = false
    public let canMarkVIPs: Bool

    @ObservationIgnored let center: VIPCenter
    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private var accountsTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    public init(center: VIPCenter, data: any MailDataSource, canMarkVIPs: Bool) {
        self.center = center
        self.data = data
        self.canMarkVIPs = canMarkVIPs
    }

    public convenience init(environment: AppEnvironment) {
        self.init(center: environment.vips, data: environment.data, canMarkVIPs: environment.importance != nil)
    }

    isolated deinit {
        accountsTask?.cancel()
        loadTask?.cancel()
    }

    public static let suggestTitle = "Suggest VIPs"
    public static let suggestDetail = "Mail suggests people you reply to often (at least 3 replies in 30 days), from the mail "
        + "on this Mac. Nothing changes until you say yes; a VIP's mail is always important."
    public static let emptyText = "No suggestions."
    public static let resetDetail = "People you answered Not now for can be suggested again. VIPs stay."
    public static let cantMarkText = "VIPs need importance rules, which aren't available here."

    public func start() {
        center.start()
        guard accountsTask == nil else { return }
        let data = self.data
        accountsTask = Task { [weak self] in
            do {
                for try await list in data.accounts() {
                    guard !Task.isCancelled, let self else { return }
                    self.accounts = list
                    if self.account == nil || !list.contains(where: { $0.id == self.account }) {
                        self.account = list.first?.id
                    }
                }
            } catch {}
        }
    }

    public func refresh() {
        loadTask?.cancel()
        guard let account else {
            suggestions = []
            return
        }
        let center = self.center
        loadTask = Task { [weak self] in
            let found = await center.suggestions(for: account)
            guard !Task.isCancelled, self?.account == account else { return }
            self?.suggestions = found
        }
    }

    func settle() async { await loadTask?.value }

    public func accept(_ suggestion: VIPSuggestion) async {
        guard canMarkVIPs else {
            errorMessage = Self.cantMarkText
            return
        }
        await change("\(suggestion.displayName) is a VIP. Their mail is always important.") {
            try await self.center.accept(suggestion)
        }
    }

    public func decline(_ suggestion: VIPSuggestion) async {
        await change("Mail won't suggest \(suggestion.displayName) again.") { try await self.center.decline(suggestion) }
    }

    public func setSuggestEnabled(_ on: Bool) async {
        await change(nil) { try await self.center.setSuggestEnabled(on) }
    }

    public func resetSuggestions() async {
        let ids = accounts.map(\.id)
        await change("Suggestions reset. People you declined can be suggested again.") {
            try await self.center.resetSuggestions(accounts: ids)
        }
    }

    public var canUndo: Bool { center.lastChange != nil && !isWorking }

    public func undoLastChange() async {
        await change(nil) { try await self.center.undoLastChange() }
    }

    private func change(_ done: String?, _ work: () async throws -> Void) async {
        guard !isWorking else { return }
        errorMessage = nil
        notice = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            notice = done
        } catch {
            errorMessage = (error as? MailPortError)?.description ?? "That change couldn't be saved."
        }
        refresh()
    }
}
