import Foundation
import MailActions
import MailModel
import OpenHumanCore

extension ComposeManager {
    @discardableResult
    public func perform(_ id: ActionID, in session: ComposeSession, source: ActionSource = .toolbar) -> Bool {
        let registry = environment.actions
        if case .disabled(let reason) = registry.availability(id, host: session), reason.announces,
           id == .send || id == .sendLater {
            session.notice = refusal(for: session)
        }
        return registry.perform(id, source: source, host: session)
    }

    func refusal(for session: ComposeSession) -> ComposeSession.Notice {
        ComposeSession.Notice(.error, String(localized: "Not sent: sending isn't available here."))
    }

    var canSend: Bool { environment.commands != nil }

    public var canSendInThisProcess: Bool { canSend }

    public var offersSendLater: Bool { environment.actions.contains(.sendLater) }

    func send(_ session: ComposeSession) -> ActionPerformance {
        guard session.isOpen else { return .notHandled }
        guard canSend else {
            session.notice = refusal(for: session)
            refuseRowAction(.send)
            return .done
        }
        guard sendsStarting.insert(session.id).inserted else { return .done }
        return .started(Task {
            await self.performSend(session)
            self.sendsStarting.remove(session.id)
        })
    }

    private func performSend(_ session: ComposeSession) async {
        await session.preparation?.value
        await session.fromResolution?.value
        guard session.isOpen, held[session.id] == nil, canSend, let commands = environment.commands else { return }
        if let blocked = blockingNotice(session) {
            session.notice = blocked
            return
        }
        if session.linkRecipients != nil, !session.linkConfirmed {
            session.isLinkConfirmationShown = true
            return
        }
        let unfilled = session.unfilledPlaceholders
        if !unfilled.isEmpty, !session.placeholdersAcknowledged {
            session.placeholdersAcknowledged = true
            let names = unfilled.map { "“\($0)”" }.joined(separator: ", ")
            session.notice = ComposeSession.Notice(.warning, String(localized: "\(names) may still need filling in. Press ⌘↵ again to send anyway."))
            return
        }
        if warnsBeforeSending(session, .send) { return }
        if await asksSendConfirmation(session, .send) { return }
        guard await session.save(force: true), let key = session.draftKey else {
            session.notice = ComposeSession.Notice(.error, String(localized: "Couldn't save the draft, so it wasn't sent."),
                                                   offersSendAgain: true)
            return
        }
        let seconds = AppSettings.undoSendHold(await Self.read(environment.settings, AppSettings.undoSendSeconds) ?? 10)
        undoSendSeconds = seconds
        let marksDone = await marksDoneWhenSent(session)
        session.expectsDraftGone = true
        let token: SendToken
        do {
            token = try await commands.send(key, undoWindow: .seconds(seconds))
            await rememberSendReminder(of: session, draft: key)
        } catch {
            session.expectsDraftGone = false
            let detail = (error as? MailPortError)?.description ?? String(localized: "Try again.")
            session.notice = ComposeSession.Notice(.error, String(localized: "Couldn't send. \(detail)"), offersSendAgain: true)
            return
        }
        var earlier: Set<MessageKey> = []
        if let thread = session.thread { earlier = await knownMessages(in: thread) }
        addOutgoing(session, earlier: earlier)
        hide(session)
        returnToList(after: session)
        let heldSend = HeldSend(session: session, token: token)
        held[session.id] = heldSend
        if marksDone, let thread = session.thread { await archiveAfterSend(PendingSendDone(draft: key, thread: thread)) }
        let title: LocalizedStringResource = session.mode == .reply || session.mode == .replyAll
            ? "Reply sent."
            : "Sending to \(Self.recipientSummary(session.allRecipients))…"
        let expiresAt = Date().addingTimeInterval(token.sendAfter.timeIntervalSince(timing.now()))
        addSending(session, draft: key, state: .queued(until: expiresAt))
        push(title, .send(session: session.id, token: token), expiresAt: expiresAt, view: session.id)
        track(watchHeldSend(heldSend, draft: key))
    }

    static func recipientSummary(_ recipients: [EmailAddress]) -> String {
        let names = recipients.map(RecipientParser.displayName)
        switch names.count {
        case 0: return String(localized: "no one")
        case 1: return names[0]
        case 2: return String(localized: "\(names[0]) and \(names[1])")
        default: return String(localized: "\(names[0]) and \(names.count - 1) others")
        }
    }

    func blockingNotice(_ session: ComposeSession) -> ComposeSession.Notice? {
        if session.instantReply?.isPreviewingUnaccepted == true {
            session.instantReply?.sendRefused()
            return ComposeSession.Notice(.warning, String(localized: "The quick reply isn't in your message yet. Press ↵ to put it in, or type your own."))
        }
        for field in [session.to, session.cc, session.bcc] { field.commitText() }
        if session.allRecipients.isEmpty {
            return ComposeSession.Notice(.error, String(localized: "Add at least one recipient."))
        }
        if let invalid = (session.to.invalidTokens + session.cc.invalidTokens + session.bcc.invalidTokens).first {
            return ComposeSession.Notice(.error, String(localized: "“\(invalid.email)” is not a valid address. Fix it before sending."))
        }
        if session.attachmentBytes > AttachmentLimits.maxTotalBytes { return ComposeSession.tooLargeNotice }
        return nil
    }

    private func watchHeldSend(_ heldSend: HeldSend, draft key: DraftKey) -> Task<Void, Never> {
        let timing = self.timing
        let (session, token) = (heldSend.session, heldSend.token)
        return Task { [weak self] in
            let wait = token.sendAfter.timeIntervalSince(timing.now())
            if wait > 0 { try? await timing.sleep(.milliseconds(Int(wait * 1000))) }
            guard let self, self.held[session.id]?.watcher == heldSend.watcher else { return }
            self.held[session.id] = nil
            self.setOutgoing(session.id, .sending)
            self.setSending(session.id, .sending)
            await self.reportOutcome(session, token: token, draft: key)
        }
    }

    private func reportOutcome(_ session: ComposeSession, token: SendToken, draft key: DraftKey) async {
        let queued = QueuedSendNotice(manager: self, session: session.id, account: session.account.id)
        defer { queued.stop() }
        do {
            for try await row in environment.data.draft(key) {
                guard let row else {
                    sent(session, draft: key)
                    return
                }
                switch row.status {
                case .sending:
                    queued.stillSending()
                case .sent:
                    sent(session, draft: key)
                    return
                case .failed, .editing:
                    sendFailed(session, draft: key)
                    return
                case .scheduled, .discarded:
                    setOutgoing(session.id, nil)
                    removeSending(session.id)
                    if row.status == .scheduled { releaseSendDone(key) } else { forgetSendDone(key) }
                    return
                }
            }
        } catch {}
    }

    private func sent(_ session: ComposeSession, draft key: DraftKey) {
        session.stopObserving()
        recovery.remove(key)
        setOutgoing(session.id, .sent)
        setSending(session.id, .sent)
        let id = session.id
        environment.notices.post(String(localized: "Sent."), style: .info, actionTitle: String(localized: "View"),
                                 duration: environment.notices.timing.brief) { [weak self] in _ = self?.showSending(id) }
        sendWentOut(key, thread: session.thread)
        if session.scheduling != nil { environment.schedulingIfStarted?.replySent(session) }
        if session.pendingReminder != nil {
            track(Task { await self.setPendingReminder(of: session, draft: key) })
        } else {
            track(Task { await self.setAutoReminder(of: session, draft: key) })
        }
    }

    private func sendFailed(_ session: ComposeSession, draft key: DraftKey) {
        forgetSendDone(key)
        session.expectsDraftGone = false
        setOutgoing(session.id, nil)
        setSending(session.id, .failed)
        let id = session.id
        environment.notices.post(String(localized: "Couldn't send. Saved as draft."), style: .error,
                                 actionTitle: String(localized: "Open draft"), duration: nil,
                                 secondary: viewChoice(id)) { [weak self] in
            self?.removeSending(id)
            self?.openDraft(key)
        }
    }

    func undoSend(session id: UUID, token: SendToken) async throws {
        guard let heldSend = held.removeValue(forKey: id), let commands = environment.commands else { return }
        let cancelled: Bool
        do {
            cancelled = try await commands.cancelSend(token)
        } catch {
            let again = HeldSend(session: heldSend.session, token: token)
            held[id] = again
            track(watchHeldSend(again, draft: token.draft))
            throw error
        }
        if cancelled {
            forgetSendDone(token.draft)
            setOutgoing(id, nil)
            removeSending(id)
            showPlace(of: heldSend.session)
            reopen(heldSend.session)
        } else {
            setOutgoing(id, .sending)
            setSending(id, .sending)
            environment.notices.post(String(localized: "Too late to undo: the message is already on its way."),
                                     style: .info, duration: NoticeCenter.infoDuration)
            track(Task { [weak self] in await self?.reportOutcome(heldSend.session, token: token, draft: token.draft) })
        }
    }

    func asksSendConfirmation(_ session: ComposeSession, _ kind: ComposeSession.SendConfirmation.Kind) async -> Bool {
        guard environment.isLiveAccount else { return false }
        if session.sendConfirmed {
            session.sendConfirmed = false
            return false
        }
        guard await Self.read(environment.settings, SendSettings.confirmEverySend) ?? false else { return false }
        let who = Self.recipientSummary(session.allRecipients)
        let when: String? = if case .schedule(let date) = kind { formatSendAt(date) } else { nil }
        let title = when == nil ? String(localized: "Send this message?") : String(localized: "Schedule this message?")
        let message = when.map { String(localized: "It goes out at \($0), to \(who).") }
            ?? String(localized: "It goes to \(who).")
        let confirm = when == nil ? String(localized: "Send") : String(localized: "Schedule")
        session.sendConfirmation = ComposeSession.SendConfirmation(kind: kind, title: title, message: message,
                                                                   confirmTitle: confirm)
        return true
    }

    public func confirmSend(in session: ComposeSession, stopAsking: Bool = false) {
        guard let card = session.sendConfirmation else { return }
        session.sendConfirmation = nil
        session.sendConfirmed = true
        if stopAsking, let settings = environment.settings {
            track(Task { try? await settings.set(SendSettings.confirmEverySend, false) })
        }
        switch card.kind {
        case .send:
            perform(.send, in: session, source: .keyboard)
        case .schedule(let date):
            track(Task { [weak self] in await self?.schedule(session, at: date) })
        }
    }

    func warnsBeforeSending(_ session: ComposeSession, _ kind: ComposeSession.SendConfirmation.Kind) -> Bool {
        guard environment.isLiveAccount else { return false }
        if session.preSendChecked {
            session.preSendChecked = false
            return false
        }
        guard let warning = PreSendWarning(issues: session.preSendIssues, kind: kind) else { return false }
        session.preSendWarning = warning
        return true
    }

    public func confirmPreSendWarning(_ warning: PreSendWarning, in session: ComposeSession) {
        session.preSendWarning = nil
        session.preSendChecked = true
        switch warning.kind {
        case .send:
            perform(.send, in: session, source: .keyboard)
        case .schedule(let date):
            track(Task { [weak self] in await self?.schedule(session, at: date) })
        }
    }

    func sendLater(_ session: ComposeSession) -> ActionPerformance {
        guard session.isOpen else { return .notHandled }
        guard canSend else {
            session.notice = refusal(for: session)
            refuseRowAction(.sendLater)
            return .done
        }
        guard session.source == .user || session.review == .approved else {
            session.notice = ComposeSession.Notice(.error, String(localized: "An agent wrote this draft. Review it before scheduling it."))
            return .done
        }
        environment.overlays.presentSendLater(draftTargets: session.thread.map { [$0] } ?? [],
                                              condition: session.sendAt == nil ? .always : session.sendCondition,
                                              scheduleWithCondition: { [weak self] date, condition in
            guard let self else { return }
            self.track(Task { await self.schedule(session, at: date, condition: condition) })
        })
        return .done
    }

    func schedule(_ session: ComposeSession, at date: Date, condition: SendLaterCondition? = nil) async {
        let condition = condition ?? pendingSendConditions.removeValue(forKey: session.id) ?? .always
        await session.preparation?.value
        await session.fromResolution?.value
        guard canSend, let commands = environment.commands else {
            session.notice = refusal(for: session)
            return
        }
        if let blocked = blockingNotice(session) {
            session.notice = blocked
            return
        }
        guard date.timeIntervalSince(timing.now()) >= Self.restoreLead else {
            session.notice = ComposeSession.Notice(.error, Self.tooSoonText)
            return
        }
        if session.linkRecipients != nil, !session.linkConfirmed {
            session.linkScheduleDate = date
            session.linkScheduleCondition = condition
            session.isLinkConfirmationShown = true
            return
        }
        if warnsBeforeSending(session, .schedule(date)) {
            pendingSendConditions[session.id] = condition
            return
        }
        if await asksSendConfirmation(session, .schedule(date)) {
            pendingSendConditions[session.id] = condition
            return
        }
        hide(session)
        returnToList(after: session)
        guard await session.save(force: true), let key = session.draftKey else {
            bringBack(session, String(localized: "Couldn't save the draft, so it wasn't scheduled."))
            return
        }
        let previous = session.sendAt
        let previousCondition = session.sendCondition
        do {
            if condition == .always {
                try await commands.scheduleSend(key, at: date)
            } else {
                try await commands.scheduleSend(key, at: date, condition: condition)
            }
        } catch {
            let detail = (error as? MailPortError)?.description ?? String(localized: "Try again.")
            bringBack(session, String(localized: "Couldn't schedule. \(detail)"))
            return
        }
        session.stopObserving()
        scheduled[session.id] = session
        addSending(session, draft: key, state: .scheduled(at: date))
        let when = formatSendAt(date) + (condition == .ifNoReply ? Self.ifNoReplySuffix : "")
        if let previous {
            push("Rescheduled for \(when)", .reschedule(draft: key.rawValue, to: previous, condition: previousCondition),
                 view: session.id)
        } else {
            push("Scheduled for \(when)", .schedule(session: session.id, draft: key.rawValue), view: session.id)
        }
        setPendingReminderOnSchedule(session)
    }

    public func confirmLinkRecipients(in session: ComposeSession) {
        session.confirmLinkRecipients()
        guard let date = session.linkScheduleDate else {
            perform(.send, in: session, source: .keyboard)
            return
        }
        let condition = session.linkScheduleCondition
        session.linkScheduleDate = nil
        track(Task { [weak self] in await self?.schedule(session, at: date, condition: condition) })
    }

    private func bringBack(_ session: ComposeSession, _ text: String) {
        showPlace(of: session)
        reopen(session)
        session.notice = ComposeSession.Notice(.error, text)
    }

    func cancelSendLater(_ session: ComposeSession) -> ActionPerformance {
        guard let key = session.draftKey, let at = session.sendAt, let commands = environment.commands else {
            return .notHandled
        }
        let condition = session.sendCondition
        return .started(Task { [weak self] in
            do {
                try await commands.cancelScheduledSend(key)
                self?.forgetSending(draft: key)
                self?.push("Send later canceled", .reschedule(draft: key.rawValue, to: at, condition: condition))
            } catch {
                let detail = (error as? MailPortError)?.description ?? String(localized: "Try again.")
                session.notice = ComposeSession.Notice(.error, String(localized: "Couldn't cancel. \(detail)"))
            }
        })
    }

    func undoSchedule(session id: UUID, draft: DraftKey) async throws {
        try await environment.commands?.cancelScheduledSend(draft)
        removeSending(id)
        if let session = scheduled.removeValue(forKey: id) {
            showPlace(of: session)
            reopen(session)
        }
    }

    func restoreSchedule(draft: DraftKey, at date: Date, condition: SendLaterCondition = .always) async throws {
        guard date.timeIntervalSince(timing.now()) >= Self.restoreLead else {
            environment.notices.post(String(localized: "That time has passed, so the earlier schedule wasn't restored."),
                                     style: .info)
            return
        }
        if condition == .always {
            try await environment.commands?.scheduleSend(draft, at: date)
        } else {
            try await environment.commands?.scheduleSend(draft, at: date, condition: condition)
        }
        if let index = sending.lastIndex(where: { $0.draft == draft }), case .scheduled = sending[index].state {
            sending[index].state = .scheduled(at: date)
        }
    }

    static let restoreLead: TimeInterval = 60

    static let tooSoonText = String(localized: "Pick a time at least a minute from now.")

    static let ifNoReplySuffix = String(localized: " if no reply")

    func cancelScheduledSend(in thread: ThreadKey) -> ActionPerformance {
        guard let commands = environment.commands else {
            refuseRowAction(.cancelScheduledSend)
            return .done
        }
        return .started(Task { [weak self] in
            guard let self else { return }
            guard let row = await self.scheduledDraft(in: thread), let at = row.sendAt else {
                self.nothingScheduled()
                return
            }
            do {
                try await commands.cancelScheduledSend(row.id)
                self.forgetSending(draft: row.id)
                self.push("Send later canceled", .reschedule(draft: row.id.rawValue, to: at, condition: row.sendCondition),
                          threads: [thread])
            } catch {
                let detail = (error as? MailPortError)?.description ?? String(localized: "Try again.")
                self.environment.notices.post(String(localized: "Couldn't cancel the scheduled send. \(detail)"),
                                              style: .error)
            }
        })
    }

    func rescheduleSend(in thread: ThreadKey) -> ActionPerformance {
        guard canSend else {
            refuseRowAction(.rescheduleSend)
            return .done
        }
        return .started(Task { [weak self] in
            guard let self else { return }
            guard let row = await self.scheduledDraft(in: thread), let previous = row.sendAt else {
                self.nothingScheduled()
                return
            }
            guard row.canBeScheduled else {
                self.environment.notices.post(String(localized: "An agent wrote this draft. Review it before scheduling it."),
                                              style: .info, duration: NoticeCenter.infoDuration)
                return
            }
            if self.environment.isLiveAccount,
               await Self.read(self.environment.settings, SendSettings.confirmEverySend) ?? false {
                self.environment.notices.post(String(localized: "Confirm before sending is on: pick the new time in the draft (⇧⌘L)."),
                                              style: .info, duration: NoticeCenter.infoDuration)
                _ = await self.resumeDraft(in: thread, scheduledFirst: true).value
                return
            }
            let draft = row.id
            let current = row.sendCondition
            self.environment.overlays.presentSendLater(draftTargets: [thread], condition: current,
                                                       scheduleWithCondition: { [weak self] date, condition in
                guard let self else { return }
                self.track(Task {
                    await self.reschedule(draft, at: date, condition: condition, previous: previous,
                                          previousCondition: current, thread: thread)
                })
            })
        })
    }

    func reschedule(_ key: DraftKey, at date: Date, condition: SendLaterCondition = .always, previous: Date,
                    previousCondition: SendLaterCondition = .always, thread: ThreadKey?) async {
        guard canSend, let commands = environment.commands else {
            refuseRowAction(.rescheduleSend)
            return
        }
        guard date.timeIntervalSince(timing.now()) >= Self.restoreLead else {
            environment.notices.post(Self.tooSoonText, style: .info, duration: NoticeCenter.infoDuration)
            return
        }
        do {
            if condition == .always {
                try await commands.scheduleSend(key, at: date)
            } else {
                try await commands.scheduleSend(key, at: date, condition: condition)
            }
        } catch {
            let detail = (error as? MailPortError)?.description ?? String(localized: "Try again.")
            environment.notices.post(String(localized: "Couldn't reschedule. \(detail)"), style: .error)
            return
        }
        let when = formatSendAt(date) + (condition == .ifNoReply ? Self.ifNoReplySuffix : "")
        push("Rescheduled for \(when)", .reschedule(draft: key.rawValue, to: previous, condition: previousCondition),
             threads: thread.map { [$0] } ?? [])
    }

    private func refuseRowAction(_ id: ActionID) {
        let title = environment.actions.descriptor(id)?.title ?? String(localized: "This action")
        environment.actions.refuse(id, .unavailable(title))
    }

    private func nothingScheduled() {
        environment.notices.post(String(localized: "Nothing is scheduled to send in this conversation any more"),
                                 style: .info, duration: NoticeCenter.infoDuration)
    }

    public func formatSendAt(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        style.timeZone = calendar.timeZone
        let day = calendar.isDate(date, inSameDayAs: timing.now())
            ? String(localized: "today")
            : date.formatted(Date.FormatStyle(date: nil, time: nil, locale: locale, calendar: calendar,
                                              timeZone: calendar.timeZone).weekday(.abbreviated).month(.abbreviated).day())
        return "\(day) \(date.formatted(style))"
    }

    func discard(_ session: ComposeSession) -> ActionPerformance {
        guard session.isOpen else { return .notHandled }
        hide(session)
        session.stopObserving()
        let wasPendingReview = session.review == .pending
        pendingDiscards[session.id] = PendingDiscard(session: session, wasPendingReview: wasPendingReview)
        if wasPendingReview, let key = session.draftKey, let commands = environment.commands, session.canPersist {
            track(Task { try? await commands.setReviewState(key, .rejected) })
        }
        push("Discarded draft", .discard(session: session.id),
             expiresAt: Date().addingTimeInterval(NoticeCenter.seconds(timing.discardWindow)))
        let timing = self.timing
        let id = session.id
        track(Task { [weak self] in
            try? await timing.sleep(timing.discardWindow)
            await self?.finishDiscard(id)
        })
        return .done
    }

    func finishDiscard(_ id: UUID) async {
        guard let pending = pendingDiscards.removeValue(forKey: id) else { return }
        let session = pending.session
        await session.settle()
        session.expectsDraftGone = true
        guard session.canPersist, let key = session.draftKey, let commands = environment.commands else { return }
        do {
            try await commands.discardDraft(key)
        } catch MailPortError.notFound(_) {
            // Deleted elsewhere already: nothing to bring back
        } catch {
            if pending.wasPendingReview { try? await commands.setReviewState(key, .pending) }
            let detail = (error as? MailPortError)?.description ?? String(localized: "Try again.")
            bringBack(session, String(localized: "Couldn't discard the draft. \(detail)"))
            return
        }
        recovery.remove(key)
    }

    func undoDiscard(session id: UUID) async throws {
        guard let pending = pendingDiscards.removeValue(forKey: id) else { return }
        if pending.wasPendingReview, let key = pending.session.draftKey, let commands = environment.commands {
            try await commands.setReviewState(key, .pending)
        }
        reopen(pending.session)
    }

    public func prepareForQuit() async {
        let commands = environment.commands
        for (id, heldSend) in held {
            held[id] = nil
            _ = try? await commands?.sendNow(heldSend.token)
        }
        await releaseHeldBatches()
        for id in Array(pendingDiscards.keys) { await finishDiscard(id) }
        for session in sessions where session.canPersist && (session.draftKey != nil || session.hasUserEdits) {
            if await session.save(), let key = session.draftKey { try? await commands?.flushDraft(key) }
        }
        await sendReminderUpdate?.value
        await sendDoneUpdate?.value
    }

    public var heldSendCount: Int { held.count + heldBatchSendCount }

    public var hasQuitWork: Bool {
        !held.isEmpty || heldBatchSendCount > 0 || !pendingDiscards.isEmpty
            || sessions.contains { $0.canPersist && $0.hasUserEdits }
    }

    @discardableResult
    func push(_ title: LocalizedStringResource, _ action: ComposeUndoAction, expiresAt: Date? = nil,
              threads: [ThreadKey] = [], view: UUID? = nil) -> UndoCoordinator.Entry.ID? {
        let secondary = view.map { viewChoice($0) }
        guard let undo = environment.undo, let payload = try? JSONEncoder().encode(action) else {
            environment.notices.post(String(localized: title), style: .info, secondary: secondary)
            return nil
        }
        let entry = UndoCoordinator.Entry(title: title, token: UndoToken(payload: payload), expiresAt: expiresAt,
                                          threads: threads, undoer: undoer, secondary: secondary)
        if let view { sendingUndoEntries[view] = entry.id }
        undo.push(entry)
        return entry.id
    }
}

enum ComposeUndoAction: Codable, Sendable {
    case send(session: UUID, token: SendToken)
    case schedule(session: UUID, draft: String)
    case reschedule(draft: String, to: Date, condition: SendLaterCondition)
    case discard(session: UUID)
    case sendBatch(batch: UUID)
}

@MainActor
final class ComposeUndoer: MailUndoing {
    private weak var manager: ComposeManager?

    init(manager: ComposeManager) {
        self.manager = manager
    }

    nonisolated func undo(_ token: UndoToken) async throws -> UndoToken? {
        let action = try JSONDecoder().decode(ComposeUndoAction.self, from: token.payload)
        try await perform(action)
        return nil
    }

    private func perform(_ action: ComposeUndoAction) async throws {
        guard let manager else { return }
        switch action {
        case .send(let session, let token): try await manager.undoSend(session: session, token: token)
        case .schedule(let session, let draft): try await manager.undoSchedule(session: session, draft: DraftKey(draft))
        case .reschedule(let draft, let date, let condition):
            try await manager.restoreSchedule(draft: DraftKey(draft), at: date, condition: condition)
        case .discard(let session): try await manager.undoDiscard(session: session)
        case .sendBatch(let batch): try await manager.undoBatch(batch)
        }
    }
}
