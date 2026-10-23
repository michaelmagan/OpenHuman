import Foundation
import OpenHumanCore
import OpenHumanGmail
import Security
import Synchronization

public final class KeychainItems: Sendable {
    public enum QueryStyle: Sendable, Equatable {
        case macLegacy
        case dataProtection

        public static var platformDefault: QueryStyle {
            #if os(macOS)
            return .macLegacy
            #else
            return .dataProtection
            #endif
        }
    }

    public static let shared = KeychainItems(backend: SecItemBackend(),
                                             canHoldSynchronizableItems: entitledForSynchronizableItems(),
                                             style: .platformDefault)

    struct Item: Hashable, Sendable { var service: String; var account: String }

    struct Entry: Sendable, Equatable {
        var data: Data
        var modifiedAt: Date?
        var label: String? = nil
        var generic: Data? = nil
    }

    private enum Cached: Sendable { case absent; case present(Entry); case refused(OSStatus) }

    private final class Gate: @unchecked Sendable { let lock = NSRecursiveLock() }

    private struct State {
        var canSync: Bool
        var entries: [Item: Cached] = [:]
        var lists: [String: Set<String>] = [:]
        var values: [Item: any Sendable] = [:]
        var finished: Set<String> = []
        var gates: [String: Gate] = [:]
    }

    // Why: a short state lock only; a Keychain call waits on its own item's gate, so a prompt never blocks other items
    private let state: Mutex<State>

    let backend: any KeychainBackend

    public let style: QueryStyle

    init(backend: any KeychainBackend, canHoldSynchronizableItems: Bool = true, style: QueryStyle = .platformDefault) {
        self.backend = backend
        state = Mutex(State(canSync: canHoldSynchronizableItems))
        self.style = style
    }

    public var canHoldSynchronizableItems: Bool { state.withLock { $0.canSync } }

    func synchronizableRefused(_ status: OSStatus) {
        state.withLock { s in
            if status == errSecMissingEntitlement || status == errSecNotAvailable { s.canSync = false }
        }
    }

    private func gated<R>(_ key: String, _ body: () throws -> R) rethrows -> R {
        let gate = state.withLock { s -> Gate in
            if let existing = s.gates[key] { return existing }
            let made = Gate()
            s.gates[key] = made
            return made
        }
        gate.lock.lock()
        defer { gate.lock.unlock() }
        return try body()
    }

    func withItem<R>(_ item: Item, _ body: () throws -> R) rethrows -> R {
        try gated("item\n\(item.service)\n\(item.account)", body)
    }

    func once(_ key: String, _ body: () -> Void) {
        if state.withLock({ $0.finished.contains(key) }) { return }
        gated("once\n" + key) {
            guard !state.withLock({ $0.finished.contains(key) }) else { return }
            body()
            state.withLock { _ = $0.finished.insert(key) }
        }
    }

    static func outcome(_ status: OSStatus) -> CredentialOutcome {
        if status == errSecMissingEntitlement || status == errSecNotAvailable { return .noEntitlement }
        if status == errSecItemNotFound { return .noItem }
        return .keychain(status: status)
    }

    static func isRefusal(_ status: OSStatus) -> Bool { CredentialOutcome.keychainRefusals.contains(status) }

    static func listed(_ result: CFTypeRef?) -> [[String: Any]] {
        (result as? [[String: Any]]) ?? KeychainSharedGrantStore.single(result).map { [$0] } ?? []
    }

    func memory<T: Sendable>(_ item: Item, as type: T.Type) -> T? { state.withLock { $0.values[item] as? T } }

    func setMemory(_ item: Item, _ value: (any Sendable)?) { state.withLock { $0.values[item] = value } }

    var hasRefusals: Bool {
        state.withLock { s in s.entries.values.contains { if case .refused = $0 { true } else { false } } }
    }

    func forgetRefusals() {
        state.withLock { s in
            for (item, cached) in s.entries { if case .refused = cached { s.entries[item] = nil } }
        }
    }

    func query(service: String, account: String? = nil) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: style == .dataProtection]
        if let account { result[kSecAttrAccount as String] = account }
        return result
    }

    func addAttributes(_ item: Item, data: Data, label: String, generic: Data? = nil) -> [String: Any] {
        var attributes = query(service: item.service, account: item.account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = label
        if let generic { attributes[kSecAttrGeneric as String] = generic }
        return attributes
    }

    private func ours(_ attributes: [String: Any], service: String, account: String) -> Bool {
        if let value = attributes[kSecAttrService as String], value as? String != service { return false }
        if let value = attributes[kSecAttrAccount as String], value as? String != account { return false }
        if let value = attributes[kSecAttrSynchronizable as String] {
            if let flag = value as? Bool { return !flag }
            if let number = value as? NSNumber { return !number.boolValue }
            if let string = value as? String { return string == "0" }
            return false
        }
        return true
    }

    private func cached(_ item: Item) throws -> Entry?? {
        switch state.withLock({ $0.entries[item] }) {
        case nil: return .none
        case .absent?: return .some(nil)
        case .present(let entry)?: return .some(entry)
        case .refused(let status)?: throw KeychainItemsError.status(status)
        }
    }

    private func remember(_ item: Item, _ value: Cached?) { state.withLock { $0.entries[item] = value } }

    func read(_ item: Item) throws -> Entry? {
        if let known = try cached(item) { return known }
        return try withItem(item) {
            if let known = try cached(item) { return known }
            var request = query(service: item.service, account: item.account)
            request[kSecReturnData as String] = true
            request[kSecReturnAttributes as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, result) = backend.copyMatching(request)
            if status == errSecItemNotFound { remember(item, .absent); return nil }
            if Self.isRefusal(status) {
                remember(item, .refused(status))
                Log(.keychain).notice("a Keychain item was refused (OSStatus \(status)); not asked again until Try again")
            }
            guard status == errSecSuccess else { throw KeychainItemsError.status(status) }
            guard let attributes = KeychainSharedGrantStore.single(result),
                  ours(attributes, service: item.service, account: item.account),
                  let data = attributes[kSecValueData as String] as? Data else { throw KeychainItemsError.notOurs }
            let entry = Entry(data: data, modifiedAt: attributes[kSecAttrModificationDate as String] as? Date,
                              label: attributes[kSecAttrLabel as String] as? String,
                              generic: attributes[kSecAttrGeneric as String] as? Data)
            remember(item, .present(entry))
            return entry
        }
    }

    func write(_ item: Item, data: Data, label: String, generic: Data? = nil) throws {
        try withItem(item) {
            let before = state.withLock { $0.entries[item] }
            if case .present(let entry)? = before, entry.data == data { return }
            let request = query(service: item.service, account: item.account)
            let attributes = addAttributes(item, data: data, label: label, generic: generic)
            do {
                if case .present? = before {
                    let status = backend.delete(request)
                    guard status == errSecSuccess || status == errSecItemNotFound else {
                        throw KeychainItemsError.status(status)
                    }
                }
                var status = backend.add(attributes)
                if status == errSecDuplicateItem {
                    let deleted = backend.delete(request)
                    guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
                        throw KeychainItemsError.status(deleted)
                    }
                    status = backend.add(attributes)
                }
                guard status == errSecSuccess else {
                    if case .present(let old)? = before { restore(item, old, label: label) }
                    throw KeychainItemsError.status(status)
                }
                state.withLock { s in
                    s.entries[item] = .present(Entry(data: data, modifiedAt: Date(), label: label, generic: generic))
                    if s.lists[item.service] != nil { s.lists[item.service]?.insert(item.account) }
                }
            } catch {
                state.withLock { s in
                    if case .refused? = s.entries[item] { return }
                    s.entries[item] = nil
                }
                throw error
            }
        }
    }

    // Why: the old item was deleted to give the new one this app's ACL; when the add fails, the old value goes back
    private func restore(_ item: Item, _ old: Entry, label: String) {
        let status = backend.add(addAttributes(item, data: old.data, label: old.label ?? label, generic: old.generic))
        guard status != errSecSuccess else { return }
        Log(.keychain).error("a Keychain item could not be put back after a failed replace (OSStatus \(status))")
    }

    func delete(_ item: Item) throws {
        try withItem(item) {
            let status = backend.delete(query(service: item.service, account: item.account))
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainItemsError.status(status)
            }
            state.withLock { s in
                s.entries[item] = .absent
                s.values[item] = nil
                s.lists[item.service]?.remove(item.account)
            }
        }
    }

    func accounts(service: String) throws -> [String] {
        if let cached = state.withLock({ $0.lists[service] }) { return cached.sorted() }
        return try gated("list\n" + service) {
            if let cached = state.withLock({ $0.lists[service] }) { return cached.sorted() }
            var request = query(service: service)
            request[kSecReturnAttributes as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitAll
            let (status, result) = backend.copyMatching(request)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainItemsError.status(status)
            }
            let accounts = Set(Self.listed(result).compactMap { attributes -> String? in
                guard let account = attributes[kSecAttrAccount as String] as? String,
                      ours(attributes, service: service, account: account) else { return nil }
                return account
            })
            state.withLock { $0.lists[service] = accounts }
            return accounts.sorted()
        }
    }

    private func attributesOnly(service: String, account: String? = nil) -> (OSStatus, [[String: Any]]) {
        var request = query(service: service, account: account)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let (status, result) = backend.copyMatching(request)
        return (status, status == errSecSuccess ? Self.listed(result) : [])
    }

    func storedAttributes(_ item: Item) -> [String: Any]? {
        let (status, listed) = attributesOnly(service: item.service, account: item.account)
        guard status == errSecSuccess else { return nil }
        return listed.first { ours($0, service: item.service, account: item.account) }
    }

    // Why: reads attributes only, never a secret; the skip flag may not stop a dialog here, so any failure is unknown
    func presence(services: [String]) -> StoredItemPresence {
        guard style == .macLegacy else { return .absent }
        var found = false
        for service in services {
            let (status, listed) = attributesOnly(service: service)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else { return .unknown }
            found = found || listed.contains { attributes in
                guard let account = attributes[kSecAttrAccount as String] as? String else { return false }
                return ours(attributes, service: service, account: account)
            }
        }
        return found ? .present : .absent
    }

    static func entitledForSynchronizableItems() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) != nil
            || SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) != nil
        #else
        return true
        #endif
    }
}

public struct KeychainCredentialAccess: CredentialAccess {
    public let items: KeychainItems
    public let services: [String]

    public init(items: KeychainItems = .shared, services: [String]) {
        self.items = items
        self.services = services
    }

    public func storedItemPresence() -> StoredItemPresence { items.presence(services: services) }

    public var hasRefusals: Bool { items.hasRefusals }

    public func forgetRefusals() { items.forgetRefusals() }
}

enum KeychainItemsError: Error, Equatable { case status(OSStatus); case notOurs }
