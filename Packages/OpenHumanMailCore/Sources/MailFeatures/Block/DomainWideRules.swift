import Foundation
import OpenHumanCore

public typealias DomainWideRuleAsking = @MainActor (DomainWideRuleConfirmation) async -> DomainWideRuleChoice

extension AppEnvironment {
    public var domainWideRuleAsking: DomainWideRuleAsking {
        { [weak self] question in
            guard let self else { return .cancel }
            return await self.system.platform.confirmDomainWideRule(question)
        }
    }
}

enum DomainWideRules {
    /// What to apply for a rule that would cover all of `domain`: the domain itself when it is not a common one,
    /// otherwise whatever the person picks. Nil means apply nothing.
    @MainActor
    static func resolve(domain: String, address: String?, effect: DomainWideRuleEffect,
                        ask: DomainWideRuleAsking) async -> DomainWideRuleResolution? {
        guard let question = DomainWideRuleGuard.confirmation(domain: domain, address: address, effect: effect) else {
            return .entireDomain(domain)
        }
        return DomainWideRuleGuard.resolution(of: await ask(question), for: question)
    }

    /// True when a rule for all of `domain` may go ahead; asks first for a common domain.
    @MainActor
    static func allowsEntireDomain(_ domain: String, effect: DomainWideRuleEffect, ask: DomainWideRuleAsking) async -> Bool {
        if case .entireDomain? = await resolve(domain: domain, address: nil, effect: effect, ask: ask) { return true }
        return false
    }
}
