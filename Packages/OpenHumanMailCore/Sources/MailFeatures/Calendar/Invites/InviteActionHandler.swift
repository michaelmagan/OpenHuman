import Foundation
import MailActions
import MailModel

@MainActor
final class InviteActionHandler: ActionHandler {
    static let ids: [ActionID] = [.inviteYes, .inviteMaybe, .inviteNo, .inviteShowOriginal, .inviteRemove]

    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard let center = environment?.invitesIfStarted, let reader = (host as? AppRouter)?.reader else { return .hidden }
        let shown = reader.messages.map(\.id)
        if id == .inviteShowOriginal {
            let focused = context.focusedMessage ?? shown.last
            return shown.contains { center.card(for: $0) != nil && ($0 == focused || shown.count == 1) } ? .enabled : .hidden
        }
        if id == .inviteRemove {
            return center.removalTarget(focused: context.focusedMessage, shown: shown) == nil ? .hidden : .enabled
        }
        return center.target(focused: context.focusedMessage, in: reader.thread, shown: shown) == nil ? .hidden : .enabled
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let center = environment?.invitesIfStarted, let reader = request.router?.reader else { return .notHandled }
        let shown = reader.messages.map(\.id)
        if request.id == .inviteShowOriginal {
            let focused = request.context.focusedMessage
            guard let key = focused.flatMap({ center.card(for: $0) != nil ? $0 : nil })
                ?? shown.reversed().first(where: { center.card(for: $0) != nil }) else { return .notHandled }
            center.toggleOriginal(key)
            return .done
        }
        if request.id == .inviteRemove {
            guard let key = center.removalTarget(focused: request.context.focusedMessage, shown: shown) else {
                return .notHandled
            }
            center.askToRemove(key)
            return .done
        }
        guard let key = center.target(focused: request.context.focusedMessage, in: reader.thread, shown: shown) else {
            return .notHandled
        }
        let response: CalendarResponse = switch request.id {
        case .inviteYes: .accepted
        case .inviteNo: .declined
        default: .tentative
        }
        return .started(Task { await center.respond(response, to: key) })
    }
}
