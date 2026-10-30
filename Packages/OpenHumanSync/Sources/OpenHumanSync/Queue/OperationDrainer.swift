import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

public actor OperationDrainer {
    public enum State: Sendable, Equatable { case idle, running, pausedNeedsReauth, stopped }

    public struct PassReport: Sendable, Equatable {
        public var claimed = 0
        public var succeeded = 0
        public var retried = 0
        public var failed = 0
        public var released = 0
        public var cancelled = 0
        public var gmailCalls = 0
        public init() {}
    }

    public static let claimLimit = 50
    public static let maxIDsPerCall = 1000
    public static let maxAttempts = 10
    public static let offlineRetry: Duration = .seconds(30)
    public static let defaultRateLimitRetry: Duration = .seconds(60)
    public static let maxSendAttempts = 5
    public static let unconfirmedRetry: Duration = .seconds(30)
    public static let staleScheduleAge: Duration = .seconds(120)
    static let perMessageConcurrency = 4

    public let account: AccountID
    private let store: MailStore
    private let api: any GmailAPI
    private let clock: any OHClock
    private let storeClock: any OHClock
    private let ownerID: String
    private let emit: @Sendable (EngineEvent) -> Void
    private let onApplied: @Sendable (Date) -> Void
    private let context: DrainContext
    private let gate: BackfillGate?
    private let log = Log(.queue)

    private var loopTask: Task<Void, Never>?
    private var sleeper: Task<Void, Error>?
    private var poked = false
    public private(set) var state: State = .idle
    public private(set) var passes = 0

    public init(account: AccountID, store: MailStore, api: any GmailAPI, clock: any OHClock,
                storeClock: any OHClock = SystemClock(), ownerID: String? = nil,
                emit: @escaping @Sendable (EngineEvent) -> Void = { _ in },
                onApplied: @escaping @Sendable (_ appliedAt: Date) -> Void = { _ in }, gate: BackfillGate? = nil) {
        self.gate = gate
        self.account = account
        self.store = store
        self.api = api
        self.clock = clock
        self.storeClock = storeClock
        self.ownerID = ownerID ?? store.writerID
        self.emit = emit
        self.onApplied = onApplied
        context = DrainContext(account: account, store: store, api: api, clock: clock)
    }

    public func start() {
        guard loopTask == nil else { return }
        state = .running
        loopTask = Task { await self.loop() }
    }

    public func stop() {
        loopTask?.cancel()
        sleeper?.cancel()
        loopTask = nil
        state = .stopped
    }

    public func poke() {
        poked = true
        sleeper?.cancel()
    }

    private func loop() async {
        while !Task.isCancelled {
            poked = false
            await drainOnce()
            if Task.isCancelled || state == .pausedNeedsReauth { break }
            if poked { continue }
            let wake = (try? store.nextWakeTime(account: account)) ?? nil
            let clock = self.clock
            // Nothing queued: wait for a poke on real time, not the injected clock, so a virtual clock cannot spin
            let nap = Task {
                if let wake { try await clock.sleep(until: wake) } else { try await Task.sleep(for: .seconds(86_400)) }
            }
            sleeper = nap
            _ = try? await nap.value
            sleeper = nil
        }
        loopTask = nil
        if state == .running { state = .idle }
    }

    @discardableResult
    public func drainOnce(limit: Int? = nil, deadline: Date? = nil,
                          shouldStop: (@Sendable () -> Bool)? = nil) async -> PassReport {
        gate?.beginDraining()
        defer { gate?.endDraining() }
        return await drainPass(limit: limit, deadline: deadline, shouldStop: shouldStop)
    }

    private func drainPass(limit: Int?, deadline: Date?, shouldStop: (@Sendable () -> Bool)?) async -> PassReport {
        var report = PassReport()
        passes += 1
        func pastDeadline() -> Bool { (deadline.map { clock.now >= $0 } ?? false) || shouldStop?() == true }
        pass: while !Task.isCancelled, state != .pausedNeedsReauth, !pastDeadline() {
            let room = limit.map { $0 - report.claimed } ?? Self.claimLimit
            if room <= 0 { break }
            let ops: [OperationItem]
            do {
                ops = try store.claimReadyOperations(account: account, now: clock.now, limit: min(room, Self.claimLimit),
                                                     ownerID: ownerID)
            } catch {
                log.error("claim failed for account \(account.rawValue): \(AccountSyncer.code(error))")
                break
            }
            if ops.isEmpty { break }
            report.claimed += ops.count
            let groups = Self.groups(ops)
            for (index, group) in groups.enumerated() {
                if index > 0, pastDeadline() {
                    for op in groups[index...].flatMap({ $0 }) { release(op, at: clock.now, report: &report) }
                    break pass
                }
                let stop = await execute(group, report: &report)
                if stop {
                    let rest = groups[(index + 1)...].flatMap { $0 }
                    for op in rest { release(op, at: clock.now, report: &report) }
                    break pass
                }
            }
        }
        return report
    }

    static func groups(_ ops: [OperationItem]) -> [[OperationItem]] {
        var result: [[OperationItem]] = []
        for op in ops {
            if op.kind == .modifyLabels, let key = op.coalesceKey, var last = result.last,
               last.last?.kind == .modifyLabels, last.last?.coalesceKey == key {
                last.append(op)
                result[result.count - 1] = last
            } else {
                result.append([op])
            }
        }
        return result
    }

    func isStale(_ op: OperationItem) -> Bool {
        guard op.origin == .scheduler,
              storeClock.now.timeIntervalSince(op.createdAt) > Self.staleScheduleAge.timeInterval else { return false }
        switch op.payload {
        case .sendDraft:
            return op.attempts == 0
        case let .modifyLabels(_, add, remove, names):
            return !(add.map(\.rawValue) == ["INBOX"] && remove.isEmpty && names.isEmpty) && !isMuteRuleOp(add, remove, names)
                && !(names.isEmpty && BlockIngest.isBlockOp(add: add, remove: remove))
        default:
            return true
        }
    }

    private func isMuteRuleOp(_ add: [GmailLabelID], _ remove: [GmailLabelID], _ names: [String]) -> Bool {
        guard add.count == 1, remove.map(\.rawValue) == ["INBOX"], names.isEmpty,
              let label = (try? store.label(account: account, key: add[0].rawValue)) ?? nil else { return false }
        return label.name == OHGmailLabels.muted
    }

    // Why: an agent draft in Gmail Drafts can be undone; a send or a mail change from the CLI or an agent cannot
    func externalRefusal(_ op: OperationItem) -> Decision? {
        guard op.origin == .cli || op.origin == .agent, !isAgentDraftChange(op) else { return nil }
        return Decision(.fail(code: "not_applied_outside_app", message: "queued outside the app: not sent to Gmail"))
    }

    private func isAgentDraftChange(_ op: OperationItem) -> Bool {
        let id: DraftID
        switch op.payload {
        case let .upsertDraft(draft, _), let .deleteDraft(draft, _): id = draft
        case .sendDraft, .modifyLabels, .trash, .untrash, .createLabel: return false
        }
        guard let draft = (try? store.draft(id)) ?? nil else { return false }
        return draft.origin != .user
    }

    private func execute(_ group: [OperationItem], report: inout PassReport) async -> Bool {
        var live: [OperationItem] = []
        for op in group {
            if isStale(op) {
                apply(Decision(.cancel(code: "stale_schedule", message: "scheduled action re-evaluated: queued too long")),
                      to: [op], report: &report)
            } else if let refusal = externalRefusal(op) {
                apply(refusal, to: [op], report: &report)
            } else {
                live.append(op)
            }
        }
        guard let first = live.first else { return false }
        let decision: Decision
        switch first.payload {
        case let .modifyLabels(_, add, remove, addNames):
            decision = await modifyLabels(live, add: add.map(\.rawValue), remove: remove.map(\.rawValue), addNames: addNames,
                                          report: &report)
        case let .trash(ids):
            decision = await perMessage(ids, untrash: false, report: &report)
        case let .untrash(ids):
            decision = await perMessage(ids, untrash: true, report: &report)
        case let .createLabel(name):
            decision = await createLabel(name, report: &report)
        case let .upsertDraft(draft, _):
            decision = await DraftUpload(context: context).run(first, draftID: draft, report: &report)
        case let .deleteDraft(draft, gmailDraftID):
            decision = await deleteDraft(draft, gmailDraftID: gmailDraftID, report: &report)
        case let .sendDraft(draft):
            decision = await SendPipeline(context: context).run(first, draftID: draft, report: &report)
        }
        apply(decision, to: live, report: &report)
        return decision.stopPass
    }

    private func modifyLabels(_ group: [OperationItem], add: [String], remove: [String], addNames: [String],
                              report: inout PassReport) async -> Decision {
        var ids: [String] = []
        var seen = Set<String>()
        for op in group {
            if case let .modifyLabels(opIDs, _, _, _) = op.payload {
                for id in opIDs where seen.insert(id.rawValue).inserted { ids.append(id.rawValue) }
            }
        }
        do {
            let named = try await context.labels.ensure(addNames, report: &report)
            for start in stride(from: 0, to: ids.count, by: Self.maxIDsPerCall) {
                let chunk = Array(ids[start..<min(start + Self.maxIDsPerCall, ids.count)])
                try await batchModify(chunk, add: add + named, remove: remove, report: &report)
            }
        } catch {
            return Self.classify(error, now: clock.now)
        }
        return Decision(.complete(.labelsApplied))
    }

    // Why: halving down to single ids drops only the missing ones; 1000 ids need at most 10 levels
    private func batchModify(_ ids: [String], add: [String], remove: [String], report: inout PassReport) async throws {
        guard !ids.isEmpty else { return }
        do {
            report.gmailCalls += 1
            try await api.batchModifyMessages(ids: ids, add: add, remove: remove)
        } catch GmailError.notFound {
            guard ids.count > 1 else {
                log.notice("batchModify dropped a missing message id")
                return
            }
            let half = ids.count / 2
            try await batchModify(Array(ids[..<half]), add: add, remove: remove, report: &report)
            try await batchModify(Array(ids[half...]), add: add, remove: remove, report: &report)
        }
    }

    private func perMessage(_ ids: [GmailMessageID], untrash: Bool, report: inout PassReport) async -> Decision {
        let api = self.api
        let returned: [GmailMessage]
        do {
            report.gmailCalls += ids.count
            returned = try await Self.concurrently(ids.map(\.rawValue), limit: Self.perMessageConcurrency) { id in
                do {
                    return untrash ? try await api.untrashMessage(id: id) : try await api.trashMessage(id: id)
                } catch GmailError.notFound {
                    return nil
                }
            }
        } catch {
            return Self.classify(error, now: clock.now)
        }
        let upserts = returned.compactMap { try? GmailMapper.messageUpsert($0, includeBody: false) }
        return Decision(.complete(upserts.isEmpty ? .labelsApplied : .messagesReturned(upserts)))
    }

    private func createLabel(_ name: String, report: inout PassReport) async -> Decision {
        do {
            let label = try await context.labels.create(name, report: &report)
            return Decision(.complete(.labelCreated(GmailMapper.labelUpsert(label))))
        } catch {
            return Self.classify(error, now: clock.now)
        }
    }

    private func deleteDraft(_ draft: DraftID, gmailDraftID: GmailDraftID?, report: inout PassReport) async -> Decision {
        let target = gmailDraftID ?? ((try? store.draft(draft)) ?? nil)?.gmailDraftID
        if let target {
            do {
                report.gmailCalls += 1
                try await api.deleteDraft(id: target.rawValue)
            } catch GmailError.notFound {
            } catch {
                return Self.classify(error, now: clock.now)
            }
        }
        return Decision(.complete(.draftDeleted))
    }

    static func concurrently(_ ids: [String], limit: Int,
                             _ body: @escaping @Sendable (String) async throws -> GmailMessage?) async throws -> [GmailMessage] {
        try await withThrowingTaskGroup(of: GmailMessage?.self) { group in
            var results: [GmailMessage] = []
            var next = 0
            while next < min(max(limit, 1), ids.count) {
                let id = ids[next]
                group.addTask { try await body(id) }
                next += 1
            }
            while let result = try await group.next() {
                if let result { results.append(result) }
                if next < ids.count {
                    let id = ids[next]
                    group.addTask { try await body(id) }
                    next += 1
                }
            }
            return results
        }
    }

    private func apply(_ decision: Decision, to ops: [OperationItem], report: inout PassReport) {
        let now = clock.now
        var completed = 0
        for op in ops {
            switch decision.disposition {
            case .complete(let outcome):
                do {
                    try store.complete(op.id, outcome: outcome)
                    report.succeeded += 1
                    completed += 1
                } catch {
                    log.error("complete failed for op \(op.id.rawValue): \(AccountSyncer.code(error))")
                    completionFailed(op, at: now, report: &report)
                }
            case let .retry(code, message, at, limit):
                if op.attempts + 1 >= limit {
                    failPermanently(op, code: code, message: "gave up after \(op.attempts + 1) attempts", report: &report)
                } else {
                    do {
                        let when = at ?? now.addingTimeInterval(Self.backoff(attempts: op.attempts).timeInterval)
                        try store.fail(op.id, code: code, message: message, retryAt: when)
                        report.retried += 1
                    } catch {
                        log.error("fail(retry) failed for op \(op.id.rawValue): \(AccountSyncer.code(error))")
                    }
                }
            case .release(let at):
                release(op, at: at, report: &report)
            case let .fail(code, message):
                failPermanently(op, code: code, message: message, report: &report)
            case let .cancel(code, message):
                do {
                    try store.fail(op.id, code: code, message: message, retryAt: nil)
                    report.cancelled += 1
                    log.notice("op \(op.id.rawValue) (\(op.kind.rawValue)) ended: \(code)")
                } catch {
                    log.error("cancel failed for op \(op.id.rawValue): \(AccountSyncer.code(error))")
                }
            }
        }
        if decision.pauseForReauth {
            state = .pausedNeedsReauth
            try? store.setAccountStatus(account, .needsReauth)
            emit(.accountNeedsReauth(account))
        }
        if case .complete = decision.disposition {
            guard completed > 0 else { return }
            if let event = decision.event { emit(event) }
            onApplied(now)
        } else {
            if let event = decision.event { emit(event) }
            if case .sent? = decision.event { onApplied(now) }
        }
    }

    // Why: Gmail has the change but the store did not record it; the retry checks Gmail again (a send looks for its
    // sent copy instead of sending twice), so the op neither sits in flight until relaunch nor reports success early
    private func completionFailed(_ op: OperationItem, at now: Date, report: inout PassReport) {
        let message = "applied in Gmail but not recorded on this Mac"
        let limit = op.kind == .sendDraft ? Self.maxSendAttempts : Self.maxAttempts
        guard op.attempts + 1 < limit else {
            failPermanently(op, code: "complete_failed", message: message, report: &report)
            return
        }
        do {
            let when = now.addingTimeInterval(Self.backoff(attempts: op.attempts).timeInterval)
            try store.fail(op.id, code: "complete_failed", message: message, retryAt: when)
            report.retried += 1
        } catch {
            log.error("fail(retry) failed for op \(op.id.rawValue): \(AccountSyncer.code(error))")
        }
    }

    public static func backoff(attempts: Int) -> Duration {
        let seconds = min(5 * pow(2, Double(min(max(attempts, 0), 20))), 600)
        return .seconds(seconds)
    }

    static func nextUTCMidnight(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }

    private func release(_ op: OperationItem, at date: Date, report: inout PassReport) {
        do {
            try store.release(op.id, retryAt: date)
            report.released += 1
        } catch {
            log.error("release failed for op \(op.id.rawValue): \(AccountSyncer.code(error))")
        }
    }

    private func failPermanently(_ op: OperationItem, code: String, message: String, report: inout PassReport) {
        do {
            var waitingSend: DraftID?
            if case let .upsertDraft(draft, _) = op.payload, try store.draft(draft)?.state == .sending { waitingSend = draft }
            try store.fail(op.id, code: code, message: message, retryAt: nil)
            report.failed += 1
            log.notice("op \(op.id.rawValue) (\(op.kind.rawValue)) failed permanently: \(code)")
            if case let .sendDraft(draft) = op.payload {
                emit(.sendFailed(draft, message))
                return
            }
            if let item = try store.operation(op.id) { emit(.operationFailed(item)) }
            if let waitingSend { emit(.sendFailed(waitingSend, message)) }
        } catch {
            log.error("fail failed for op \(op.id.rawValue): \(AccountSyncer.code(error))")
        }
    }
}
