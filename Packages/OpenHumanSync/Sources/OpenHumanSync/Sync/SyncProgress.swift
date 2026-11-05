import Foundation
import OpenHumanStore
import Synchronization

public struct SyncProgress: Sendable, Hashable {
    public enum Stage: String, Sendable, Hashable {
        case idle
        case inbox
        case drafts
        case recentViews
        case allMail
        case bodies
        case searchBodies
        case complete
    }

    public var stage: Stage
    public var inboxSynced: Int
    public var inboxTotal: Int?
    public var mailSynced: Int
    public var mailTotal: Int?
    public var oldestSynced: Date?
    public var bodiesFetched: Int
    public var pausedUntil: Date?
    public var isRunning: Bool
    public var bodiesDone: Int
    public var bodiesTotal: Int?
    public var hold: BackfillHold?

    public init(stage: Stage = .idle, inboxSynced: Int = 0, inboxTotal: Int? = nil, mailSynced: Int = 0,
                mailTotal: Int? = nil, oldestSynced: Date? = nil, bodiesFetched: Int = 0, pausedUntil: Date? = nil,
                isRunning: Bool = false, bodiesDone: Int = 0, bodiesTotal: Int? = nil, hold: BackfillHold? = nil) {
        self.stage = stage
        self.inboxSynced = inboxSynced
        self.inboxTotal = inboxTotal
        self.mailSynced = mailSynced
        self.mailTotal = mailTotal
        self.oldestSynced = oldestSynced
        self.bodiesFetched = bodiesFetched
        self.pausedUntil = pausedUntil
        self.isRunning = isRunning
        self.bodiesDone = bodiesDone
        self.bodiesTotal = bodiesTotal
        self.hold = hold
    }

    public var statusText: String? {
        guard isRunning else { return nil }
        if pausedUntil != nil { return "Sync paused by Gmail's rate limit" }
        switch stage {
        case .inbox, .drafts, .recentViews:
            guard let total = inboxTotal else { return "Syncing \(Self.grouped(inboxSynced))" }
            return "Syncing \(Self.grouped(min(inboxSynced, total))) of \(Self.grouped(total))"
        case .allMail:
            guard let total = mailTotal else { return "Syncing older mail, \(Self.grouped(mailSynced))" }
            return "Syncing older mail, \(Self.grouped(min(mailSynced, total))) of \(Self.grouped(total))"
        case .bodies:
            return "Downloading recent messages, \(Self.grouped(bodiesFetched))"
        case .searchBodies:
            let count = bodiesTotal.map { "\(Self.grouped(min(bodiesDone, $0))) of \(Self.grouped($0))" } ?? Self.grouped(bodiesDone)
            switch hold {
            case nil: return "Downloading messages for search: \(count)"
            case .offline?: return "Message download paused, offline: \(count)"
            case .lowPower?: return "Message download paused to save power: \(count)"
            case .interactive?, .queueDrain?: return "Downloading messages for search: \(count)"
            }
        case .idle, .complete:
            return nil
        }
    }

    static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return n < 0 ? "-" + out : out
    }
}

final class ProgressBroadcaster: Sendable {
    private struct State {
        var value = SyncProgress()
        var observers: [UInt64: AsyncStream<SyncProgress>.Continuation] = [:]
        var nextID: UInt64 = 0
    }
    private let state = Mutex(State())

    var current: SyncProgress { state.withLock { $0.value } }

    // Why: yielding after unlocking let two concurrent updates reach observers in the opposite order, leaving them on a stale value
    func update(_ change: (inout SyncProgress) -> Void) {
        state.withLock { s in
            var next = s.value
            change(&next)
            guard next != s.value else { return }
            s.value = next
            for observer in s.observers.values { observer.yield(next) }
        }
    }

    func stream() -> AsyncStream<SyncProgress> {
        let (stream, continuation) = AsyncStream.makeStream(of: SyncProgress.self, bufferingPolicy: .bufferingNewest(256))
        let id: UInt64 = state.withLock { s in
            s.nextID += 1
            s.observers[s.nextID] = continuation
            continuation.yield(s.value)
            return s.nextID
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
        return stream
    }
}
