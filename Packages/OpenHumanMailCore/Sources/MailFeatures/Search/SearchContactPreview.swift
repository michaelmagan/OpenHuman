import Foundation
import MailModel
import Observation
import OpenHumanCore

/// The person highlighted in the search suggestions, for the panel beside them: the name, the address, its domain
/// and the newest conversations with them on this Mac.
@MainActor @Observable
public final class SearchContactPreview {
    public static let maxConversations = 4

    public struct Conversation: Hashable, Sendable {
        public let subject: String
        public let date: Date

        public init(subject: String, date: Date) {
            self.subject = subject
            self.date = date
        }
    }

    public struct Contact: Equatable, Sendable {
        public let name: String?
        public let email: String
        /// Nil while they are being looked up; empty when there are none or lookups are off.
        public var conversations: [Conversation]?

        public init(name: String?, email: String, conversations: [Conversation]?) {
            self.name = name
            self.email = email
            self.conversations = conversations
        }

        public var title: String { name ?? email }

        public var domain: String? {
            guard let at = email.lastIndex(of: "@") else { return nil }
            let domain = email[email.index(after: at)...]
            return domain.isEmpty ? nil : domain.lowercased()
        }
    }

    public private(set) var contact: Contact?
    public private(set) var lookups = 0

    @ObservationIgnored public var delay: Duration = .milliseconds(80)
    @ObservationIgnored public var lookup: (@Sendable (String) async -> [ThreadRow])?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var found: [String: [Conversation]] = [:]

    public init(lookup: (@Sendable (String) async -> [ThreadRow])? = nil) {
        self.lookup = lookup
    }

    isolated deinit { task?.cancel() }

    /// Shows a person, or nothing for nil. `looksUp` false shows the name and address without their conversations.
    public func show(name: String?, email: String?, looksUp: Bool = true) {
        guard let email, !email.isEmpty else {
            task?.cancel()
            task = nil
            if contact != nil { contact = nil }
            return
        }
        let key = email.lowercased()
        if let contact, contact.email.lowercased() == key, contact.name == name { return }
        task?.cancel()
        task = nil
        let lookup = looksUp ? self.lookup : nil
        contact = Contact(name: name, email: email, conversations: found[key] ?? (lookup == nil ? [] : nil))
        guard found[key] == nil, let lookup else { return }
        let delay = self.delay
        task = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            self.lookups += 1
            let rows = await lookup(key)
            guard !Task.isCancelled else { return }
            let conversations = rows.prefix(Self.maxConversations).map(Self.conversation)
            self.found[key] = conversations
            if self.contact?.email.lowercased() == key { self.contact?.conversations = conversations }
        }
    }

    public func reset() {
        task?.cancel()
        task = nil
        found = [:]
        contact = nil
    }

    static func conversation(_ row: ThreadRow) -> Conversation {
        let subject = row.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return Conversation(subject: subject.isEmpty ? String(localized: "(no subject)") : subject, date: row.lastMessageAt)
    }
}
