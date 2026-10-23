import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore
import OpenHumanSync
import Synchronization

public struct KeychainDiagnosticsReport: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var subject: String
        public var local: Bool
        public var synced: Bool
        public var file: Bool
    }
    public var entries: [Entry]
    public var lastStatus: String
}

public final class LiveAccountManager: AccountManaging {
    public struct Dependencies: Sendable {
        var environment: [String: String]
        var storeDirectory: URL
        var clientStore: any OAuthClientStore = InMemoryOAuthClientStore()
        var tokenStore: any TokenStore
        var transport: any HTTPTransport
        var makeReceiver: @Sendable () -> any LoopbackRedirectReceiver
        var browser: any ExternalBrowser
        var clock: any OHClock
        var signInTimeout: Duration = .seconds(300)
        var remoteSignInTimeout: Duration = .seconds(600)
        var calendarTokenStore: (any TokenStore)? = nil
        var developerClientFile: @Sendable ([String: String]) -> String? = { _ in nil }
        var credentialAccess: (any CredentialAccess)? = nil

        public init(environment: [String: String], storeDirectory: URL, clientStore: any OAuthClientStore = InMemoryOAuthClientStore(),
                    tokenStore: any TokenStore, transport: any HTTPTransport,
                    makeReceiver: @escaping @Sendable () -> any LoopbackRedirectReceiver, browser: any ExternalBrowser,
                    clock: any OHClock, signInTimeout: Duration = .seconds(300), remoteSignInTimeout: Duration = .seconds(600),
                    calendarTokenStore: (any TokenStore)? = nil,
                    developerClientFile: @escaping @Sendable ([String: String]) -> String? = { _ in nil },
                    credentialAccess: (any CredentialAccess)? = nil) {
            self.environment = environment
            self.storeDirectory = storeDirectory
            self.clientStore = clientStore
            self.tokenStore = tokenStore
            self.transport = transport
            self.makeReceiver = makeReceiver
            self.browser = browser
            self.clock = clock
            self.signInTimeout = signInTimeout
            self.remoteSignInTimeout = remoteSignInTimeout
            self.calendarTokenStore = calendarTokenStore
            self.developerClientFile = developerClientFile
            self.credentialAccess = credentialAccess
        }
    }

    private struct PendingRemote {
        let flow: OAuthFlow
        let session: OAuthFlow.ManualAuthorization
        let expiresAt: Date
    }

    struct SessionLink: Sendable {
        let engine: MailEngine
        let forgetInWindow: @MainActor @Sendable (_ account: AccountID, _ email: String) async -> Void
        let removed: @MainActor @Sendable (AccountID) async -> Void
    }

    private let store: MailStore
    private let dependencies: Dependencies
    private let vault: OAuthClientVault
    private let pendingRemote = Mutex<PendingRemote?>(nil)
    private struct StatusWatcher {
        var continuation: AsyncStream<OAuthClientStatus>.Continuation
        var answered = false
    }
    private let watchers = Mutex<[UUID: StatusWatcher]>([:])
    private let migrated = Mutex(false)
    private let link = Mutex<SessionLink?>(nil)
    private let selectedClientKey = Mutex<String?>(nil)
    private let clientList = Mutex<[OAuthClientConfig]?>(nil)

    static var clientKeySetting: SettingKey<String?> {
        SettingKey(name: "oauth.client_key", defaultValue: nil, isSafetyKey: false)
    }

    init(store: MailStore, dependencies: Dependencies, migrateNow: Bool = true) {
        self.store = store
        self.dependencies = dependencies
        vault = OAuthClientVault(store: dependencies.clientStore, storeDirectory: dependencies.storeDirectory)
        if migrateNow { runLaunchMigrations() }
    }

    func runLaunchMigrations() {
        let first = migrated.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return }
        vault.migrateLegacyFiles()
        (dependencies.tokenStore as? SyncedTokenStore)?.migrateLocalSignIns()
        vault.migrateSyncWanted()
    }

    func attach(_ session: SessionLink?) {
        link.withLock { $0 = session }
    }

    private var session: SessionLink? { link.withLock { $0 } }

    private var developerClientFile: String? { dependencies.developerClientFile(dependencies.environment) }

    private func makeFlow(_ client: OAuthClientConfig) -> OAuthFlow {
        OAuthFlow(client: client, scopes: OAuthScopes.mailRequest, transport: dependencies.transport,
                  receiver: dependencies.makeReceiver(), browser: dependencies.browser, clock: dependencies.clock)
    }

    func loadClient() throws(AccountSetupError) -> OAuthClientConfig {
        do {
            return try vault.loadDefault(clientFile: developerClientFile)
        } catch let OAuthError.configurationMissing(why) {
            throw Self.clientMissingError(why)
        } catch {
            throw Self.clientMissingError(nil)
        }
    }

    func knownClients() -> [OAuthClientConfig] {
        if let cached = clientList.withLock({ $0 }) { return cached }
        let fresh = vault.available(clientFile: developerClientFile)
        clientList.withLock { $0 = fresh }
        return fresh
    }

    func forgetKnownClients() { clientList.withLock { $0 = nil } }

    private func selectedClient() -> OAuthClientConfig? {
        guard let key = selectedClientKey.withLock({ $0 }) else { return nil }
        return knownClients().first { $0.registryKey == key }
    }

    func signInClient() throws(AccountSetupError) -> OAuthClientConfig {
        if let chosen = selectedClient() { return chosen }
        return try loadClient()
    }

    func ownClient(email: String, account: AccountID?) -> OAuthClientConfig? {
        let known = knownClients()
        if let minted = (try? dependencies.tokenStore.load(account: AccountCredentials.accountKey(email)))?.clientID,
           let match = known.first(where: { $0.clientID == minted }) {
            return match
        }
        if let account, let recorded = try? store.setting(Self.clientKeySetting, scope: .account(account)),
           let match = known.first(where: { $0.registryKey == recorded }) {
            return match
        }
        return nil
    }

    func client(for account: AccountItem) throws(AccountSetupError) -> OAuthClientConfig {
        if let own = ownClient(email: account.email, account: account.id) { return own }
        return try loadClient()
    }

    static var calendarClientKeySetting: SettingKey<String?> {
        SettingKey(name: "calendar.client_key", defaultValue: nil, isSafetyKey: false)
    }
    static var calendarScopesSetting: SettingKey<[String]?> {
        SettingKey(name: "calendar.requested_scopes", defaultValue: nil, isSafetyKey: false)
    }

    private func accountID(email: String) -> AccountID? {
        let key = AccountCredentials.accountKey(email)
        return (try? store.accounts())?.first { AccountCredentials.accountKey($0.email) == key }?.id
    }

    func recordCalendarConnect(email: String, clientID: String, requested: [String]) {
        guard let account = accountID(email: email) else { return }
        do {
            try store.setSetting(Self.calendarClientKeySetting, OAuthClientConfig.registryKey(clientID: clientID),
                                 scope: .account(account))
            try store.setSetting(Self.calendarScopesSetting, requested, scope: .account(account))
        } catch {
            Log(.oauth).error("account \(account.rawValue): its calendar record was not saved (\(String(describing: type(of: error))))")
        }
    }

    func calendarPinnedScopes(email: String) -> [String]? {
        guard let account = accountID(email: email) else { return nil }
        return (try? store.setting(Self.calendarScopesSetting, scope: .account(account))) ?? nil
    }

    func calendarLogLabel(email: String) -> String {
        accountID(email: email).map { "account \($0.rawValue)" } ?? "an account"
    }

    func signedInAccounts() -> [(id: AccountID, email: String)] {
        ((try? store.accounts()) ?? []).filter { $0.status != .removing && $0.status != .disabled }
            .map { (id: $0.id, email: $0.email) }
    }

    func calendarClientKey(email: String) -> String? {
        guard let account = accountID(email: email) else { return nil }
        return (try? store.setting(Self.calendarClientKeySetting, scope: .account(account))) ?? nil
    }

    private func recordClient(_ clientID: String, for account: AccountID) {
        do {
            try store.setSetting(Self.clientKeySetting, OAuthClientConfig.registryKey(clientID: clientID),
                                 scope: .account(account))
        } catch {
            Log(.oauth).error("account \(account.rawValue): its OAuth client was not recorded (\(String(describing: type(of: error))))")
        }
    }

    private func publishClientStatus() {
        let status = currentClientStatus()
        watchers.withLock { all in
            for id in Array(all.keys) {
                all[id]?.answered = true
                all[id]?.continuation.yield(status)
            }
        }
    }

    private func answerFirst(_ id: UUID) {
        let status = currentClientStatus()
        watchers.withLock { all in
            guard let watcher = all[id], !watcher.answered else { return }
            all[id]?.answered = true
            watcher.continuation.yield(status)
        }
    }

    func currentClientStatus() -> OAuthClientStatus {
        let main = try? vault.loadDefault(clientFile: developerClientFile)
        if let chosen = selectedClient(), chosen.clientID != main?.clientID {
            return chosen.hasClientSecret ? .configured(source: .file) : .configuredWithoutSecret(source: .file)
        }
        let withoutSecret = main.map { !$0.hasClientSecret } ?? false
        switch vault.source(clientFile: developerClientFile) {
        case .missing: return .missing
        case .environment: return withoutSecret ? .configuredWithoutSecret(source: .environment) : .configured(source: .environment)
        case .storeFile: return withoutSecret ? .configuredWithoutSecret(source: .file) : .configured(source: .file)
        }
    }

    // Why: the first status reads the Keychain, which must never happen on the caller's (main) thread
    public func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<OAuthClientStatus>.makeStream()
        watchers.withLock { $0[id] = StatusWatcher(continuation: continuation) }
        continuation.onTermination = { [weak self] _ in _ = self?.watchers.withLock { $0.removeValue(forKey: id) } }
        Task.detached(priority: .userInitiated) { [weak self] in self?.answerFirst(id) }
        return stream
    }

    public func importOAuthClient(json: Data) async throws {
        let imported: OAuthClientVault.ImportResult
        do {
            imported = try vault.importClientReporting(json)
        } catch let OAuthError.configurationMissing(why) {
            Log(.oauth).notice("OAuth client import refused: \(why)")
            throw AccountSetupError(.clientMissing, "That file isn't a Google sign-in client file. Download the Desktop "
                + "client .json from Google Cloud Console and import that.")
        } catch let failure as OAuthClientSaveError {
            throw AccountSetupError(.failed, Self.clientNotSaved(failure))
        }
        lastImportSync.withLock { $0 = imported.sync }
        clientList.withLock { $0 = nil }
        selectedClientKey.withLock { $0 = imported.config.registryKey }
        publishClientStatus()
    }

    private let lastImportSync = Mutex<OAuthClientSyncState?>(nil)

    static let clientNotSyncedNote = "Couldn't sync this client to iCloud. It's saved on this Mac, so you can sign in."

    public func oauthClientImportNote() async -> String? {
        lastImportSync.withLock { $0 } == .unavailable ? Self.clientNotSyncedNote : nil
    }

    public func keychainDiagnostics() -> KeychainDiagnosticsReport {
        var entries: [KeychainDiagnosticsReport.Entry] = []
        let stored = vault.stored()
        let files = Set(vault.legacyFileClients().map(\.registryKey))
        var keys = Set(stored.map(\.config.registryKey)).union(files)
        for client in knownClients() { keys.insert(client.registryKey) }
        for key in keys.sorted() {
            let entry = stored.first { $0.config.registryKey == key }
            entries.append(.init(subject: "client \(key.prefix(8))", local: entry?.isLocal == true,
                                 synced: entry?.sync == .syncing, file: files.contains(key)))
        }
        let accounts = ((try? store.accounts()) ?? []).filter { $0.status != .removing }
        for (offset, item) in accounts.enumerated() {
            let key = AccountCredentials.accountKey(item.email)
            var local = false
            var synced = false
            if let sync = tokenSync {
                local = (try? sync.local.load(account: key)) != nil
                if case .found? = try? sync.shared.read(account: key) { synced = true }
            } else {
                local = (try? dependencies.tokenStore.load(account: key)) != nil
            }
            entries.append(.init(subject: "account \(offset + 1)", local: local, synced: synced, file: false))
        }
        return KeychainDiagnosticsReport(entries: entries, lastStatus: KeychainDiagnostics.shared.summary())
    }

    static func clientNotSaved(_ failure: OAuthClientSaveError) -> String {
        let code = failure.status.map { " (Keychain error \($0))" } ?? ""
        return "Mail couldn't save this client in the Keychain on this Mac\(code). Quit and open Mail again, then "
            + "import the file again."
    }

    public func oauthClients() async -> [OAuthClientSummary] {
        let known = knownClients()
        let main = (try? vault.loadDefault(clientFile: developerClientFile))?.clientID
        let selected = selectedClient()?.clientID ?? main
        return known.map { client in
            OAuthClientSummary(id: client.registryKey, shortID: client.shortID, isDefault: client.clientID == main,
                               isSelected: client.clientID == selected, hasSecret: client.hasClientSecret)
        }
    }

    public func selectOAuthClient(_ id: OAuthClientSummary.ID?) async throws {
        if let id, !knownClients().contains(where: { $0.registryKey == id }) {
            throw AccountSetupError(.clientMissing, "That sign-in client is no longer on this Mac. Import its file again.")
        }
        selectedClientKey.withLock { $0 = id }
        publishClientStatus()
    }

    public func oauthClientShortID(for account: AccountID) async -> String? {
        guard let item = try? store.accounts().first(where: { $0.id == account }) else { return nil }
        if let own = ownClient(email: item.email, account: item.id) { return own.shortID }
        return (try? dependencies.tokenStore.load(account: AccountCredentials.accountKey(item.email)))
            .map { OAuthClientConfig.shortID(clientID: $0.clientID) }
    }

    public func oauthClientUsage() async -> [OAuthClientUsage] {
        let summaries = await oauthClients()
        var accountsByKey: [String: [AccountID]] = [:]
        var calendarsByKey: [String: [AccountID]] = [:]
        for item in (try? store.accounts()) ?? [] {
            if let key = accountClientKey(item) { accountsByKey[key, default: []].append(item.id) }
            if let key = calendarClientKeyInUse(item) { calendarsByKey[key, default: []].append(item.id) }
        }
        return summaries.map { summary in
            let entry = vault.entry(key: summary.id)
            return OAuthClientUsage(client: summary, importedAt: entry?.modifiedAt,
                                    accounts: accountsByKey[summary.id] ?? [], calendars: calendarsByKey[summary.id] ?? [],
                                    sync: entry.map { Self.sync($0.sync) })
        }
    }

    private func accountClientKey(_ item: AccountItem) -> String? {
        if let minted = (try? dependencies.tokenStore.load(account: AccountCredentials.accountKey(item.email)))?.clientID {
            return OAuthClientConfig.registryKey(clientID: minted)
        }
        return (try? store.setting(Self.clientKeySetting, scope: .account(item.id))) ?? nil
    }

    private func calendarClientKeyInUse(_ item: AccountItem) -> String? {
        guard let calendarTokens = dependencies.calendarTokenStore else {
            return (try? store.setting(Self.calendarClientKeySetting, scope: .account(item.id))) ?? nil
        }
        let minted = (try? calendarTokens.load(account: AccountCredentials.accountKey(item.email)))?.clientID
        return minted.map { OAuthClientConfig.registryKey(clientID: $0) }
    }

    private static func sync(_ state: OAuthClientSyncState) -> OAuthClientSync {
        switch state {
        case .syncing: .syncing
        case .notSyncing: .notSyncing
        case .unavailable: .unavailable
        }
    }

    public func setOAuthClientSync(_ id: OAuthClientSummary.ID, enabled: Bool) async throws {
        guard knownClients().contains(where: { $0.registryKey == id }), vault.entry(key: id) != nil else {
            throw AccountSetupError(.failed, "That sign-in client isn't stored on this Mac.")
        }
        do {
            try vault.setSynchronizable(key: id, enabled)
        } catch {
            Log(.oauth).error("a client's iCloud Keychain setting was not changed")
            throw AccountSetupError(.failed, "Mail couldn't change that setting in the Keychain. Try again.")
        }
        clientList.withLock { $0 = nil }
    }

    private var tokenSync: SyncedTokenStore? { dependencies.tokenStore as? SyncedTokenStore }

    public func signInSync(for account: AccountID) async -> SignInSync? {
        guard let tokenSync, let item = try? store.accounts().first(where: { $0.id == account }),
              let state = try? tokenSync.syncState(account: item.email) else { return nil }
        return Self.signInSync(state)
    }

    static func signInSync(_ state: TokenSyncState) -> SignInSync {
        switch state {
        case .syncing: .syncing
        case .pending: .pending
        case .notSyncing: .notSyncing
        case .unavailable: .unavailable
        case .ownSignInHere: .ownSignInHere
        case .needsSignInHere: .needsSignInHere
        }
    }

    public func setSignInSync(_ account: AccountID, enabled: Bool) async throws {
        guard let tokenSync, let item = try? store.accounts().first(where: { $0.id == account }) else {
            throw AccountSetupError(.failed, "That account's sign-in isn't stored on this Mac.")
        }
        do {
            try tokenSync.setSyncEnabled(enabled, account: item.email)
        } catch TokenSyncError.nothingToKeep, TokenSyncError.nothingToShare {
            throw AccountSetupError(.failed, "This Mac has no sign-in of its own for that account. Sign in again first.")
        } catch {
            Log(.oauth).error("account \(account.rawValue): its sign-in's iCloud Keychain setting was not changed "
                              + "(\(String(describing: type(of: error))))")
            throw AccountSetupError(.failed, "Mail couldn't change that setting in the Keychain. Try again.")
        }
    }

    public func signInsSyncThroughICloudKeychain() async -> Bool {
        guard let tokenSync else { return false }
        return tokenSync.syncsThroughICloudKeychain() || vault.stored().contains { $0.sync == .syncing }
    }

    public func sharedSignIns() async -> [String] {
        guard let tokenSync, let shared = try? tokenSync.sharedSignIns() else { return [] }
        let here = Set(((try? store.accounts()) ?? []).map { AccountCredentials.accountKey($0.email) })
        return shared.filter { !here.contains($0) }
    }

    public func useSharedSignIn(email: String) async throws -> AccountID {
        let key = AccountCredentials.accountKey(email)
        guard session == nil else {
            throw AccountSetupError(.failed, "Quit and reopen Mail, then use the sign-in from your other device.")
        }
        guard let tokenSync, (try? tokenSync.sharedSignIns())?.contains(key) == true,
              let shared = try? tokenSync.load(account: key) else {
            throw AccountSetupError(.failed, "There's no sign-in from your other devices for that account here.")
        }
        guard let client = knownClients().first(where: { $0.clientID == shared.clientID }) else {
            throw AccountSetupError(.clientMissing, "The Google sign-in client from your other device isn't on this "
                + "device yet. Check that iCloud Keychain is on, then try again.")
        }
        let credentials = AccountCredentials(store: tokenSync, client: client, transport: dependencies.transport,
                                             clock: dependencies.clock)
        let scopes: [String]
        do {
            scopes = try await credentials.useSharedSignIn(key)
        } catch OAuthError.reauthRequired {
            throw AccountSetupError(.failed, "The sign-in from your other device didn't work here. Sign in on this "
                + "device instead.")
        } catch {
            throw Self.setupError(error, step: .refreshing)
        }
        try refuseUnsafeGrant(scopes)
        do {
            let id = try store.addAccount(email: key, displayName: nil, scopes: scopes)
            recordClient(client.clientID, for: id)
            Log(.oauth).notice("account \(id.rawValue) uses a sign-in shared from another device (no browser)")
            return id
        } catch {
            Log(.oauth).error("could not store the account (\(String(describing: type(of: error))))")
            throw AccountSetupError(.failed, "Mail could not save the account. Try again.")
        }
    }

    public func removeOAuthClient(_ id: OAuthClientSummary.ID) async throws {
        guard let usage = await oauthClientUsage().first(where: { $0.id == id }) else {
            throw AccountSetupError(.failed, "That sign-in client is no longer on this Mac.")
        }
        var emails: [AccountID: String] = [:]
        for item in (try? store.accounts()) ?? [] { emails[item.id] = item.email }
        if let reason = usage.removalRefusal(emails: emails) {
            throw AccountSetupError(.refused, reason)
        }
        do {
            try vault.remove(key: id)
        } catch {
            Log(.oauth).error("a stored OAuth client was not removed")
            throw AccountSetupError(.failed, "Mail couldn't remove that client from the Keychain. Try again.")
        }
        clientList.withLock { $0 = nil }
        selectedClientKey.withLock { if $0 == id { $0 = nil } }
        publishClientStatus()
    }

    public func inspectOAuthClientFile(_ json: Data, replacing id: OAuthClientSummary.ID) async throws
        -> OAuthClientReplacement {
        let parsed = try Self.inspectedClient(json)
        return parsed.registryKey == id ? .sameClient : .differentClient(id: parsed.registryKey, shortID: parsed.shortID)
    }

    public func replaceOAuthClient(_ id: OAuthClientSummary.ID, json: Data) async throws {
        let parsed = try Self.inspectedClient(json)
        guard knownClients().contains(where: { $0.registryKey == id }) else {
            throw AccountSetupError(.failed, "That sign-in client is no longer on this Mac.")
        }
        guard parsed.registryKey == id else {
            throw AccountSetupError(.refused, "That file is for another client (…\(parsed.shortID)). Nothing was changed.")
        }
        do {
            _ = try vault.importClient(json)
        } catch let failure as OAuthClientSaveError {
            throw AccountSetupError(.failed, Self.clientNotSaved(failure))
        } catch {
            throw AccountSetupError(.clientMissing, Self.notAClientFile)
        }
        clientList.withLock { $0 = nil }
        publishClientStatus()
    }

    public func moveAccount(_ account: AccountID, toOAuthClient id: OAuthClientSummary.ID) async throws {
        guard let item = try? store.accounts().first(where: { $0.id == account }) else {
            throw AccountSetupError(.failed, "That account is no longer on this Mac.")
        }
        guard let client = knownClients().first(where: { $0.registryKey == id }) else {
            throw AccountSetupError(.clientMissing, "That sign-in client is no longer on this Mac. Import its file again.")
        }
        if let session {
            do {
                try await session.engine.reauthorize(account, using: makeFlow(client))
            } catch {
                throw Self.setupError(error)
            }
            try discardBroaderGrant(email: item.email)
            recordClient(client.clientID, for: account)
        } else {
            let flow = makeFlow(client)
            let result: OAuthResult
            do {
                result = try await flow.authorize(loginHint: item.email, timeout: dependencies.signInTimeout)
            } catch {
                throw Self.setupError(error)
            }
            guard AccountCredentials.accountKey(result.email) == AccountCredentials.accountKey(item.email) else {
                throw Self.setupError(OAuthError.denied("account_mismatch"))
            }
            try refuseUnsafeGrant(result.token.grantedScopes)
            do {
                try dependencies.tokenStore.save(result.token, account: result.email)
            } catch {
                throw AccountSetupError(.failed, "Signed in, but Mail could not save the account. Try again.")
            }
            recordClient(result.token.clientID, for: account)
        }
        Log(.oauth).notice("account \(account.rawValue) signed in again with another OAuth client")
    }

    static let notAClientFile = "That file isn't a Google sign-in client file. Download the Desktop client .json from "
        + "Google Cloud Console and import that."

    private static func inspectedClient(_ json: Data) throws -> OAuthClientConfig {
        do {
            return try OAuthClientConfig.inspectImport(json)
        } catch let OAuthError.configurationMissing(why) {
            Log(.oauth).notice("OAuth client file refused: \(why)")
            throw AccountSetupError(.clientMissing, notAClientFile)
        } catch {
            throw AccountSetupError(.clientMissing, notAClientFile)
        }
    }

    public func addAccount(loginHint: String?) async throws -> AccountID {
        let client = try signInClient()
        if let session {
            let item: AccountItem
            do {
                item = try await session.engine.addAccount(using: makeFlow(client),
                                                           loginHint: loginHint)
            } catch {
                throw Self.setupError(error)
            }
            try discardBroaderGrant(email: item.email)
            recordClient(client.clientID, for: item.id)
            Log(.oauth).notice("account \(item.id.rawValue) signed in while Mail runs")
            return item.id
        }
        let flow = makeFlow(client)
        let result: OAuthResult
        do {
            result = try await flow.authorize(loginHint: loginHint, timeout: dependencies.signInTimeout)
        } catch {
            throw Self.setupError(error)
        }
        return try finishSignIn(result)
    }

    private func finishSignIn(_ result: OAuthResult) throws -> AccountID {
        try refuseUnsafeGrant(result.token.grantedScopes)
        do {
            try dependencies.tokenStore.save(result.token, account: result.email)
            let id = try store.addAccount(email: result.email, displayName: nil, scopes: result.token.grantedScopes)
            recordClient(result.token.clientID, for: id)
            Log(.oauth).notice("account \(id.rawValue) signed in")
            return id
        } catch {
            Log(.oauth).error("could not store the new account (\(String(describing: type(of: error))))")
            throw AccountSetupError(.failed, "Signed in, but Mail could not save the account. Try again.")
        }
    }

    private func refuseUnsafeGrant(_ scopes: [String]) throws {
        if LiveBackend.scopeRefusal(scopes) != nil {
            Log(.oauth).error("sign-in refused: the token carries a scope broader than gmail.modify")
            throw AccountSetupError(.refused, Self.broaderThanModify)
        }
    }

    public func reauthorize(_ account: AccountID) async throws {
        guard let session else {
            throw AccountSetupError(.failed, "Quit and reopen Mail to sign in again.")
        }
        let item = try? store.accounts().first(where: { $0.id == account })
        let client = try item.flatMap { ownClient(email: $0.email, account: $0.id) } ?? signInClient()
        do {
            try await session.engine.reauthorize(account, using: makeFlow(client))
        } catch {
            throw Self.setupError(error)
        }
        if let item {
            try discardBroaderGrant(email: item.email)
            recordClient(client.clientID, for: account)
        }
    }

    private func discardBroaderGrant(email: String) throws {
        let key = AccountCredentials.accountKey(email)
        guard let token = try? dependencies.tokenStore.load(account: key),
              LiveBackend.scopeRefusal(token.grantedScopes) != nil else { return }
        if let tokenSync {
            try? tokenSync.deleteEverywhere(account: key)
        } else {
            try? dependencies.tokenStore.delete(account: key)
        }
        Log(.oauth).error("sign-in refused after the fact: the token carries a scope broader than gmail.modify")
        throw AccountSetupError(.refused, Self.broaderThanModify)
    }

    public func setAlias(_ account: AccountID, _ alias: String?) async throws {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            try store.setAccountAlias(account, trimmed.isEmpty ? nil : trimmed)
        } catch {
            throw AccountSetupError(.failed, "Mail couldn't save the short name. Try again.")
        }
    }

    public func remove(_ account: AccountID) async throws {
        try await remove(account, includingSharedSignIn: false)
    }

    public func removeIncludingSharedSignIn(_ account: AccountID) async throws {
        try await remove(account, includingSharedSignIn: true)
    }

    private func remove(_ account: AccountID, includingSharedSignIn: Bool) async throws {
        guard let item = try? store.accounts().first(where: { $0.id == account }) else {
            throw AccountSetupError(.failed, "That account is no longer on this Mac.")
        }
        if includingSharedSignIn, let tokenSync {
            do {
                try tokenSync.deleteEverywhere(account: AccountCredentials.accountKey(item.email))
            } catch {
                Log(.oauth).error("account \(account.rawValue): the shared sign-in was not removed "
                                  + "(\(String(describing: type(of: error))))")
                throw AccountSetupError(.failed, "Mail couldn't remove the shared sign-in from iCloud Keychain. Try again.")
            }
        }
        let session = self.session
        Log(.oauth).notice("account \(account.rawValue): signing out locally")
        do {
            // Why: delete the calendar token first so a failed delete leaves the account in place and sign-out can be retried
            try dependencies.calendarTokenStore?.delete(account: AccountCredentials.accountKey(item.email))
            if let session { try await session.engine.removeAccount(account) }
            try deleteTokens(email: item.email)
            if try store.accounts().contains(where: { $0.id == account }) {
                try store.removeAccountData(account) { _ in }
            }
        } catch {
            Log(.oauth).error("account \(account.rawValue): sign-out failed (\(String(describing: type(of: error))))")
            throw AccountSetupError(.failed, "Mail couldn't remove this account from this Mac. Try again.")
        }
        if let session { await session.forgetInWindow(account, item.email) }
        Log(.oauth).notice("account \(account.rawValue): signed out; local data removed, nothing changed in Gmail")
        if let session { await session.removed(account) }
    }

    private func deleteTokens(email: String) throws {
        let key = AccountCredentials.accountKey(email)
        try dependencies.tokenStore.delete(account: key)
        for stored in (try? dependencies.tokenStore.allAccounts()) ?? [] where AccountCredentials.accountKey(stored) == key {
            try dependencies.tokenStore.delete(account: stored)
        }
        try dependencies.calendarTokenStore?.delete(account: key)
    }

    public func beginRemoteSignIn(loginHint: String?) async throws -> RemoteSignInChallenge {
        let client = try signInClient()
        let flow = makeFlow(client)
        let session: OAuthFlow.ManualAuthorization
        do { session = try flow.beginManual(loginHint: loginHint) } catch { throw Self.setupError(error) }
        let expiresAt = dependencies.clock.now.addingTimeInterval(
            TimeInterval(dependencies.remoteSignInTimeout.components.seconds))
        pendingRemote.withLock { $0 = PendingRemote(flow: flow, session: session, expiresAt: expiresAt) }
        return RemoteSignInChallenge(url: session.url, expiresAt: expiresAt)
    }

    public func completeRemoteSignIn(pasted: String) async throws -> AccountID {
        guard let pending = pendingRemote.withLock({ $0 }) else {
            throw AccountSetupError(.failed, "There is no sign-in in progress. Start again.")
        }
        guard dependencies.clock.now < pending.expiresAt else {
            pendingRemote.withLock { $0 = nil }
            throw AccountSetupError(.failed, "That sign-in link expired. Start again.")
        }
        let result: OAuthResult
        do {
            result = try await pending.flow.completeManual(pasted: pasted, pending.session)
        } catch {
            let mapped = Self.remoteSetupError(error)
            if mapped.kind != .invalidPaste {
                let spent = pending.session.state
                pendingRemote.withLock { if $0?.session.state == spent { $0 = nil } }
            }
            throw mapped
        }
        let state = pending.session.state
        let cancelled = pendingRemote.withLock { current -> Bool in
            guard current?.session.state == state else { return true }
            current = nil
            return false
        }
        guard !cancelled, !Task.isCancelled else {
            throw AccountSetupError(.cancelled, "Sign-in was cancelled.")
        }
        return try finishSignIn(result)
    }

    public func cancelRemoteSignIn() async {
        pendingRemote.withLock { $0 = nil }
    }

    static func remoteSetupError(_ error: Error) -> AccountSetupError {
        if let oauth = error as? OAuthError {
            switch oauth {
            case .denied("manual_paste_not_a_redirect_url"):
                return AccountSetupError(.invalidPaste, "That isn't the full address. Copy the whole address from the "
                    + "browser's address bar (it starts with http://127.0.0.1); the code alone is not accepted.")
            case .denied("redirect_mismatch"), .denied("invalid_callback"), .denied("invalid_redirect_uri"):
                return AccountSetupError(.invalidPaste, "That address is not from this sign-in. Open the address shown "
                    + "above, approve, and copy the address the browser ends up on.")
            case .denied("missing_code"):
                return AccountSetupError(.invalidPaste, "That address has no code. Approve access first, then copy the "
                    + "address the browser ends up on.")
            case .stateMismatch:
                return AccountSetupError(.invalidPaste, "That address belongs to a different sign-in attempt. Use the "
                    + "address shown above, or start again.")
            case .tokenEndpoint(_, "invalid_grant", _):
                return AccountSetupError(.failed, "Google no longer accepts that code (already used or expired). "
                    + "Start again.")
            default:
                break
            }
        }
        return setupError(error)
    }

    static let broaderThanModify = "Google gave Mail more access than it asks for (such as full Gmail access), so Mail "
        + "stopped and saved nothing. Sign in again."

    static let clientMissing = "Mail can't find its Google sign-in client, so it can't sign in or sync. Import the client "
        + "file to continue."

    static func clientMissingError(_ why: String?) -> AccountSetupError {
        if let why { Log(.oauth).notice("no usable OAuth client: \(why)") }
        return AccountSetupError(.clientMissing, clientMissing)
    }

    static let mailWriteScopes: Set<String> = [
        "https://mail.google.com/", GmailScope.modify,
        "https://www.googleapis.com/auth/gmail.compose", "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.insert", "https://www.googleapis.com/auth/gmail.labels",
        "https://www.googleapis.com/auth/gmail.settings.basic", "https://www.googleapis.com/auth/gmail.settings.sharing",
    ]

    enum SignInStep: Sendable {
        case exchangingCode, refreshing, readingProfile
        var phrase: String {
            switch self {
            case .exchangingCode: return "while exchanging the code"
            case .refreshing: return "while refreshing"
            case .readingProfile: return "while reading the profile"
            }
        }
    }

    static func diagnostic(status: Int, code: String?, description: String?) -> String {
        var text = "HTTP \(status)"
        if let code, isOAuthCode(code) {
            text += ", \(code)"
            if let description = safeDescription(description) { text += ": \(description)" }
        }
        return text
    }

    private static func isOAuthCode(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.utf8.allSatisfy { (0x61...0x7A).contains($0) || $0 == 0x5F }
    }

    static func safeDescription(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.count <= 120,
              text.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else { return nil }
        let lower = text.lowercased()
        if lower.contains("://") || lower.contains("www.") || lower.contains("http") { return nil }
        var run = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let opaque = (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
                || v == 0x2B || v == 0x2F || v == 0x3D || v == 0x5F || v == 0x2D || v == 0x2E
            run = opaque ? run + 1 : 0
            if run >= 20 { return nil }
        }
        return text
    }

    static func setupError(_ error: Error, step: SignInStep = .exchangingCode) -> AccountSetupError {
        switch error {
        case let setup as AccountSetupError:
            return setup
        case is CancellationError:
            return AccountSetupError(.cancelled, "Sign-in was cancelled.")
        case let oauth as OAuthError:
            switch oauth {
            case .cancelled:
                return AccountSetupError(.cancelled, "Sign-in was cancelled.")
            case .timedOut:
                return AccountSetupError(.failed, "Sign-in timed out. Try again.")
            case .stateMismatch:
                return AccountSetupError(.failed, "Google didn't return a valid response. Try again.")
            case .denied(let reason) where reason.hasPrefix("write sign-in refused"):
                return AccountSetupError(.refused, broaderThanModify)
            case .denied("access_denied"):
                return AccountSetupError(.cancelled, "Sign-in was cancelled in the browser.")
            case .denied("account_mismatch"):
                return AccountSetupError(.refused, "That was a different Google account. Sign in again with the "
                    + "account's own address. Nothing was stored.")
            case .denied("admin_policy_enforced"):
                return AccountSetupError(.refused, "Your organization's Google admin doesn't allow Mail to sign in.")
            case .denied(let reason):
                return AccountSetupError(.failed, "Google didn't finish the sign-in. Try again."
                    + "\nDetails: \(isOAuthCode(reason) ? reason : "unknown")")
            case .insufficientScopes(let missing) where missing.contains(GmailScope.modify):
                return AccountSetupError(.refused, "Google didn't give Mail permission to change your mail. Sign in "
                    + "again and allow it. Nothing was saved.\nDetails: add gmail.modify under Data access in Google Cloud.")
            case .insufficientScopes:
                return AccountSetupError(.refused, "Google didn't give Mail permission to read your mail. Sign in again "
                    + "and allow it.")
            case .reauthRequired:
                return AccountSetupError(.failed, "Google asked to sign in again. Try again.")
            case .tokenEndpoint(let status, let code, let description):
                return AccountSetupError(.failed, "Google refused the sign-in. Try again.\nDetails: \(step.phrase), "
                    + diagnostic(status: status, code: code, description: description))
            case .configurationMissing(let why):
                return clientMissingError(why)
            }
        case let gmail as GmailError:
            return AccountSetupError(.failed, "You signed in, but Gmail didn't answer. Try again in a moment."
                + "\nDetails: \(gmail.code)")
        case is TransportError:
            return AccountSetupError(.failed, "Couldn't reach Google. Check the connection and try again.")
        case let engine as EngineError:
            switch engine {
            case .writeAccessMissing:
                return AccountSetupError(.refused, LiveBackend.writeAccessNotice)
            case .oauthClientMissing:
                return clientMissingError(nil)
            case .requiresApp, .sendNotAllowed:
                return AccountSetupError(.failed, "Sign-in isn't available here.")
            }
        default:
            return AccountSetupError(.failed, "Sign-in failed. Try again.")
        }
    }
}
