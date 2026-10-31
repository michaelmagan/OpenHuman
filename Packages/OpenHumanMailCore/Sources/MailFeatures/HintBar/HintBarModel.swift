import Foundation
import MailActions
import MailModel
import Observation

public enum HintContext: String, Hashable, Sendable, CaseIterable {
    case list, conversation, composer, search, review
    case muted
    case calendar

    var scope: ActionScope {
        switch self {
        case .list, .search, .muted: .list
        case .conversation: .reader
        case .composer: .composer
        case .review: .review
        case .calendar: .calendar
        }
    }

    var candidates: [ActionID] {
        let returnAction: ActionID = ActionCatalog.returnRepliesAll ? .replyAll : .reply
        let shiftReturnAction: ActionID = ActionCatalog.returnRepliesAll ? .reply : .replyAll
        switch self {
        case .list: return [.markDone, .remind, .openThread, .commandPalette, .snooze, .toggleMute, .search]
        case .conversation:
            return [.markDone, .remind, returnAction, .commandPalette, .snooze, .toggleMute, shiftReturnAction]
        case .composer: return [.send, .discardDraft, .attachFiles, .commandPalette]
        case .search: return [.openThread, .search, .commandPalette, .shortcutHelp]
        case .review: return [.commandPalette, .shortcutHelp]
        case .muted: return [.toggleMute, .openThread, .commandPalette, .shortcutHelp]
        case .calendar: return [.calendarNewEvent, .calendarShowToday, .calendarBackToMail, .commandPalette]
        }
    }

    /// With drafts checked in Drafts, the list leads with sending them in place of opening one.
    func candidates(checkedDrafts: Bool) -> [ActionID] {
        guard self == .list, checkedDrafts else { return candidates }
        return [.sendDrafts] + candidates.filter { $0 != .openThread }
    }
}

public struct ShortcutHint: Hashable, Sendable, Identifiable {
    public var id: ActionID { action }
    public let action: ActionID
    public let title: String
    public let keycaps: [String]
    public let isEnabled: Bool
}

public enum HintBar {
    public static let limit = 4

    public static func hints(for context: HintContext, checkedDrafts: Bool = false, descriptors: [ActionDescriptor],
                             title: (ActionDescriptor) -> String = { $0.title },
                             availability: (ActionID) -> ActionAvailability) -> [ShortcutHint] {
        var result: [ShortcutHint] = []
        for id in context.candidates(checkedDrafts: checkedDrafts) {
            guard result.count < limit, let descriptor = descriptors.first(where: { $0.id == id }) else { continue }
            let state = availability(id)
            guard state != .hidden, let binding = binding(of: descriptor, in: context.scope) else { continue }
            let named = title(descriptor)
            let shown = named == descriptor.title ? (descriptor.shortTitle ?? named) : named
            result.append(ShortcutHint(action: id, title: Self.title(shown), keycaps: binding.keycaps,
                                       isEnabled: state.isEnabled))
        }
        return result
    }

    static func binding(of descriptor: ActionDescriptor, in scope: ActionScope) -> KeyBinding? {
        let active = descriptor.defaultBindings.filter { $0.onlyIn.map { $0.contains(scope) } ?? true }
        return active.first { $0.onlyIn != nil } ?? active.first
    }

    static func title(_ title: String) -> String {
        title.hasSuffix("…") ? String(title.dropLast()) : title
    }
}

@MainActor @Observable
public final class HintBarModel {
    public let show: StoredSetting<Bool>
    @ObservationIgnored private let router: AppRouter
    private var dismissedHere = false

    public init(router: AppRouter) {
        self.router = router
        show = StoredSetting(AppSettings.showShortcutHints, port: router.environment.settings)
    }

    public func start() { show.start() }

    public var isVisible: Bool { show.value && !dismissedHere }

    public func dismiss() async {
        if router.environment.settings == nil { dismissedHere = true }
        await show.set(false)
    }

    public var context: HintContext {
        let scope = router.actionContext().scope
        switch scope {
        case .composer: return .composer
        case .review: return .review
        case .reader: return .conversation
        case .calendar: return .calendar
        default:
            if router.active?.searchOpen == true { return .search }
            if let muted = router.active?.mutedLabel, router.active?.location == .label(muted.labelID) { return .muted }
            return .list
        }
    }

    public var hints: [ShortcutHint] {
        let registry = router.environment.actions
        let context = router.actionContext()
        let checkedDrafts = context.location == .system(.drafts) && context.checkedCount > 0
        return HintBar.hints(for: self.context, checkedDrafts: checkedDrafts, descriptors: registry.descriptors,
                             title: { ActionRules.title(for: $0, in: context) }) {
            registry.availability($0, host: router, context: context)
        }
    }
}
