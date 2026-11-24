import Foundation
import MailActions
import MailModel

@MainActor
final class CoreActions {
    let feedback: ActionFeedback
    let thread: ThreadActionHandler
    let shell = ShellActionHandler()
    let undo: UndoActionHandler
    let presentation: PresentationActionHandler
    let importance: ImportanceActionHandler
    let waiting: WaitingActionHandler
    let autoLabels: AutoLabelActionHandler
    let classification: ClassificationCorrectionHandler
    let messages = ReaderMessageActionHandler()
    let composeEditing: ComposeEditingActionHandler
    let app: AppActionHandler
    let extras: SuperhumanCoreActionHandler
    let invites: InviteActionHandler

    let instantIntro: InstantIntroActionHandler

    init(environment: AppEnvironment) {
        feedback = ActionFeedback(environment: environment)
        thread = ThreadActionHandler(environment: environment, feedback: feedback)
        undo = UndoActionHandler(environment: environment)
        presentation = PresentationActionHandler(environment: environment)
        importance = ImportanceActionHandler(environment: environment, feedback: feedback)
        waiting = WaitingActionHandler(environment: environment, feedback: feedback)
        autoLabels = AutoLabelActionHandler(environment: environment, feedback: feedback)
        classification = ClassificationCorrectionHandler(environment: environment, feedback: feedback)
        composeEditing = ComposeEditingActionHandler(environment: environment)
        instantIntro = InstantIntroActionHandler(environment: environment)
        app = AppActionHandler(environment: environment, feedback: feedback)
        extras = SuperhumanCoreActionHandler(environment: environment, feedback: feedback)
        invites = InviteActionHandler(environment: environment)
    }

    func registerCore(in registry: ActionRegistry) {
        registry.register(thread, for: ThreadActionHandler.coreIDs)
        registry.register(shell, for: ShellActionHandler.ids)
        registry.register(undo, for: [.undo, .redo])
        registry.register(waiting, for: WaitingActionHandler.ids)
        registry.register(autoLabels, for: AutoLabelActionHandler.ids)
        registry.register(classification, for: ClassificationCorrectionHandler.ids)
        registry.register(presentation, for: PresentationActionHandler.ids)
        registry.register(messages, for: ReaderMessageActionHandler.ids)
        registry.register(composeEditing, for: ComposeEditingActionHandler.ids)
        registry.register(app, for: AppActionHandler.ids)
        registry.register(extras, for: SuperhumanCoreActionHandler.ids)
        registry.register(instantIntro, for: InstantIntroActionHandler.ids)
        registry.register(invites, for: InviteActionHandler.ids)
    }

    func handlers(for module: FeatureModuleID) -> [(any ActionHandler, [ActionID])] {
        var result: [(any ActionHandler, [ActionID])] = []
        if let ids = ThreadActionHandler.moduleIDs[module] { result.append((thread, ids)) }
        if let ids = ShellActionHandler.moduleIDs[module] { result.append((shell, ids)) }
        if module == .importance { result.append((importance, ImportanceActionHandler.ids)) }
        return result
    }
}

extension ActionRegistry {
    func install(environment: AppEnvironment, modules: [any FeatureModule], flags: FeatureFlags) -> ModuleRegistry {
        let core = CoreActions(environment: environment)
        self.core = core
        core.registerCore(in: self)
        let feedback = core.feedback
        onRefused = { id, reason in feedback.refuse(id, reason) }
        let hints = ShortcutLearning(settings: environment.settings, notices: environment.notices)
        shortcutHints = hints
        register(ShortcutHintActionHandler(learning: hints, notices: environment.notices), for: ShortcutHintActionHandler.ids)
        register(SearchRankingActionHandler(environment: environment), for: SearchRankingActionHandler.ids)
        let built = ModuleRegistry.build(modules, flags: flags, env: environment)
        for module in built.modules { noteEnabled(module) }
        for registration in built.actions {
            register(registration.descriptors, handler: registration.handler, module: registration.module)
        }
        return built
    }

    public func refuse(_ id: ActionID, _ reason: DisabledReason) {
        onRefused?(id, reason)
    }

    public var threadActions: ThreadActionHandler? { core?.thread }

    public var importanceActions: ImportanceActionHandler? { core?.importance }
}
