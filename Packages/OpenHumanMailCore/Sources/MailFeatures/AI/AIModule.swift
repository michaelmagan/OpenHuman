import Foundation
import MailActions
import MailModel
import OpenHumanAI

public struct AIModule: FeatureModule {
    public static let id = FeatureModuleID.ai
    public static let defaultEnabled = true
    public init() {}

    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.actions(ActionCatalog.descriptors(module: Self.id), handler: AIActionHandler(environment: env))
        guard let center = env.ai else { return }
        registry.onLaunch { await center.refreshProviders() }
    }
}

@MainActor
final class AIActionHandler: ActionHandler {
    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var center: AICenter? { environment?.ai }

    private func session(_ context: ActionContext) -> ComposeSession? {
        guard let session = environment?.composeIfStarted?.session(id: context.composer), session.isOpen else { return nil }
        return session
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard let center else { return .hidden }
        switch id {
        case .aiRewrite:
            return session(context) == nil ? .hidden : .enabled
        case .aiReplyOptions:
            guard center.settings.enabled, center.settings.draftReplies != .off else { return .hidden }
            if context.scope == .composer {
                guard let session = session(context), session.thread != nil,
                      session.mode == .reply || session.mode == .replyAll else { return .hidden }
            }
            return .enabled
        case .aiSummarize:
            return center.settings.enabled ? .enabled : .disabled(.other(AIWording.reason(.disabledBySettings)))
        case .aiAskInbox:
            return environment?.actions.presenter?.canPresent(.askInbox) == true ? .enabled : .hidden
        case .aiUseInlineReply, .aiNextInlineReply, .aiPreviousInlineReply:
            guard environment?.router.mode == .reader, center.inlineReplies.current?.state == .ready else { return .hidden }
            if id != .aiUseInlineReply, (center.inlineReplies.current?.replyCount ?? 0) < 2 { return .hidden }
            return .enabled
        default:
            return .hidden
        }
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let center, let environment else { return .notHandled }
        switch request.id {
        case .aiRewrite:
            guard let session = session(request.context) else { return .notHandled }
            center.togglePanel(session)
            return .done
        case .aiReplyOptions:
            if let session = session(request.context) {
                center.togglePanel(session, showQuickReplies: true)
                return .done
            }
            guard let thread = request.context.focusedThread else { return .notHandled }
            let message = environment.compose.replyTarget(in: thread)
            guard let session = environment.compose.openReply(thread, mode: .reply, message: message) else {
                return .notHandled
            }
            center.togglePanel(session, showQuickReplies: true)
            return .done
        case .aiSummarize:
            guard let thread = request.context.focusedThread else { return .notHandled }
            if environment.router.reader?.thread != thread { environment.router.open(thread) }
            let model = center.summary(for: thread)
            guard request.source == .keyboard, center.settings.featurePins[.summarize] == nil else {
                model.summarize(trigger: .user)
                return .done
            }
            return .started(Task { [weak environment, weak center] in
                guard let center else { return }
                let status = await center.features.status(for: .summarize, accountKey: nil)
                if let location = status.dataLocation, location != .onDevice {
                    let provider = status.providerName ?? String(localized: "a provider off this Mac")
                    environment?.notices.post(
                        String(localized: "Summarize would use \(provider). Use the Summarize link or the command palette."),
                        style: .info, duration: NoticeCenter.infoDuration)
                    return
                }
                model.summarize(trigger: .user)
            })
        case .aiAskInbox:
            guard let presenter = environment.actions.presenter, presenter.canPresent(.askInbox) else { return .notHandled }
            if let overlays = presenter as? OverlayCenter, case .ask = overlays.overlay {
                overlays.dismiss()
                return .done
            }
            presenter.present(.askInbox(question: nil))
            return .done
        case .aiUseInlineReply:
            guard let row = center.inlineReplies.current, row.state == .ready else { return .notHandled }
            return .started(Task { @MainActor in _ = await row.accept() })
        case .aiNextInlineReply:
            guard let row = center.inlineReplies.current, row.state == .ready else { return .notHandled }
            row.next()
            return .done
        case .aiPreviousInlineReply:
            guard let row = center.inlineReplies.current, row.state == .ready else { return .notHandled }
            row.previous()
            return .done
        default:
            return .notHandled
        }
    }
}

extension AICenter {
    public func conversationAppeared(_ thread: ThreadKey, messageCount: Int) {
        summary(for: thread).appeared(messageCount: messageCount)
        if settings.enabled, settings.writesRepliesAutomatically {
            quickReplies(for: thread).request(trigger: .automatic)
        }
        threadLines.request(thread)
        preparation.bump(thread)
    }

    public func conversationDisappeared(_ thread: ThreadKey) {
        summary(for: thread).cancelAutomatic()
        for model in allQuickReplies(in: thread) { model.cancelAutomatic() }
        threadLines.leave(thread)
    }
}

extension ComposeManager {
    public var aiCenter: AICenter? {
        environment.actions.contains(.aiRewrite) ? environment.ai : nil
    }

    public func allowsWritingTools(in session: ComposeSession) -> Bool {
        aiCenter?.allowsWritingTools(for: session.account) ?? false
    }
}
