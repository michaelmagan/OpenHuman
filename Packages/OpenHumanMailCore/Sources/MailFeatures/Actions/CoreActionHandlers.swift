import Foundation
import MailActions
import MailModel

@MainActor
public final class ActionFeedback {
    private weak var environment: AppEnvironment?
    private var contextToast: Toast.ID?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    public func refuse(_ id: ActionID, _ reason: DisabledReason) {
        guard let environment else { return }
        switch reason {
        case .unavailable:
            environment.notices.post(reason.description, style: .info, duration: NoticeCenter.infoDuration)
        case .noSelection, .needs, .notBuilt:
            if let contextToast { environment.notices.dismiss(contextToast) }
            contextToast = environment.notices.post(reason.description, style: .info, duration: NoticeCenter.infoDuration)
        case .nothingToUndo, .nothingToRedo, .other:
            break
        }
    }

    public func failed(_ message: String, retry: (@MainActor () async -> Void)? = nil) {
        environment?.notices.post(message, style: .error, actionTitle: retry == nil ? nil : "Retry", action: retry)
    }
}

@MainActor
final class ShellActionHandler: ActionHandler {
    static let ids: [ActionID] = [.nextThread, .previousThread, .openThread, .backToList, .nextSplit, .previousSplit,
                                  .goInbox, .goStarred, .goDrafts, .goSent, .goAllMail, .goDone, .goWaiting,
                                  .toggleLabelSidebar, .focusLabelSidebar]
        + (1...9).map(ActionID.switchToAccount)
    static let moduleIDs: [FeatureModuleID: [ActionID]] = [
        .snooze: [.goSnoozed], .reminders: [.goReminders], .sendLater: [.goScheduled], .review: [.goReview, .reviewLeave],
        .mute: [.goMuted],
    ]

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard let router = host as? AppRouter else { return .hidden }
        return router.shellIsEnabled(id) ? .enabled : .hidden
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let router = request.router else { return .notHandled }
        return router.performShellAction(request.id) ? .done : .notHandled
    }
}

@MainActor
final class UndoActionHandler: ActionHandler {
    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        environment?.undo == nil ? .hidden : .enabled
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let undo = environment?.undo else { return .notHandled }
        switch request.id {
        case .undo:
            guard undo.canUndo else { return .notHandled }
            return .started(Task { await undo.undoLast() })
        case .redo:
            guard undo.canRedo else { return .notHandled }
            return .started(Task { await undo.redoLast() })
        default:
            return .notHandled
        }
    }
}

@MainActor
final class PresentationActionHandler: ActionHandler {
    static let ids: [ActionID] = [.commandPalette, .shortcutHelp, .search, .goLabel, .compose, .composeInWindow,
                                  .reply, .replyAll, .forward]

    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var presenter: (any ActionPresenting)? { environment?.actions.presenter }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard id != .commandPalette, let presentation = presentation(id, context) else { return .enabled }
        return presenter?.canPresent(presentation.kind) == true ? .enabled : .hidden
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        if request.id == .commandPalette {
            guard let palette = environment?.actions.palette else { return .notHandled }
            if palette.isOpen { palette.close() } else { palette.open(host: request.host, context: request.context) }
            if palette.isOpen, let presenter, presenter.canPresent(.palette) { presenter.present(.palette) }
            return .done
        }
        guard let presentation = presentation(request.id, request.context), let presenter,
              presenter.canPresent(presentation.kind) else { return .notHandled }
        presenter.present(presentation)
        return .done
    }

    private func presentation(_ id: ActionID, _ c: ActionContext) -> ActionPresentation? {
        switch id {
        case .commandPalette: return .palette
        case .shortcutHelp: return .shortcutHelp
        case .search: return .search
        case .goLabel: return .labelPicker(targets: [], mode: .navigate)
        case .compose: return .compose(.new)
        case .composeInWindow: return .compose(.newWindow)
        case .reply, .replyAll, .forward:
            guard let thread = c.focusedThread else { return .compose(.new) }
            return .compose(id == .reply ? .reply(thread) : id == .replyAll ? .replyAll(thread) : .forward(thread))
        default: return nil
        }
    }
}
