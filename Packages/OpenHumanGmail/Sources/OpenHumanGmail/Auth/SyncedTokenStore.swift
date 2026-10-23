import Foundation
import OpenHumanCore
import Synchronization

public protocol SharedTokenStore: TokenStore {
    func saveRefreshed(_ token: StoredToken, account email: String, refreshedWith refreshToken: String) throws
    func sharedTokenRefused(account email: String, refreshToken: String) throws -> SharedRefusal
    func deleteEverywhere(account email: String) throws
}

public enum SharedRefusal: Sendable, Equatable {
    case notShared
    case replaced
    case refusedHere
}

public enum TokenSyncState: String, Sendable, Equatable {
    case syncing
    case pending
    case notSyncing
    case unavailable
    case ownSignInHere
    case needsSignInHere
}

public enum TokenSyncError: Error, Equatable, Sendable {
    case nothingToKeep
    case nothingToShare
}

public struct TokenSyncMigrationReport: Sendable, Equatable {
    public var shared = 0
    public var alreadyShared = 0
    public var removedElsewhere = 0
    public var stayLocal = 0
    public var skipped = 0

    public init() {}
}

public final class SyncedTokenStore: SharedTokenStore {
    public let local: any TokenStore
    public let shared: any SharedGrantStore
    public let device: any TokenDeviceRecordStore
    public let log: CredentialChainLog
    private let gates = Mutex<[String: AccountGate]>([:])

    private final class AccountGate: @unchecked Sendable { let lock = NSLock() }

    // Why: one account's Keychain dialog must not hold up another account's sign-in
    private func exclusively<R>(_ key: String, _ body: () throws -> R) rethrows -> R {
        let gate = gates.withLock { all -> AccountGate in
            if let existing = all[key] { return existing }
            let made = AccountGate()
            all[key] = made
            return made
        }
        gate.lock.lock()
        defer { gate.lock.unlock() }
        return try body()
    }

    public init(local: any TokenStore, shared: any SharedGrantStore, device: any TokenDeviceRecordStore,
                log: CredentialChainLog = .shared) {
        self.local = local
        self.shared = shared
        self.device = device
        self.log = log
    }

    private enum Source: Equatable { case nothing, local, shared(SharedGrant) }

    private struct Resolved {
        var token: StoredToken?
        var source: Source
        var record: TokenDeviceRecord
        var own: StoredToken?
        var read: SharedGrantRead?
    }

    private func resolve(_ key: String) throws -> Resolved {
        // This device's own sign-in must not depend on the record or the shared copy being readable
        let record = (try? device.load(account: key)) ?? TokenDeviceRecord()
        let own = try local.load(account: key)
        guard record.choice == nil else {
            return Resolved(token: own, source: own == nil ? .nothing : .local, record: record, own: own, read: nil)
        }
        let read = (try? shared.read(account: key)) ?? .unavailable
        if case .found(let grant) = read, grant.isUsable, tokenFingerprint(grant.refreshToken) != record.refused {
            var token = StoredToken(refreshToken: grant.refreshToken, grantedScopes: grant.grantedScopes,
                                    clientID: grant.clientID)
            if record.accessFor == tokenFingerprint(grant.refreshToken), let access = record.accessToken {
                token.accessToken = access
                token.accessTokenExpiry = record.accessTokenExpiry
            } else if let own, own.refreshToken == grant.refreshToken, own.clientID == grant.clientID {
                token.accessToken = own.accessToken
                token.accessTokenExpiry = own.accessTokenExpiry
            }
            return Resolved(token: token, source: .shared(grant), record: record, own: own, read: read)
        }
        return Resolved(token: own, source: own == nil ? .nothing : .local, record: record, own: own, read: read)
    }

    private static func dropAccess(_ record: inout TokenDeviceRecord) {
        record.accessToken = nil
        record.accessTokenExpiry = nil
        record.accessFor = nil
    }

    public func load(account email: String) throws -> StoredToken? {
        let key = try normalizedAccount(email)
        return try exclusively(key) { try resolve(key).token }
    }

    public func save(_ token: StoredToken, account email: String) throws {
        let key = try normalizedAccount(email)
        try exclusively(key) { try saveSignIn(token, key) }
    }

    // Write this device's own copy first; failing to share it must not fail the sign-in
    private func saveSignIn(_ token: StoredToken, _ key: String) throws {
        do { try local.save(token, account: key) } catch {
            KeychainDiagnostics.shared.record(.tokenLocalWrite, Self.status(error))
            Log(.keychain).error("sign-in: this device's own copy could not be written (\(Self.code(error)))")
            throw error
        }
        KeychainDiagnostics.shared.record(.tokenLocalWrite, 0)
        var record: TokenDeviceRecord
        do { record = try device.load(account: key) ?? TokenDeviceRecord() } catch {
            Log(.keychain).error("sign-in: this device's record could not be read (\(Self.code(error))); "
                                 + "the sign-in stays on this device")
            record = TokenDeviceRecord(choice: .dontSync)
        }
        if record.choice == nil {
            do {
                try share(token, key, &record)
            } catch {
                Log(.keychain).error("sign-in: the iCloud Keychain copy could not be written (\(Self.code(error))); "
                                     + "the sign-in stays on this device")
                if case .found(let grant)? = try? shared.read(account: key), grant.refreshToken != token.refreshToken {
                    record.choice = .ownSignIn
                } else {
                    record.cannotSync = true
                }
            }
        }
        Self.dropAccess(&record)
        do { try device.save(record, account: key) } catch {
            KeychainDiagnostics.shared.record(.tokenDeviceRecord, Self.status(error))
            Log(.keychain).error("sign-in: this device's record could not be saved (\(Self.code(error)))")
            if record.choice != nil || record.cannotSync == true { throw error }
        }
    }

    private func share(_ token: StoredToken, _ key: String, _ record: inout TokenDeviceRecord) throws {
        let read = try shared.read(account: key)
        switch read {
        case .found(let grant) where tokenFingerprint(grant.refreshToken) == record.refused:
            record.choice = .ownSignIn
            Log(.oauth).notice("a sign-in made after a shared one was refused here stays on this device")
        case .unavailable:
            record.cannotSync = true
        case .found(let grant) where grant.refreshToken == token.refreshToken && grant.clientID == token.clientID
            && grant.grantedScopes == token.grantedScopes:
            break
        case .found, .missing:
            var version = 1
            if case .found(let grant) = read { version = grant.version + 1 }
            let next = SharedGrant(refreshToken: token.refreshToken, clientID: token.clientID,
                                   grantedScopes: token.grantedScopes, version: version)
            switch try shared.save(next, account: key) {
            case .written:
                guard case .found(let back) = try shared.read(account: key), back == next else {
                    throw TokenStoreError.corrupt
                }
                record.wrote = tokenFingerprint(token.refreshToken)
                record.refused = nil
                record.cannotSync = nil
                Log(.oauth).notice("a sign-in was shared through iCloud Keychain")
            case .unavailable:
                if case .found = read {
                    record.choice = .ownSignIn
                } else {
                    record.cannotSync = true
                }
            }
        }
    }

    static func status(_ error: any Error) -> Int32 {
        if case TokenStoreError.keychain(let status) = error { return status }
        return -1
    }

    static func code(_ error: any Error) -> String {
        if case TokenStoreError.keychain(let status) = error { return "OSStatus \(status)" }
        return String(describing: type(of: error))
    }

    public func delete(account email: String) throws {
        let key = try normalizedAccount(email)
        try exclusively(key) {
            try local.delete(account: key)
            try device.delete(account: key)
        }
    }

    public func deleteEverywhere(account email: String) throws {
        let key = try normalizedAccount(email)
        try exclusively(key) {
            try shared.delete(account: key)
            try local.delete(account: key)
            try device.delete(account: key)
        }
    }

    public func allAccounts() throws -> [String] {
        let own = try local.allAccounts()
        let shared = (try? self.shared.allAccounts()) ?? []
        return Array(Set((own + shared).compactMap { try? normalizedAccount($0) })).sorted()
    }

    public func saveRefreshed(_ token: StoredToken, account email: String, refreshedWith used: String) throws {
        let key = try normalizedAccount(email)
        try exclusively(key) {
            let now = try resolve(key)
            // Why: the sign-in was removed while the refresh was out; a refresh never recreates it
            guard now.token != nil else { throw TokenStoreError.missing }
            guard case .shared(let grant) = now.source else {
                try local.save(token, account: key)
                return
            }
            guard grant.refreshToken == used else {
                Log(.oauth).notice("the shared sign-in changed during a refresh; the newer shared copy is kept")
                return
            }
            var record = now.record
            let rotated = token.refreshToken != used
            if rotated || token.grantedScopes != grant.grantedScopes {
                let next = SharedGrant(refreshToken: token.refreshToken, clientID: grant.clientID,
                                       grantedScopes: token.grantedScopes, version: grant.version + 1)
                var confirmed = false
                if (try? shared.save(next, account: key)) == .written,
                   case .found(let back)? = try? shared.read(account: key), back == next {
                    confirmed = true
                }
                if rotated {
                    log.record(.writeBack, confirmed ? .ok : .keptLocal,
                               subject: CredentialChainLog.subject(account: key))
                }
                if confirmed, rotated { record.wrote = tokenFingerprint(token.refreshToken) }
                if !confirmed, rotated {
                    // Never lose a rotated refresh token: keep it on this device in case the shared one is refused
                    try local.save(token, account: key)
                    Log(.oauth).error("a rotated refresh token could not be shared; it is kept on this device")
                }
            }
            if let own = now.own, own.refreshToken == used {
                try local.save(token, account: key)
            }
            record.accessToken = token.accessToken
            record.accessTokenExpiry = token.accessTokenExpiry
            record.accessFor = tokenFingerprint(token.refreshToken)
            try device.save(record, account: key)
        }
    }

    public func sharedTokenRefused(account email: String, refreshToken: String) throws -> SharedRefusal {
        let key = try normalizedAccount(email)
        return try exclusively(key) {
            let now = try resolve(key)
            guard let current = now.token else { return .notShared }
            if current.refreshToken != refreshToken { return .replaced }
            guard case .shared = now.source else { return .notShared }
            let print = tokenFingerprint(refreshToken)
            var record = now.record
            if let own = now.own, own.refreshToken != refreshToken {
                record.refused = print
                Self.dropAccess(&record)
                try device.save(record, account: key)
                Log(.oauth).notice("a shared sign-in was refused here; this device's own sign-in is used")
                return .replaced
            }
            if record.wrote == print { return .notShared }
            record.refused = print
            Self.dropAccess(&record)
            try device.save(record, account: key)
            Log(.oauth).notice("a sign-in shared from another device was refused here; the shared copy is kept")
            return .refusedHere
        }
    }

    public func syncState(account email: String) throws -> TokenSyncState? {
        let key = try normalizedAccount(email)
        return try exclusively(key) {
            let now = try resolve(key)
            switch now.record.choice {
            case .dontSync?: return now.own == nil ? nil : .notSyncing
            case .ownSignIn?: return now.own == nil ? nil : .ownSignInHere
            case nil: break
            }
            switch now.read {
            case .found(let grant)?:
                guard tokenFingerprint(grant.refreshToken) == now.record.refused else { return .syncing }
                return now.own == nil ? .needsSignInHere : .ownSignInHere
            case .unavailable?:
                return now.own == nil ? nil : .unavailable
            case .missing?, nil:
                guard now.own != nil else { return nil }
                return now.record.cannotSync == true ? .unavailable : .pending
            }
        }
    }

    @discardableResult
    public func setSyncEnabled(_ enabled: Bool, account email: String) throws -> TokenSyncState? {
        let key = try normalizedAccount(email)
        try exclusively(key) {
            let now = try resolve(key)
            var record = now.record
            if !enabled {
                guard let token = now.token else { throw TokenSyncError.nothingToKeep }
                try local.save(token, account: key)
                guard let back = try local.load(account: key), back.refreshToken == token.refreshToken,
                      back.clientID == token.clientID else { throw TokenStoreError.corrupt }
                if case .found(let grant) = try shared.read(account: key), grant.refreshToken == token.refreshToken {
                    try shared.delete(account: key)
                }
                record.choice = .dontSync
                record.wrote = nil
                record.cannotSync = nil
                Self.dropAccess(&record)
                try device.save(record, account: key)
                Log(.oauth).notice("a sign-in now stays on this device; its shared copy was removed")
                return
            }
            guard let own = now.own else {
                guard now.token != nil else { throw TokenSyncError.nothingToShare }
                record.choice = nil
                try device.save(record, account: key)
                return
            }
            let read = try shared.read(account: key)
            switch read {
            case .unavailable:
                record.cannotSync = true
            case .found(let grant) where grant.refreshToken == own.refreshToken && grant.clientID == own.clientID:
                record.wrote = tokenFingerprint(own.refreshToken)
                record.cannotSync = nil
            case .found, .missing:
                var version = 1
                if case .found(let grant) = read { version = grant.version + 1 }
                let next = SharedGrant(refreshToken: own.refreshToken, clientID: own.clientID,
                                       grantedScopes: own.grantedScopes, version: version)
                switch try shared.save(next, account: key) {
                case .written:
                    guard case .found(let back) = try shared.read(account: key), back == next else {
                        throw TokenStoreError.corrupt
                    }
                    record.wrote = tokenFingerprint(own.refreshToken)
                    record.cannotSync = nil
                case .unavailable:
                    record.cannotSync = true
                }
            }
            record.choice = nil
            record.refused = nil
            try device.save(record, account: key)
            Log(.oauth).notice("a sign-in is shared through iCloud Keychain again")
        }
        return try syncState(account: key)
    }

    public func syncsThroughICloudKeychain() -> Bool {
        let accounts = (try? shared.allAccounts()) ?? []
        return accounts.contains { account in
            if case .found? = try? shared.read(account: account) { return true }
            return false
        }
    }

    @discardableResult
    public func migrateLocalSignIns() -> TokenSyncMigrationReport {
        guard shared.canHoldSharedCopies else {
            log.record(.entitlement, .noEntitlement)
            return TokenSyncMigrationReport()
        }
        var report = TokenSyncMigrationReport()
        let accounts = (try? local.allAccounts()) ?? []
        for account in accounts {
            guard let key = try? normalizedAccount(account) else { continue }
            let outcome: Outcome
            do {
                outcome = try exclusively(key) { try migrate(key) }
            } catch {
                outcome = .skipped(Self.outcome(error))
            }
            let subject = CredentialChainLog.subject(account: key)
            switch outcome {
            case .shared: report.shared += 1
            case .alreadyShared: report.alreadyShared += 1
            case .removedElsewhere:
                report.removedElsewhere += 1
                log.record(.shareSignIn, .removedElsewhere, subject: subject)
            case .stayLocal(let why):
                report.stayLocal += 1
                log.record(.shareSignIn, why, subject: subject)
            case .skipped(let why):
                report.skipped += 1
                log.record(.shareSignIn, why, subject: subject)
            }
        }
        if report != TokenSyncMigrationReport() {
            Log(.oauth).notice("token sync at launch: \(report.shared) shared, \(report.alreadyShared) already shared, "
                               + "\(report.removedElsewhere) removed on another device, \(report.stayLocal) on this "
                               + "device only, \(report.skipped) left for the next launch")
        }
        return report
    }

    private enum Outcome {
        case shared, alreadyShared, removedElsewhere
        case stayLocal(CredentialOutcome)
        case skipped(CredentialOutcome)
    }

    static func outcome(_ error: any Error) -> CredentialOutcome {
        if case TokenStoreError.keychain(let status) = error { return .keychain(status: status) }
        return .unreadable
    }

    private func migrate(_ key: String) throws -> Outcome {
        var record = try device.load(account: key) ?? TokenDeviceRecord()
        guard record.choice == nil else { return .stayLocal(.keptLocal) }
        guard let own = try local.load(account: key) else { return .skipped(.noItem) }
        let print = tokenFingerprint(own.refreshToken)
        switch try shared.read(account: key) {
        case .unavailable:
            if record.cannotSync != true {
                record.cannotSync = true
                try device.save(record, account: key)
            }
            return .stayLocal(.noEntitlement)
        case .found(let grant):
            if tokenFingerprint(grant.refreshToken) == print, record.wrote == nil {
                record.wrote = print
                try device.save(record, account: key)
            }
            return .alreadyShared
        case .missing:
            if record.wrote == print {
                record.choice = .dontSync
                record.wrote = nil
                Self.dropAccess(&record)
                try device.save(record, account: key)
                return .removedElsewhere
            }
            let next = SharedGrant(refreshToken: own.refreshToken, clientID: own.clientID,
                                   grantedScopes: own.grantedScopes, version: 1)
            switch try shared.save(next, account: key) {
            case .written:
                guard case .found(let back) = try shared.read(account: key), back == next else {
                    return .skipped(.unreadable)
                }
                record.wrote = print
                record.cannotSync = nil
                try device.save(record, account: key)
                return .shared
            case .unavailable:
                record.cannotSync = true
                try device.save(record, account: key)
                return .stayLocal(.noEntitlement)
            }
        }
    }

    public func setSource(_ source: CredentialSource?, account email: String) throws {
        let key = try normalizedAccount(email)
        try exclusively(key) {
            var record = try device.load(account: key) ?? TokenDeviceRecord()
            guard record.source != source else { return }
            record.source = source
            try device.save(record, account: key)
        }
    }

    public func sharedSignIns() throws -> [String] {
        try shared.allAccounts().compactMap { account -> String? in
            guard let key = try? normalizedAccount(account) else { return nil }
            let now = try exclusively(key) { try resolve(key) }
            if case .shared = now.source { return key }
            return nil
        }
    }
}
