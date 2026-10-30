import Foundation
import MailActions
import MailModel

/// The open conversation's actions as the window toolbar shows them: a primary group (Done, Remind, Label, Trash),
/// Previous and Next, and a More menu. The reader draws no glyph row of its own: the toolbar builds its items from
/// this value and runs them with `perform(_:router:)`, so a click takes the same route as a key.
public struct ReaderToolbarActions: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public let id: ActionID
        /// The title in the current context ("Unstar", "Mark as Read").
        public let title: String
        /// The SF Symbol to draw; the filled variant when `isOn`.
        public let symbol: String?
        public let isEnabled: Bool
        /// The tooltip: the title and its key, or why the action is unavailable.
        public let help: String
        /// A toggle that is currently on (starred, has unread messages).
        public let isOn: Bool
        public let shortcutHint: String?
    }

    public var primary: [Item]
    public var navigation: [Item]
    public var more: [[Item]]

    public static let empty = ReaderToolbarActions(primary: [], navigation: [], more: [])

    public var isEmpty: Bool { primary.isEmpty && navigation.isEmpty && more.isEmpty }

    public static let primaryIDs: [ActionID] = [.markDone, .remind, .label, .trash]

    public static var moreMenuSections: [[ActionDescriptor]] {
        let thread = ActionCatalog.all.filter {
            $0.scopes.contains(.reader) && $0.category == .thread && $0.appearsInMenu && $0.target != ActionTarget.none
                && !primaryIDs.contains($0.id)
        }
        return [ReaderActions.messageActions, thread, ActionCatalog.all.filter { $0.id == .printConversation }]
    }

    /// The actions for the router's open conversation; empty when no conversation is open.
    @MainActor
    public init(router: AppRouter) {
        guard let reader = router.reader else {
            self = .empty
            return
        }
        self.init(router: router, reader: reader)
    }

    @MainActor
    public init(router: AppRouter, reader: ReaderModel) {
        guard router.active != nil else {
            self = .empty
            return
        }
        let context = ReaderActions.context(host: router, thread: reader.thread, lastMessage: reader.messages.last?.id,
                                            isStarred: reader.isStarred)
        let registry = router.environment.actions
        let hasUnread = reader.messages.contains { $0.summary.isUnread }
        func item(_ action: ActionDescriptor) -> Item? {
            let decided = ReaderActions.decide(action, registry: registry, host: router, context: context)
            guard decided != .hidden else { return nil }
            let descriptor = registry.descriptor(action.id) ?? action
            let title = ActionRules.title(for: descriptor, in: context)
            let availability = ReaderActions.availability(descriptor, decided: decided, title: title)
            let isOn = (action.id == .toggleStar && reader.isStarred) || (action.id == .toggleRead && hasUnread)
            let symbol = isOn ? (ReaderActions.activeSymbol(for: action.id) ?? ReaderActions.symbol(for: action.id))
                : ReaderActions.symbol(for: action.id)
            return Item(id: action.id, title: title, symbol: symbol, isEnabled: availability.isEnabled,
                        help: availability.help, isOn: isOn, shortcutHint: descriptor.shortcutHint)
        }
        let offered = ReaderActions.threadActions
        self.init(
            primary: Self.primaryIDs.compactMap { id in offered.first { $0.id == id } ?? ActionCatalog.descriptor(id) }
                .compactMap(item),
            navigation: ReaderActions.navigationActions.compactMap(item),
            more: Self.moreMenuSections.map { $0.compactMap(item) }.filter { !$0.isEmpty })
    }

    public init(primary: [Item], navigation: [Item], more: [[Item]]) {
        self.primary = primary
        self.navigation = navigation
        self.more = more
    }

    public func item(_ id: ActionID) -> Item? {
        (primary + navigation + more.flatMap { $0 }).first { $0.id == id }
    }

    /// Runs a toolbar item through the router; the source tells the action it came from a click in the toolbar.
    @MainActor @discardableResult
    public static func perform(_ id: ActionID, router: AppRouter, source: ActionSource = .toolbar) -> Bool {
        router.performClick(id, source: source)
    }
}
