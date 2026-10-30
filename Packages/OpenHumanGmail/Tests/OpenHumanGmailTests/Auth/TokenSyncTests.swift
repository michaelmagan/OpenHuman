import Foundation
import OpenHumanCore
import Synchronization
import Testing
@testable import OpenHumanGmail

private struct Device {
    let local: InMemoryTokenStore
    let records: InMemoryTokenDeviceStore
    let store: SyncedTokenStore

    init(cloud: any SharedGrantStore, local: InMemoryTokenStore = InMemoryTokenStore()) {
        let records = InMemoryTokenDeviceStore()
        self.local = local
        self.records = records
        store = SyncedTokenStore(local: local, shared: cloud, device: records)
    }
}

private func endpoint(_ prefix: String = "access", refusing: Set<String> = [], error: String = "invalid_grant",
                      rotate: [String: String] = [:], hold: Gate? = nil,
                      before: (@Sendable (String) -> Void)? = nil) -> ScriptedTransport {
    ScriptedTransport { request in
        let refresh = formFields(request.body)["refresh_token"] ?? ""
        before?(refresh)
        if let hold { await hold.wait() }
        if refusing.contains(refresh) {
            return jsonResponse(400, ["error": error, "error_description": "Synthetic refusal."])
        }
        var body: [String: Any] = ["access_token": "\(prefix)-\(refresh)", "expires_in": 3600, "token_type": "Bearer",
                                   "scope": GmailScope.readonly]
        if let rotated = rotate[refresh] { body["refresh_token"] = rotated }
        return jsonResponse(200, body)
    }
}

private final class LyingSharedStore: SharedGrantStore {
    func read(account email: String) throws -> SharedGrantRead { .missing }
    func save(_ grant: SharedGrant, account email: String) throws -> SharedGrantWrite { .written }
    func delete(account email: String) throws {}
    func allAccounts() throws -> [String] { [] }
}

private final class ForgetfulTokenStore: TokenStore {
    let inner: InMemoryTokenStore
    private let forgetting = Mutex(false)
    init(_ inner: InMemoryTokenStore) { self.inner = inner }
    func forget(_ on: Bool) { forgetting.withLock { $0 = on } }
    func load(account email: String) throws -> StoredToken? { try inner.load(account: email) }
    func save(_ token: StoredToken, account email: String) throws {
        if !forgetting.withLock({ $0 }) { try inner.save(token, account: email) }
    }
    func delete(account email: String) throws { try inner.delete(account: email) }
    func allAccounts() throws -> [String] { try inner.allAccounts() }
}

@Suite struct TokenSyncTests {
    private let email = "someone@example.com"

    private func manager(_ device: Device, _ transport: ScriptedTransport, _ clock: TestClock,
                         client: OAuthClientConfig = Synthetic.client, events: EventLog? = nil) -> TokenManager {
        TokenManager(account: email, store: device.store, client: client, transport: transport, clock: clock,
                     minimumValidity: .seconds(300), retryWaits: [], onEvent: events?.sink)
    }

    private static let phoneDefault = OAuthClientConfig(
        clientID: "9999-synthetic-phone.apps.googleusercontent.com", clientSecret: nil,
        authURI: Synthetic.client.authURI, tokenURI: Synthetic.client.tokenURI)

    @Test func aSignInIsSharedByDefaultWithItsClientAndThisDeviceKeepsItsOwnCopy() throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-mac", access: "access-mac",
                                           expiry: clock.now.addingTimeInterval(3600)), account: " Someone@Example.com")
        #expect(cloud.peek(email) == SharedGrant(refreshToken: "refresh-mac", clientID: Synthetic.clientID,
                                                 grantedScopes: [GmailScope.readonly], version: 1))
        let encoded = String(decoding: try JSONEncoder().encode(try #require(cloud.peek(email))), as: UTF8.self)
        #expect(!encoded.contains("access"), "the shared copy never carries an access token")
        #expect(try mac.local.load(account: email)?.refreshToken == "refresh-mac", "this device's own copy is kept")
        let loaded = try #require(try mac.store.load(account: email))
        #expect(loaded.accessToken == "access-mac" && loaded.clientID == Synthetic.clientID)
        #expect(try mac.store.syncState(account: email) == .syncing)
        #expect(try mac.records.load(account: email)?.wrote == tokenFingerprint("refresh-mac"))

        try mac.store.save(Synthetic.token(refresh: "refresh-mac-2"), account: email)
        #expect(cloud.peek(email)?.refreshToken == "refresh-mac-2" && cloud.peek(email)?.version == 2)
    }

    @Test func aRefreshWithoutASignInWritesNothingBack() throws {
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        #expect(throws: TokenStoreError.missing) {
            try mac.store.saveRefreshed(Synthetic.token(refresh: "refresh-1"), account: email, refreshedWith: "refresh-1")
        }
        #expect(try mac.store.load(account: email) == nil)
        #expect(try mac.store.allAccounts().isEmpty)
    }

    @Test func aRefreshKeepsTheAccessTokenOnThisDeviceAndNeverWritesTheSharedCopy() async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-1", expiry: clock.now.addingTimeInterval(-1)), account: email)
        let writes = cloud.writeCount
        let google = endpoint("mac")
        #expect(try await manager(mac, google, clock).accessToken() == "mac-refresh-1")
        #expect(cloud.writeCount == writes, "a plain refresh never writes the shared copy")
        #expect(cloud.peek(email)?.version == 1)
        #expect(try mac.records.load(account: email)?.accessToken == "mac-refresh-1")
        #expect(try await manager(mac, google, clock).accessToken() == "mac-refresh-1")
        #expect(google.requests.count == 1)
    }

    @Test func anotherDeviceUsesTheSharedSignInWithOneRefreshAndNoRedirect() async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        let phone = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-mac"), account: email)
        #expect(try phone.store.sharedSignIns() == [email])

        let google = endpoint("phone")
        let credentials = AccountCredentials(store: phone.store, client: Self.phoneDefault, transport: google, clock: clock,
                                             minimumValidity: .seconds(300), retryWaits: [], onEvent: nil,
                                             knownClients: { [Self.phoneDefault, Synthetic.client] })
        #expect(try await credentials.useSharedSignIn(email) == [GmailScope.readonly])
        #expect(google.requests.count == 1, "one refresh and nothing else: no consent page, no redirect")
        let request = try #require(google.requests.first)
        #expect(request.method == "POST" && request.url == Synthetic.client.tokenURI)
        let fields = formFields(request.body)
        #expect(fields["grant_type"] == "refresh_token" && fields["refresh_token"] == "refresh-mac")
        #expect(fields["client_id"] == Synthetic.clientID && fields["client_secret"] == Synthetic.clientSecret,
                "the client the shared copy names, from the synced client config")
        #expect(fields["code"] == nil && fields["redirect_uri"] == nil)
        #expect(try phone.local.load(account: email) == nil, "the phone keeps no refresh token of its own")
        #expect(try phone.records.load(account: email)?.accessToken == "phone-refresh-mac")
        #expect(try await credentials.tokenManager(for: email).accessToken() == "phone-refresh-mac")
        #expect(google.requests.count == 1)
    }

    @Test func aDeviceWithoutTheIssuingClientNeverSendsTheSharedToken() async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        try Device(cloud: cloud).store.save(Synthetic.token(refresh: "refresh-mac"), account: email)
        let phone = Device(cloud: cloud)
        let google = endpoint()
        let credentials = AccountCredentials(store: phone.store, client: Self.phoneDefault, transport: google, clock: clock,
                                             minimumValidity: .seconds(300), retryWaits: [], onEvent: nil,
                                             knownClients: { [Self.phoneDefault] })
        await #expect(throws: OAuthError.reauthRequired) { _ = try await credentials.useSharedSignIn(email) }
        #expect(google.requests.isEmpty, "a refresh token is never sent with another client")
        #expect(await credentials.authState(for: email) == .needsReauth(.clientMismatch))
        #expect(cloud.peek(email)?.refreshToken == "refresh-mac")
    }

    @Test func launchMigrationSharesOwnSignInsOnlyWithSyncOnAndKeepsTheLocalCopies() throws {
        let cloud = InMemorySharedGrantStore()
        let local = InMemoryTokenStore(["a@example.com": Synthetic.token(refresh: "refresh-a"),
                                        "b@example.com": Synthetic.token(refresh: "refresh-b")])
        let device = Device(cloud: cloud, local: local)
        try device.records.save(TokenDeviceRecord(choice: .dontSync), account: "b@example.com")

        var first = TokenSyncMigrationReport()
        first.shared = 1
        first.stayLocal = 1
        #expect(device.store.migrateLocalSignIns() == first)
        #expect(cloud.peek("a@example.com") == SharedGrant(refreshToken: "refresh-a", clientID: Synthetic.clientID,
                                                           grantedScopes: [GmailScope.readonly], version: 1))
        #expect(cloud.peek("b@example.com") == nil, "Don't sync is respected")
        #expect(try local.load(account: "a@example.com")?.refreshToken == "refresh-a", "the working local token stays")
        #expect(try local.load(account: "b@example.com")?.refreshToken == "refresh-b")
        #expect(try device.store.syncState(account: "a@example.com") == .syncing)
        #expect(try device.store.syncState(account: "b@example.com") == .notSyncing)

        var again = TokenSyncMigrationReport()
        again.alreadyShared = 1
        again.stayLocal = 1
        #expect(device.store.migrateLocalSignIns() == again, "safe to run at every launch")
        #expect(cloud.writeCount == 1)
    }

    @Test func aMigrationThatCannotWriteOrReadBackKeepsTheLocalTokenAndTriesAgainNextLaunch() throws {
        let local = InMemoryTokenStore([email: Synthetic.token(refresh: "refresh-a")])
        let lying = Device(cloud: LyingSharedStore(), local: local)
        var skipped = TokenSyncMigrationReport()
        skipped.skipped = 1
        #expect(lying.store.migrateLocalSignIns() == skipped)
        #expect(try lying.records.load(account: email)?.wrote == nil)
        #expect(try local.load(account: email)?.refreshToken == "refresh-a")

        let cloud = InMemorySharedGrantStore()
        cloud.failWrites(true)
        let device = Device(cloud: cloud, local: local)
        #expect(device.store.migrateLocalSignIns() == skipped)
        #expect(try device.store.syncState(account: email) == .pending)
        #expect(try device.store.load(account: email)?.refreshToken == "refresh-a", "still signed in meanwhile")
        cloud.failWrites(false)
        #expect(device.store.migrateLocalSignIns().shared == 1)
        #expect(cloud.peek(email)?.refreshToken == "refresh-a")
    }

    @Test func aSignInIsSavedOnThisDeviceWhenTheSharedCopyCannotBeRead() throws {
        let cloud = InMemorySharedGrantStore()
        cloud.failReads(true)
        let device = Device(cloud: cloud)
        try device.store.save(Synthetic.token(refresh: "refresh-here"), account: email)
        #expect(try device.local.load(account: email)?.refreshToken == "refresh-here", "this device's own copy first")
        #expect(try device.store.load(account: email)?.refreshToken == "refresh-here")
        #expect(try device.records.load(account: email)?.cannotSync == true)
        #expect(cloud.writeCount == 0)
    }

    @Test func aSignInIsSavedOnThisDeviceWhenTheSharedWriteFails() throws {
        let cloud = InMemorySharedGrantStore()
        cloud.deliver(SharedGrant(refreshToken: "refresh-older", clientID: Synthetic.clientID,
                                  grantedScopes: [GmailScope.readonly], version: 1), account: email)
        cloud.failWrites(true)
        let device = Device(cloud: cloud)
        try device.store.save(Synthetic.token(refresh: "refresh-new"), account: email)
        #expect(try device.store.load(account: email)?.refreshToken == "refresh-new",
                "never the older shared sign-in over this one")
        #expect(try device.store.syncState(account: email) == .ownSignInHere)
    }

    @Test func anUnreadableDeviceRecordNeverHidesThisDevicesSignIn() throws {
        let local = InMemoryTokenStore([email: Synthetic.token(refresh: "refresh-a")])
        let store = SyncedTokenStore(local: local, shared: InMemorySharedGrantStore(available: false),
                                     device: FailingRecords())
        #expect(try store.load(account: email)?.refreshToken == "refresh-a")
    }

    @Test func aSignInWhoseDeviceRecordCannotBeReadStaysOnThisDevice() throws {
        let cloud = InMemorySharedGrantStore()
        let records = UnreadableRecords()
        let store = SyncedTokenStore(local: InMemoryTokenStore(), shared: cloud, device: records)
        try store.save(Synthetic.token(refresh: "refresh-here"), account: email)
        #expect(cloud.writeCount == 0 && cloud.peek(email) == nil)
        #expect(records.saved?.choice == .dontSync)

        let unsaved = SyncedTokenStore(local: InMemoryTokenStore(), shared: cloud, device: FailingRecords())
        #expect(throws: TokenStoreError.keychain(-25308), "a choice that cannot be kept fails the sign-in") {
            try unsaved.save(Synthetic.token(refresh: "refresh-here"), account: email)
        }
        #expect(cloud.writeCount == 0)
    }

    @Test func aBuildThatCannotSyncKeepsEverySignInOnThisDevice() async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore(available: false)
        let mac = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-mac", expiry: clock.now.addingTimeInterval(-1)), account: email)
        #expect(cloud.peek(email) == nil)
        #expect(try mac.store.syncState(account: email) == .unavailable)
        #expect(try await manager(mac, endpoint("mac"), clock).accessToken() == "mac-refresh-mac")
        #expect(try mac.local.load(account: email)?.accessToken == "mac-refresh-mac", "refreshes as before")
        cloud.setAvailable(true)
        #expect(mac.store.migrateLocalSignIns().shared == 1)
        #expect(try mac.store.syncState(account: email) == .syncing)
    }

    @Test func aSharedCopyRemovedOnAnotherDeviceTurnsSyncOffHereAndIsNeverUploadedAgainOnItsOwn() throws {
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-mac"), account: email)
        cloud.deliver(nil, account: email)

        #expect(mac.store.migrateLocalSignIns().removedElsewhere == 1)
        #expect(cloud.peek(email) == nil)
        #expect(try mac.store.syncState(account: email) == .notSyncing)
        #expect(try mac.store.load(account: email)?.refreshToken == "refresh-mac", "this Mac keeps its own sign-in")
        #expect(mac.store.migrateLocalSignIns().stayLocal == 1)
        #expect(cloud.peek(email) == nil)
        #expect(try mac.store.setSyncEnabled(true, account: email) == .syncing)
        #expect(cloud.peek(email)?.refreshToken == "refresh-mac")
    }

    @Test(arguments: ["invalid_grant", "invalid_client", "unauthorized_client"])
    func aRefusalOnADeviceThatDidNotMintItAsksForASignInThereAndKeepsTheSharedCopy(_ code: String) async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        let phone = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-mac"), account: email)
        let phoneGoogle = endpoint("phone", refusing: ["refresh-mac"], error: code)
        let events = EventLog()
        let phoneTokens = manager(phone, phoneGoogle, clock, events: events)

        await #expect(throws: OAuthError.reauthRequired) { _ = try await phoneTokens.accessToken() }
        #expect(await phoneTokens.authState() == .needsReauth(.needsSignInHere))
        #expect(events.all == [.needsReauth(account: email, reason: .needsSignInHere)])
        #expect(cloud.peek(email)?.refreshToken == "refresh-mac", "never deleted: the Mac may still use it")
        #expect(try phone.store.syncState(account: email) == .needsSignInHere)
        #expect(try phone.store.load(account: email) == nil, "never used on this device again")
        await #expect(throws: OAuthError.reauthRequired) { _ = try await phoneTokens.accessToken(forceRefresh: true) }
        #expect(phoneGoogle.requests.count == 1, "sticky: Google is not asked again")

        #expect(try await manager(mac, endpoint("mac"), clock).accessToken() == "mac-refresh-mac")

        try await phoneTokens.adopt(Synthetic.token(refresh: "refresh-phone", access: "access-phone",
                                                    expiry: clock.now.addingTimeInterval(3600)))
        #expect(try await phoneTokens.accessToken() == "access-phone")
        #expect(cloud.peek(email)?.refreshToken == "refresh-mac")
        #expect(try phone.store.syncState(account: email) == .ownSignInHere)
        #expect(try mac.store.load(account: email)?.refreshToken == "refresh-mac")
    }

    @Test func aRefusalOfTheMintingDevicesOwnSignInIsTheUsualSignInAgainAndDeletesNothing() async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-mac"), account: email)
        let tokens = manager(mac, endpoint(refusing: ["refresh-mac"]), clock)
        await #expect(throws: OAuthError.reauthRequired) { _ = try await tokens.accessToken() }
        #expect(await tokens.authState() == .needsReauth(.invalidGrant))
        #expect(try cloud.peek(email) != nil && mac.local.load(account: email) != nil)
        try await tokens.adopt(Synthetic.token(refresh: "refresh-mac-2"))
        #expect(cloud.peek(email)?.refreshToken == "refresh-mac-2" && cloud.peek(email)?.version == 2)
    }

    @Test func aDeviceWithItsOwnSignInFallsBackToItWhenTheSharedOneIsRefused() async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-mac"), account: email)
        cloud.deliver(SharedGrant(refreshToken: "refresh-other", clientID: Synthetic.clientID,
                                  grantedScopes: [GmailScope.readonly], version: 2), account: email)
        let google = endpoint("mac", refusing: ["refresh-other"])
        let events = EventLog()
        #expect(try await manager(mac, google, clock, events: events).accessToken() == "mac-refresh-mac")
        #expect(events.all.isEmpty, "no sign-in asked for: this Mac's own sign-in still works")
        #expect(google.requests.map { formFields($0.body)["refresh_token"] } == ["refresh-other", "refresh-mac"])
        #expect(cloud.peek(email)?.refreshToken == "refresh-other", "the other device's copy is kept")
        #expect(try mac.store.syncState(account: email) == .ownSignInHere)
    }

    @Test func signingOutOnThisDeviceKeepsTheSharedSignInForTheOtherDevices() async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        let phone = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-mac"), account: email)
        _ = try await manager(phone, endpoint("phone"), clock).accessToken()
        let macTokens = manager(mac, endpoint("mac"), clock)
        _ = try await macTokens.accessToken()

        try await macTokens.signOut()
        #expect(try mac.local.load(account: email) == nil && mac.records.load(account: email) == nil)
        #expect(cloud.peek(email)?.refreshToken == "refresh-mac", "the shared copy stays")
        #expect(try phone.store.load(account: email)?.refreshToken == "refresh-mac")
        #expect(try await manager(phone, endpoint("phone"), clock).accessToken(forceRefresh: true) == "phone-refresh-mac")
        #expect(mac.store.migrateLocalSignIns() == TokenSyncMigrationReport(), "nothing of its own to share again")
        #expect(cloud.peek(email)?.version == 1)
    }

    @Test func removingTheSharedSignInRemovesItThisDevicesCopyAndItsRecord() async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        let phone = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-mac"), account: email)
        _ = try await manager(phone, endpoint("phone"), clock).accessToken()

        try mac.store.deleteEverywhere(account: " Someone@Example.com")
        #expect(cloud.peek(email) == nil)
        #expect(try mac.local.load(account: email) == nil && mac.records.load(account: email) == nil)
        #expect(try phone.store.load(account: email) == nil, "the phone had no sign-in of its own")
        #expect(try mac.store.allAccounts().isEmpty)
    }

    @Test func aRefreshWithABroaderGrantRemovesTheSharedCopyToo() async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-mac", expiry: clock.now.addingTimeInterval(-1)), account: email)
        let broader = ScriptedTransport { _ in
            jsonResponse(200, ["access_token": "broader-access", "expires_in": 3600, "token_type": "Bearer",
                               "scope": "\(GmailScope.readonly) https://mail.google.com/"])
        }
        let tokens = manager(mac, broader, clock)
        await #expect(throws: OAuthError.reauthRequired) { _ = try await tokens.accessToken() }
        #expect(await tokens.authState() == .needsReauth(.broaderGrant))
        #expect(cloud.peek(email) == nil, "a broader grant is kept nowhere")
        #expect(try mac.local.load(account: email) == nil && mac.store.load(account: email) == nil)
    }

    @Test func syncThroughICloudKeychainIsReportedOnlyWhileASharedSignInIsReadableHere() throws {
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        #expect(!mac.store.syncsThroughICloudKeychain(), "nothing shared yet")
        try mac.store.save(Synthetic.token(refresh: "refresh-mac"), account: email)
        #expect(mac.store.syncsThroughICloudKeychain())
        #expect(try mac.store.setSyncEnabled(false, account: email) == .notSyncing)
        #expect(!mac.store.syncsThroughICloudKeychain(), "Don't sync removed the only shared copy")

        let unsigned = Device(cloud: InMemorySharedGrantStore(available: false))
        try unsigned.store.save(Synthetic.token(refresh: "refresh-unsigned"), account: email)
        #expect(try unsigned.store.syncState(account: email) == .unavailable)
        #expect(!unsigned.store.syncsThroughICloudKeychain(), "a build that cannot hold synchronizable items")

        let failing = InMemorySharedGrantStore()
        let other = Device(cloud: failing)
        try other.store.save(Synthetic.token(refresh: "refresh-other"), account: email)
        failing.failReads(true)
        #expect(!other.store.syncsThroughICloudKeychain(), "a shared copy that can't be read doesn't count")
    }

    @Test func dontSyncKeepsALocalOnlyCopyFirstThenRemovesTheSharedOne() async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        let phone = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-mac"), account: email)
        _ = try await manager(phone, endpoint("phone"), clock).accessToken()

        #expect(try phone.store.setSyncEnabled(false, account: email) == .notSyncing)
        #expect(try phone.local.load(account: email)?.refreshToken == "refresh-mac")
        #expect(cloud.peek(email) == nil)
        #expect(try await manager(phone, endpoint("phone"), clock).accessToken() == "phone-refresh-mac")
        #expect(try mac.store.load(account: email)?.refreshToken == "refresh-mac")
        #expect(mac.store.migrateLocalSignIns().removedElsewhere == 1)
        #expect(try mac.store.setSyncEnabled(true, account: email) == .syncing)
        #expect(cloud.peek(email)?.refreshToken == "refresh-mac")
        #expect(try phone.store.syncState(account: email) == .notSyncing)
    }

    @Test func dontSyncNeverRemovesTheSharedCopyBeforeTheLocalOneReadsBack() throws {
        let cloud = InMemorySharedGrantStore()
        let forgetful = ForgetfulTokenStore(InMemoryTokenStore())
        let store = SyncedTokenStore(local: forgetful, shared: cloud, device: InMemoryTokenDeviceStore())
        try SyncedTokenStore(local: InMemoryTokenStore(), shared: cloud, device: InMemoryTokenDeviceStore())
            .save(Synthetic.token(refresh: "refresh-mac"), account: email)
        forgetful.forget(true)
        #expect(throws: TokenStoreError.corrupt) { try store.setSyncEnabled(false, account: email) }
        #expect(cloud.peek(email)?.refreshToken == "refresh-mac", "the working shared copy stays")
        #expect(try store.syncState(account: email) == .syncing)
    }

    @Test func twoDevicesRefreshingAtOnceNeverOverwriteEachOther() async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        let phone = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-1"), account: email)
        let gate = Gate()
        let macGoogle = endpoint("mac", hold: gate)
        let phoneGoogle = endpoint("phone", hold: gate)
        let macTokens = manager(mac, macGoogle, clock)
        let phoneTokens = manager(phone, phoneGoogle, clock)
        async let fromMac = macTokens.accessToken()
        async let fromPhone = phoneTokens.accessToken()
        #expect(await eventually { macGoogle.requests.count == 1 && phoneGoogle.requests.count == 1 })
        gate.open()
        #expect(try await fromMac == "mac-refresh-1")
        #expect(try await fromPhone == "phone-refresh-1")
        #expect(cloud.writeCount == 1 && cloud.peek(email)?.version == 1, "only the sign-in wrote the shared copy")
        #expect(try mac.records.load(account: email)?.accessToken == "mac-refresh-1")
        #expect(try phone.records.load(account: email)?.accessToken == "phone-refresh-1")
        #expect(try await manager(mac, macGoogle, clock).accessToken() == "mac-refresh-1")
        #expect(try await manager(phone, phoneGoogle, clock).accessToken() == "phone-refresh-1")
    }

    @Test func aRotatedRefreshTokenIsWrittenOnceOverTheCopyThatWasUsedWithTheNextVersion() async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        let phone = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-1"), account: email)
        #expect(try await manager(phone, endpoint("phone", rotate: ["refresh-1": "refresh-2"]), clock).accessToken()
                == "phone-refresh-1")
        #expect(cloud.peek(email) == SharedGrant(refreshToken: "refresh-2", clientID: Synthetic.clientID,
                                                 grantedScopes: [GmailScope.readonly], version: 2))
        #expect(cloud.writeCount == 2)
        #expect(try phone.records.load(account: email)?.wrote == tokenFingerprint("refresh-2"))
        let macGoogle = endpoint("mac")
        #expect(try await manager(mac, macGoogle, clock).accessToken() == "mac-refresh-2")
    }

    @Test func whenTwoDevicesRotateAtOnceTheFirstWriteStaysAndTheOtherKeepsIt() async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        let phone = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-1"), account: email)
        let macGate = Gate()
        let phoneGate = Gate()
        let macGoogle = endpoint("mac", rotate: ["refresh-1": "refresh-mac"], hold: macGate)
        let phoneGoogle = endpoint("phone", rotate: ["refresh-1": "refresh-phone"], hold: phoneGate)
        let macTokens = manager(mac, macGoogle, clock)
        let phoneTokens = manager(phone, phoneGoogle, clock)
        async let fromMac = macTokens.accessToken()
        async let fromPhone = phoneTokens.accessToken()
        #expect(await eventually { macGoogle.requests.count == 1 && phoneGoogle.requests.count == 1 })
        macGate.open()
        #expect(try await fromMac == "mac-refresh-1")
        #expect(cloud.peek(email)?.refreshToken == "refresh-mac" && cloud.peek(email)?.version == 2)
        phoneGate.open()
        #expect(try await fromPhone == "phone-refresh-1")
        #expect(cloud.peek(email)?.refreshToken == "refresh-mac" && cloud.peek(email)?.version == 2,
                "the later rotation never overwrites the newer copy")
        #expect(cloud.writeCount == 2)
    }

    @Test func aRefusalAfterAnotherDeviceRotatedTheTokenRetriesOnceWithTheNewOne() async throws {
        let clock = TestClock()
        let cloud = InMemorySharedGrantStore()
        let mac = Device(cloud: cloud)
        let phone = Device(cloud: cloud)
        try mac.store.save(Synthetic.token(refresh: "refresh-1"), account: email)
        let rotated = SharedGrant(refreshToken: "refresh-2", clientID: Synthetic.clientID,
                                  grantedScopes: [GmailScope.readonly], version: 2)
        let google = endpoint("phone", refusing: ["refresh-1"], before: { refresh in
            if refresh == "refresh-1" { cloud.deliver(rotated, account: "someone@example.com") }
        })
        let events = EventLog()
        #expect(try await manager(phone, google, clock, events: events).accessToken() == "phone-refresh-2")
        #expect(google.requests.count == 2)
        #expect(events.all.isEmpty)
        #expect(cloud.peek(email) == rotated)
        #expect(try phone.store.syncState(account: email) == .syncing)
    }

    @Test func tokenSyncLogsNoAccountTokenOrFingerprint() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = ["Sources/OpenHumanGmail/Auth/SyncedTokenStore.swift",
                     "Sources/OpenHumanGmail/Auth/TokenSyncStores.swift",
                     "Sources/OpenHumanGmailApple/KeychainTokenSync.swift"]
        var statements = 0
        for file in files {
            let lines = try String(contentsOf: package.appendingPathComponent(file), encoding: .utf8)
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("Log(") {
                statements += 1
                var text = line
                var depth = line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
                var next = index + 1
                while depth > 0, next < lines.count {
                    text += lines[next]
                    depth += lines[next].filter { $0 == "(" }.count - lines[next].filter { $0 == ")" }.count
                    next += 1
                }
                let pieces = text.components(separatedBy: "\\(").dropFirst()
                #expect(pieces.allSatisfy { $0.hasPrefix("report.") || $0.hasPrefix("Self.code(error))") },
                        "\(file):\(index + 1) interpolates a value")
            }
        }
        #expect(statements >= 6)
    }

    @Test func anErrorIsLoggedAsItsCodeOnly() {
        #expect(SyncedTokenStore.code(TokenStoreError.keychain(-34018)) == "OSStatus -34018")
        #expect(SyncedTokenStore.code(TokenStoreError.io("a path that must not be logged")) == "TokenStoreError")
        #expect(SyncedTokenStore.code(TokenStoreError.corrupt) == "TokenStoreError")
    }
}

private struct FailingRecords: TokenDeviceRecordStore {
    func load(account email: String) throws -> TokenDeviceRecord? { throw TokenStoreError.keychain(-25308) }
    func save(_ record: TokenDeviceRecord, account email: String) throws { throw TokenStoreError.keychain(-25308) }
    func delete(account email: String) throws { throw TokenStoreError.keychain(-25308) }
}

private final class UnreadableRecords: TokenDeviceRecordStore {
    private let record = Mutex<TokenDeviceRecord?>(nil)
    var saved: TokenDeviceRecord? { record.withLock { $0 } }
    func load(account email: String) throws -> TokenDeviceRecord? { throw TokenStoreError.keychain(-25308) }
    func save(_ record: TokenDeviceRecord, account email: String) throws { self.record.withLock { $0 = record } }
    func delete(account email: String) throws { record.withLock { $0 = nil } }
}
