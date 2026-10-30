import Foundation
import MailModel
import OpenHumanCore

struct BlockRuleChange: Codable, Sendable, Hashable {
    var account: AccountID
    var added: [BlockRule]
    var removed: [BlockRule]

    var inverse: BlockRuleChange { BlockRuleChange(account: account, added: removed, removed: added) }
}

enum BlockKeys {
    static func rules(_ account: AccountID) -> AppSettingKey<[BlockRule]> {
        AppSettingKey(name: BlockSettingNames.rules, scope: .account(account), defaultValue: [])
    }

    static let defaultDisposition = AppSettingKey(name: BlockSettingNames.defaultDisposition, defaultValue: BlockDisposition.archive)
}

enum BlockRuleList {
    static func applying(_ change: BlockRuleChange, to rules: [BlockRule]) -> [BlockRule] {
        let out = Set(change.removed.map(\.id)).union(change.added.map(\.id))
        return change.added + rules.filter { !out.contains($0.id) }
    }

    static func filtered(_ rules: [BlockRule], query: String) -> [BlockRule] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return rules }
        return rules.filter { $0.value.contains(needle) }
    }

    static func parse(_ typed: String, now: Date) -> BlockRule? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = text.firstIndex(of: "@"), at != text.startIndex {
            return BlockRule(kind: .sender, value: text, createdAt: now)
        }
        return BlockRule(kind: .domain, value: text, createdAt: now)
    }
}

enum BlockRuleStore {
    static func write(_ change: BlockRuleChange, settings: any SettingsPort) async throws -> UndoToken {
        let key = BlockKeys.rules(change.account)
        let current = (try? await settings.get(key)) ?? []
        let next = BlockRuleList.applying(change, to: current)
        let payload = try JSONEncoder().encode(change)
        guard next != current else { return UndoToken(payload: payload, changesNothing: true) }
        try await settings.set(key, next)
        return UndoToken(payload: payload)
    }
}

struct BlockRuleUndoer: MailUndoing {
    let settings: any SettingsPort

    func undo(_ token: UndoToken) async throws -> UndoToken? {
        let change = try JSONDecoder().decode(BlockRuleChange.self, from: token.payload).inverse
        return try await BlockRuleStore.write(change, settings: settings)
    }
}

@MainActor
public final class BlockCenter {
    private let settings: any SettingsPort
    private let finds: @Sendable (String, AccountID) async throws -> Bool

    public init(settings: any SettingsPort, data: any MailDataSource) {
        self.settings = settings
        finds = { query, account in
            try await !data.searchOnce(query, semanticText: nil, accounts: [account], limit: 1).hits.isEmpty
        }
    }

    init(settings: any SettingsPort, finds: @escaping @Sendable (String, AccountID) async throws -> Bool) {
        self.settings = settings
        self.finds = finds
    }

    var ruleUndoer: BlockRuleUndoer { BlockRuleUndoer(settings: settings) }


    public func rules(_ account: AccountID) async -> [BlockRule] {
        (try? await settings.get(BlockKeys.rules(account))) ?? []
    }

    public func observeRules(_ account: AccountID) -> AsyncStream<[BlockRule]> { settings.observe(BlockKeys.rules(account)) }

    public func defaultDisposition() async -> BlockDisposition {
        (try? await settings.get(BlockKeys.defaultDisposition)) ?? .archive
    }

    public func observeDefaultDisposition() -> AsyncStream<BlockDisposition> { settings.observe(BlockKeys.defaultDisposition) }

    public func setDefaultDisposition(_ value: BlockDisposition) async throws {
        try await settings.set(BlockKeys.defaultDisposition, value)
    }


    /// Refuses a rule for a whole common domain (gmail.com, github.com) with `DomainWideRuleError` unless
    /// `allowingCommonDomain` says the person chose the entire domain.
    public func add(_ rule: BlockRule, account: AccountID, allowingCommonDomain: Bool = false) async throws -> UndoToken {
        if rule.kind == .domain {
            try DomainWideRuleGuard.requireConfirmation(domain: rule.value, confirmed: allowingCommonDomain)
        }
        let current = await rules(account)
        let replaced = current.filter { $0.id == rule.id }
        return try await BlockRuleStore.write(BlockRuleChange(account: account, added: [rule], removed: replaced), settings: settings)
    }

    public func remove(ids: [String], account: AccountID) async throws -> UndoToken {
        let removed = await rules(account).filter { ids.contains($0.id) }
        return try await BlockRuleStore.write(BlockRuleChange(account: account, added: [], removed: removed), settings: settings)
    }

    public func setDisposition(_ disposition: BlockDisposition?, ofRule id: String, account: AccountID) async throws -> UndoToken {
        guard var rule = await rules(account).first(where: { $0.id == id }) else {
            return UndoToken(payload: Data(), changesNothing: true)
        }
        let before = rule
        rule.disposition = disposition
        return try await BlockRuleStore.write(BlockRuleChange(account: account, added: [rule], removed: [before]), settings: settings)
    }


    public func hasSentTo(_ rule: BlockRule, account: AccountID) async -> Bool {
        guard let query = BlockMatcher.sentToQuery(kind: rule.kind, value: rule.value) else { return true }
        do {
            return try await finds(query, account)
        } catch {
            return true
        }
    }
}

@MainActor
final class BlockUndoer: MailUndoing {
    private struct State {
        var rule: UndoToken
        var moved: UndoToken?
        var cleanup: UndoToken?
        var applied: Bool
    }

    private var states: [UUID: State] = [:]
    private let rules: any MailUndoing
    private let mail: any MailUndoing

    init(rules: any MailUndoing, mail: any MailUndoing) {
        self.rules = rules
        self.mail = mail
    }

    func begin(rule: UndoToken, moved: UndoToken? = nil) -> UndoToken {
        let id = UUID()
        states[id] = State(rule: rule, moved: moved, cleanup: nil, applied: true)
        return Self.token(id)
    }

    func isApplied(_ token: UndoToken) -> Bool { Self.id(token).flatMap { states[$0]?.applied } ?? false }

    func attach(cleanup: UndoToken, to token: UndoToken) -> Bool {
        guard let id = Self.id(token), var state = states[id], state.applied, state.cleanup == nil else { return false }
        state.cleanup = cleanup
        states[id] = state
        return true
    }

    nonisolated func undo(_ token: UndoToken) async throws -> UndoToken? {
        try await reverse(token)
    }

    private func reverse(_ token: UndoToken) async throws -> UndoToken? {
        guard let id = Self.id(token), var state = states[id] else { return nil }
        do {
            if state.applied {
                if let cleanup = state.cleanup, !cleanup.changesNothing { state.cleanup = try await mail.undo(cleanup) }
                if let moved = state.moved, !moved.changesNothing { state.moved = try await mail.undo(moved) }
                if !state.rule.changesNothing { state.rule = try await rules.undo(state.rule) ?? state.rule }
                state.applied = false
            } else {
                if !state.rule.changesNothing { state.rule = try await rules.undo(state.rule) ?? state.rule }
                if let moved = state.moved, !moved.changesNothing { state.moved = try await mail.undo(moved) }
                if let cleanup = state.cleanup, !cleanup.changesNothing { state.cleanup = try await mail.undo(cleanup) }
                state.applied = true
            }
        } catch {
            states[id] = state
            throw error
        }
        states[id] = state
        return token
    }

    private static func token(_ id: UUID) -> UndoToken { UndoToken(payload: Data(id.uuidString.utf8)) }
    private static func id(_ token: UndoToken) -> UUID? { UUID(uuidString: String(decoding: token.payload, as: UTF8.self)) }
}
