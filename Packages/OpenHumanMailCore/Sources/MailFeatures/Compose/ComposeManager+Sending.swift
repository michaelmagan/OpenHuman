import Foundation
import MailActions
import MailModel
import OpenHumanCore

public struct SendingMessage: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case queued(until: Date)
        case sending
        case waitingForConnection
        case sent
        case failed
        case scheduled(at: Date)

        public var isOnItsWay: Bool {
            switch self {
            case .queued, .sending, .waitingForConnection: true
            case .sent, .failed, .scheduled: false
            }
        }
    }

    public enum Step: Int, CaseIterable, Sendable {
        case queued, sending, sent
    }

    public let id: UUID
    public let draft: DraftKey
    public let account: AccountID
    public let thread: ThreadKey?
    public let mode: DraftMode
    public let from: EmailAddress
    public let to: [EmailAddress]
    public let cc: [EmailAddress]
    public let bcc: [EmailAddress]
    public let subject: String
    public let text: String
    public let attachmentNames: [String]
    public let date: Date
    public internal(set) var state: State

    public init(id: UUID, draft: DraftKey, account: AccountID, thread: ThreadKey?, mode: DraftMode, from: EmailAddress,
                to: [EmailAddress], cc: [EmailAddress], bcc: [EmailAddress], subject: String, text: String,
                attachmentNames: [String], date: Date, state: State) {
        self.id = id
        self.draft = draft
        self.account = account
        self.thread = thread
        self.mode = mode
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.text = text
        self.attachmentNames = attachmentNames
        self.date = date
        self.state = state
    }

    public var step: Step? {
        switch state {
        case .queued: .queued
        case .sending, .waitingForConnection: .sending
        case .sent: .sent
        case .failed, .scheduled: nil
        }
    }

    public var offersUndo: Bool {
        switch state {
        case .queued, .scheduled: true
        default: false
        }
    }

    public var offersRetry: Bool { state == .failed }

    public var offersEdit: Bool {
        switch state {
        case .failed, .scheduled: true
        default: false
        }
    }

    public var offersShowInSent: Bool { state == .sent }

    public func secondsLeft(now: Date) -> Int {
        guard case .queued(let until) = state else { return 0 }
        return max(0, Int(until.timeIntervalSince(now).rounded(.up)))
    }
}

public enum SendLanding: Equatable, Sendable {
    case stays
    case list(row: ThreadKey?)
}

extension ComposeManager {
    public static func landing(placement: ComposeSession.Placement, showing: ThreadKey?, inList: Bool) -> SendLanding {
        guard placement != .window, let showing else { return .stays }
        return .list(row: inList ? showing : nil)
    }

    func returnToList(after session: ComposeSession) {
        guard let state = environment.router.active else { return }
        let showing = state.mode == .reader ? state.reader?.thread : nil
        let inList = showing.map { state.list?.index(of: $0) != nil } ?? false
        let landing = Self.landing(placement: session.placement, showing: showing, inList: inList)
        guard case .list(let row) = landing else { return }
        environment.router.closeReader()
        if let row, let list = state.list, list.index(of: row) != nil { list.setCursor(row) }
    }

    func showPlace(of session: ComposeSession) {
        guard case .docked(let thread) = session.placement else { return }
        let router = environment.router
        if router.activeAccountID != thread.account { router.switchAccount(to: thread.account) }
        guard let state = router.active, state.reader?.thread != thread || state.mode != .reader else { return }
        state.reopenAfterUndo(thread)
        router.setNeedsPersist()
    }

    static let sendingLimit = 20

    func addSending(_ session: ComposeSession, draft: DraftKey, state: SendingMessage.State) {
        addSending(SendingMessage(
            id: session.id, draft: draft, account: session.account.id, thread: session.thread, mode: session.mode,
            from: session.from.address, to: session.to.tokens, cc: session.cc.tokens, bcc: session.bcc.tokens,
            subject: session.subject, text: session.plainText, attachmentNames: session.attachments.map(\.filename),
            date: timing.now(), state: state))
    }

    func addSending(_ message: SendingMessage) {
        var list = sending.filter { $0.id != message.id }
        list.append(message)
        while list.count > Self.sendingLimit {
            if let done = list.firstIndex(where: { !$0.state.isOnItsWay }) { list.remove(at: done) } else { list.removeFirst() }
        }
        sending = list
    }

    func setSending(_ id: UUID, _ state: SendingMessage.State) {
        guard let index = sending.firstIndex(where: { $0.id == id }), sending[index].state != state else { return }
        sending[index].state = state
    }

    func removeSending(_ id: UUID) {
        sending.removeAll { $0.id == id }
        sendingUndoEntries[id] = nil
        if shownSendingID == id { shownSendingID = nil }
    }

    func forgetSending(draft: DraftKey) {
        for message in sending where message.draft == draft { removeSending(message.id) }
    }

    func updateSendingLine() {
        let count = sending.filter(\.state.isOnItsWay).count
        let line: String? = switch count {
        case 0: nil
        case 1: String(localized: "Sending 1 message…")
        default: String(localized: "Sending \(count) messages…")
        }
        if environment.status.sendingLine != line { environment.status.sendingLine = line }
    }

    func viewChoice(_ id: UUID) -> NoticeCenter.Choice {
        NoticeCenter.Choice(String(localized: "View")) { [weak self] in _ = self?.showSending(id) }
    }

    public var shownSending: SendingMessage? {
        guard let shownSendingID else { return nil }
        return sending.first { $0.id == shownSendingID }
    }

    public var newestSending: SendingMessage? {
        sending.last { $0.state.isOnItsWay } ?? sending.last
    }

    @discardableResult
    public func showSending(_ id: UUID? = nil) -> Bool {
        let message = id.flatMap { id in sending.first { $0.id == id } } ?? (id == nil ? newestSending : nil)
        guard let message else { return false }
        shownSendingID = message.id
        return true
    }

    public func closeSendingView() {
        shownSendingID = nil
    }

    public func sendingStatus(_ message: SendingMessage, now: Date) -> String {
        switch message.state {
        case .queued:
            let left = message.secondsLeft(now: now)
            return left > 0 ? String(localized: "Sending in \(left) s. You can still undo.")
                            : String(localized: "Sending…")
        case .sending: return String(localized: "Sending…")
        case .waitingForConnection: return String(localized: "Queued. Sends when you're back online.")
        case .sent: return String(localized: "Sent.")
        case .failed: return String(localized: "Couldn't send. Saved as draft.")
        case .scheduled(let at): return String(localized: "Scheduled for \(formatSendAt(at))")
        }
    }

    public func undoSending(_ id: UUID) async {
        guard let entry = sendingUndoEntries[id], let undo = environment.undo else { return }
        await undo.undo(entryID: entry)
    }

    public func retrySending(_ id: UUID) {
        guard let message = sending.first(where: { $0.id == id }), message.offersRetry else { return }
        removeSending(id)
        let opening = openDraft(message.draft)
        track(Task { [weak self] in
            guard let session = await opening.value, let self else { return }
            self.perform(.send, in: session, source: .toolbar)
        })
    }

    public func editSending(_ id: UUID) {
        guard let message = sending.first(where: { $0.id == id }), message.offersEdit else { return }
        closeSendingView()
        if message.state == .failed {
            removeSending(id)
        } else {
            scheduled[id] = nil
        }
        openDraft(message.draft)
    }

    public func showSendingInSent(_ id: UUID) {
        guard let message = sending.first(where: { $0.id == id }), message.offersShowInSent else { return }
        closeSendingView()
        let router = environment.router
        if router.activeAccountID != message.account { router.switchAccount(to: message.account) }
        router.go(to: .system(.sent))
        let data = environment.data
        track(Task { [weak self] in
            var thread = message.thread
            if thread == nil { thread = try? await data.sentConversation(message.draft) }
            guard let self, let thread, self.environment.router.activeAccountID == message.account else { return }
            self.environment.router.open(thread)
        })
    }
}

@MainActor
final class SendingActionHandler: ActionHandler {
    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        environment?.composeIfStarted?.newestSending == nil ? .hidden : .enabled
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        environment?.composeIfStarted?.showSending() == true ? .done : .notHandled
    }
}
