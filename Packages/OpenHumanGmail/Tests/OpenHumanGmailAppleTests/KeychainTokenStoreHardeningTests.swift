import Foundation
import OpenHumanCore
import OpenHumanGmail
import Security
import Synchronization
import Testing
@testable import OpenHumanGmailApple

final class FakeKeychain: KeychainBackend {
    struct Item: Sendable, Equatable {
        var service: String
        var account: String
        var synchronizable: Bool
        var data: Data
    }
    private struct State {
        var items: [Item] = []
        var calls: [String] = []
        var queriesPinUnsynchronized = true
        var queriesPinLegacyKeychain = true
        var answer: Item?
        var status: OSStatus?
        var failingAdds: [OSStatus] = []
    }
    private let state = Mutex(State())

    var items: [Item] { state.withLock { $0.items } }
    var calls: [String] { state.withLock { $0.calls } }
    var everyQueryPinned: Bool { state.withLock { $0.queriesPinUnsynchronized && $0.queriesPinLegacyKeychain } }

    func plant(_ item: Item) { state.withLock { $0.items.append(item) } }
    func answerWith(_ item: Item?, status: OSStatus? = nil) { state.withLock { $0.answer = item; $0.status = status } }
    func failNextAdd(with status: OSStatus) { state.withLock { $0.failingAdds.append(status) } }

    private func record(_ name: String, _ query: [String: Any]) {
        let sync = (query[kSecAttrSynchronizable as String] as? Bool) == false
        let legacy = (query[kSecUseDataProtectionKeychain as String] as? Bool) == false
        state.withLock {
            $0.calls.append(name)
            $0.queriesPinUnsynchronized = $0.queriesPinUnsynchronized && sync
            $0.queriesPinLegacyKeychain = $0.queriesPinLegacyKeychain && legacy
        }
    }

    private func matches(_ item: Item, _ query: [String: Any]) -> Bool {
        if let service = query[kSecAttrService as String] as? String, service != item.service { return false }
        if let account = query[kSecAttrAccount as String] as? String, account != item.account { return false }
        let wantsSync = (query[kSecAttrSynchronizable as String] as? Bool) ?? false
        return wantsSync == item.synchronizable
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        record("add", attributes)
        if let failure = state.withLock({ $0.failingAdds.isEmpty ? nil : $0.failingAdds.removeFirst() }) { return failure }
        guard let data = attributes[kSecValueData as String] as? Data,
              let service = attributes[kSecAttrService as String] as? String,
              let account = attributes[kSecAttrAccount as String] as? String else { return errSecParam }
        let item = Item(service: service, account: account,
                        synchronizable: (attributes[kSecAttrSynchronizable as String] as? Bool) ?? false, data: data)
        return state.withLock { s in
            if s.items.contains(where: { $0.service == item.service && $0.account == item.account
                                           && $0.synchronizable == item.synchronizable }) { return errSecDuplicateItem }
            s.items.append(item)
            return errSecSuccess
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        record("copy", query)
        let (override, status, stored) = state.withLock { ($0.answer, $0.status, $0.items) }
        if let status, status != errSecSuccess { return (status, nil) }
        let found = override.map { [$0] } ?? stored.filter { matches($0, query) }
        if found.isEmpty { return (errSecItemNotFound, nil) }
        let wantsData = (query[kSecReturnData as String] as? Bool) == true
        func dictionary(_ item: Item) -> NSDictionary {
            var d: [String: Any] = [kSecAttrService as String: item.service, kSecAttrAccount as String: item.account,
                                    kSecAttrSynchronizable as String: item.synchronizable]
            if wantsData { d[kSecValueData as String] = item.data }
            return d as NSDictionary
        }
        if (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String) {
            return (errSecSuccess, found.map(dictionary) as NSArray)
        }
        return (errSecSuccess, dictionary(found[0]))
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        record("delete", query)
        return state.withLock { s in
            let before = s.items.count
            s.items.removeAll { matches($0, query) }
            return s.items.count < before ? errSecSuccess : errSecItemNotFound
        }
    }
}

@Suite struct KeychainTokenStoreHardeningTests {
    private let token = StoredToken(refreshToken: "synthetic-refresh", accessToken: "synthetic-access",
                                    accessTokenExpiry: Date(timeIntervalSince1970: 1_790_000_000),
                                    grantedScopes: [GmailScope.readonly], clientID: "synthetic.apps.example")
    private let service = OHIdentifiers.keychainService

    private func store(_ keychain: FakeKeychain, app: Bool = true) -> KeychainTokenStore {
        KeychainTokenStore(service: service, items: KeychainItems(backend: keychain), isAppProcess: { app })
    }

    @Test func roundTripPinsTheLegacyUnsynchronizedItem() throws {
        let keychain = FakeKeychain()
        let tokens = store(keychain)
        try tokens.save(token, account: "Me@Example.com")
        #expect(try tokens.load(account: "me@example.com") == token)
        #expect(try tokens.allAccounts() == ["me@example.com"])
        #expect(keychain.items.map(\.account) == ["me@example.com"])
        #expect(keychain.items.allSatisfy { !$0.synchronizable && $0.service == "dev.openhuman.mail.oauth.v1" })
        #expect(try store(keychain).load(account: "me@example.com")?.accessToken == nil)
        try tokens.delete(account: "ME@example.com")
        #expect(try tokens.load(account: "me@example.com") == nil)
        try tokens.delete(account: "me@example.com")
        #expect(keychain.everyQueryPinned)
    }

    @Test func saveReplacesAnExistingItemAndNeverUpdatesItInPlace() throws {
        let keychain = FakeKeychain()
        keychain.plant(.init(service: service, account: "me@example.com", synchronizable: false, data: Data("{}".utf8)))
        try store(keychain).save(token, account: "me@example.com")
        #expect(Array(keychain.calls.suffix(2)) == ["delete", "add"],
                "calls=\(keychain.calls.count), \(keychain.calls)")
        #expect(!keychain.calls.contains("update"))
        #expect(keychain.items.count == 1, "items=\(keychain.items.count), \(keychain.calls)")
        let stored = try JSONDecoder().decode(StoredToken.self, from: keychain.items[0].data)
        #expect(stored.refreshToken == token.refreshToken && stored.clientID == token.clientID
                && stored.grantedScopes == token.grantedScopes)
        #expect(stored.accessToken == nil && stored.accessTokenExpiry == nil)
    }

    @Test func aReplaceWhoseAddFailsPutsTheOldTokenBack() throws {
        let keychain = FakeKeychain()
        let tokens = store(keychain)
        try tokens.save(token, account: "me@example.com")
        #expect(try tokens.load(account: "me@example.com")?.refreshToken == token.refreshToken)
        var rotated = token
        rotated.refreshToken = "synthetic-refresh-rotated"
        keychain.failNextAdd(with: errSecInteractionNotAllowed)
        let before = keychain.calls.count
        #expect(throws: TokenStoreError.keychain(errSecInteractionNotAllowed)) {
            try tokens.save(rotated, account: "me@example.com")
        }
        #expect(Array(keychain.calls.dropFirst(before)) == ["delete", "add", "add"], "\(keychain.calls)")
        #expect(keychain.items.count == 1, "items=\(keychain.items.count), \(keychain.calls)")
        let kept = try JSONDecoder().decode(StoredToken.self, from: keychain.items[0].data)
        #expect(kept.refreshToken == token.refreshToken && kept.clientID == token.clientID)
        #expect(try store(keychain).load(account: "me@example.com")?.refreshToken == token.refreshToken)
        try tokens.save(rotated, account: "me@example.com")
        #expect(try store(keychain).load(account: "me@example.com")?.refreshToken == rotated.refreshToken)
    }

    @Test func aFailedReplaceOfAnyItemLeavesTheOldValueReadable() throws {
        let keychain = FakeKeychain()
        let items = KeychainItems(backend: keychain)
        let item = KeychainItems.Item(service: "com.example.items", account: "a")
        try items.write(item, data: Data("old".utf8), label: "Old", generic: Data("g".utf8))
        keychain.failNextAdd(with: errSecAuthFailed)
        #expect(throws: KeychainItemsError.status(errSecAuthFailed)) {
            try items.write(item, data: Data("new".utf8), label: "New")
        }
        #expect(keychain.items.map(\.data) == [Data("old".utf8)])
        #expect(try KeychainItems(backend: keychain).read(item)?.data == Data("old".utf8))
        #expect(try items.read(item)?.data == Data("old".utf8))
    }

    @Test func aSaveStillReplacesAnItemItCannotRead() throws {
        let keychain = FakeKeychain()
        keychain.plant(.init(service: service, account: "a@example.com", synchronizable: false,
                             data: Data("{}".utf8)))
        keychain.answerWith(nil, status: errSecInteractionNotAllowed)
        try store(keychain).save(token, account: "a@example.com")
        #expect(Array(keychain.calls.suffix(2)) == ["delete", "add"],
                "calls=\(keychain.calls.count), \(keychain.calls)")
        #expect(!keychain.calls.contains("update"))
        #expect(keychain.items.count == 1, "items=\(keychain.items.count), \(keychain.calls)")
        let item = try #require(keychain.items.first)
        let stored = try JSONDecoder().decode(StoredToken.self, from: item.data)
        #expect(stored.refreshToken == token.refreshToken && stored.clientID == token.clientID)
        #expect(keychain.everyQueryPinned)
    }

    @Test func anOlderTokenLoadsAndARefreshWritesNothing() throws {
        let keychain = FakeKeychain()
        keychain.plant(.init(service: service, account: "a@example.com", synchronizable: false,
                             data: try JSONEncoder().encode(token)))
        let tokens = store(keychain)
        #expect(try tokens.load(account: "a@example.com") == token)
        let before = keychain.calls.count
        var refreshed = token
        refreshed.accessToken = "synthetic-new-access"
        try tokens.save(refreshed, account: "a@example.com")
        let calls = Array(keychain.calls.dropFirst(before))
        #expect(calls.isEmpty, "calls=\(calls.count), \(calls)")
        #expect(try tokens.load(account: "a@example.com") == refreshed)
    }

    @Test func synchronizedItemsAreNeverReadWrittenOrDeleted() throws {
        let keychain = FakeKeychain()
        let synced = FakeKeychain.Item(service: service, account: "me@example.com", synchronizable: true,
                                       data: try JSONEncoder().encode(token))
        keychain.plant(synced)
        let tokens = store(keychain)
        #expect(try tokens.load(account: "me@example.com") == nil)
        #expect(try tokens.allAccounts().isEmpty)
        try tokens.delete(account: "me@example.com")
        #expect(keychain.items == [synced])
        try tokens.save(token, account: "me@example.com")
        #expect(keychain.items.filter { !$0.synchronizable }.count == 1)
        #expect(keychain.everyQueryPinned)
    }

    @Test func loadRefusesAnItemThatIsNotExactlyOurs() throws {
        let good = try JSONEncoder().encode(token)
        var emptyRefresh = token
        emptyRefresh.refreshToken = ""
        let cases: [(String, FakeKeychain.Item)] = [
            ("other service", .init(service: "com.example.other", account: "me@example.com", synchronizable: false, data: good)),
            ("other account", .init(service: service, account: "you@example.com", synchronizable: false, data: good)),
            ("synchronized", .init(service: service, account: "me@example.com", synchronizable: true, data: good)),
            ("not JSON", .init(service: service, account: "me@example.com", synchronizable: false, data: Data("x".utf8))),
            ("oversized", .init(service: service, account: "me@example.com", synchronizable: false,
                                data: Data(repeating: 0x20, count: 16 * 1024 + 1))),
            ("empty refresh token", .init(service: service, account: "me@example.com", synchronizable: false,
                                          data: try JSONEncoder().encode(emptyRefresh))),
        ]
        for (name, item) in cases {
            let keychain = FakeKeychain()
            keychain.answerWith(item)
            #expect(throws: TokenStoreError.corrupt, "\(name)") { _ = try store(keychain).load(account: "me@example.com") }
        }
    }

    @Test func saveRefusesTokensItCouldNotUseLater() {
        let keychain = FakeKeychain()
        var noRefresh = token
        noRefresh.refreshToken = ""
        var noClient = token
        noClient.clientID = ""
        var huge = token
        huge.accessToken = String(repeating: "a", count: 20 * 1024)
        for bad in [noRefresh, noClient, huge] {
            #expect(throws: TokenStoreError.corrupt) { try store(keychain).save(bad, account: "me@example.com") }
        }
        #expect(keychain.calls.isEmpty)
    }

    @Test func keychainFailuresArePassedOnAsStatusCodes() {
        let keychain = FakeKeychain()
        keychain.answerWith(nil, status: errSecInteractionNotAllowed)
        #expect(throws: TokenStoreError.keychain(errSecInteractionNotAllowed)) {
            _ = try store(keychain).load(account: "me@example.com")
        }
        #expect(throws: TokenStoreError.invalidAccount) { _ = try store(keychain).load(account: "  ") }
    }

    @Test func allAccountsKeepsOnlyWellFormedItemsOfOurs() throws {
        let keychain = FakeKeychain()
        let data = try JSONEncoder().encode(token)
        for (account, sync) in [("b@example.com", false), ("a@example.com", false), ("Mixed@Example.com", false),
                                ("c@example.com", true)] {
            keychain.plant(.init(service: service, account: account, synchronizable: sync, data: data))
        }
        keychain.plant(.init(service: "com.example.other", account: "z@example.com", synchronizable: false, data: data))
        #expect(try store(keychain).allAccounts() == ["a@example.com", "b@example.com"])
    }

    @Test func outsideAnAppBundleNothingReachesTheKeychain() throws {
        let keychain = FakeKeychain()
        let tokens = store(keychain, app: false)
        #expect(throws: TokenStoreError.notAppProcess) { _ = try tokens.load(account: "me@example.com") }
        #expect(throws: TokenStoreError.notAppProcess) { try tokens.save(token, account: "me@example.com") }
        #expect(throws: TokenStoreError.notAppProcess) { try tokens.delete(account: "me@example.com") }
        #expect(throws: TokenStoreError.notAppProcess) { _ = try tokens.allAccounts() }
        #expect(keychain.calls.isEmpty)
        #expect(!KeychainTokenStore.runningInAppBundle())
        #expect(throws: TokenStoreError.notAppProcess) { _ = try KeychainTokenStore().load(account: "me@example.com") }
    }
}
