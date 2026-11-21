import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class ArchiveSuggestionModel {
    public enum Kind: Sendable, Hashable {
        case promotions
        case oldConversations
    }

    public struct Suggestion: Sendable, Hashable {
        public let account: AccountID
        public let threads: [ThreadKey]
        public let kind: Kind
        public let ageDays: Int
        public let inboxCount: Int

        public var count: Int { threads.count }

        public var text: String {
            let n = count.formatted()
            switch kind {
            case .promotions:
                return count == 1 ? "1 promotion is older than \(ageDays) days. Archive it?"
                                  : "\(n) promotions are older than \(ageDays) days. Archive them?"
            case .oldConversations:
                return "Your inbox holds \(inboxCount.formatted()) conversations; \(n) are older than \(ageDays) days "
                    + "and need nothing from you. Archive them?"
            }
        }

        public var confirmTitle: String { count == 1 ? "Archive 1" : "Archive \(count.formatted())" }
    }

    public nonisolated static let maxScanned = 10_000
    public nonisolated static let maxSenderChecks = 300
    public nonisolated static let firstCheckDelay: Duration = .seconds(20)
    public nonisolated static let checkInterval: Duration = .seconds(3_600)
    public static let footnote = "Archived mail stays in Done and search. Undo with ⌘Z, or Bulk actions for 7 days."

    public private(set) var suggestion: Suggestion?
    public private(set) var isChecking = false
    public private(set) var lastCheckFoundNothing = false

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var schedule: Task<Void, Never>?

    public init(environment: AppEnvironment, now: @escaping @Sendable () -> Date = { Date() }) {
        self.environment = environment
        self.now = now
    }

    isolated deinit {
        schedule?.cancel()
    }

    public func startSchedule() {
        guard schedule == nil, let environment, !environment.isFake else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: Self.firstCheckDelay)
            while !Task.isCancelled {
                guard let self else { return }
                await self.check(byUser: false)
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    public func checkNow() async {
        await check(byUser: true)
        if suggestion == nil {
            lastCheckFoundNothing = true
            environment?.notices.post("Nothing to clean up: no old conversations to archive.",
                                      style: .info, duration: NoticeCenter.infoDuration)
        }
    }

    func check(byUser: Bool) async {
        guard let environment, !isChecking, let settings = environment.settings,
              let account = environment.router.active?.account else { return }
        let enabled = (try? await settings.get(AppSettings.archiveSuggestionEnabled)) ?? true
        guard enabled || byUser else { return }
        let state = (try? await settings.get(AppSettings.archiveSuggestionState)) ?? ArchiveSuggestionSchedule()
        guard state.mayOffer(at: now(), byUser: byUser) else { return }
        isChecking = true
        defer { isChecking = false }
        let threshold = (try? await settings.get(AppSettings.archiveSuggestionInboxThreshold))
            ?? AppSettings.archiveSuggestionInboxThreshold.defaultValue
        let ageDays = (try? await settings.get(AppSettings.archiveSuggestionAgeDays))
            ?? AppSettings.archiveSuggestionAgeDays.defaultValue
        let raw = (try? await settings.get(AppSettings.archiveSuggestionOverrides)) ?? [:]
        let overrides = raw.compactMapValues(ArchiveSuggestionOverride.init(rawValue:))
        guard let found = await Self.find(in: account, data: environment.data, threshold: threshold, ageDays: ageDays,
                                          overrides: overrides, now: now()) else { return }
        suggestion = found
        lastCheckFoundNothing = false
        var next = state
        next.lastOfferedAt = now()
        try? await settings.set(AppSettings.archiveSuggestionState, next)
    }

    public func confirm() async {
        guard let environment, let suggestion else { return }
        self.suggestion = nil
        await BulkArchive.archive(suggestion.threads, account: suggestion.account, environment: environment, now: now())
    }

    public func notNow() async {
        suggestion = nil
        guard let settings = environment?.settings else { return }
        var state = (try? await settings.get(AppSettings.archiveSuggestionState)) ?? ArchiveSuggestionSchedule()
        state.hiddenUntil = now().addingTimeInterval(ArchiveSuggestionSchedule.snoozeInterval)
        try? await settings.set(AppSettings.archiveSuggestionState, state)
    }

    public var canEditRules: Bool { environment?.settingsNavigator.canOpen ?? false }

    public func openRules() {
        environment?.settingsNavigator.open(SettingsPageID.general.rawValue)
    }

    public func dismiss() { suggestion = nil }

    func show(_ value: Suggestion?) { suggestion = value }

    struct Candidate: Sendable {
        let key: ThreadKey
        let isOld: Bool
        let isPromotion: Bool
        var facts: ArchiveSuggestionFacts
    }

    nonisolated static func find(in account: Account, data: any MailDataSource, threshold: Int, ageDays: Int,
                                 overrides: [String: ArchiveSuggestionOverride], now: Date) async -> Suggestion? {
        let id = account.id
        guard let inbox = try? await rows(of: .system(.inbox), account: id, data: data) else { return nil }
        let cutoff = now.addingTimeInterval(-Double(max(ageDays, 1)) * 86_400)
        let promotions = Set((try? await rows(of: .search("in:inbox category:promotions"), account: id,
                                              data: data))?.map(\.id) ?? [])
        let overThreshold = inbox.count > threshold
        let hasOldPromotions = inbox.contains { promotions.contains($0.id) && $0.lastMessageAt < cutoff }
        guard overThreshold || hasOldPromotions else { return nil }
        let labels = await labelNames(account: id, data: data)
        let muted = labels.first { $0.value == OHGmailLabels.muted }?.key
        var candidates: [Candidate] = inbox.compactMap { row in
            let isOld = row.lastMessageAt < cutoff
            let isPromotion = promotions.contains(row.id)
            guard isOld, overThreshold || isPromotion else { return nil }
            return Candidate(key: row.id, isOld: isOld, isPromotion: isPromotion,
                             facts: facts(of: row, labels: labels, muted: muted, isPromotion: isPromotion))
        }
        var wrote: [String: Bool] = [:]
        for candidate in candidates {
            guard let sender = candidate.facts.sender, wrote[sender] == nil else { continue }
            if wrote.count >= maxSenderChecks { break }
            wrote[sender] = await authorWrote(to: sender, account: id, data: data)
        }
        for i in candidates.indices {
            guard let sender = candidates[i].facts.sender else { continue }
            candidates[i].facts.authorWroteToSender = wrote[sender] ?? true
        }
        let domains = Set(account.myAddresses.compactMap { ArchiveSuggestionRules.domain(of: $0) })
        let rules = ArchiveSuggestionRules(overrides: overrides, ownDomains: domains)
        let chosen = candidates.filter { rules.decide($0.facts) == .include }
        guard !chosen.isEmpty else { return nil }
        let kind: Kind = !overThreshold || chosen.allSatisfy(\.isPromotion) ? .promotions : .oldConversations
        return Suggestion(account: id, threads: chosen.map(\.key), kind: kind, ageDays: max(ageDays, 1),
                          inboxCount: inbox.count)
    }

    nonisolated static func facts(of row: ThreadRow, labels: [Int64: String], muted: Int64?,
                                  isPromotion: Bool) -> ArchiveSuggestionFacts {
        var facts = ArchiveSuggestionFacts(sender: row.participants.first { !$0.isMe }?.email)
        facts.isStarred = row.isStarred
        facts.isImportantByRule = row.isImportant
        facts.isSnoozed = row.snoozedUntil != nil
        facts.hasReminder = row.reminderAt != nil
        facts.isMuted = muted.map { row.userLabelIDs.contains($0) } ?? false
        facts.userLabels = row.userLabelIDs.filter { $0 != muted }.compactMap { labels[$0] }
        facts.categories = row.categoryLabelIDs.compactMap { labels[$0] } + (isPromotion ? ["promotions"] : [])
        return facts
    }

    nonisolated static func rows(of location: MailLocation, account: AccountID,
                                 data: any MailDataSource) async throws -> [ThreadRow] {
        var found: [ThreadRow] = []
        var cursor: PageCursor?
        repeat {
            let page = try await data.threadPage(location, account: account, after: cursor, limit: 500)
            found += page.rows
            cursor = page.next
        } while cursor != nil && found.count < maxScanned && !Task.isCancelled
        return found
    }

    nonisolated static func labelNames(account: AccountID, data: any MailDataSource) async -> [Int64: String] {
        do {
            for try await list in data.labels(account) {
                return Dictionary(list.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            }
        } catch {}
        return [:]
    }

    nonisolated static func authorWrote(to sender: String, account: AccountID, data: any MailDataSource) async -> Bool {
        let quoted = sender.replacingOccurrences(of: "\"", with: "")
        guard let page = try? await data.threadPage(.search("in:sent to:\"\(quoted)\""), account: account, after: nil,
                                                    limit: 1) else { return true }
        return !page.rows.isEmpty
    }
}
