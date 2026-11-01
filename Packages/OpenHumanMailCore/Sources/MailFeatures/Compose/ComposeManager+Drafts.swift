import Foundation
import MailActions
import MailModel
import OpenHumanCore

extension ComposeManager {
    func drafts(in thread: ThreadKey) async -> [DraftSummary] {
        let rows = await Self.first(environment.data.drafts(thread.account, review: false)) ?? []
        return rows.filter { $0.thread == thread }
    }

    func scheduledDraft(in thread: ThreadKey) async -> DraftSummary? {
        Self.soonestScheduled(await drafts(in: thread))
    }

    static func soonestScheduled(_ drafts: [DraftSummary]) -> DraftSummary? {
        drafts.filter { $0.status == .scheduled && $0.sendAt != nil }
            .min { ($0.sendAt ?? .distantFuture) < ($1.sendAt ?? .distantFuture) }
    }

    static func resumable(_ drafts: [DraftSummary], scheduledFirst: Bool) -> DraftSummary? {
        if scheduledFirst, let soonest = soonestScheduled(drafts) { return soonest }
        let newest = drafts.sorted { $0.updatedAt > $1.updatedAt }
        return newest.first { $0.review != .pending } ?? newest.first
    }

    @discardableResult
    public func resumeDraft(in thread: ThreadKey, scheduledFirst: Bool = false) -> Task<ComposeSession?, Never> {
        Task { [weak self] in
            guard let self else { return nil }
            let candidates = await self.drafts(in: thread)
            guard let row = Self.resumable(candidates, scheduledFirst: scheduledFirst) else { return nil }
            let router = self.environment.router
            if row.mode != .new, let conversation = row.thread, router.active?.reader?.thread != conversation {
                if router.activeAccountID != conversation.account { router.switchAccount(to: conversation.account) }
                router.open(conversation)
            }
            return await self.openDraft(row.id).value
        }
    }

    func openDraftAction(in thread: ThreadKey, scheduledFirst: Bool) -> ActionPerformance {
        let opening = resumeDraft(in: thread, scheduledFirst: scheduledFirst)
        let notices = environment.notices
        return .started(Task {
            guard await opening.value == nil else { return }
            notices.post(String(localized: "This conversation has no draft any more"), style: .info,
                         duration: NoticeCenter.infoDuration)
        })
    }
}

@MainActor
final class DraftRowActionHandler: ActionHandler {
    static let coreIDs: [ActionID] = [.openDraft, .sendDrafts]
    static let sendLaterIDs: [ActionID] = [.rescheduleSend, .cancelScheduledSend, .sendScheduledNow]

    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var manager: ComposeManager? { environment?.composeIfStarted }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        manager == nil ? .hidden : .enabled
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let manager else { return .notHandled }
        if request.id == .sendDrafts { return manager.batchSendAction(threads: request.context.selection) }
        guard let thread = request.context.focusedThread else { return .notHandled }
        switch request.id {
        case .openDraft:
            return manager.openDraftAction(in: thread, scheduledFirst: request.context.location == .system(.scheduled))
        case .rescheduleSend:
            return manager.rescheduleSend(in: thread)
        case .cancelScheduledSend:
            return manager.cancelScheduledSend(in: thread)
        case .sendScheduledNow:
            return manager.sendScheduledNowAction(in: thread)
        default:
            return .notHandled
        }
    }
}
