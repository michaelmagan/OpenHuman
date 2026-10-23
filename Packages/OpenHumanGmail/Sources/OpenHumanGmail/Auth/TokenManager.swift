import Foundation
import OpenHumanCore

public enum ReauthReason: String, Sendable, Equatable, Codable {
    case noToken
    case invalidGrant
    case clientMismatch
    case signedOut
    case broaderGrant
    case needsSignInHere
}

public enum TokenAuthState: Sendable, Equatable {
    case unknown
    case authorized
    case needsReauth(ReauthReason)
}

public enum TokenEvent: Sendable, Equatable {
    case needsReauth(account: String, reason: ReauthReason)
    case scopesChanged(account: String, scopes: [String])
    case authorized(account: String, scopes: [String])
    case signedOut(account: String)
}

public actor TokenManager: AccessTokenProvider {
    public nonisolated let accountEmail: String
    private let store: any TokenStore
    private let client: OAuthClientConfig
    private let transport: any HTTPTransport
    private let clock: any OHClock
    private let minimumValidity: Duration
    private let retryWaits: [Duration]
    private let onEvent: (@Sendable (TokenEvent) -> Void)?
    private let log: CredentialChainLog
    private let subject: String

    private var cached: StoredToken?
    private var rejectedAccessToken: String?
    private var refreshTask: Task<String, Error>?
    private var state: TokenAuthState = .unknown
    private var rejectedRefreshToken: String?
    private var generation = 0
    private var refusal: String?

    public init(account email: String, store: any TokenStore, client: OAuthClientConfig,
                transport: any HTTPTransport, clock: any OHClock, minimumValidity: Duration = .seconds(300)) {
        self.init(account: email, store: store, client: client, transport: transport, clock: clock,
                  minimumValidity: minimumValidity, retryWaits: TokenEndpoint.refreshRetryWaits, onEvent: nil)
    }

    init(account email: String, store: any TokenStore, client: OAuthClientConfig, transport: any HTTPTransport,
         clock: any OHClock, minimumValidity: Duration, retryWaits: [Duration],
         onEvent: (@Sendable (TokenEvent) -> Void)? = nil, log: CredentialChainLog = .shared) {
        self.accountEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.log = log
        subject = CredentialChainLog.subject(account: email)
        self.store = store
        self.client = client
        self.transport = transport
        self.clock = clock
        self.minimumValidity = minimumValidity
        self.retryWaits = retryWaits
        self.onEvent = onEvent
    }

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        if case .needsReauth = state { try resumeIfReauthorized() }
        if cached == nil { cached = try store.load(account: accountEmail) }
        if forceRefresh {
            if let current = cached?.accessToken { rejectedAccessToken = current }
        } else if let cached, let token = usableAccessToken(cached) {
            if state == .unknown { state = .authorized }
            return token
        }
        let task = Task { try await self.refresh() }
        refreshTask = task
        defer { if refreshTask == task { refreshTask = nil } }
        return try await task.value
    }

    public func invalidateAccessToken() {
        if let current = cached?.accessToken { rejectedAccessToken = current }
    }

    public func authState() -> TokenAuthState { state }

    public func lastRefusal() -> String? { refusal }

    public func grantedScopes() throws -> [String]? {
        try store.load(account: accountEmail)?.grantedScopes
    }

    public func adopt(_ token: StoredToken) throws {
        guard token.clientID == client.clientID else { throw OAuthError.denied("client_mismatch") }
        try store.save(token, account: accountEmail)
        generation += 1
        refreshTask = nil
        cached = token
        rejectedAccessToken = nil
        rejectedRefreshToken = nil
        state = .authorized
        onEvent?(.authorized(account: accountEmail, scopes: token.grantedScopes))
    }

    // Why: never contact Google on sign-out; revoking the grant would also sign out other tools sharing this client
    public func signOut() throws {
        let stored = try? store.load(account: accountEmail)
        generation += 1
        refreshTask = nil
        cached = nil
        rejectedAccessToken = nil
        rejectedRefreshToken = stored?.refreshToken
        state = .needsReauth(.signedOut)
        Log(.oauth).notice("account signed out locally: the app's token item is deleted; nothing is revoked at Google")
        onEvent?(.signedOut(account: accountEmail))
        try store.delete(account: accountEmail)
    }

    private var isSticky: Bool {
        if case .needsReauth = state { return true }
        return false
    }

    private func resumeIfReauthorized() throws {
        guard let stored = try store.load(account: accountEmail),
              stored.refreshToken != rejectedRefreshToken,
              stored.clientID == client.clientID else {
            throw OAuthError.reauthRequired
        }
        cached = stored
        rejectedAccessToken = nil
        rejectedRefreshToken = nil
        state = .authorized
        Log(.oauth).notice("a new credential was stored; reauthorization complete")
    }

    private func enterReauth(_ reason: ReauthReason, rejecting refreshToken: String?) -> OAuthError {
        let changed = state != .needsReauth(reason)
        state = .needsReauth(reason)
        rejectedRefreshToken = refreshToken
        cached = nil
        rejectedAccessToken = nil
        if changed {
            Log(.oauth).notice("reauthorization required (\(reason.rawValue))")
            onEvent?(.needsReauth(account: accountEmail, reason: reason))
        }
        return .reauthRequired
    }

    private func usableAccessToken(_ token: StoredToken) -> String? {
        guard let access = token.accessToken, !access.isEmpty, access != rejectedAccessToken,
              let expiry = token.accessTokenExpiry,
              expiry.timeIntervalSince(clock.now) >= minimumValidity.timeInterval else { return nil }
        return access
    }

    private func sharedVerdict(_ stored: StoredToken) -> SharedRefusal {
        guard let shared = store as? any SharedTokenStore else { return .notShared }
        return (try? shared.sharedTokenRefused(account: accountEmail, refreshToken: stored.refreshToken)) ?? .notShared
    }

    private func refresh(retried: Bool = false) async throws -> String {
        let startGeneration = generation
        guard let stored = try store.load(account: accountEmail) else { throw enterReauth(.noToken, rejecting: nil) }
        if let token = usableAccessToken(stored) {
            cached = stored
            state = .authorized
            return token
        }
        // A refresh token only works with the client that minted it, so never send it with another client
        guard stored.clientID == client.clientID else {
            Log(.oauth).error("stored token was minted by a different OAuth client; reauthorization required")
            throw enterReauth(.clientMismatch, rejecting: stored.refreshToken)
        }
        var form: [(String, String)] = [
            ("grant_type", "refresh_token"), ("refresh_token", stored.refreshToken), ("client_id", client.clientID),
        ]
        if let secret = client.clientSecret { form.append(("client_secret", secret)) }
        let reply: TokenEndpoint.Reply
        do {
            reply = try await TokenEndpoint.post(form: form, to: client.tokenURI, transport: transport, clock: clock,
                                                 retryWaits: retryWaits)
        } catch {
            if !(error is CancellationError), (error as? TransportError) != .cancelled {
                log.record(.refresh, .unreachable, subject: subject)
            }
            throw error
        }
        guard generation == startGeneration else { return try await afterCredentialChange() }
        guard reply.status == 200, let body = reply.body,
              let access = body.accessToken, !access.isEmpty else {
            refusal = reply.body?.error.map(CredentialChainLog.safeCode)
            if let refusal {
                log.record(.refresh, .googleRefused(code: refusal), subject: subject)
            } else {
                log.record(.refresh, reply.status >= 500 ? .unreachable : .unreadable, subject: subject)
            }
            // A refusal of a shared sign-in never deletes it: the device that shared it may still use it
            if let code = reply.body?.error, Self.refusalCodes.contains(code) {
                switch sharedVerdict(stored) {
                case .replaced where !retried:
                    Log(.oauth).notice("refresh refused; the store holds another sign-in, trying it once")
                    return try await refresh(retried: true)
                case .refusedHere:
                    Log(.oauth).notice("a sign-in shared from another device was refused here (\(code)); sign in on "
                                       + "this device")
                    throw enterReauth(.needsSignInHere, rejecting: stored.refreshToken)
                default:
                    break
                }
            }
            if reply.body?.error == "invalid_grant" {
                Log(.oauth).notice("refresh token rejected (invalid_grant)")
                throw enterReauth(.invalidGrant, rejecting: stored.refreshToken)
            }
            if reply.status == 200 {
                throw OAuthError.tokenEndpoint(status: 200, error: "missing_access_token", description: nil)
            }
            throw TokenEndpoint.failure(reply)
        }
        // A grant broader than the stored one is never used, even for the request in flight
        let beyond = body.scope == nil ? [] : OAuthScopes.beyondGrant(body.grantedScopes, stored: stored.grantedScopes)
        if !beyond.isEmpty {
            log.record(.scopeCheck, .broaderGrant, subject: subject)
            Log(.oauth).error("a refresh granted scopes beyond the stored grant (\(beyond.joined(separator: " "))); "
                              + "the token is not used and the app's own token item is deleted")
            if let shared = store as? any SharedTokenStore {
                try? shared.deleteEverywhere(account: accountEmail)
            } else {
                try? store.delete(account: accountEmail)
            }
            throw enterReauth(.broaderGrant, rejecting: stored.refreshToken)
        }
        var updated = stored
        updated.accessToken = access
        updated.accessTokenExpiry = clock.now.addingTimeInterval(TimeInterval(body.expiresIn ?? 3600))
        let scopesChanged = body.scope != nil && OAuthScopes.differ(stored.grantedScopes, body.grantedScopes)
        if body.scope != nil { updated.grantedScopes = body.grantedScopes }
        if let rotated = body.refreshToken, !rotated.isEmpty { updated.refreshToken = rotated }
        // Why: the item can be deleted while the request is out (the account was removed); never write it back
        if let shared = store as? any SharedTokenStore {
            do {
                try shared.saveRefreshed(updated, account: accountEmail, refreshedWith: stored.refreshToken)
            } catch TokenStoreError.missing {
                throw enterReauth(.noToken, rejecting: nil)
            }
        } else {
            guard try store.load(account: accountEmail) != nil else { throw enterReauth(.noToken, rejecting: nil) }
            try store.save(updated, account: accountEmail)
        }
        cached = updated
        rejectedAccessToken = nil
        state = .authorized
        refusal = nil
        log.record(.refresh, .ok, subject: subject)
        Log(.oauth).info("access token refreshed")
        if scopesChanged {
            Log(.oauth).notice("granted scopes changed on refresh: \(updated.grantedScopes.joined(separator: " "))")
            onEvent?(.scopesChanged(account: accountEmail, scopes: updated.grantedScopes))
        }
        return access
    }

    static let refusalCodes: Set<String> = ["invalid_grant", "invalid_client", "unauthorized_client"]

    private func afterCredentialChange() async throws -> String {
        if isSticky { throw OAuthError.reauthRequired }
        if let cached, let token = usableAccessToken(cached) { return token }
        return try await refresh()
    }
}
