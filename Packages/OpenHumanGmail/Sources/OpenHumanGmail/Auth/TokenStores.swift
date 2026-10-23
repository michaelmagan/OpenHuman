import Foundation
import OpenHumanCore
import Synchronization

public enum TokenStoreError: Error, Equatable, Sendable {
    case invalidAccount
    case io(String)
    case keychain(Int32)
    case corrupt
    case missing
    case notAppProcess
}

func normalizedAccount(_ email: String) throws -> String {
    let account = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !account.isEmpty, !account.contains("/"), !account.contains("\0"), account != ".", account != "..",
          !account.hasPrefix(".") else { throw TokenStoreError.invalidAccount }
    return account
}

public final class InMemoryTokenStore: TokenStore {
    private let tokens = Mutex<[String: StoredToken]>([:])

    public init(_ initial: [String: StoredToken] = [:]) {
        tokens.withLock { dict in
            for (email, token) in initial { dict[email.lowercased()] = token }
        }
    }

    public func load(account email: String) throws -> StoredToken? {
        let key = try normalizedAccount(email)
        return tokens.withLock { $0[key] }
    }

    public func save(_ token: StoredToken, account email: String) throws {
        let key = try normalizedAccount(email)
        tokens.withLock { $0[key] = token }
    }

    public func delete(account email: String) throws {
        let key = try normalizedAccount(email)
        _ = tokens.withLock { $0.removeValue(forKey: key) }
    }

    public func allAccounts() throws -> [String] {
        tokens.withLock { $0.keys.sorted() }
    }
}

public final class FileTokenStore: TokenStore {
    public let directory: URL

    public init(baseDirectory: URL) {
        directory = baseDirectory.appendingPathComponent("tokens", isDirectory: true)
    }

    private func fileURL(_ email: String) throws -> URL {
        directory.appendingPathComponent(try normalizedAccount(email) + ".json", isDirectory: false)
    }

    public func load(account email: String) throws -> StoredToken? {
        let url = try fileURL(email)
        let (kind, _) = SecureFile.inspect(url)
        switch kind {
        case .missing: return nil
        case .other: throw TokenStoreError.io("token path is not a regular file")
        case .regularFile: break
        }
        guard let data = FileManager.default.contents(atPath: url.path) else { throw TokenStoreError.io("read") }
        do { return try JSONDecoder().decode(StoredToken.self, from: data) } catch { throw TokenStoreError.corrupt }
    }

    public func save(_ token: StoredToken, account email: String) throws {
        let url = try fileURL(email)
        do {
            try SecureFile.ensureDirectory(directory, mode: 0o700, tighten: true)
            try SecureFile.writeAtomically(try JSONEncoder().encode(token), to: url, mode: 0o600)
        } catch let failure as SecureFile.Failure {
            throw TokenStoreError.io(failure.description)
        }
    }

    public func delete(account email: String) throws {
        let url = try fileURL(email)
        if unlink(url.path) != 0, errno != ENOENT { throw TokenStoreError.io("unlink (errno \(errno))") }
    }

    public func allAccounts() throws -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map { String($0.dropLast(5)) }.sorted()
    }
}
