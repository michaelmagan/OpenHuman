import Foundation
import MailActions
import MailModel

@MainActor
final class AppActionHandler: ActionHandler {
    static let ids: [ActionID] = [.refresh, .addAccount, .goSnippets, .importSuperhumanLabels, .sendFeedback, .checkForUpdates]
        + ActionCatalog.settingsPages.map(\.id)

    static let snippetsPage = "snippets"
    static let generalPage = "general"

    private weak var environment: AppEnvironment?
    private let feedback: ActionFeedback

    init(environment: AppEnvironment, feedback: ActionFeedback) {
        self.environment = environment
        self.feedback = feedback
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard let environment else { return .hidden }
        let navigator = environment.settingsNavigator
        switch id {
        case .refresh:
            return environment.settings == nil ? .hidden : .enabled
        case .addAccount:
            return environment.accounts != nil && navigator.canOpen ? .enabled : .hidden
        case .goSnippets:
            return availability(of: .settingsPage(Self.snippetsPage), in: context, host: host)
        case .importSuperhumanLabels:
            return availability(of: .settingsPage(Self.generalPage), in: context, host: host)
        case .sendFeedback:
            return environment.system.sendFeedback.canBegin ? .enabled : .hidden
        case .checkForUpdates:
            return environment.system.updates == nil ? .hidden : .enabled
        default:
            guard let page = id.settingsPageID, navigator.canOpen,
                  SettingsShellModel.pages(for: environment.modules).contains(where: { $0.id == page }) else { return .hidden }
            return .enabled
        }
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let environment else { return .notHandled }
        switch request.id {
        case .refresh:
            guard let settings = environment.settings else { return .notHandled }
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let feedback = self.feedback
            return .started(Task {
                do {
                    try await settings.set(AppSettings.syncRequestAt, stamp)
                } catch {
                    feedback.failed("Couldn't check for new mail. Try again.")
                }
            })
        case .addAccount:
            environment.settingsNavigator.addAccount()
            return .done
        case .goSnippets:
            environment.settingsNavigator.open(Self.snippetsPage)
            return .done
        case .importSuperhumanLabels:
            environment.settingsNavigator.open(Self.generalPage)
            return .done
        case .sendFeedback:
            environment.system.sendFeedback.begin()
            return .done
        case .checkForUpdates:
            guard let updates = environment.system.updates else { return .notHandled }
            updates.begin()
            return .done
        default:
            guard let page = request.id.settingsPageID else { return .notHandled }
            environment.settingsNavigator.open(page)
            return .done
        }
    }
}
