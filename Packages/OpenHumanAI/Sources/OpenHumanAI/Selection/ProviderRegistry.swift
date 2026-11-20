import Foundation
import Synchronization

public final class ProviderRegistry: Sendable {
    private struct State {
        var providers: [any AIProvider] = []
        var classifiers: [any AIClassificationProvider] = []
    }

    private let state: Mutex<State>

    public init(providers: [any AIProvider] = [], classifiers: [any AIClassificationProvider] = []) {
        state = Mutex(State())
        for provider in providers { register(provider) }
        for classifier in classifiers { register(classifier: classifier) }
    }

    public func register(_ provider: any AIProvider) {
        state.withLock { state in
            if let index = state.providers.firstIndex(where: { $0.id == provider.id }) {
                state.providers[index] = provider
            } else {
                state.providers.append(provider)
            }
        }
    }

    public func register(classifier: any AIClassificationProvider) {
        state.withLock { state in
            if let index = state.classifiers.firstIndex(where: { $0.id == classifier.id }) {
                state.classifiers[index] = classifier
            } else {
                state.classifiers.append(classifier)
            }
        }
    }

    public func unregister(_ id: AIProviderID) {
        state.withLock { state in
            state.providers.removeAll { $0.id == id }
            state.classifiers.removeAll { $0.id == id }
        }
    }

    public var providers: [any AIProvider] { state.withLock { $0.providers } }
    public var classifiers: [any AIClassificationProvider] { state.withLock { $0.classifiers } }

    public func provider(_ id: AIProviderID) -> (any AIProvider)? {
        state.withLock { $0.providers.first { $0.id == id } }
    }

    public func classifier(_ id: AIProviderID) -> (any AIClassificationProvider)? {
        state.withLock { $0.classifiers.first { $0.id == id } }
    }

    static func defaultRank(id: AIProviderID, kind: ProviderCandidate.Kind, location: AIDataLocation) -> Int {
        if kind == .classifier { return location == .onDevice ? 0 : 9 }
        if id == .appleSystem { return 1 }
        if id.isLocalModel { return 2 }
        switch location {
        case .onDevice: return 3
        case .appleCloud: return 4
        case .thirdParty:
            if id == .agentClaude { return 5 }
            if id == .agentCodex { return 6 }
            return 7
        }
    }

    public func candidates(for feature: AIFeature, settings: AISettings) async -> [ProviderCandidate] {
        let snapshot = state.withLock { $0 }
        var entries: [(candidate: ProviderCandidate, rank: Int, position: Int)] = []
        for (position, provider) in snapshot.providers.enumerated() {
            if AIModelDefaults.writingModels.contains(provider.id), feature != .summarize, feature != .replyOptions { continue }
            let capabilities = await provider.capabilities()
            let location = capabilities.dataLocation
            let consented = location.leavesDevice
                ? settings.hasConsent(for: provider.id, fingerprint: await provider.consentFingerprint()) : true
            let candidate = ProviderCandidate(
                id: provider.id, displayName: provider.displayName, kind: .languageModel, dataLocation: location,
                availability: await provider.availability(), consented: consented,
                autoSelectable: !provider.id.isExperimental)
            entries.append((candidate, Self.defaultRank(id: provider.id, kind: .languageModel, location: location),
                            position))
        }
        if feature == .classify {
            for (offset, classifier) in snapshot.classifiers.enumerated()
            where ClassifierSelection.allows(classifier, preference: settings.classifier) {
                let location = classifier.dataLocation
                let candidate = ProviderCandidate(
                    id: classifier.id, displayName: classifier.displayName, kind: .classifier, dataLocation: location,
                    availability: await classifier.availability(),
                    consented: location.leavesDevice ? settings.hasConsent(for: classifier.id, fingerprint: nil) : true,
                    autoSelectable: !classifier.id.isExperimental)
                entries.append((candidate, Self.defaultRank(id: classifier.id, kind: .classifier, location: location),
                                snapshot.providers.count + offset))
            }
        }
        let order = Dictionary(settings.providerOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        entries.sort { a, b in
            switch (order[a.candidate.id], order[b.candidate.id]) {
            case (let x?, let y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return (a.rank, a.position) < (b.rank, b.position)
            }
        }
        return entries.map(\.candidate)
    }
}
