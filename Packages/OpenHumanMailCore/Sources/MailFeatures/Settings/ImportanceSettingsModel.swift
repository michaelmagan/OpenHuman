import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class ImportanceSettingsModel {
    nonisolated public static let pageID = "importance"

    public struct Draft: Hashable, Sendable {
        public var id: String?
        public var match: ImportanceRuleMatch
        public var effect: ImportanceRuleEffect
        public var value: String

        public init(id: String? = nil, match: ImportanceRuleMatch = .sender, effect: ImportanceRuleEffect = .important,
                    value: String = "") {
            self.id = id
            self.match = match
            self.effect = effect
            self.value = value
        }
    }

    public struct RuleRow: Identifiable, Hashable, Sendable {
        public var id: String { rule.id }
        public let rule: ImportanceRuleInfo
        public let title: String
        public let detail: String?
        public let isEditable: Bool
    }

    public struct RuleGroup: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let footnote: String?
        public let rows: [RuleRow]
    }

    public struct LastChange: Hashable, Sendable {
        public let title: String
        let entryID: UUID?
        let token: UndoToken?
    }

    public private(set) var accounts: [Account] = []
    public var account: AccountID? {
        didSet { if account != oldValue { accountChanged() } }
    }
    public private(set) var rules: [ImportanceRuleInfo] = []
    public private(set) var groups: [RuleGroup] = []
    public private(set) var hasLoaded = false
    public var draft: Draft?
    public private(set) var errorMessage: String?
    public private(set) var lastChange: LastChange?
    public private(set) var isWorking = false
    public let availability: SettingsAvailability
    public let sendsToGmail: StoredSetting<Bool>

    nonisolated public static let editableMatches: [ImportanceRuleMatch] = [.sender, .domain, .label, .keyword]

    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private let port: (any ImportanceRulesPort)?
    @ObservationIgnored private let undo: UndoCoordinator?
    @ObservationIgnored private var splitNames: [SplitKey: String] = [:]
    @ObservationIgnored private var threadSubjects: [String: String] = [:]
    @ObservationIgnored private var subjectLookups: Set<String> = []
    @ObservationIgnored private var accountsTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let askDomainWide: DomainWideRuleAsking

    public init(data: any MailDataSource, port: (any ImportanceRulesPort)?, undo: UndoCoordinator?,
                availability: SettingsAvailability, settings: (any SettingsPort)? = nil,
                askDomainWide: @escaping DomainWideRuleAsking = { _ in .cancel }) {
        self.data = data
        self.port = port
        self.undo = undo
        self.availability = availability
        self.askDomainWide = askDomainWide
        sendsToGmail = StoredSetting(AppSettings.importanceSendsToGmail, port: settings)
    }

    public convenience init(environment: AppEnvironment) {
        self.init(data: environment.data, port: environment.importance, undo: environment.undo,
                  availability: SettingsAvailability(environment: environment), settings: environment.settings,
                  askDomainWide: environment.domainWideRuleAsking)
    }

    isolated deinit {
        accountsTask?.cancel()
        for task in tasks { task.cancel() }
    }

    public func start() {
        guard accountsTask == nil else { return }
        sendsToGmail.start()
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
    }

    private func accountChanged() {
        for task in tasks { task.cancel() }
        tasks = []
        rules = []
        groups = []
        splitNames = [:]
        threadSubjects = [:]
        subjectLookups = []
        hasLoaded = false
        draft = nil
        errorMessage = nil
        guard let account else { return }
        let data = self.data
        if let port {
            tasks.append(Task { [weak self] in
                do {
                    for try await list in port.rules(account) {
                        guard !Task.isCancelled, let self else { return }
                        self.rules = list
                        self.hasLoaded = true
                        self.rebuild()
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.errorMessage = "The rules couldn't be read."
                }
            })
        }
        tasks.append(Task { [weak self] in
            do {
                for try await list in data.splits(account) {
                    guard !Task.isCancelled, let self else { return }
                    self.splitNames = Dictionary(list.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
                    self.rebuild()
                }
            } catch {}
        })
    }

    private func rebuild() {
        groups = Self.groups(rules, splitNames: splitNames, threadSubjects: threadSubjects)
        lookUpThreadSubjects()
    }

    private func lookUpThreadSubjects() {
        guard let account else { return }
        let wanted = rules.filter { $0.match == .thread && threadSubjects[$0.value] == nil && !subjectLookups.contains($0.value) }
            .map(\.value)
        guard !wanted.isEmpty else { return }
        subjectLookups.formUnion(wanted)
        let data = self.data
        tasks.append(Task { [weak self] in
            var found: [String: String] = [:]
            for id in wanted {
                if let row = try? await data.localThread(account, gmailThreadID: GmailThreadID(id)) { found[id] = row.subject }
            }
            guard !Task.isCancelled, let self, !found.isEmpty, self.account == account else { return }
            self.threadSubjects.merge(found) { _, new in new }
            self.groups = Self.groups(self.rules, splitNames: self.splitNames, threadSubjects: self.threadSubjects)
        })
    }

    public var canEdit: Bool { port != nil }

    public var editNote: String? { port == nil ? "Importance rules aren't available with this mail source." : nil }

    public func beginAdd(_ match: ImportanceRuleMatch = .sender) {
        guard canEdit else { return }
        draft = Draft(match: Self.editableMatches.contains(match) ? match : .sender)
        errorMessage = nil
    }

    public func beginEdit(_ row: RuleRow) {
        guard canEdit, row.isEditable else { return }
        draft = Draft(id: row.id, match: row.rule.match, effect: row.rule.effect, value: row.rule.value)
        errorMessage = nil
    }

    public func cancelEdit() {
        draft = nil
        errorMessage = nil
    }

    public var canSave: Bool {
        guard canEdit, !isWorking, let draft else { return false }
        return !draft.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var draftCheck: (text: String, isProblem: Bool)? {
        guard let draft, !draft.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let value = Self.normalized(draft.value, for: draft.match) else { return (Self.problem(for: draft.match), true) }
        return (Self.importanceTitle(match: draft.match, effect: draft.effect, value: value), false)
    }

    public func save() async {
        guard canSave, let account, let draft, let port else { return }
        guard let value = Self.normalized(draft.value, for: draft.match) else {
            errorMessage = Self.problem(for: draft.match)
            return
        }
        let effect: ImportanceRuleEffect = draft.effect == .neverImportant ? .neverImportant : .important
        let change = ImportanceChange(kind: ImportanceRuleKind.kind(match: draft.match, effect: effect), account: account,
                                      value: value, effect: effect)
        let words = Self.importanceTitle(match: draft.match, effect: effect, value: change.value)
        if let id = draft.id {
            if let current = rules.first(where: { $0.id == id }), current.match == draft.match, current.effect == effect,
               current.value == change.value, current.origin == .user {
                self.draft = nil
                return
            }
            guard await allowsDomainWide(change) else { return }
            if await perform("Changed rule: \(words)", { try await port.update(id, to: change) }) { self.draft = nil }
        } else {
            if rules.contains(where: { $0.match == draft.match && $0.effect == effect && $0.value == change.value }) {
                errorMessage = "That rule is already in the list."
                return
            }
            guard await allowsDomainWide(change) else { return }
            if await perform("Added rule: \(words)", { try await port.apply(change) }) { self.draft = nil }
        }
    }

    private func allowsDomainWide(_ change: ImportanceChange) async -> Bool {
        guard let effect = ImportanceActionHandler.domainWideEffect(change.kind) else { return true }
        return await DomainWideRules.allowsEntireDomain(change.value, effect: effect, ask: askDomainWide)
    }

    public func delete(_ row: RuleRow) async {
        guard canEdit, !isWorking, let port else { return }
        if draft?.id == row.id { draft = nil }
        _ = await perform("Deleted rule: \(row.title)") { try await port.delete([row.id]) }
    }

    public var canUndoLastChange: Bool {
        guard canEdit, !isWorking, let change = lastChange else { return false }
        if let entryID = change.entryID { return undo?.stack.contains { $0.id == entryID } ?? false }
        return change.token != nil
    }

    public func undoLastChange() async {
        guard canUndoLastChange, let change = lastChange else { return }
        errorMessage = nil
        if let entryID = change.entryID, let undo {
            await undo.undo(entryID: entryID)
            if undo.stack.contains(where: { $0.id == entryID }) {
                errorMessage = "That change couldn't be undone. Try again."
                return
            }
        } else if let token = change.token, let port {
            isWorking = true
            defer { isWorking = false }
            do {
                if try await port.undo(token) == nil { errorMessage = "Nothing to undo: the rules changed since." }
            } catch {
                errorMessage = Self.message(error)
                return
            }
        }
        lastChange = nil
    }

    private func perform(_ title: String, _ change: () async throws -> UndoToken) async -> Bool {
        guard let port else { return false }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            if let undo {
                let entry = try await undo.perform("\(title)", via: port, change)
                lastChange = LastChange(title: title, entryID: entry.id, token: nil)
            } else {
                let token = try await change()
                lastChange = LastChange(title: title, entryID: nil, token: token)
            }
            return true
        } catch {
            errorMessage = Self.message(error)
        }
        return false
    }

    static func message(_ error: Error) -> String {
        (error as? MailPortError)?.description ?? "That change couldn't be saved."
    }

    nonisolated public static let precedenceNote = "Importance is decided before splits and categories. When rules "
        + "disagree, the more specific one wins: a sender rule beats a rule for one conversation (Move to Important or "
        + "Other), which beats a domain rule, which beats a Gmail label rule, which beats a keyword rule. At the same "
        + "level, never beats always. Your rules beat AI suggestions at every level."

    nonisolated public static let exemptionsNote = "These only change which split a sender's mail goes to, never whether "
        + "it is important."

    nonisolated public static let sendsToGmailTitle = "Tell Gmail when I move mail"
    nonisolated public static let sendsToGmailDetail = "Move to Important, Move to Other, Mark important and Not important "
        + "also set or clear Gmail's Important mark on that conversation's messages. Undo puts both back. Off: only this "
        + "Mac changes."

    nonisolated public static var emptyText: String {
        func key(_ id: ActionID) -> String {
            guard let hint = ActionCatalog.descriptor(id)?.shortcutHint else { return "" }
            return " (\(hint))"
        }
        return "No rules yet. Add one here, or on a conversation choose Always important from this sender"
            + key(.alwaysImportantSender) + " or Never important from this domain" + key(.neverImportantDomain)
            + " in ⌘K."
    }

    nonisolated public static func matchTitle(_ match: ImportanceRuleMatch) -> String {
        switch match {
        case .sender: "Sender"
        case .thread: "Conversation"
        case .domain: "Domain"
        case .label: "Gmail label"
        case .keyword: "Keyword"
        case .matcher: "Add-on"
        }
    }

    nonisolated public static func prompt(for match: ImportanceRuleMatch) -> String {
        switch match {
        case .sender: "name@example.com"
        case .thread: ""
        case .domain: "example.com"
        case .label: "The label's name, for example Clients"
        case .keyword: "A word or phrase in the subject or body"
        case .matcher: ""
        }
    }

    nonisolated public static func problem(for match: ImportanceRuleMatch) -> String {
        switch match {
        case .sender: "Enter an address like name@example.com."
        case .thread: "Rules for one conversation are made on it: Move to Important or Move to Other."
        case .domain: "Enter a domain like example.com."
        case .label: "Enter the Gmail label's name (up to 500 characters)."
        case .keyword: "Enter a word or phrase (up to 200 characters)."
        case .matcher: "Rules from add-ons can't be written here."
        }
    }

    nonisolated static func groupTitle(_ match: ImportanceRuleMatch) -> String {
        switch match {
        case .sender: "Senders"
        case .thread: "Conversations"
        case .domain: "Domains"
        case .label: "Gmail labels"
        case .keyword: "Keywords"
        case .matcher: "Rules from add-ons"
        }
    }

    nonisolated public static func normalized(_ raw: String, for match: ImportanceRuleMatch) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch match {
        case .sender:
            var address = trimmed
            if let open = address.lastIndex(of: "<"), let close = address[open...].firstIndex(of: ">") {
                address = String(address[address.index(after: open)..<close])
            }
            if address.lowercased().hasPrefix("mailto:") { address = String(address.dropFirst("mailto:".count)) }
            address = address.trimmingCharacters(in: .whitespaces).lowercased()
            guard let at = address.lastIndex(of: "@"), at != address.startIndex, address.index(after: at) != address.endIndex,
                  !address.contains(where: \.isWhitespace) else { return nil }
            return address
        case .domain:
            var domain = trimmed.lowercased()
            if domain.hasPrefix("@") { domain.removeFirst() }
            while domain.hasSuffix(".") { domain.removeLast() }
            guard domain.contains("."), !domain.contains("@"), !domain.hasPrefix("."), !domain.contains(".."),
                  !domain.contains(where: \.isWhitespace) else { return nil }
            return domain
        case .keyword:
            let words = trimmed.precomposedStringWithCanonicalMapping
                .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            return words.isEmpty || words.count > 200 ? nil : words
        case .label:
            return trimmed.isEmpty || trimmed.count > 500 ? nil : trimmed
        case .matcher, .thread:
            return nil
        }
    }

    nonisolated public static func importanceTitle(match: ImportanceRuleMatch, effect: ImportanceRuleEffect,
                                                   value: String) -> String {
        let verb = effect == .neverImportant ? "Never important" : "Always important"
        switch match {
        case .sender, .domain: return "\(verb) from \(value)"
        case .label: return "\(verb) with the label \(value)"
        case .keyword: return "\(verb) when it mentions \u{201C}\(value)\u{201D}"
        case .matcher:
            if let category = AutoLabelRule.category(inValue: value) {
                return effect == .important ? "Auto label \(category) is important" : "Auto label \(category) goes to Other"
            }
            return "\(verb) by the \(value) rule"
        case .thread:
            return effect == .neverImportant ? "Moved to Other: \(value)" : "Moved to Important: \(value)"
        }
    }

    nonisolated static func conversationName(_ threadID: String, subjects: [String: String]) -> String {
        guard let subject = subjects[threadID] else { return "a conversation not on this Mac" }
        return subject.isEmpty ? "(no subject)" : subject
    }

    nonisolated public static func title(_ rule: ImportanceRuleInfo, splitName: String? = nil,
                                         threadSubjects: [String: String] = [:]) -> String {
        guard rule.effect == .exemptFromSplit else {
            let value = rule.match == .thread ? conversationName(rule.value, subjects: threadSubjects) : rule.value
            return importanceTitle(match: rule.match, effect: rule.effect, value: value)
        }
        if rule.kind == .notPitch { return "Not a pitch: \(rule.value)" }
        if let splitName { return "Not in \(splitName): \(rule.value)" }
        return rule.split == nil ? "Not in any split: \(rule.value)" : "Not in a split: \(rule.value)"
    }

    nonisolated public static func groups(_ rules: [ImportanceRuleInfo], splitNames: [SplitKey: String] = [:],
                                          threadSubjects: [String: String] = [:]) -> [RuleGroup] {
        let deciding = rules.filter { $0.effect != .exemptFromSplit }
        var out: [RuleGroup] = []
        for match in ImportanceRuleMatch.allCases {
            let rows = deciding.filter { $0.match == match }.map {
                Self.row($0, among: deciding, splitNames: splitNames, threadSubjects: threadSubjects)
            }
            guard !rows.isEmpty else { continue }
            out.append(RuleGroup(id: match.rawValue, title: Self.groupTitle(match), footnote: nil, rows: rows))
        }
        let exemptions = rules.filter { $0.effect == .exemptFromSplit }
            .map { Self.row($0, among: deciding, splitNames: splitNames) }
        if !exemptions.isEmpty {
            out.append(RuleGroup(id: "exemptions", title: "Kept out of splits", footnote: exemptionsNote, rows: exemptions))
        }
        return out
    }

    nonisolated static func row(_ rule: ImportanceRuleInfo, among deciding: [ImportanceRuleInfo],
                                splitNames: [SplitKey: String], threadSubjects: [String: String] = [:]) -> RuleRow {
        var notes: [String] = []
        if rule.match == .thread { notes.append("This conversation only") }
        if rule.effect != .exemptFromSplit, let note = exceptionNote(rule, among: deciding) { notes.append(note) }
        if rule.appliesToEveryAccount { notes.append("All accounts") }
        if rule.origin == .ai { notes.append("Suggested by AI") }
        let editable = rule.effect != .exemptFromSplit && editableMatches.contains(rule.match)
        return RuleRow(rule: rule, title: title(rule, splitName: rule.split.flatMap { splitNames[$0] },
                                                threadSubjects: threadSubjects),
                       detail: notes.isEmpty ? nil : notes.joined(separator: " · "), isEditable: editable)
    }

    nonisolated static func exceptionNote(_ rule: ImportanceRuleInfo, among deciding: [ImportanceRuleInfo]) -> String? {
        switch rule.match {
        case .sender:
            let domains = deciding.filter {
                $0.match == .domain && $0.effect != rule.effect && Self.isInDomain(rule.value, $0.value)
            }
            guard let domain = domains.max(by: { $0.value.count < $1.value.count }) else { return nil }
            return "Exception to the rule for \(domain.value)"
        case .domain:
            let senders = deciding.filter {
                $0.match == .sender && $0.effect != rule.effect && Self.isInDomain($0.value, rule.value)
            }
            switch senders.count {
            case 0: return nil
            case 1: return "\(senders[0].value) is an exception"
            default: return "\(senders.count) senders are exceptions"
            }
        case .thread, .label, .keyword, .matcher:
            return nil
        }
    }

    nonisolated static func isInDomain(_ address: String, _ domain: String) -> Bool {
        guard let at = address.lastIndex(of: "@") else { return false }
        let host = String(address[address.index(after: at)...])
        return host == domain || host.hasSuffix("." + domain)
    }
}
