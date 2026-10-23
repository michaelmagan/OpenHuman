import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
final class RecordingPresenter: ActionPresenting {
    var kinds: Set<ActionPresentation.Kind> = Set(ActionPresentation.Kind.allCases)
    var shown: [ActionPresentation] = []

    func canPresent(_ kind: ActionPresentation.Kind) -> Bool { kinds.contains(kind) }
    func present(_ presentation: ActionPresentation) { shown.append(presentation) }

    var lastKind: ActionPresentation.Kind? { shown.last?.kind }
}

@MainActor
struct ActionFixture {
    let env: AppEnvironment
    let router: AppRouter
    let store: FakeMailStore
    let presenter = RecordingPresenter()

    init(corpus: FakeCorpus = .make(threadCount: 10, now: fixedNow), options: FakeMailStore.Options = .init(remoteAck: .immediate),
         location: MailLocation? = .system(.inbox), flags: FeatureFlags = FeatureFlags(), presenter: Bool = true,
         platform: SystemPlatform? = nil) {
        env = AppEnvironment.fake(corpus: corpus, options: options, featureFlags: flags)
        if let platform { env.installPlatform(platform) }
        store = env.commands as! FakeMailStore
        router = AppRouter(environment: env, location: location)
        if presenter { env.actions.presenter = self.presenter }
        router.start()
    }

    var registry: ActionRegistry { env.actions }
    var rows: [ThreadRow] { router.list?.rows ?? [] }

    func loaded(_ count: Int? = nil) async {
        await eventually { router.list?.state == .loaded && (count.map { router.list?.rows.count == $0 } ?? true) }
    }

    @discardableResult
    func run(_ id: ActionID, source: ActionSource = .keyboard, context: ActionContext? = nil) async -> Bool {
        await registry.run(id, source: source, host: router, context: context)
    }

    func toast(_ message: String) async {
        await eventually { env.notices.toasts.contains { $0.message == message } }
    }

    var toastMessages: [String] { env.notices.toasts.map(\.message) }
}
