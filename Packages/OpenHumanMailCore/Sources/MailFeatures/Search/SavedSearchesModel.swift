import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class SavedSearchesModel {
    public private(set) var searches: [SavedSearch] = []
    public private(set) var errorMessage: String?

    @ObservationIgnored private let settings: (any SettingsPort)?
    @ObservationIgnored public private(set) var account: AccountID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored public var now: @Sendable () -> Date = { Date() }

    public init(settings: (any SettingsPort)?) {
        self.settings = settings
    }

    isolated deinit { task?.cancel() }

    public var hasPort: Bool { settings != nil }
    public var canSave: Bool { settings != nil && account != nil }

    public static let fullMessage = "Limit of 50 saved searches per account. Delete one in Settings › General › Search."
    static let failedMessage = "That saved search couldn't be stored."

    public func follow(_ account: AccountID?) {
        guard account != self.account || task == nil else { return }
        task?.cancel()
        task = nil
        self.account = account
        searches = []
        guard let account, let settings else { return }
        let key = AppSettings.savedSearches(account)
        task = Task { [weak self] in
            for await list in settings.observe(key) {
                guard !Task.isCancelled, let self else { return }
                self.searches = list
            }
        }
    }

    public func saved(forQuery query: String) -> SavedSearch? {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return searches.first { $0.query == wanted }
    }

    public func matching(_ word: String) -> [SavedSearch] {
        let needle = word.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return searches }
        return searches.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.query.localizedCaseInsensitiveContains(needle)
        }
    }

    @discardableResult
    public func save(query: String, name: String? = nil) async -> SavedSearch? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let account else { return nil }
        let title = Self.clean(name) ?? SavedSearch.defaultName(for: text)
        let created = SavedSearch(name: title, query: text, createdAt: Int64(now().timeIntervalSince1970 * 1000))
        var stored: SavedSearch?
        var isFull = false
        let changed = await update(account) { current in
            if let index = current.firstIndex(where: { $0.query == text }) {
                var list = current
                list[index].name = title
                stored = list[index]
                return list
            }
            guard current.count < SavedSearch.maxPerAccount else {
                isFull = true
                return nil
            }
            stored = created
            return current + [created]
        }
        if isFull { errorMessage = Self.fullMessage }
        return changed ? stored : nil
    }

    public func rename(_ id: String, to name: String) async {
        guard let account, let title = Self.clean(name) else { return }
        _ = await update(account) { current in
            guard let index = current.firstIndex(where: { $0.id == id }) else { return nil }
            var list = current
            list[index].name = title
            return list
        }
    }

    public func delete(_ id: String) async {
        guard let account else { return }
        _ = await update(account) { current in
            current.contains(where: { $0.id == id }) ? current.filter { $0.id != id } : nil
        }
    }

    private func update(_ account: AccountID, _ change: ([SavedSearch]) -> [SavedSearch]?) async -> Bool {
        guard let settings else { return false }
        let key = AppSettings.savedSearches(account)
        do {
            guard let list = change(try await settings.get(key)) else { return false }
            if self.account == account { searches = list }
            errorMessage = nil
            try await settings.set(key, list)
            return true
        } catch {
            errorMessage = (error as? MailPortError)?.description ?? Self.failedMessage
            if self.account == account, let current = try? await settings.get(key) { searches = current }
            return false
        }
    }

    static func clean(_ name: String?) -> String? {
        guard let name else { return nil }
        let line = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(SavedSearch.nameLimit))
    }
}
