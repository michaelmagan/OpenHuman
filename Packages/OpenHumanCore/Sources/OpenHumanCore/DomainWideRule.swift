import Foundation

public enum DomainWideRuleEffect: Sendable, Hashable {
    case block
    case alwaysImportant
    case neverImportant
    case autoLabel(String)
    case alwaysInCleanup
}

public enum DomainWideRuleChoice: String, Sendable, Hashable, CaseIterable {
    case thisAddressOnly
    case entireDomain
    case cancel
}

public enum DomainWideRuleResolution: Sendable, Hashable {
    case entireDomain(String)
    case thisAddressOnly(String)
}

/// The question to ask before a rule covers a whole common domain. `choices` are in display order and the first is
/// the default: narrowing to the one address when there is one, otherwise Cancel.
public struct DomainWideRuleConfirmation: Sendable, Hashable {
    public let domain: String
    public let address: String?
    public let effect: DomainWideRuleEffect
    public let kind: CommonMailDomains.Kind

    public var choices: [DomainWideRuleChoice] {
        address == nil ? [.cancel, .entireDomain] : [.thisAddressOnly, .entireDomain, .cancel]
    }

    public var defaultChoice: DomainWideRuleChoice { choices[0] }

    public var title: String {
        switch effect {
        case .block: "Block everyone at \(domain)?"
        case .alwaysImportant: "Make all mail from \(domain) important?"
        case .neverImportant: "Make all mail from \(domain) not important?"
        case .autoLabel(let label): "Label all mail from \(domain) as \(label)?"
        case .alwaysInCleanup: "Always include all of \(domain) in cleanup?"
        }
    }

    public var message: String {
        let reach = switch kind {
        case .mailboxProvider: "\(domain) is a shared email provider, so this covers everyone with an address there"
        case .sharedSender: "\(domain) sends mail for many unrelated people and companies, so this covers all of them"
        }
        let only = address.map { ", not just \($0)." } ?? "."
        let result = switch effect {
        case .block: "New mail from any of them will skip the Inbox."
        case .alwaysImportant: "Mail from any of them will go to Important."
        case .neverImportant: "Mail from any of them will go to Other."
        case .autoLabel(let label): "Mail from any of them will be labelled \(label)."
        case .alwaysInCleanup: "Cleanup will suggest archiving mail from any of them."
        }
        return reach + only + " " + result
    }

    public func buttonTitle(_ choice: DomainWideRuleChoice) -> String {
        let blocks = effect == .block
        switch choice {
        case .thisAddressOnly: return blocks ? "Block This Address Only" : "Apply to This Address Only"
        case .entireDomain:
            if blocks { return "Block Entire Domain" }
            return effect == .alwaysInCleanup ? "Include Entire Domain" : "Apply to Entire Domain"
        case .cancel: return "Cancel"
        }
    }
}

public enum DomainWideRuleError: Error, Sendable, Hashable, LocalizedError {
    case needsConfirmation(domain: String)

    public var errorDescription: String? {
        switch self {
        case .needsConfirmation(let domain):
            "\(domain) is a common email domain shared by many unrelated senders. "
                + "Confirm that the rule should cover the whole domain, or use a single address."
        }
    }
}

public enum DomainWideRuleGuard {
    /// The question to ask before `effect` applies to all of `domain`, or nil when the domain is not a common one and
    /// the rule can go ahead. `address` is the narrower alternative, if there is one.
    public static func confirmation(domain: String, address: String?,
                                    effect: DomainWideRuleEffect) -> DomainWideRuleConfirmation? {
        guard let kind = CommonMailDomains.kind(of: domain) else { return nil }
        let shown = CommonMailDomains.normalizedHost(domain) ?? domain
        let narrower = address.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.contains("@") ? $0 : nil }
        return DomainWideRuleConfirmation(domain: shown, address: narrower, effect: effect, kind: kind)
    }

    /// What to apply once the person has answered; nil means apply nothing.
    public static func resolution(of choice: DomainWideRuleChoice,
                                  for confirmation: DomainWideRuleConfirmation) -> DomainWideRuleResolution? {
        switch choice {
        case .entireDomain: return .entireDomain(confirmation.domain)
        case .thisAddressOnly: return confirmation.address.map { .thisAddressOnly($0) }
        case .cancel: return nil
        }
    }

    /// For callers that cannot ask: throws unless the domain is not a common one or `confirmed` says the caller
    /// explicitly chose the whole domain.
    public static func requireConfirmation(domain: String, confirmed: Bool) throws {
        guard !confirmed, CommonMailDomains.isCommonMailDomain(domain) else { return }
        throw DomainWideRuleError.needsConfirmation(domain: CommonMailDomains.normalizedHost(domain) ?? domain)
    }
}
