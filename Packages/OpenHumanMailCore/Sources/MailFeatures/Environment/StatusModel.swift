import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor
@Observable
public final class StatusModel {
    public private(set) var connectivity: [AccountID: ConnectivityState] = [:]
    public private(set) var progress: [AccountID: String] = [:]
    public var activeAccount: AccountID?
    public var focusLine: String?
    public private(set) var smartSearch: SmartSearchStatus = .off
    public var sendingLine: String?
    @ObservationIgnored public var showSending: (@MainActor () -> Void)?
    public var preparingLine: String?

    public private(set) var pendingCounts: [AccountID: Int] = [:]
    public private(set) var pendingSettled = false
    public let showPendingSync: StoredSetting<Bool>
    public nonisolated static let pendingDebounce: Duration = .milliseconds(400)

    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let sleeper: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    public init(data: any MailDataSource, settings: (any SettingsPort)? = nil,
                pendingDebounce: Duration = StatusModel.pendingDebounce,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.data = data
        self.debounce = pendingDebounce
        self.sleeper = sleep
        self.showPendingSync = StoredSetting(AppSettings.showPendingSync, port: settings)
    }

    isolated deinit {
        debounceTask?.cancel()
    }

    public func run() async {
        let source = data
        let lines = Task { [weak self] in
            for await value in source.syncProgress() {
                guard !Task.isCancelled else { return }
                await self?.setProgress(value)
            }
        }
        let pending = Task { [weak self] in
            for await value in source.pendingChanges() {
                guard !Task.isCancelled else { return }
                await self?.setPending(value)
            }
        }
        showPendingSync.start()
        let smart = Task { [weak self] in
            for await value in source.smartSearchStatus() {
                guard !Task.isCancelled else { return }
                await self?.setSmartSearch(value)
            }
        }
        await withTaskCancellationHandler {
            for await state in data.connectivity() {
                guard !Task.isCancelled else { return }
                connectivity = state
            }
        } onCancel: {
            lines.cancel()
            smart.cancel()
            pending.cancel()
        }
    }

    private func setProgress(_ value: [AccountID: String]) { progress = value }

    func setPending(_ value: [AccountID: Int]) {
        pendingCounts = value.filter { $0.value > 0 }
        if pendingCounts.isEmpty {
            debounceTask?.cancel()
            debounceTask = nil
            pendingSettled = false
        } else if !pendingSettled, debounceTask == nil {
            let wait = debounce, sleeper = self.sleeper
            debounceTask = Task { [weak self] in
                do { try await sleeper(wait) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.debounceTask = nil
                if !self.pendingCounts.isEmpty { self.pendingSettled = true }
            }
        }
    }

    func pendingDebounceFinished() async { await debounceTask?.value }

    private func setSmartSearch(_ value: SmartSearchStatus) {
        if smartSearch != value { smartSearch = value }
    }

    public var smartSearchLine: String? {
        guard let text = SmartSearchStatusText.statusBar(smartSearch), progress.isEmpty else { return nil }
        for state in connectivity.values {
            guard case .online(false, _) = state else { return nil }
        }
        return text
    }

    public var isVisible: Bool {
        !connectivity.isEmpty || focusLine != nil || smartSearchLine != nil || sendingLine != nil || preparingLine != nil
            || pendingLine != nil
    }

    public var pendingLine: String? {
        guard showPendingSync.value, pendingSettled else { return nil }
        let total = pendingCounts.values.reduce(0, +)
        guard total > 0 else { return nil }
        let states = pendingCounts.keys.compactMap { connectivity[$0] }
        let state = states.first { if case .needsReauth = $0 { return true } else { return false } }
            ?? states.first { switch $0 { case .offline, .rateLimited: return true; default: return false } }
            ?? states.first
        return Self.pendingText(count: total, connectivity: state)
    }

    public var pendingHelp: String {
        var text = "Changes are saved on this Mac and sent to Gmail in the background."
        if pendingCounts.count > 1 {
            let parts = pendingCounts.sorted { $0.key.rawValue < $1.key.rawValue }.enumerated()
                .map { "Account \($0.offset + 1): \($0.element.value)" }
            text += " " + parts.joined(separator: ", ") + "."
        }
        return text
    }

    public nonisolated static func pendingText(count: Int, connectivity: ConnectivityState?) -> String? {
        guard count > 0 else { return nil }
        let noun = count == 1 ? "1 change" : "\(count) changes"
        switch connectivity {
        case .offline, .rateLimited: return "\(noun) waiting for a connection"
        case .needsReauth: return "\(noun) waiting for you to sign in"
        case .online, .syncFailing, nil: return "Syncing \(noun) to Gmail"
        }
    }

    public var shownSync: (account: AccountID, state: ConnectivityState)? {
        if let activeAccount, let state = connectivity[activeAccount] { return (activeAccount, state) }
        guard let first = connectivity.sorted(by: { $0.key.rawValue < $1.key.rawValue }).first else { return nil }
        return (first.key, first.value)
    }

    public func syncText(now: Date) -> String? {
        guard let shown = shownSync else { return nil }
        if case .online = shown.state, let line = progress[shown.account] { return line }
        return Self.syncText(shown.state, now: now)
    }

    public nonisolated static let pollingText = "Syncing…"

    public nonisolated static func syncText(_ state: ConnectivityState, now: Date) -> String {
        switch state {
        case .online(syncing: true, lastSyncAt: nil):
            return "Syncing your inbox…"
        case .online(syncing: true, lastSyncAt: _):
            return pollingText
        case .online(syncing: false, lastSyncAt: nil):
            return "Waiting to sync"
        case .online(syncing: false, lastSyncAt: let last?):
            return "Synced " + relative(last, now: now)
        case .offline:
            return "Offline. Retrying."
        case .rateLimited:
            return "Gmail asked us to slow down. Retrying."
        case .syncFailing(let code, _, _):
            return syncFailureText(code)
        case .needsReauth:
            return "Google signed this account out. Quit and reopen Mail to sign in again."
        }
    }

    public var syncFailureCode: String? {
        guard let shown = shownSync, case .syncFailing(let code, _, _) = shown.state else { return nil }
        return code
    }

    public nonisolated static func syncFailureText(_ code: String, account: String? = nil) -> String {
        if code == "owned_elsewhere" {
            return "Another copy of Mail is syncing \(account ?? "this account"). Quit it to sync here."
        }
        if code.hasPrefix("server_") { return "Gmail is having trouble. Retrying." }
        if code == "unauthorized" || code.hasPrefix("forbidden") {
            return "Gmail refused access to \(account ?? "this account"). Retrying."
        }
        return account.map { "Couldn't sync \($0). Retrying." } ?? "Couldn't sync. Retrying."
    }

    nonisolated static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return minutes == 1 ? "1 min ago" : "\(minutes) min ago" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
    }
}
