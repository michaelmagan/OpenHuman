import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class CleanupRulesModel {
    public struct Entry: Identifiable, Sendable, Hashable {
        public let target: String
        public let choice: ArchiveSuggestionOverride
        public var id: String { target }
        public var isDomain: Bool { target.hasPrefix("@") }
        public var title: String { isDomain ? String(target.dropFirst()) + " (whole domain)" : target }
    }

    public let overrides: StoredSetting<[String: String]>
    public private(set) var addError: String?
    @ObservationIgnored private let askDomainWide: DomainWideRuleAsking

    public init(settings: (any SettingsPort)?, askDomainWide: @escaping DomainWideRuleAsking = { _ in .cancel }) {
        overrides = StoredSetting(AppSettings.archiveSuggestionOverrides, port: settings)
        self.askDomainWide = askDomainWide
    }

    public func start() { overrides.start() }

    public var entries: [Entry] {
        overrides.value.compactMap { key, raw in
            ArchiveSuggestionOverride(rawValue: raw).map { Entry(target: key, choice: $0) }
        }
        .sorted { ($0.isDomain ? 1 : 0, $0.target) < ($1.isDomain ? 1 : 0, $1.target) }
    }

    public nonisolated static func normalizedTarget(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"), open < close {
            value = String(value[value.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        }
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0 == "," || $0 == ";" }) else { return nil }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return isDomain(value) ? "@" + value : nil
        case 2:
            guard isDomain(String(parts[1])) else { return nil }
            return parts[0].isEmpty ? value : (parts[0].count <= 64 ? value : nil)
        default: return nil
        }
    }

    private nonisolated static func isDomain(_ text: String) -> Bool {
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    @discardableResult
    public func add(_ text: String, choice: ArchiveSuggestionOverride) async -> Bool {
        guard let target = Self.normalizedTarget(text) else {
            addError = String(localized: "Enter an email address like dana@example.com or a domain like example.com.")
            return false
        }
        addError = nil
        if choice == .always, target.hasPrefix("@"),
           !(await DomainWideRules.allowsEntireDomain(String(target.dropFirst()), effect: .alwaysInCleanup,
                                                       ask: askDomainWide)) {
            return false
        }
        await set(target, choice)
        return overrides.errorMessage == nil
    }

    public func set(_ target: String, _ choice: ArchiveSuggestionOverride) async {
        await overrides.update { $0[target.lowercased()] = choice.rawValue }
    }

    public func remove(_ target: String) async {
        await overrides.update { $0.removeValue(forKey: target.lowercased()) }
    }

    public static let sectionTitle = String(localized: "Always / Never include in cleanup")
    public static let note = String(localized: "These choices beat every other cleanup rule, except that Gmail spam is never suggested. A sender’s own choice beats its domain’s. Mail never archives on its own: the suggestion still asks first.")
    public static func title(_ choice: ArchiveSuggestionOverride) -> String {
        switch choice {
        case .always: String(localized: "Always include")
        case .never: String(localized: "Never include")
        }
    }

    public var errorMessage: String? { addError ?? overrides.errorMessage }
}
