import Foundation
import OpenHumanCore
import Synchronization
import Testing
@testable import OpenHumanGmail

@Suite struct TokenManagerTests {
    private let email = "someone@example.com"

    private func refreshing(access: String = "synthetic-access-2", delay: Duration? = nil) -> ScriptedTransport {
        ScriptedTransport { _ in
            if let delay { try await Task.sleep(for: delay) }
            return jsonResponse(200, ["access_token": access, "expires_in": 3600, "scope": GmailScope.readonly,
                                      "token_type": "Bearer"])
        }
    }

    private func manager(store: any TokenStore, transport: ScriptedTransport, clock: TestClock,
                         retryWaits: [Duration] = TokenEndpoint.refreshRetryWaits) -> TokenManager {
        TokenManager(account: email, store: store, client: Synthetic.client, transport: transport, clock: clock,
                     minimumValidity: .seconds(300), retryWaits: retryWaits)
    }

    @Test func validTokenNeedsNoNetwork() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([email: Synthetic.token(expiry: clock.now.addingTimeInterval(360))])
        let transport = refreshing()
        let tokens = manager(store: store, transport: transport, clock: clock)
        #expect(try await tokens.accessToken() == "synthetic-access-0")
        #expect(try await tokens.accessToken(forceRefresh: false) == "synthetic-access-0")
        #expect(transport.requests.isEmpty)
    }

    @Test func refreshesInsideTheMinimumValidityMargin() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([email: Synthetic.token(expiry: clock.now.addingTimeInterval(240))])
        let transport = refreshing()
        let tokens = manager(store: store, transport: transport, clock: clock)
        #expect(try await tokens.accessToken() == "synthetic-access-2")
        #expect(transport.requests.count == 1)
        let saved = try #require(try store.load(account: email))
        #expect(saved.accessToken == "synthetic-access-2")
        #expect(saved.accessTokenExpiry == clock.now.addingTimeInterval(3600))
        #expect(saved.refreshToken == "synthetic-refresh-0")

        let request = transport.requests[0]
        #expect(request.method == "POST" && request.url == Synthetic.client.tokenURI)
        let form = formFields(request.body)
        #expect(form == ["grant_type": "refresh_token", "refresh_token": "synthetic-refresh-0",
                         "client_id": Synthetic.clientID, "client_secret": Synthetic.clientSecret])
    }

    @Test func fiftyConcurrentCallersTriggerExactlyOneRefresh() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([email: Synthetic.token(expiry: clock.now.addingTimeInterval(-1))])
        let transport = refreshing(delay: .milliseconds(200))
        let tokens = manager(store: store, transport: transport, clock: clock)
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<50 { group.addTask { try await tokens.accessToken() } }
            var all: [String] = []
            for try await value in group { all.append(value) }
            return all
        }
        #expect(results.count == 50)
        #expect(Set(results) == ["synthetic-access-2"])
        #expect(transport.requests.count == 1)
    }

    @Test func aRefreshAnsweredAfterTheTokenWasDeletedWritesNothingBack() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([email: Synthetic.token(expiry: clock.now.addingTimeInterval(-1))])
        let answer = Gate()
        let ready = Gate()
        let transport = ScriptedTransport { _ in
            ready.open()
            await answer.wait()
            return jsonResponse(200, ["access_token": "synthetic-access-2", "expires_in": 3600,
                                      "scope": GmailScope.readonly, "token_type": "Bearer"])
        }
        let tokens = manager(store: store, transport: transport, clock: clock)
        let pending = Task { try await tokens.accessToken() }
        await ready.wait()
        #expect(transport.requests.count == 1)
        try store.delete(account: email)
        answer.open()
        await #expect(throws: OAuthError.reauthRequired) { _ = try await pending.value }
        #expect(try store.load(account: email) == nil)
        #expect(try store.allAccounts().isEmpty)
        #expect(await tokens.authState() == .needsReauth(.noToken))
    }

    @Test func reloadsFromTheStoreBeforeRefreshing() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([email: Synthetic.token(expiry: clock.now.addingTimeInterval(600))])
        let transport = refreshing()
        let tokens = manager(store: store, transport: transport, clock: clock)
        #expect(try await tokens.accessToken() == "synthetic-access-0")
        clock.advance(by: .seconds(600))
        try store.save(Synthetic.token(access: "synthetic-access-other", expiry: clock.now.addingTimeInterval(3600)),
                       account: email)
        #expect(try await tokens.accessToken() == "synthetic-access-other")
        #expect(transport.requests.isEmpty)
    }

    @Test func forceRefreshAndInvalidateSkipTheRejectedToken() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([email: Synthetic.token(expiry: clock.now.addingTimeInterval(3000))])
        let transport = refreshing()
        let tokens = manager(store: store, transport: transport, clock: clock)
        #expect(try await tokens.accessToken() == "synthetic-access-0")
        #expect(try await tokens.accessToken(forceRefresh: true) == "synthetic-access-2")
        #expect(transport.requests.count == 1)
        #expect(try store.load(account: email)?.accessToken == "synthetic-access-2")

        await tokens.invalidateAccessToken()
        _ = try await tokens.accessToken()
        #expect(transport.requests.count == 2)
    }

    @Test func invalidGrantMeansReauthRequired() async throws {
        let clock = TestClock()
        let before = Synthetic.token(expiry: clock.now.addingTimeInterval(-10))
        let store = InMemoryTokenStore([email: before])
        let transport = ScriptedTransport { _ in
            jsonResponse(400, ["error": "invalid_grant", "error_description": "Token has been expired or revoked."])
        }
        let tokens = manager(store: store, transport: transport, clock: clock)
        await #expect(throws: OAuthError.reauthRequired) { _ = try await tokens.accessToken() }
        #expect(transport.requests.count == 1)
        #expect(try store.load(account: email) == before)
    }

    @Test func otherClientErrorsAreNotRetried() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([email: Synthetic.token(expiry: nil)])
        let transport = ScriptedTransport { _ in jsonResponse(401, ["error": "invalid_client"]) }
        let tokens = manager(store: store, transport: transport, clock: clock)
        await #expect(throws: OAuthError.tokenEndpoint(status: 401, error: "invalid_client", description: nil)) {
            _ = try await tokens.accessToken()
        }
        #expect(transport.requests.count == 1)
    }

    @Test func serverErrorsAreRetriedAfterOneThenTwoSeconds() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([email: Synthetic.token(expiry: nil)])
        let calls = Mutex(0)
        let transport = ScriptedTransport { _ in
            let n = calls.withLock { c -> Int in
                c += 1
                return c
            }
            return n < 3 ? jsonResponse(503, [:])
                : jsonResponse(200, ["access_token": "synthetic-access-3", "expires_in": 3600])
        }
        let tokens = manager(store: store, transport: transport, clock: clock)
        let task = Task { try await tokens.accessToken() }
        let start = clock.now
        #expect(await eventually { clock.sleeperCount == 1 })
        #expect(clock.nextDeadline == start.addingTimeInterval(1))
        clock.advance(by: .seconds(1))
        #expect(await eventually { clock.sleeperCount == 1 })
        #expect(clock.nextDeadline == start.addingTimeInterval(3))
        clock.advance(by: .seconds(2))
        #expect(try await task.value == "synthetic-access-3")
        #expect(transport.requests.count == 3)
        #expect(TokenEndpoint.refreshRetryWaits == [.seconds(1), .seconds(2)])
    }

    @Test func transportErrorsGiveUpAfterThreeAttempts() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([email: Synthetic.token(expiry: nil)])
        let transport = ScriptedTransport { _ in throw TransportError.timedOut }
        let tokens = manager(store: store, transport: transport, clock: clock, retryWaits: [.zero, .zero])
        await #expect(throws: TransportError.timedOut) { _ = try await tokens.accessToken() }
        #expect(transport.requests.count == 3)
    }

    @Test func tokenFromAnotherClientOrNoTokenMeansReauthRequired() async throws {
        let clock = TestClock()
        let foreign = InMemoryTokenStore([email: Synthetic.token(expiry: nil, clientID: "some-other-client")])
        let transport = refreshing()
        await #expect(throws: OAuthError.reauthRequired) {
            _ = try await manager(store: foreign, transport: transport, clock: clock).accessToken()
        }
        await #expect(throws: OAuthError.reauthRequired) {
            _ = try await manager(store: InMemoryTokenStore(), transport: transport, clock: clock).accessToken()
        }
        #expect(transport.requests.isEmpty)
    }
}
