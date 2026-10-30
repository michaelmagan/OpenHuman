import Foundation
import MailActions
import MailModel
import Observation

@MainActor @Observable
public final class UnsubscribeModel: ReaderHeaderAccessory, ActionPresenting {
    @ObservationIgnored public weak var next: (any ActionPresenting)?
    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private let urlOpener: any URLOpening

    @ObservationIgnored private let accessorySlot: ReaderHeaderAccessoryStore

    public init(environment: AppEnvironment, urlOpener: any URLOpening,
                accessorySlot: ReaderHeaderAccessoryStore = ReaderHeaderAccessorySlot.shared) {
        self.accessorySlot = accessorySlot
        self.environment = environment
        self.urlOpener = urlOpener
    }

    public func install() {
        guard let environment else { return }
        let overlays = environment.overlays
        if let previous = overlays.fallback, previous !== self { next = previous }
        overlays.fallback = self
        accessorySlot.current = self
    }

    public func uninstall() {
        if let environment, environment.overlays.fallback === self { environment.overlays.fallback = next }
        if accessorySlot.current === self { accessorySlot.current = nil }
        next = nil
    }

    public func canPresent(_ kind: ActionPresentation.Kind) -> Bool {
        switch kind {
        case .openURL: true
        default: next?.canPresent(kind) == true
        }
    }

    public func present(_ presentation: ActionPresentation) {
        switch presentation {
        case .openURL(let url):
            guard let environment else { return }
            guard url.scheme?.lowercased() == "https", url.host() != nil else {
                environment.notices.post("Mail only opens secure (https) unsubscribe links.", style: .info,
                                         duration: NoticeCenter.infoDuration)
                return
            }
            urlOpener.open(url)
        default:
            next?.present(presentation)
        }
    }

    public func item(for message: MessageSummary, in thread: ThreadKey) async -> ReaderHeaderAccessoryItem? {
        guard let environment else { return nil }
        let info: UnsubscribeInfo?
        do { info = try await environment.data.unsubscribeInfo(message.id) } catch { info = nil }
        guard info != nil else { return nil }
        let who = message.from.map { $0.name?.isEmpty == false ? ($0.name ?? $0.email) : $0.email }
        return ReaderHeaderAccessoryItem(title: "Unsubscribe", accessibilityLabel: who.map { "Unsubscribe from \($0)" } ?? "Unsubscribe")
    }

    public func activate(_ item: ReaderHeaderAccessoryItem, for message: MessageSummary, in thread: ThreadKey) {
        guard let environment else { return }
        var context = environment.router.actionContext()
        context.scope = .reader
        context.account = thread.account
        context.focusedThread = thread
        context.focusedMessage = message.id
        context.sender = message.from?.email.lowercased()
        let registry = environment.actions
        let router = environment.router
        Task { await registry.run(.unsubscribe, source: .toolbar, host: router, context: context) }
    }
}
