import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore
import Synchronization

typealias ConnectivityHub = AccountHub<AccountConnectivity>
typealias ProgressHub = AccountHub<SyncProgress>

final class AccountHub<Value: Equatable & Sendable>: Sendable {
    private struct State {
        var value: [AccountID: Value] = [:]
        var observers: [UInt64: AsyncStream<[AccountID: Value]>.Continuation] = [:]
        var nextID: UInt64 = 0
    }
    private let state = Mutex(State())

    var current: [AccountID: Value] { state.withLock { $0.value } }

    func set(_ account: AccountID, _ value: Value?) {
        update { $0[account] = value }
    }

    // Why: yielding after unlocking let two concurrent updates reach observers in the opposite order, leaving them on a stale value
    func update(_ change: (inout [AccountID: Value]) -> Void) {
        state.withLock { s in
            var next = s.value
            change(&next)
            guard next != s.value else { return }
            s.value = next
            for observer in s.observers.values { observer.yield(next) }
        }
    }

    func stream() -> AsyncStream<[AccountID: Value]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [AccountID: Value].self, bufferingPolicy: .bufferingNewest(16))
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

extension AccountHub where Value == AccountConnectivity {
    // Why: a run already under way when the network dropped finishes after the engine marked the account offline; the
    // network event is newer, so the account stays offline until the network returns and pokes a fresh run.
    // Callers read isReachable inside update(_:): the engine sets reachability before it marks the account offline,
    // so a run's state either lands before the offline mark or sees the network down
    static func afterRun(_ next: AccountConnectivity, previous: AccountConnectivity?,
                         isReachable: Bool) -> AccountConnectivity {
        guard !isReachable, case .online = next, case let .offline(since)? = previous else { return next }
        return .offline(since: since)
    }

    static func afterFailure(_ error: Error, now: Date, previous: AccountConnectivity?,
                             lastSyncAt: Date?) -> AccountConnectivity {
        switch error {
        case GmailError.transport(.notConnected), GmailError.transport(.cannotConnect),
             GmailError.transport(.timedOut), GmailError.transport(.connectionLost):
            if case let .offline(since) = previous { return .offline(since: since) }
            return .offline(since: now)
        case GmailError.rateLimited(let retryAfter):
            return .rateLimited(until: now.addingTimeInterval((retryAfter ?? .seconds(60)).timeInterval))
        case GmailError.quotaBudgetExhausted:
            return .rateLimited(until: now.addingTimeInterval(60))
        case GmailError.dailyLimitExceeded:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            return .rateLimited(until: midnight ?? now.addingTimeInterval(86_400))
        case GmailError.reauthRequired, GmailError.unauthorized, OAuthError.reauthRequired:
            return .needsReauth
        default:
            return .online(syncing: false, lastSyncAt: lastSyncAt)
        }
    }
}

final class Reachability: Sendable {
    private let state = Mutex<(reachable: Bool, since: Date?)>((true, nil))
    var isReachable: Bool { state.withLock { $0.reachable } }
    func set(_ reachable: Bool, now: Date) {
        state.withLock { s in
            if s.reachable != reachable { s = (reachable, reachable ? nil : now) }
        }
    }
}
