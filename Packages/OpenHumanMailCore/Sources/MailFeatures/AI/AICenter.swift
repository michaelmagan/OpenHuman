import Foundation
import MailModel
import Observation
import OpenHumanAI
import OpenHumanCore

@MainActor @Observable
public final class AICenter {
    @ObservationIgnored public let features: any AIFeatures
    @ObservationIgnored public let registry: ProviderRegistry?
    public private(set) var settings: AISettings
    @ObservationIgnored public let activity: AIActivityLog
    @ObservationIgnored public let traces: (any AITraceStore)?
    public private(set) var providers: [AIProviderRow] = []
    @ObservationIgnored public var pasteboard: (any TextPasteboard)?
    @ObservationIgnored public var instantReplyTiming = InstantReplyTiming()
    @ObservationIgnored public let appleModel: AppleModelSupport

    @ObservationIgnored let settingsBox: AISettingsBox
    @ObservationIgnored let cache: (any AIResultCache)?
    @ObservationIgnored let makeProvider: @Sendable (AIProviderID) -> (any AIProvider)?
    @ObservationIgnored let bodyTimeout: Duration
    @ObservationIgnored weak var environment: AppEnvironment?
    @ObservationIgnored public private(set) lazy var threadLines = ThreadLineSummaries(center: self)
    @ObservationIgnored public private(set) lazy var inlineReplies = InlineReplies(center: self)
    @ObservationIgnored public private(set) lazy var preparation = AIPreparationQueue(center: self)
    @ObservationIgnored private var classifications: [ThreadKey: (newest: MessageKey, category: TriageCategory)] = [:]
    @ObservationIgnored private var summaries: [ThreadKey: ThreadSummaryModel] = [:]
    @ObservationIgnored private var replies: [ReplyKey: QuickRepliesModel] = [:]
    @ObservationIgnored private var contexts: [ReplyKey: AIThreadContext] = [:]
    @ObservationIgnored private var contextOrder: [ReplyKey] = []
    @ObservationIgnored private var unlisted: [QuickRepliesModel] = []
    private(set) var hiddenQuickReplies: Set<ThreadKey> = []
    @ObservationIgnored private var recent: [ThreadKey] = []
    @ObservationIgnored var askStorage: AskModel?
    @ObservationIgnored var styleExampleCache: [AccountID: [String]] = [:]
    static let sessionCapacity = 60

    public init(features: any AIFeatures, registry: ProviderRegistry? = nil, settings: AISettingsBox,
                cache: (any AIResultCache)? = nil, activity: AIActivityLog = AIActivityLog(),
                traces: (any AITraceStore)? = nil,
                makeProvider: @escaping @Sendable (AIProviderID) -> (any AIProvider)? = { _ in nil },
                bodyTimeout: Duration = .seconds(20), appleModel: AppleModelSupport = .current) {
        self.features = features
        self.registry = registry
        self.settingsBox = settings
        self.settings = settings.current
        self.cache = cache
        self.activity = activity
        self.traces = traces
        self.makeProvider = makeProvider
        self.bodyTimeout = bodyTimeout
        self.appleModel = appleModel
    }

    public static func make(registry: ProviderRegistry, settings: AISettingsBox,
                            cache: any AIResultCache = InMemoryAIResultCache(), activity: AIActivityLog = AIActivityLog(),
                            traces: (any AITraceStore)? = nil,
                            makeProvider: @escaping @Sendable (AIProviderID) -> (any AIProvider)? = { _ in nil },
                            appleModel: AppleModelSupport = .current)
        -> AICenter
    {
        let sink = traces.map { store in StoreTraceSink(store: store, settings: { settings.current.traces }) }
        let features = DefaultAIFeatures(registry: registry, settings: { settings.current }, cache: cache,
                                         activity: activity, traces: sink)
        return AICenter(features: features, registry: registry, settings: settings, cache: cache, activity: activity,
                        traces: traces, makeProvider: makeProvider, appleModel: appleModel)
    }

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    public func update(_ change: (inout AISettings) -> Void) throws {
        let before = settings
        settings = try settingsBox.update(change)
        if before.prepareInAdvance != settings.prepareInAdvance || before.enabled != settings.enabled
            || before.draftReplies != settings.draftReplies || before.autoDraftReplies != settings.autoDraftReplies {
            preparation.settingsChanged()
        }
    }

    public nonisolated static func policyKey(email: String) -> String {
        "account." + Digest.sha256Hex(email.lowercased()).prefix(20)
    }

    public func policyKey(_ account: AccountID) -> String? {
        self.account(account).map { Self.policyKey(email: $0.email) }
    }

    public func isOnDeviceOnly(_ account: Account) -> Bool {
        settings.onDeviceOnlyAccounts.contains(Self.policyKey(email: account.email))
    }

    public func setOnDeviceOnly(_ on: Bool, account: Account) throws {
        let key = Self.policyKey(email: account.email)
        try update { settings in
            if on { settings.onDeviceOnlyAccounts.insert(key) } else { settings.onDeviceOnlyAccounts.remove(key) }
        }
        guard on else { return }
        for model in allReplies where model.thread.account == account.id && model.badge?.leavesMac == true {
            model.reset()
        }
    }

    public func setOnDeviceOnly(_ on: Bool, accountID: AccountID) throws {
        guard let account = account(accountID) else { return }
        try setOnDeviceOnly(on, account: account)
    }

    public func allowsWritingTools(for account: Account) -> Bool {
        settings.allowsWritingTools(accountKey: Self.policyKey(email: account.email))
    }

    public func clearCache() async {
        await cache?.removeAll()
        for model in summaries.values { model.reset() }
        for model in allReplies { model.reset() }
        contexts = [:]
        contextOrder = []
        hiddenQuickReplies = []
        styleExampleCache = [:]
        threadLines.reset()
        classifications = [:]
        inlineReplies.reset()
    }

    public func forgetTraces(for account: AccountID) async {
        guard let traces, let key = policyKey(account) else { return }
        try? await traces.forget(accountKey: key)
    }

    // Why: at sign-out the account may already be gone from the router, so the key comes from the email
    public func forgetTraces(email: String) async {
        guard let traces else { return }
        try? await traces.forget(accountKey: Self.policyKey(email: email))
    }

    @ObservationIgnored public private(set) var rewriteFeedback: (up: Int, down: Int) = (0, 0)
    @ObservationIgnored private(set) var pendingRating: Task<Void, Never>?

    func recordRewriteFeedback(up: Bool, undo: Bool, traceID: UUID? = nil) {
        if let traces, let traceID {
            let rating: Int? = undo ? nil : (up ? 1 : -1)
            pendingRating = Task { try? await traces.setRating(traceID, rating: rating) }
        }
        let step = undo ? -1 : 1
        if up { rewriteFeedback.up = max(0, rewriteFeedback.up + step) } else {
            rewriteFeedback.down = max(0, rewriteFeedback.down + step)
        }
        Self.logger.info("rewrite feedback \(up ? "up" : "down")\(undo ? " undone" : "")")
    }

    private nonisolated static let logger = Log(.ai)

    func classification(of thread: ThreadKey, newest: MessageKey) -> TriageCategory? {
        guard let known = classifications[thread], known.newest == newest else { return nil }
        return known.category
    }

    func remember(_ category: TriageCategory, of thread: ThreadKey, newest: MessageKey) {
        if classifications.count >= Self.sessionCapacity * 4, classifications[thread] == nil,
           let any = classifications.keys.first {
            classifications[any] = nil
        }
        classifications[thread] = (newest, category)
    }

    public func summary(for thread: ThreadKey) -> ThreadSummaryModel {
        touch(thread)
        if let model = summaries[thread] { return model }
        let model = ThreadSummaryModel(thread: thread, center: self)
        summaries[thread] = model
        return model
    }

    public func finishedSummary(_ thread: ThreadKey) -> String? {
        guard let model = summaries[thread], model.phase == .done, !model.isSuspicious else { return nil }
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public func quickReplies(for thread: ThreadKey, replyingTo message: MessageKey? = nil) -> QuickRepliesModel {
        touch(thread)
        let key = ReplyKey(thread: thread, message: message ?? replyTarget(in: thread))
        if let model = replies[key] { return model }
        let model = QuickRepliesModel(thread: thread, target: key.message, center: self)
        replies[key] = model
        return model
    }

    func replyTarget(in thread: ThreadKey) -> MessageKey? {
        if let reader = environment?.router.active?.reader, reader.thread == thread, let target = reader.replyTarget {
            return target
        }
        return contexts[ReplyKey(thread: thread, message: nil)]?.messageKeys.last
    }

    func setQuickRepliesHidden(_ hidden: Bool, in thread: ThreadKey) {
        if hidden { hiddenQuickReplies.insert(thread) } else { hiddenQuickReplies.remove(thread) }
    }

    func context(for thread: ThreadKey, upTo target: MessageKey? = nil, trigger: AITrigger) async -> AIThreadContext? {
        let account = self.account(thread.account)
        let key = account.map { Self.policyKey(email: $0.email) }
        if var cached = contexts[ReplyKey(thread: thread, message: target)], let data = environment?.data {
            let detail = await AIThreadLoader.first(data.threadDetail(thread)) ?? nil
            if let detail, let window = AIThreadLoader.window(detail.messages, upTo: target),
               window.map(\.id) == cached.messageKeys, trigger == .automatic || cached.input.trigger == .user {
                cached.input.trigger = trigger
                cached.isNewest = window.last?.id == detail.messages.last?.id
                return cached
            }
        }
        guard let data = environment?.data else { return nil }
        let loader = AIThreadLoader(data: data, bodyTimeout: bodyTimeout)
        guard let loaded = await loader.load(thread, upTo: target, account: account, accountKey: key, trigger: trigger,
                                             bodies: trigger == .user ? .all : .readerDefault) else { return nil }
        store(loaded, thread: thread)
        touch(thread)
        return loaded
    }

    private func store(_ context: AIThreadContext, thread: ThreadKey) {
        guard let answered = context.messageKeys.last else { return }
        remember(context, under: ReplyKey(thread: thread, message: answered))
        guard context.isNewest else { return }
        remember(context, under: ReplyKey(thread: thread, message: nil))
        let floating = ReplyKey(thread: thread, message: nil)
        if let model = replies[floating] {
            replies[floating] = nil
            model.pin(answered)
            let pinned = ReplyKey(thread: thread, message: answered)
            if replies[pinned] == nil { replies[pinned] = model } else { unlisted.append(model) }
        }
    }

    private var allReplies: [QuickRepliesModel] { Array(replies.values) + unlisted }

    private func remember(_ context: AIThreadContext, under key: ReplyKey) {
        contexts[key] = context
        contextOrder.removeAll { $0 == key }
        contextOrder.append(key)
        while contextOrder.count > Self.sessionCapacity * 2 {
            contexts[contextOrder.removeFirst()] = nil
        }
    }

    func loadedContext(_ thread: ThreadKey, upTo target: MessageKey? = nil) -> AIThreadContext? {
        contexts[ReplyKey(thread: thread, message: target)]
    }


    func exclusion(for thread: ThreadKey, context: AIThreadContext) -> QuickReplyExclusion? {
        QuickReplyExclusion.reason(windowFacts(for: thread, context: context))
    }

    func windowFacts(for thread: ThreadKey, context: AIThreadContext, row given: ThreadRow? = nil)
        -> QuickReplyExclusion.Facts
    {
        var facts = context.facts
        if let active = environment?.router.active, active.id == thread.account,
           let row = active.list?.row(for: thread) ?? given {
            let labels = Dictionary(active.labels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            facts.categories = row.categoryLabelIDs.compactMap { labels[$0] }.filter { $0.kind == .category }.map(\.labelID)
            if active.list?.row(for: thread) != nil {
                switch active.location {
                case .system(.spam)?, .system(.trash)?: facts.inSpamOrTrash = true
                case .system(.inbox)?, .split?, .splitOther?: facts.inInbox = true
                default: break
                }
            } else {
                facts.inInbox = true
            }
        }
        return facts
    }

    func needsReplyFacts(for thread: ThreadKey, context: AIThreadContext, row: ThreadRow? = nil) -> NeedsReply.Facts {
        NeedsReply.Facts(lastIsFromMe: context.lastIsFromMe, sender: context.newestFrom,
                         exclusion: windowFacts(for: thread, context: context, row: row),
                         triage: context.messageKeys.last.flatMap { classification(of: thread, newest: $0) })
    }

    public var showsInlineReplies: Bool {
        settings.enabled && settings.writesRepliesAutomatically
    }

    func account(_ id: AccountID) -> Account? {
        environment?.router.accounts.first { $0.id == id }?.account
    }

    func userName(_ id: AccountID) -> String {
        guard let account = account(id) else { return String(localized: "the user") }
        if let name = account.displayName, !name.isEmpty { return name }
        return String(account.email.split(separator: "@").first ?? "")
    }

    private func touch(_ thread: ThreadKey) {
        recent.removeAll { $0 == thread }
        recent.append(thread)
        while recent.count > Self.sessionCapacity {
            let old = recent.removeFirst()
            summaries[old]?.cancel()
            summaries[old] = nil
            for model in allQuickReplies(in: old) { model.cancel() }
            for key in Array(replies.keys) where key.thread == old { replies[key] = nil }
            unlisted.removeAll { $0.thread == old }
            for key in Array(contexts.keys) where key.thread == old { contexts[key] = nil }
            contextOrder.removeAll { $0.thread == old }
        }
    }

    func allQuickReplies(in thread: ThreadKey) -> [QuickRepliesModel] {
        allReplies.filter { $0.thread == thread }
    }

    @discardableResult
    public func togglePanel(_ session: ComposeSession, showQuickReplies: Bool = false) -> AIComposerModel? {
        if let open = session.aiPanel {
            if showQuickReplies, open.quickReplies != nil { return open }
            open.close()
            return nil
        }
        let model = AIComposerModel(session: session, center: self, preferQuickReplies: showQuickReplies)
        session.aiPanel = model
        return model
    }

    func copyInstead(_ text: String, session: ComposeSession?, reason: String) {
        pasteboard?.copy(text)
        let note = pasteboard == nil ? reason : reason + " " + String(localized: "The text is on the clipboard.")
        if let session {
            session.notice = ComposeSession.Notice(.info, note)
        } else {
            environment?.notices.post(note, style: .info, duration: NoticeCenter.infoDuration)
        }
    }

    public func onDeviceStatus() async -> (available: Bool, hint: String?) {
        let noModel = appleModel.unavailableReason.map { AIWording.reason($0) }
            ?? String(localized: "No on-device model is set up")
        guard let registry else { return (false, noModel) }
        var firstReason: String?
        for provider in registry.providers {
            guard await provider.capabilities().dataLocation == .onDevice else { continue }
            switch await provider.availability() {
            case .available:
                return (true, nil)
            case .unavailable(let reason):
                if firstReason == nil { firstReason = AIWording.reason(reason, providerName: provider.displayName) }
            }
        }
        return (false, firstReason ?? noModel)
    }

    public func summarizeOnDevice(_ thread: ThreadKey) async throws -> String? {
        let key = policyKey(thread.account)
        let status = await features.status(for: .summarize, accountKey: key)
        guard status.availability.isAvailable, status.dataLocation == .onDevice else { return nil }
        guard let context = await context(for: thread, trigger: .user) else { return nil }
        var text = ""
        for try await event in features.summarize(context.input) {
            switch event {
            case .started(let provenance):
                guard provenance.dataLocation == .onDevice else { return nil }
            case .textDelta(let delta):
                text += delta
            case .completed:
                break
            }
        }
        return text
    }

    public func refreshProviders() async {
        guard let registry else {
            providers = []
            return
        }
        let settings = self.settings
        var rows: [AIProviderRow] = []
        for provider in registry.providers {
            let location = await provider.capabilities().dataLocation
            let availability = await provider.availability()
            let fingerprint = location.leavesDevice ? await provider.consentFingerprint() : nil
            let consented = !location.leavesDevice || settings.hasConsent(for: provider.id, fingerprint: fingerprint)
            rows.append(AIProviderRow(id: provider.id, name: provider.displayName,
                                      badge: AIProviderBadge(providerName: provider.displayName, location: location),
                                      isReady: availability.isAvailable,
                                      status: availability.unavailableReason.map {
                                          AIWording.reason($0, providerName: provider.displayName)
                                      } ?? String(localized: "Ready"),
                                      needsConsent: location.leavesDevice, consented: consented))
        }
        providers = rows
    }

    public func consentRequest(for id: AIProviderID) async -> AIProviderConsentRequest? {
        guard let provider = registry?.provider(id) ?? makeProvider(id) else { return nil }
        let location = await provider.capabilities().dataLocation
        guard location.leavesDevice else { return nil }
        let accounts = environment?.router.accounts.map(\.account) ?? []
        return AIProviderConsentRequest(providerID: id, providerName: provider.displayName, location: location,
                                accounts: accounts.map { account in
                                    AIProviderConsentRequest.AccountChoice(id: account.id, title: account.alias ?? account.email,
                                                                   onDeviceOnly: isOnDeviceOnly(account))
                                })
    }

    public func grantConsent(_ request: AIProviderConsentRequest) async throws {
        guard let registry else { return }
        let provider: any AIProvider
        if let registered = registry.provider(request.providerID) {
            provider = registered
        } else if let made = makeProvider(request.providerID) {
            registry.register(made)
            provider = made
        } else {
            return
        }
        let fingerprint = await provider.consentFingerprint()
        let now = Date()
        try update { settings in
            settings.consents[request.providerID] = ProviderConsent(grantedAt: now, fingerprint: fingerprint)
            if request.providerID == .applePCC { settings.pccEnabled = true }
        }
        await refreshProviders()
    }

    public func revokeConsent(_ id: AIProviderID) async throws {
        try update { settings in
            settings.consents[id] = nil
            if id == .applePCC { settings.pccEnabled = false }
            if !settings.consents.keys.contains(where: \.isAgentCLI) { settings.agentCLIAutoQuickReplies = false }
            for (feature, pinned) in settings.featurePins where pinned == id { settings.featurePins[feature] = nil }
        }
        await refreshProviders()
    }
}

struct ReplyKey: Hashable {
    let thread: ThreadKey
    let message: MessageKey?
}

public struct AIProviderRow: Identifiable, Hashable, Sendable {
    public let id: AIProviderID
    public let name: String
    public let badge: AIProviderBadge
    public let isReady: Bool
    public let status: String
    public let needsConsent: Bool
    public let consented: Bool
}
