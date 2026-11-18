import Foundation
import MailModel
import Synchronization

public final class FakeCalendarConnections: CalendarConnectionsProviding, Sendable {
    private struct State {
        var connections: [String: FakeCalendarConnection] = [:]
        var requests: [String] = []
    }
    private let state = Mutex(State())
    private let grantsWrites: Bool
    private let connected: Set<String>
    private let providers: [String: any CalendarProviding]?
    private let followsConnection: Bool
    private let windowAccount: String?
    private let otherSources: [CalendarSource]

    // `otherSources` are calendars that belong to no account; the window lists them after the accounts' own
    public init(connected: Set<String> = [], grantsWrites: Bool = true,
                providers: [String: any CalendarProviding]? = nil, followsConnection: Bool = false,
                windowAccount: String? = nil, otherSources: [CalendarSource] = []) {
        self.connected = Set(connected.map { $0.lowercased() })
        self.grantsWrites = grantsWrites
        self.providers = providers.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.lowercased(), $0.value) }) }
        self.followsConnection = followsConnection
        self.windowAccount = windowAccount?.lowercased()
        self.otherSources = otherSources
    }

    public func calendarProvider(for account: Account) -> (any CalendarProviding)? {
        provider(account.email)
    }

    public var routesByAccount: Bool { providers != nil }

    public func windowSources(accounts: [Account]) -> [CalendarSource] { accountSources(accounts) + otherSources }

    public func windowCalendarProvider() -> (any CalendarProviding)? {
        if let windowAccount, let own = provider(windowAccount) { return own }
        return (providers?.keys.sorted() ?? []).lazy.compactMap { self.provider($0) }.first
    }

    private func provider(_ email: String) -> (any CalendarProviding)? {
        let key = email.lowercased()
        guard let found = providers?[key] else { return nil }
        if followsConnection, connection(key).current.status != .connected { return nil }
        return found
    }

    public func calendarConnection(for account: Account) -> (any CalendarConnecting)? {
        state.withLock { $0.requests.append(account.email.lowercased()) }
        return connection(account.email)
    }

    public func connection(_ email: String) -> FakeCalendarConnection {
        let key = email.lowercased()
        return state.withLock { s in
            if let existing = s.connections[key] { return existing }
            let made = FakeCalendarConnection(account: key, connected: connected.contains(key), grantsWrites: grantsWrites)
            s.connections[key] = made
            return made
        }
    }

    public var requests: [String] { state.withLock { $0.requests } }
}
