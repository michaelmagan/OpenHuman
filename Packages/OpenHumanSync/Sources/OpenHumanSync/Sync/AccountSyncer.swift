import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanMIME
import OpenHumanStore

public typealias SyncStore = SyncWriting & MailReading & AccountStoring

public struct SyncSettings: Sendable {
    public var inboxThreads: Int = 50
    public var prefetchFullBodies: Int = 10
    public var bodyHorizon: Duration = .seconds(90 * 86_400)
    public var historyPageSize: Int = 500
    public var labelsRefreshEveryCycles: Int = 10
    public var resyncReconcileLimit: Int = 500
    public var inboxBackfillLimit: Int = 5_000
    public var inboxPageSize: Int = 500
    public var recentViewThreads: Int = 100
    public var recentViewLabels: [String] = ["STARRED", "SENT", "IMPORTANT"]
    public var mailPageSize: Int = 500
    public var fetchChunk: Int = 50
    public var bodyChunk: Int = 25
    public var metadataHorizon: Duration? = nil
    public var backfillUnitsPerMinute: Int = 3_000
    public var rateLimitPause: Duration = .seconds(60)
    public var bodyDownload = BodyDownloadPolicy()
    public var inviteChecksPerRun: Int = 20

    public init(inboxThreads: Int = 50, prefetchFullBodies: Int = 10, bodyHorizon: Duration = .seconds(90 * 86_400),
                historyPageSize: Int = 500, labelsRefreshEveryCycles: Int = 10, resyncReconcileLimit: Int = 500,
                inboxBackfillLimit: Int = 5_000, inboxPageSize: Int = 500, recentViewThreads: Int = 100,
                recentViewLabels: [String] = ["STARRED", "SENT", "IMPORTANT"], mailPageSize: Int = 500,
                fetchChunk: Int = 50, bodyChunk: Int = 25, metadataHorizon: Duration? = nil,
                backfillUnitsPerMinute: Int = 3_000, rateLimitPause: Duration = .seconds(60),
                bodyDownload: BodyDownloadPolicy = BodyDownloadPolicy(), inviteChecksPerRun: Int = 20) {
        self.inboxThreads = inboxThreads
        self.prefetchFullBodies = prefetchFullBodies
        self.bodyHorizon = bodyHorizon
        self.historyPageSize = historyPageSize
        self.labelsRefreshEveryCycles = labelsRefreshEveryCycles
        self.resyncReconcileLimit = resyncReconcileLimit
        self.inboxBackfillLimit = inboxBackfillLimit
        self.inboxPageSize = inboxPageSize
        self.recentViewThreads = recentViewThreads
        self.recentViewLabels = recentViewLabels
        self.mailPageSize = mailPageSize
        self.fetchChunk = fetchChunk
        self.bodyChunk = bodyChunk
        self.metadataHorizon = metadataHorizon
        self.backfillUnitsPerMinute = backfillUnitsPerMinute
        self.rateLimitPause = rateLimitPause
        self.bodyDownload = bodyDownload
        self.inviteChecksPerRun = inviteChecksPerRun
    }
}

public actor AccountSyncer {
    public nonisolated let account: AccountID
    let store: any SyncStore
    let api: any GmailAPI
    let clock: any OHClock
    let settings: SyncSettings
    let metrics: SyncMetricsCollector?
    let log = Log(.sync)
    let broadcaster = ProgressBroadcaster()

    var current: Task<SyncReport, Error>?
    private var rerunRequested = false
    private var incrementalCycles = 0
    var bodyCountQueries = 0
    public private(set) var runCount = 0

    var backfillTask: Task<BackfillOutcome, Never>?
    var backfillTaskID: UInt64 = 0
    var backfillFinished = false
    var backfillPaused = false
    var backfillWaitsForRun = false
    var pacer: BackfillPacer
    let gate: BackfillGate?
    let bodyPolicy: @Sendable () -> BodyDownloadPolicy
    var rateLimitStreak = 0
    var draftCache: [String: RemoteDraftUpsert] = [:]
    let muting: (any MailMutating)?
    let blocking: (any BlockStoring)?

    public init(account: AccountID, store: any SyncStore, api: any GmailAPI, clock: any OHClock,
                settings: SyncSettings = SyncSettings(), metrics: SyncMetricsCollector? = nil,
                gate: BackfillGate? = nil, bodyPolicy: (@Sendable () -> BodyDownloadPolicy)? = nil,
                muting: (any MailMutating)? = nil, blocking: (any BlockStoring)? = nil) {
        self.gate = gate
        self.muting = muting
        self.blocking = blocking
        let fallback = settings.bodyDownload
        self.bodyPolicy = bodyPolicy ?? { fallback }
        self.account = account
        self.store = store
        self.api = api
        self.clock = clock
        self.settings = settings
        self.metrics = metrics
        pacer = BackfillPacer(unitsPerMinute: settings.backfillUnitsPerMinute)
    }

    @discardableResult
    public func sync(reason: String, rerunIfRunning: Bool = true) async throws -> SyncReport {
        if let running = current {
            if rerunIfRunning { rerunRequested = true }
            return try await running.value
        }
        let task = Task { try await self.runUntilSettled(reason: reason) }
        current = task
        return try await task.value
    }

    public func cancel() {
        current?.cancel()
        cancelBackfill()
    }

    public func cancelRun() {
        current?.cancel()
    }

    public nonisolated var progress: SyncProgress { broadcaster.current }

    public nonisolated func observeProgress() -> AsyncStream<SyncProgress> { broadcaster.stream() }

    private func runUntilSettled(reason: String) async throws -> SyncReport {
        defer { current = nil }
        var report: SyncReport
        repeat {
            rerunRequested = false
            report = try await runOnce(reason: reason)
        } while rerunRequested
        return report
    }

    enum Mode: Equatable {
        case initial, resync, incremental(HistoryID)
        var logKind: String {
            switch self {
            case .initial: return "inbox"
            case .resync: return "full_resync"
            case .incremental: return "incremental"
            }
        }
    }

    static func mode(_ status: SyncStatus) -> Mode {
        switch status.phase {
        case .resyncRequired: return .resync
        case .incremental, .backfilling, .inboxReady: return status.historyID.map(Mode.incremental) ?? .initial
        case .new, .bootstrapping: return .initial
        }
    }

    struct Counts {
        var added = 0, changed = 0, deleted = 0
        static func += (a: inout Counts, b: Counts) { a.added += b.added; a.changed += b.changed; a.deleted += b.deleted }
    }

    private func runOnce(reason: String) async throws -> SyncReport {
        runCount += 1
        let started = clock.now
        let before = metrics?.snapshot ?? .init()
        let status = try store.syncStatus(account: account)
        var mode = Self.mode(status)
        try store.updateSyncState(account: account) { $0.lastAttemptAt = started }
        log.info("account \(account.rawValue): \(mode.logKind) run (\(reason))")
        let signpost = SyncSignposts.begin(mode == .initial ? "initial-sync" : mode == .resync ? "full-resync" : "incremental")
        defer { SyncSignposts.end(signpost) }
        var counts = Counts()
        do {
            switch mode {
            case .initial:
                counts = try await initialSync(generation: status.generation, resync: false)
            case .resync:
                counts = try await fullResync()
            case .incremental(let start):
                do {
                    counts = try await incremental(from: start, generation: status.generation)
                } catch GmailError.historyExpired {
                    log.notice("account \(account.rawValue): history \(start.rawValue) expired; full resync")
                    mode = .resync
                    counts = try await fullResync()
                }
            }
            let finished = clock.now
            try store.updateSyncState(account: account) {
                $0.consecutiveFailures = 0
                $0.clearLastError = true
                $0.lastSuccessAt = finished
            }
            let used = (metrics?.snapshot ?? .init()) - before
            appendLog(mode.logKind, started, finished, outcome: "ok", units: used.units, requests: used.requests, counts,
                      errorCode: nil)
            return SyncReport(accountID: account, kind: mode.logKind, added: counts.added, changed: counts.changed,
                              deleted: counts.deleted, units: used.units, duration: Self.duration(finished, started))
        } catch {
            let code = Self.code(error)
            let finished = clock.now
            let used = (metrics?.snapshot ?? .init()) - before
            if code == "cancelled" {
                appendLog(mode.logKind, started, finished, outcome: "cancelled", units: used.units,
                          requests: used.requests, counts, errorCode: code)
                throw error
            }
            try? store.updateSyncState(account: account) {
                $0.incrementFailures = true
                $0.lastErrorCode = code
                $0.lastErrorMessage = code
            }
            if case GmailError.reauthRequired = error { try? store.setAccountStatus(account, .needsReauth) }
            appendLog(mode.logKind, started, finished, outcome: "error", units: used.units, requests: used.requests,
                      counts, errorCode: code)
            log.notice("account \(account.rawValue): \(mode.logKind) failed (\(code))")
            throw error
        }
    }

    func appendLog(_ kind: String, _ started: Date, _ finished: Date, outcome: String, units: Int, requests: Int,
                   _ counts: Counts, errorCode: String?, detail: String? = nil) {
        try? store.appendSyncLog(SyncLogEntry(accountID: account, startedAt: started, finishedAt: finished, kind: kind,
                                              outcome: outcome, quotaUnits: units, requests: requests,
                                              added: counts.added, changed: counts.changed, deleted: counts.deleted,
                                              errorCode: errorCode, detail: detail))
    }

    private func fullResync() async throws -> Counts {
        cancelBackfill()
        backfillFinished = false
        draftCache = [:]
        try store.updateSyncState(account: account) { $0.phase = .resyncRequired }
        let generation = try store.beginFullResync(account: account)
        log.notice("account \(account.rawValue): full resync, generation \(generation)")
        return try await initialSync(generation: generation, resync: true)
    }

    private func initialSync(generation: Int, resync: Bool) async throws -> Counts {
        var counts = Counts()
        if !resync { try store.updateSyncState(account: account) { $0.phase = .bootstrapping } }
        let profile = try await api.getProfile(priority: .interactive)
        guard let raw = UInt64(profile.historyId) else { throw GmailMapperError.missingField("profile.historyId") }
        let bootstrap = HistoryID(raw)
        try store.updateSyncState(account: account) { $0.bootstrapHistoryID = bootstrap }
        broadcaster.update { $0.mailTotal = profile.threadsTotal }
        try await refreshLabels()
        try await refreshSendAs(profileEmail: profile.emailAddress)

        let firstInbox = SyncSignposts.begin("first-inbox")
        let listing = try await api.listThreads(ListQuery(labelIDs: ["INBOX"], maxResults: settings.inboxThreads),
                                                priority: .interactive)
        let stubs = listing.threads ?? []
        let targets = resync ? stubs.map(\.id) : try needingFetch(stubs)
        let fetched = try await fetchThreadChunk(targets, generation: generation, priority: .interactive, sweep: resync,
                                                 tombstone: bootstrap)
        counts += fetched.counts
        if resync {
            let complete = listing.nextPageToken == nil
            counts += try await recheckMissingInboxThreads(listed: Set(stubs.map(\.id)), fetched: fetched.threads,
                                                           complete: complete, generation: generation,
                                                           tombstone: bootstrap)
        }
        try store.updateSyncState(account: account) {
            $0.phase = .inboxReady
            $0.backfillComplete = false
        }
        SyncSignposts.end(firstInbox)
        if let error = fetched.firstError { throw error }

        let top = stubs.prefix(settings.prefetchFullBodies).compactMap { stub in
            fetched.threads[stub.id]?.messages?.max { ($0.internalDateValue ?? .distantPast) < ($1.internalDateValue ?? .distantPast) }?.id
        }
        try await prefetchBodies(top)
        try await checkInvites()
        try store.updateSyncState(account: account) { $0.historyID = bootstrap }
        refreshInboxProgress()
        return counts
    }

    private func recheckMissingInboxThreads(listed: Set<String>, fetched: [String: GmailThread], complete: Bool,
                                            generation: Int, tombstone: HistoryID) async throws -> Counts {
        let newestDates = fetched.values.compactMap { thread in
            thread.messages?.compactMap(\.internalDateValue).max()
        }
        let cutoff = complete ? Date.distantPast : (newestDates.min() ?? Date.distantPast)
        let missing = Array(try missingLocalInboxThreads(listed: listed, newerThan: cutoff).prefix(settings.inboxThreads))
        guard !missing.isEmpty else { return Counts() }
        let result = try await fetchThreadChunk(missing, generation: generation, priority: .interactive, sweep: true,
                                                tombstone: tombstone)
        if let error = result.firstError { throw error }
        return result.counts
    }

    private func prefetchBodies(_ messageIDs: [String]) async throws {
        let needed = try messageIDs.filter {
            let state = try store.message(account: account, gmailMessageID: GmailMessageID($0))?.bodyState
            return state == BodyState.none || state == .metadataOnly
        }
        guard !needed.isEmpty else { return }
        do {
            let results = try await api.getMessages(ids: needed, format: .full, metadataHeaders: [], priority: .interactive)
            try BodyFetcher.store(results, account: account, store: store, log: log)
        } catch GmailError.cancelled {
            throw GmailError.cancelled
        } catch {
            log.notice("account \(account.rawValue): body prefetch failed (\(Self.code(error)))")
        }
    }

    private func incremental(from start: HistoryID, generation: Int) async throws -> Counts {
        incrementalCycles += 1
        if incrementalCycles % max(settings.labelsRefreshEveryCycles, 1) == 0 { try await refreshLabels() }
        var counts = Counts()
        var token: String?
        var newest = start
        var touchesDrafts = false
        repeat {
            let page = try await api.listHistory(startHistoryID: start, pageToken: token,
                                                 types: [.messageAdded, .messageDeleted, .labelAdded, .labelRemoved],
                                                 labelID: nil, maxResults: settings.historyPageSize, priority: .sync)
            var batch = GmailMapper.labelDeltas(page.history ?? [], knownLabelIDs: try knownLabelKeys())
            if !batch.unknownLabelIDs.isEmpty {
                try await refreshLabels()
                batch.unknownLabelIDs = []
            }
            var draftChange = batch.touchesDrafts
            if !draftChange && !touchesDrafts && !batch.deletedMessageIDs.isEmpty {
                draftChange = try deletesADraft(batch.deletedMessageIDs)
            }
            touchesDrafts = touchesDrafts || draftChange
            let pageNewest = UInt64(page.historyId).map { HistoryID($0) } ?? newest
            let chunkSize = max(settings.fetchChunk, 1)
            let deleted = batch.deletedMessageIDs.map { GmailMessageID($0) }
            for start in stride(from: 0, to: deleted.count, by: chunkSize) {
                counts.deleted += try store.deleteMessages(Array(deleted[start..<min(start + chunkSize, deleted.count)]),
                                                           account: account,
                                                           historyID: batch.deleteHistoryID ?? pageNewest).updated
            }
            let candidates = batch.addedMessageIDs.map { GmailMessageID($0) } + batch.labelDeltas.map(\.gmailMessageID)
            let known = try store.knownMessageIDs(account: account, among: candidates)
            var seen = Set<GmailMessageID>()
            let unknown = candidates.filter { !known.contains($0) && seen.insert($0).inserted }.map(\.rawValue)
            for start in stride(from: 0, to: unknown.count, by: chunkSize) {
                var fetched: [GmailMessage] = []
                defer {
                    applyMuteRule(fetched)
                    applyBlockRule(fetched)
                }
                counts += try await fetchMessagesFull(Array(unknown[start..<min(start + chunkSize, unknown.count)]),
                                                      generation: generation, tombstone: pageNewest, fetched: &fetched)
            }
            // Why: a message stored before this run is not fetched again, so label changes after its arrival apply as deltas
            let applicable = (batch.labelDeltas + batch.addedLabelDeltas).filter { known.contains($0.gmailMessageID) }
            if !applicable.isEmpty {
                counts.changed += try store.applyLabelDeltas(applicable, account: account).updated
            }
            newest = max(newest, pageNewest)
            token = page.nextPageToken
        } while token != nil
        if touchesDrafts { try await refreshDrafts() }
        let now = clock.now
        try store.updateSyncState(account: account) {
            $0.historyID = newest
            $0.lastIncrementalAt = now
        }
        recheckMuteRule()
        recheckBlockRule()
        try await checkInvites()
        return counts
    }

    public func refreshLabels() async throws {
        let labels = try await api.listLabels()
        try store.upsertLabels(labels.map(GmailMapper.labelUpsert), account: account, removeMissing: true)
        let now = clock.now
        try store.updateSyncState(account: account) { $0.labelsRefreshedAt = now }
    }

    public func refreshSendAsOnRequest() async throws {
        guard let email = try store.accounts().first(where: { $0.id == account })?.email else { return }
        try await refreshSendAs(profileEmail: email)
    }

    private func refreshSendAs(profileEmail: String) async throws {
        var identities: [SendAsIdentity]
        do {
            identities = try await api.listSendAs().map {
                SendAsIdentity(email: $0.sendAsEmail.lowercased(), name: $0.displayName, isDefault: $0.isDefault ?? false,
                               isPrimary: $0.isPrimary ?? false, signatureHTML: $0.signature, replyTo: $0.replyToAddress,
                               verificationStatus: $0.verificationStatus)
            }
        } catch GmailError.forbidden(let reason, _) {
            log.notice("account \(account.rawValue): sendAs.list refused (\(reason)); using the profile address")
            identities = []
        }
        if identities.isEmpty {
            identities = [SendAsIdentity(email: profileEmail.lowercased(), isDefault: true, isPrimary: true)]
        }
        try store.updateSendAs(account: account, identities: identities)
        let now = clock.now
        try store.updateSyncState(account: account) { $0.sendAsRefreshedAt = now }
    }

    private func applyMuteRule(_ arrived: [GmailMessage]) {
        guard let muting, !arrived.isEmpty else { return }
        do {
            let changed = try MuteRule.apply(arrived: arrived, account: account, store: store, mutating: muting)
            if changed > 0 {
                log.info("account \(account.rawValue): mute rule kept \(changed) new message(s) out of the inbox")
            }
        } catch {
            log.notice("account \(account.rawValue): mute rule failed (\(Self.code(error)))")
        }
    }

    private func applyBlockRule(_ arrived: [GmailMessage]) {
        guard let blocking, !arrived.isEmpty else { return }
        do {
            let changed = try BlockIngest.apply(arrived: arrived, account: account, store: blocking, mutating: blocking)
            if changed > 0 {
                log.info("account \(account.rawValue): block rule kept \(changed) new message(s) out of the inbox")
            }
        } catch {
            log.notice("account \(account.rawValue): block rule failed (\(Self.code(error)))")
        }
    }

    private func recheckMuteRule() {
        guard let muting else { return }
        do {
            let changed = try MuteRule.recheck(account: account, store: store, mutating: muting)
            if changed > 0 {
                log.info("account \(account.rawValue): mute rule re-check kept \(changed) message(s) out of the inbox")
            }
        } catch {
            log.notice("account \(account.rawValue): mute rule re-check failed (\(Self.code(error)))")
        }
    }

    private func recheckBlockRule() {
        guard let blocking else { return }
        do {
            let changed = try BlockIngest.recheck(account: account, store: blocking, mutating: blocking)
            if changed > 0 {
                log.info("account \(account.rawValue): block rule re-check kept \(changed) message(s) out of the inbox")
            }
        } catch {
            log.notice("account \(account.rawValue): block rule re-check failed (\(Self.code(error)))")
        }
    }

    private func deletesADraft(_ ids: [String]) throws -> Bool {
        let cached = Set(draftCache.values.map(\.gmailMessageID.rawValue))
        for id in ids {
            if cached.contains(id) { return true }
            if try store.message(account: account, gmailMessageID: GmailMessageID(id))?.isDraft == true { return true }
        }
        return false
    }

    func knownLabelKeys() throws -> Set<String> {
        Set(try store.labels(account: account).map(\.key))
    }

    func localMessageIDs(thread id: String) throws -> [String] {
        guard let ref = try store.thread(account: account, gmailThreadID: GmailThreadID(id)),
              let detail = try store.threadDetail(ref.rowID) else { return [] }
        return detail.messages.map(\.gmailMessageID.rawValue)
    }

    func refreshInboxProgress() {
        let inbox = (try? store.label(account: account, key: "INBOX"))?.map(\.totalThreads) ?? 0
        let all = (try? store.label(account: account, key: "oh:allmail"))?.map(\.totalThreads) ?? 0
        broadcaster.update {
            $0.inboxSynced = inbox
            $0.mailSynced = all
        }
    }

    static func code(_ error: Error) -> String {
        switch error {
        case let e as GmailError: return e.code
        case is GmailMapperError: return "mapping"
        case is StoreError: return "store"
        case is CancellationError: return "cancelled"
        default: return "error"
        }
    }

    static func duration(_ end: Date, _ start: Date) -> Duration {
        .milliseconds(Int64((end.timeIntervalSince(start) * 1000).rounded()))
    }
}
