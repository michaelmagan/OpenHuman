import Foundation
import MailActions
import MailModel
import OpenHumanCore

@MainActor
public final class ThreadActionHandler: ActionHandler {
    public static let coreIDs: [ActionID] = [.markDone, .moveToInbox, .trash, .spam, .notSpam, .toggleStar, .toggleRead,
                                             .label, .move, .removeLabel, .createLabel, .toggleCheck,
                                             .extendSelectionDown, .extendSelectionUp, .checkAll, .clearChecks,
                                             .removeLabelAndDone, .checkFromHere]
    public static let moduleIDs: [FeatureModuleID: [ActionID]] = [
        .snooze: [.snooze, .unsnooze], .reminders: [.remind, .clearReminder],
        .unsubscribe: [.unsubscribe, .unsubscribeAndDone, .unsubscribeAndTrash],
        .mute: [.toggleMute],
    ]

    private(set) weak var environment: AppEnvironment?
    private let feedback: ActionFeedback
    public var timeZone: TimeZone = .current
    public var locale: Locale = .current
    // Why: one-click unsubscribe can't be undone once sent, so it waits out the undo toast; Undo drops it
    public var unsubscribeWindow: Duration = NoticeCenter.toastDuration
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    public private(set) var lastTask: Task<Void, Never>?
    private var heldUnsubscribes: [UUID: Task<Void, Never>] = [:]
    private var canceledUnsubscribes: Set<UUID> = []

    init(environment: AppEnvironment, feedback: ActionFeedback) {
        self.environment = environment
        self.feedback = feedback
    }

    private var presenter: (any ActionPresenting)? { environment?.actions.presenter }

    private func canPresent(_ kind: ActionPresentation.Kind) -> ActionAvailability {
        presenter?.canPresent(kind) == true ? .enabled : .hidden
    }

    public func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        switch id {
        case .label, .move, .createLabel: canPresent(.labelPicker)
        case .snooze: canPresent(.snoozePicker)
        case .remind: canPresent(.remindPicker)
        case .unsubscribe, .unsubscribeAndDone, .unsubscribeAndTrash: canPresent(.openURL)
        case .toggleCheck, .extendSelectionDown, .extendSelectionUp, .checkAll, .clearChecks, .checkFromHere:
            (host as? AppRouter)?.active?.list == nil ? .hidden : .enabled
        default: .enabled
        }
    }

    public func perform(_ request: ActionRequest) -> ActionPerformance {
        let c = request.context
        let targets = c.selection
        let n = targets.count
        switch request.id {
        case .markDone:
            return apply(.markDone(targets), request, title: Titles.markDone(n), advances: true)
        case .moveToInbox:
            let command: MailCommand = switch c.location {
            case .system(.trash): .untrash(targets)
            case .system(.spam): .markNotSpam(targets)
            default: .moveToInbox(targets)
            }
            return apply(command, request, title: Titles.movedToInbox(n), advances: true)
        case .trash:
            return apply(.trash(targets), request, title: Titles.trashed(n), advances: true)
        case .spam:
            return apply(.markSpam(targets), request, title: Titles.spam(n), advances: true)
        case .notSpam:
            return apply(.markNotSpam(targets), request, title: Titles.notSpam(n), advances: true)
        case .toggleStar:
            if c.targets.allStarred {
                return apply(.unstar(targets), request, title: Titles.unstarred(n), advances: false)
            }
            let changing = Self.changing(targets, request) { $0.isStarred }
            return apply(.star(changing), request, title: Titles.starred(changing.count), advances: false)
        case .toggleRead:
            let state = request.router?.accounts.first { $0.id == c.account } ?? request.router?.active
            let readMark = state?.pendingReadMark(for: targets)
            if c.targets.anyUnread {
                let changing = Self.changing(targets, request) { !$0.isUnread }
                Self.showWaitingMessages(in: changing, request)
                return apply(.markRead(changing), request, title: Titles.read(changing.count), advances: false,
                             after: readMark)
            }
            return apply(.markUnread(targets), request, title: Titles.unread(n), advances: false, after: readMark)
        case .removeLabel:
            guard case .label(let label) = c.location else { return .notHandled }
            let name = labelName(label, account: c.account, router: request.router)
            return apply(.modifyLabels(targets, add: [], remove: [label]), request, title: Titles.removedLabel(name),
                         advances: true)
        case .removeLabelAndDone:
            guard case .label(let label) = c.location else { return .notHandled }
            let name = labelName(label, account: c.account, router: request.router)
            return apply(.modifyLabels(targets, add: [], remove: [label, GmailLabelID("INBOX")]), request,
                         title: Titles.removedLabelAndDone(name), advances: true)
        case .unsnooze:
            return apply(.unsnooze(targets), request, title: Titles.movedToInbox(n),
                         advances: c.location == .system(.snoozed))
        case .clearReminder:
            guard let thread = c.focusedThread else { return .notHandled }
            return apply(.cancelReminder(thread), request, title: "Reminder cleared",
                         advances: c.location == .system(.reminders))
        case .label, .createLabel:
            return present(.labelPicker(targets: targets, mode: .label))
        case .move:
            return present(.labelPicker(targets: targets, mode: .move))
        case .snooze:
            return present(.snoozePicker(targets: targets))
        case .remind:
            guard let thread = c.focusedThread else { return .notHandled }
            return present(.remindPicker(thread: thread))
        case .unsubscribe:
            return startUnsubscribe(request)
        case .unsubscribeAndDone:
            return startUnsubscribe(request, then: .markDone)
        case .unsubscribeAndTrash:
            return startUnsubscribe(request, then: .trash)
        case .toggleMute:
            return toggleMute(request)
        case .toggleCheck, .extendSelectionDown, .extendSelectionUp, .checkAll, .clearChecks, .checkFromHere:
            return select(request)
        default:
            return .notHandled
        }
    }

    @discardableResult
    public func snooze(_ targets: [ThreadKey], until date: Date, host: (any ActionHost)?,
                       source: ActionSource = .palette) -> Task<Void, Never>? {
        guard !targets.isEmpty else { return nil }
        let request = callbackRequest(.snooze, targets: targets, host: host, source: source)
        return task(apply(.snooze(targets, until: date), request, title: Titles.snoozed(time(date)), advances: true))
    }

    @discardableResult
    public func remind(_ thread: ThreadKey, at date: Date, kind: ReminderKind,
                       host: (any ActionHost)?, source: ActionSource = .palette) -> Task<Void, Never>? {
        let request = callbackRequest(.remind, targets: [thread], host: host, source: source)
        let title = ReminderItem.isSomeday(date) ? Titles.reminderSomeday(ifNoReply: kind == .ifNoReply)
                                                 : Titles.reminderSet(time(date), ifNoReply: kind == .ifNoReply)
        return task(apply(.setReminder(thread, dueAt: date, kind: kind), request, title: title, advances: false))
    }

    @discardableResult
    public func setLabels(_ targets: [ThreadKey], add: [LabelInfo], remove: [LabelInfo],
                          host: (any ActionHost)?) -> Task<Void, Never>? {
        guard !targets.isEmpty, !(add.isEmpty && remove.isEmpty) else { return nil }
        let request = callbackRequest(.label, targets: targets, host: host)
        let title: LocalizedStringResource = switch (add.count, remove.count) {
        case (1, 0): Titles.labeled(add[0].displayName)
        case (0, 1): Titles.removedLabel(remove[0].displayName)
        default: "Updated labels"
        }
        return task(apply(.modifyLabels(targets, add: add.map(\.labelID), remove: remove.map(\.labelID)), request,
                          title: title, advances: false))
    }

    @discardableResult
    public func move(_ targets: [ThreadKey], to label: LabelInfo, host: (any ActionHost)?) -> Task<Void, Never>? {
        guard !targets.isEmpty else { return nil }
        let request = callbackRequest(.move, targets: targets, host: host)
        return task(apply(.modifyLabels(targets, add: [label.labelID], remove: [GmailLabelID("INBOX")]), request,
                          title: Titles.moved(label.displayName), advances: true))
    }

    @discardableResult
    public func moveToSplit(_ targets: [ThreadKey], split: SplitInfo, label: LabelInfo,
                            host: (any ActionHost)?) -> Task<Void, Never>? {
        guard !targets.isEmpty else { return nil }
        let request = callbackRequest(.move, targets: targets, host: host)
        return task(apply(.modifyLabels(targets, add: [label.labelID], remove: [GmailLabelID("INBOX")]), request,
                          title: Titles.moved(split.name), advances: true))
    }

    @discardableResult
    public func moveToPlace(_ place: MovePlace, context: ActionContext, host: (any ActionHost)?) -> Task<Void, Never>? {
        guard let registry = environment?.actions else { return nil }
        let performed = registry.performCount
        guard registry.perform(place.actionID, source: .palette, host: host, context: context),
              registry.performCount > performed else { return nil }
        if let task = registry.lastTask { lastTask = task }
        return registry.lastTask
    }

    @discardableResult
    public func createLabel(named name: String, account: AccountID, applyTo targets: [ThreadKey],
                            host: (any ActionHost)?) -> Task<Void, Never>? {
        guard let commands = environment?.commands, let undo = environment?.undo else { return nil }
        let list = (host as? AppRouter)?.accounts.first { $0.id == account }?.list
        let ticket = list?.applyOptimisticLabel(named: name, to: targets)
        let restore: @MainActor () -> Void = { [weak list] in if let ticket { list?.revertOptimistic(ticket) } }
        let feedback = self.feedback
        let task = Task {
            do {
                try await undo.perform(Titles.createdLabel(name), threads: targets) {
                    try await commands.createLabel(account, name: name, applyTo: targets)
                }
            } catch {
                restore()
                feedback.failed("Couldn't create label \(name)")
            }
        }
        lastTask = task
        return task
    }

    @discardableResult
    public func markDone(_ targets: [ThreadKey], host: (any ActionHost)?) -> Task<Void, Never>? {
        guard !targets.isEmpty else { return nil }
        let request = callbackRequest(.markDone, targets: targets, host: host)
        return task(apply(.markDone(targets), request, title: Titles.markDone(targets.count), advances: true,
                          consumesChecks: false))
    }

    func markReadWhenShown(_ key: ThreadKey, shown: [MessageSummary], in state: AccountState) -> Task<Void, Never>? {
        guard let environment, state.reader?.thread == key, shown.contains(where: \.isUnread) else { return nil }
        let through = max(shown.map(\.date).max() ?? .distantPast, state.list?.row(for: key)?.lastMessageAt ?? .distantPast)
        guard let commands = environment.commands else {
            state.markReadLocally(key, through: through)
            return nil
        }
        let command = MailCommand.markRead([key])
        let list = state.list
        let ticket = list?.applyOptimistic(command)
        return Task {
            do {
                _ = try await commands.apply(command)
            } catch {
                if let ticket { list?.revertOptimistic(ticket) }
                Log(.app).notice("mark read on open not applied: \(String(describing: type(of: error)))")
            }
        }
    }

    func apply(_ command: MailCommand, _ request: ActionRequest, title: LocalizedStringResource,
               advances: Bool, failure: String? = nil, steps: MailSteps? = nil,
               consumesChecks: Bool = true, after: Task<Void, Never>? = nil) -> ActionPerformance {
        guard let commands = environment?.commands, let undo = environment?.undo else {
            feedback.refuse(request.id, .unavailable(ActionCatalog.descriptor(request.id)?.title ?? "This action"))
            return .done
        }
        guard !command.threads.isEmpty else { return .notHandled }
        let title = request.source == .intent ? Titles.fromShortcuts(title) : title
        let local = applyLocally(command, request, advances: advances, consumesChecks: consumesChecks)
        let feedback = self.feedback
        let task = Task {
            await after?.value
            await Self.run(command, title: title, undo: undo, commands: commands, feedback: feedback,
                           failure: failure, steps: steps, reopens: local.reopens, onFailure: local.restore)
        }
        return .started(task)
    }

    struct LocalChange {
        let reopens: UndoCoordinator.Entry.Reopen?
        let restore: @MainActor () -> Void
    }

    func applyLocally(_ command: MailCommand, _ request: ActionRequest, advances: Bool,
                      consumesChecks: Bool = true) -> LocalChange {
        let router = request.router
        let state = router?.accounts.first { $0.id == request.context.account } ?? router?.active
        let fromIntent = request.source == .intent
        var checked: [ThreadKey] = []
        if consumesChecks, !fromIntent, let state {
            checked = state.selection.targets(cursor: nil, order: state.list?.rows.map(\.id) ?? [])
            state.selection.clearChecked()
        }
        var reopens: UndoCoordinator.Entry.Reopen?
        if advances, !fromIntent, let router, let state {
            reopens = Self.advance(past: command.threads, in: state, router: router)
        }
        if let reopens { keepDraft(of: reopens.thread) }
        let list = state?.list
        let ticket = list?.applyOptimistic(command)
        return LocalChange(reopens: reopens) { [weak list, weak router, weak state] in
            if let ticket { list?.revertOptimistic(ticket) }
            if let state, !checked.isEmpty, state.selection.checked.isEmpty { state.selection.restoreChecked(checked) }
            if let reopens, let state { router?.reopen(reopens, in: state) }
        }
    }

    private static func run(_ command: MailCommand, title: LocalizedStringResource,
                            undo: UndoCoordinator, commands: any MailCommanding, feedback: ActionFeedback,
                            failure: String? = nil, steps: MailSteps? = nil, reopens: UndoCoordinator.Entry.Reopen? = nil,
                            onFailure: @MainActor () -> Void = {}) async {
        do {
            try await undo.perform(title, threads: command.threads, via: steps?.undoer(commands), reopens: reopens) {
                if let steps { return try await steps.perform(commands) }
                return try await commands.apply(command)
            }
        } catch {
            onFailure()
            feedback.failed(failure ?? Titles.failure(command)) {
                await run(command, title: title, undo: undo, commands: commands, feedback: feedback,
                          failure: failure, steps: steps)
            }
        }
    }

    func retry(_ command: MailCommand) async {
        guard let commands = environment?.commands, let undo = environment?.undo else {
            feedback.refuse(.markDone, .unavailable(String(localized: "Retry")))
            return
        }
        await Self.run(command, title: Titles.done(command), undo: undo, commands: commands, feedback: feedback)
    }

    static func changing(_ targets: [ThreadKey], _ request: ActionRequest,
                         alreadyThere: (ThreadRow) -> Bool) -> [ThreadKey] {
        let router = request.router
        let list = (router?.accounts.first { $0.id == request.context.account } ?? router?.active)?.list
        let changing = targets.filter { key in list?.row(for: key).map(alreadyThere) != true }
        return changing.isEmpty ? targets : changing
    }

    static func showWaitingMessages(in targets: [ThreadKey], _ request: ActionRequest) {
        guard let reader = request.router?.active?.reader, targets.contains(reader.thread) else { return }
        reader.showNewMessages()
    }

    @discardableResult
    static func advance(past targets: [ThreadKey], in state: AccountState,
                        router: AppRouter) -> UndoCoordinator.Entry.Reopen? {
        guard state.mode == .reader, let current = state.reader?.thread, targets.contains(current) else { return nil }
        var shown: ThreadKey?
        if let next = state.neighbor(of: current), !targets.contains(next) {
            state.open(next)
            shown = next
        } else {
            state.closeReader()
        }
        router.setNeedsPersist()
        return UndoCoordinator.Entry.Reopen(thread: current, shown: shown)
    }

    private func present(_ presentation: ActionPresentation) -> ActionPerformance {
        guard let presenter, presenter.canPresent(presentation.kind) else { return .notHandled }
        presenter.present(presentation)
        return .done
    }

    private func startUnsubscribe(_ request: ActionRequest, then followUp: ActionID? = nil) -> ActionPerformance {
        guard let message = request.context.focusedMessage, let environment else { return .notHandled }
        let data = environment.data
        let sender = request.context.senderDomain ?? request.context.sender
        let fromKey = request.source == .keyboard
        let thread = request.context.focusedThread
        let sweep = SenderSweep(address: request.context.sender, account: request.context.account ?? thread?.account,
                                thread: thread)
        let task = Task { [weak self] in
            let info: UnsubscribeInfo?
            do { info = try await data.unsubscribeInfo(message) } catch { info = nil }
            guard let self else { return }
            guard let info else {
                self.environment?.notices.post("This message has no unsubscribe link", style: .info,
                                               duration: NoticeCenter.infoDuration)
                return
            }
            switch info {
            case .oneClick(let listHost):
                await self.holdOneClick(message, from: sender ?? listHost, sweep: sweep, then: followUp, request: request)
            case .mailto(let address, let subject):
                _ = self.present(.compose(.mailto(address, subject: subject)))
                if let followUp { await self.clearSender(sweep, followUp, request: request) }
            case .link(let url):
                if fromKey && followUp == nil {
                    self.environment?.notices.postChoice(
                        "This sender's unsubscribe is a web page",
                        NoticeCenter.Choice("Open unsubscribe page") { [weak self] in _ = self?.present(.openURL(url)) },
                        NoticeCenter.Choice("Cancel") {})
                    return
                }
                _ = self.present(.openURL(url))
                if let followUp { await self.clearSender(sweep, followUp, request: request) }
            }
        }
        return .started(task)
    }

    private static func localChange(_ followUp: ActionID?, _ thread: ThreadKey) -> MailCommand {
        followUp == .trash ? .trash([thread]) : .markDone([thread])
    }

    private func clearSender(_ sweep: SenderSweep, _ followUp: ActionID, request: ActionRequest) async {
        if let thread = sweep.thread {
            let title = followUp == .trash ? Titles.trashed(1) : Titles.markDone(1)
            await task(apply(Self.localChange(followUp, thread), request, title: title, advances: true))?.value
        }
        await sweepSender(sweep.others, followUp, host: request.host)
    }

    private func holdOneClick(_ message: MessageKey, from sender: String, sweep: SenderSweep, then followUp: ActionID?,
                              request: ActionRequest) async {
        guard let environment, let commands = environment.commands, let undo = environment.undo else {
            feedback.refuse(.unsubscribe, .unavailable("Unsubscribe"))
            return
        }
        let id = UUID()
        let window = unsubscribeWindow
        let change = sweep.thread.map { Self.localChange(followUp, $0) }
        let local = change.map { applyLocally($0, request, advances: true) }
        let entry: UndoCoordinator.Entry
        do {
            entry = try await undo.perform("Unsubscribing from \(sender)…", threads: change?.threads ?? [],
                                           via: UnsubscribeUndoer(handler: self, id: id, port: commands),
                                           reopens: local?.reopens,
                                           expiresAt: Date().addingTimeInterval(NoticeCenter.seconds(window))) {
                guard let change else { return UndoToken(payload: Data()) }
                return try await commands.apply(change)
            }
        } catch {
            local?.restore()
            feedback.failed("Couldn't unsubscribe from \(sender). Nothing was sent.")
            return
        }
        let sleep = self.sleep
        let host = request.host
        heldUnsubscribes[id] = Task { [weak self, weak host] in
            do { try await sleep(window) } catch { return }
            guard let self, self.heldUnsubscribes.removeValue(forKey: id) != nil else { return }
            await self.sendUnsubscribe(message, undoing: entry, commands: commands, sweep: sweep, then: followUp,
                                       host: host)
        }
    }

    func cancelUnsubscribe(_ id: UUID) {
        guard let held = heldUnsubscribes.removeValue(forKey: id) else {
            guard !canceledUnsubscribes.contains(id) else { return }
            environment?.notices.post("Too late to undo: the unsubscribe request was already sent.", style: .info,
                                      duration: NoticeCenter.infoDuration)
            return
        }
        held.cancel()
        canceledUnsubscribes.insert(id)
        environment?.notices.post("Unsubscribe canceled. Nothing was sent.", style: .info,
                                  duration: NoticeCenter.infoDuration)
    }

    var heldUnsubscribeCount: Int { heldUnsubscribes.count }
    var heldUnsubscribeTasks: [Task<Void, Never>] { Array(heldUnsubscribes.values) }

    private func sendUnsubscribe(_ message: MessageKey, undoing entry: UndoCoordinator.Entry,
                                 commands: any MailCommanding, sweep: SenderSweep, then followUp: ActionID?,
                                 host: (any ActionHost)?) async {
        do {
            try await commands.unsubscribe(message)
        } catch {
            await putBack(entry, commands: commands)
            feedback.failed("Couldn't send the unsubscribe request")
            return
        }
        guard let environment else { return }
        if let followUp {
            environment.notices.post("Unsubscribe request sent", style: .info, duration: NoticeCenter.infoDuration)
            await sweepSender(sweep.others, followUp, host: host)
            return
        }
        await offerCleanup(sweep, host: host)
    }

    private func putBack(_ entry: UndoCoordinator.Entry, commands: any MailCommanding) async {
        guard let undo = environment?.undo else { return }
        undo.discard(entry.id)
        guard !entry.token.payload.isEmpty else { return }
        do { _ = try await commands.undo(entry.token) } catch { return }
        undo.onUndone?(entry)
    }

    static func cleanupMessage(count: Int, capped: Bool, hasAddress: Bool, leftOut: Int = 0) -> String {
        guard hasAddress else { return "Unsubscribe request sent" }
        let number = capped ? "\(count)+" : "\(count)"
        var text = "Unsubscribe request sent. \(number) \(count == 1 ? "conversation" : "conversations") from this sender "
            + "on this Mac."
        if leftOut > 0 { text += " Trash leaves out \(leftOut) you're part of." }
        return text
    }

    private func offerCleanup(_ sweep: SenderSweep, host: (any ActionHost)?) async {
        guard let environment else { return }
        let plain = "Unsubscribe request sent"
        guard environment.system.preferences.unsubscribeCleanupOffer else {
            environment.notices.post(plain, style: .info, duration: NoticeCenter.infoDuration)
            return
        }
        let trash = await sweepPlan(sweep, scope: .all)
        guard !trash.targets.isEmpty else {
            environment.notices.post(plain, style: .info, duration: NoticeCenter.infoDuration)
            return
        }
        let archive = await sweepPlan(sweep.others, scope: .inbox)
        func label(_ plan: SweepPlan) -> String { plan.capped ? "\(plan.targets.count)+" : "\(plan.targets.count)" }
        let message = Self.cleanupMessage(count: trash.targets.count + trash.leftOut, capped: trash.capped,
                                          hasAddress: sweep.address != nil, leftOut: trash.leftOut)
        let moveToTrash = NoticeCenter.Choice("Move \(label(trash)) to Trash") { [weak self, weak host] in
            await self?.sweepSender(sweep, .trash, scope: .all, host: host)
        }
        guard !archive.targets.isEmpty else {
            environment.notices.post(message, style: .info, actionTitle: moveToTrash.title,
                                     duration: Self.cleanupOfferDuration, action: moveToTrash.action)
            return
        }
        environment.notices.postChoice(
            message,
            NoticeCenter.Choice("Archive all \(label(archive))") { [weak self, weak host] in
                await self?.sweepSender(sweep.others, .markDone, scope: .inbox, host: host)
            },
            moveToTrash,
            duration: Self.cleanupOfferDuration)
    }

    static let cleanupOfferDuration: Duration = .seconds(12)

    private func select(_ request: ActionRequest) -> ActionPerformance {
        guard let state = request.router?.active, let list = state.list else { return .notHandled }
        let rows = list.rows.map(\.id)
        switch request.id {
        case .toggleCheck:
            guard let cursor = list.cursor else { return .notHandled }
            state.selection.toggle(cursor)
        case .extendSelectionDown, .extendSelectionUp:
            guard let from = list.cursor else { return .notHandled }
            list.moveCursor(by: request.id == .extendSelectionDown ? 1 : -1)
            guard let to = list.cursor else { return .notHandled }
            state.selection.extend(to: to, from: from, in: rows)
        case .checkAll:
            guard !rows.isEmpty else { return .notHandled }
            state.selection.checkAll(in: rows)
        case .checkFromHere:
            guard !rows.isEmpty else { return .notHandled }
            state.selection.checkFromHere(cursor: list.cursor, in: rows)
        case .clearChecks:
            let searching = if case .search? = state.location { true } else { state.searchOpen }
            if state.selection.checked.isEmpty, searching {
                environment?.overlays.search.close()
            } else {
                state.selection.clearChecked()
            }
        default:
            return .notHandled
        }
        return .done
    }

    private func callbackRequest(_ id: ActionID, targets: [ThreadKey], host: (any ActionHost)?,
                                 source: ActionSource = .palette) -> ActionRequest {
        var context = (host as? AppRouter)?.contentContext() ?? host?.actionContext() ?? ActionContext()
        context.selection = targets
        context.account = targets.first?.account ?? context.account
        return ActionRequest(id: id, context: context, source: source, host: host)
    }

    private func task(_ performance: ActionPerformance) -> Task<Void, Never>? {
        guard case .started(let task) = performance else { return nil }
        lastTask = task
        return task
    }

    private func labelName(_ label: GmailLabelID, account: AccountID?, router: AppRouter?) -> String {
        let state = router?.accounts.first { $0.id == account }
        return state?.labels.first { $0.labelID == label }?.displayName ?? label.rawValue
    }

    func time(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        style = style.weekday(.abbreviated)
        return date.formatted(style)
    }
}

@MainActor
final class UnsubscribeUndoer: MailUndoing {
    private weak var handler: ThreadActionHandler?
    private let id: UUID
    private let port: any MailUndoing

    init(handler: ThreadActionHandler, id: UUID, port: any MailUndoing) {
        self.handler = handler
        self.id = id
        self.port = port
    }

    nonisolated func undo(_ token: UndoToken) async throws -> UndoToken? {
        await cancel()
        if !token.payload.isEmpty { _ = try await port.undo(token) }
        return nil
    }

    private func cancel() { handler?.cancelUnsubscribe(id) }
}

enum Titles {
    static func markDone(_ n: Int) -> LocalizedStringResource { n == 1 ? "Marked done" : "Marked \(n) conversations done" }
    static func movedToInbox(_ n: Int) -> LocalizedStringResource {
        n == 1 ? "Moved to Inbox" : "Moved \(n) conversations to Inbox"
    }
    static func trashed(_ n: Int) -> LocalizedStringResource { n == 1 ? "Moved to Trash" : "Moved \(n) conversations to Trash" }
    static func spam(_ n: Int) -> LocalizedStringResource { n == 1 ? "Marked as spam" : "Marked \(n) conversations as spam" }
    static func notSpam(_ n: Int) -> LocalizedStringResource { n == 1 ? "Marked not spam" : "Marked \(n) conversations not spam" }
    static func starred(_ n: Int) -> LocalizedStringResource { n == 1 ? "Starred" : "Starred \(n) conversations" }
    static func unstarred(_ n: Int) -> LocalizedStringResource { n == 1 ? "Unstarred" : "Unstarred \(n) conversations" }
    static func read(_ n: Int) -> LocalizedStringResource { n == 1 ? "Marked read" : "Marked \(n) conversations read" }
    static func unread(_ n: Int) -> LocalizedStringResource { n == 1 ? "Marked unread" : "Marked \(n) conversations unread" }
    static func labeled(_ name: String) -> LocalizedStringResource { "Labeled \(name)" }
    static func removedLabel(_ name: String) -> LocalizedStringResource { "Removed label \(name)" }
    static func removedLabelAndDone(_ name: String) -> LocalizedStringResource { "Removed label \(name) and marked done" }
    static func moved(_ name: String) -> LocalizedStringResource { "Moved to \(name)" }
    static func createdLabel(_ name: String) -> LocalizedStringResource { "Created label \(name)" }
    static func snoozed(_ time: String) -> LocalizedStringResource { "Snoozed until \(time)" }
    static func reminderSet(_ time: String, ifNoReply: Bool) -> LocalizedStringResource {
        ifNoReply ? "Reminder set for \(time) if no reply" : "Reminder set for \(time)"
    }
    static func fromShortcuts(_ title: LocalizedStringResource) -> LocalizedStringResource {
        "\(String(localized: title)) from Shortcuts"
    }

    static func reminderSomeday(ifNoReply: Bool) -> LocalizedStringResource {
        ifNoReply ? "Reminder set for someday if no reply" : "Reminder set for someday"
    }

    static func done(_ command: MailCommand) -> LocalizedStringResource {
        let n = command.threads.count
        switch command {
        case .markDone: return markDone(n)
        case .moveToInbox, .untrash, .unsnooze: return movedToInbox(n)
        case .trash: return trashed(n)
        case .markSpam: return spam(n)
        case .markNotSpam: return notSpam(n)
        case .star: return starred(n)
        case .unstar: return unstarred(n)
        case .markRead: return read(n)
        case .markUnread: return unread(n)
        case .modifyLabels, .snooze, .clearSnooze, .setReminder, .cancelReminder: return "Changed in Gmail"
        }
    }

    static func failure(_ command: MailCommand) -> String {
        let n = command.threads.count
        let what = n == 1 ? "1 conversation" : "\(n) conversations"
        return switch command {
        case .markDone: "Couldn't mark \(what) done"
        case .trash: "Couldn't move \(what) to Trash"
        case .moveToInbox, .untrash, .unsnooze: "Couldn't move \(what) to Inbox"
        case .markSpam: "Couldn't mark \(what) as spam"
        case .markNotSpam: "Couldn't mark \(what) not spam"
        case .star, .unstar: "Couldn't change the star on \(what)"
        case .markRead, .markUnread: "Couldn't change \(what)"
        case .modifyLabels: "Couldn't change labels on \(what)"
        case .snooze: "Couldn't snooze \(what)"
        case .clearSnooze: "Couldn't end the snooze of \(what)"
        case .setReminder: "Couldn't set the reminder"
        case .cancelReminder: "Couldn't clear the reminder"
        }
    }
}
