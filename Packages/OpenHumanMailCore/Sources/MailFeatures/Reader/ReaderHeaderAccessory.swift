import Foundation
import MailModel

public struct ReaderHeaderAccessoryItem: Sendable, Hashable {
    public let title: String
    public let accessibilityLabel: String

    public init(title: String, accessibilityLabel: String? = nil) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel ?? title
    }
}

@MainActor
public protocol ReaderHeaderAccessory: AnyObject {
    func item(for message: MessageSummary, in thread: ThreadKey) async -> ReaderHeaderAccessoryItem?
    func activate(_ item: ReaderHeaderAccessoryItem, for message: MessageSummary, in thread: ThreadKey)
}

@MainActor
public final class ReaderHeaderAccessoryStore {
    public weak var current: (any ReaderHeaderAccessory)?
    public init(current: (any ReaderHeaderAccessory)? = nil) { self.current = current }
}

@MainActor
public enum ReaderHeaderAccessorySlot {
    public static let shared = ReaderHeaderAccessoryStore()
    public static var current: (any ReaderHeaderAccessory)? {
        get { shared.current }
        set { shared.current = newValue }
    }
}
