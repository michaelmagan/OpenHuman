import Foundation
import MailActions
import MailModel

extension CalendarWindowModel {
    public var cardTimeZone: TimeZone { timeZone }


    func saveFormCard(_ current: CalendarEventCard) async {
        var current = current
        let patch = current.formPatch
        if let why = current.rights.firstViolation(of: patch) {
            current.note = why
            card = current
            return
        }
        if let problem = current.form?.problem {
            current.note = problem
            card = current
            return
        }
        let scopes = CalendarRecurrenceScope.options(for: current.event, patch: patch)
        if !scopes.isEmpty {
            var question = CalendarScopeQuestion(eventID: current.event.copyKey, action: .save)
            question.scopes = scopes
            scopeQuestion = question
            return
        }
        await commitPatch(current, patch, scope: .thisEvent)
    }

    public func answerRecurrenceScope(_ scope: CalendarRecurrenceScope) async {
        guard let question = scopeQuestion, question.action == .save, let current = card, current.form != nil else {
            scopeQuestion = nil
            return
        }
        scopeQuestion = nil
        await commitPatch(current, current.formPatch, scope: scope)
    }

    public func chooseSendUpdates(_ choice: CalendarSendUpdates) {
        card?.sendUpdatesChoice = choice
    }

    public func sendUpdates(for card: CalendarEventCard) -> CalendarSendUpdates {
        let patch = card.formPatch
        return CalendarSendUpdatesPolicy.effective(chosen: card.sendUpdatesChoice,
                                                   hasOtherGuests: !card.event.attendees.isEmpty || !patch.guestsAdded.isEmpty,
                                                   patch: patch)
    }

    public func asksSendUpdates(for card: CalendarEventCard) -> Bool {
        let patch = card.formPatch
        return CalendarSendUpdatesPolicy.needsChoice(hasOtherGuests: !card.event.attendees.isEmpty || !patch.guestsAdded.isEmpty,
                                                     patch: patch)
    }

    func commitPatch(_ current: CalendarEventCard, _ patch: CalendarEventPatch, scope: CalendarRecurrenceScope) async {
        guard let target = provider(for: current.event).provider else { return }
        let event = current.event
        let key = current.calendarKey
        let zone = timeZone.identifier
        let others = !event.attendees.isEmpty || !patch.guestsAdded.isEmpty
        let updates = CalendarSendUpdatesPolicy.effective(chosen: current.sendUpdatesChoice, hasOtherGuests: others, patch: patch)
        let series = event.isRecurring && scope != .thisEvent
        let id = UUID()
        if let time = patch.time { overlays[id] = .times(id: event.copyKey, start: time.start, end: time.end) }
        closeCard()
        if others, patch.touchesGuests {
            let line = updates == .all ? String(localized: "Saving \(event.title)… Google emails the guests.")
                                       : String(localized: "Saving \(event.title)…")
            hold(id, title: line) { [weak self] in
                do {
                    let latest = try await target.patchEvent(event, with: patch, scope: scope, sendUpdates: updates)
                    self?.storePatched(latest, replacing: event, series: series)
                } catch {
                    self?.failed(String(localized: "Couldn't save \(event.title). \(CalendarSidebarModel.message(error))"), id)
                    return
                }
                await self?.changed(id, line: updates == .all
                                    ? String(localized: "Saved \(event.title). Google emailed the guests.")
                                    : String(localized: "Saved \(event.title)."))
            }
            return
        }
        let latest: CalendarEvent
        do {
            latest = try await target.patchEvent(event, with: patch, scope: scope, sendUpdates: .none)
            storePatched(latest, replacing: event, series: series)
        } catch {
            failed(String(localized: "Couldn't save \(event.title). \(CalendarSidebarModel.message(error))"), id)
            return
        }
        if series {
            // Why: the calendar answers a series change with the series' own event, so Undo changes this occurrence back
            // with the same scope; a series split from here on is not undone
            guard scope == .allEvents, let edited = current.form else {
                await changed(id, line: String(localized: "Saved \(event.title)."))
                return
            }
            let back = CalendarEventForm(event: event, calendarKey: key, defaultZone: zone).diff(against: edited)
            let after = event.with(start: patch.time?.start ?? event.start, end: patch.time?.end ?? event.end)
            offerUndo(String(localized: "Saved \(event.title).")) { [weak self] in
                _ = try await target.patchEvent(after, with: back, scope: .allEvents, sendUpdates: .none)
                self?.storePatched(after, replacing: event, series: true)
            }
            await changed(id, line: nil)
            return
        }
        let back = CalendarEventForm(event: event, calendarKey: key, defaultZone: zone)
            .diff(against: CalendarEventForm(event: latest, calendarKey: key, defaultZone: zone))
        offerUndo(String(localized: "Saved \(event.title).")) { [weak self] in
            let restored = try await target.patchEvent(latest, with: back, scope: scope, sendUpdates: .none)
            self?.store(restored, replacing: event)
        }
        await changed(id, line: nil)
    }

    // Why: a whole-series answer is the series' own event, never one of the occurrences on the grid, so it is not stored
    // under its id; the refresh after the save reads the occurrences
    func storePatched(_ answer: CalendarEvent, replacing event: CalendarEvent, series: Bool) {
        guard series else { return store(answer, replacing: event) }
        if let key = storeKey(for: event) { eventStore.noteRemoteWrite(key) }
    }

    // Why: a dropped event is only proposed until Accept, so leaving the proposal says the event kept its time
    func noteUnsavedMove(keeping id: String? = nil) {
        guard let current = card, current.pendingMove != nil, current.event.copyKey != id else { return }
        environment.notices.post(String(localized: "Didn't move \(current.event.title). Accept a move to save it."),
                                 duration: NoticeCenter.infoDuration)
    }


    public func declineInsteadOfDelete() async {
        guard case .declineInstead = card?.rights.delete else { return }
        await respond(.declined)
    }

    public func duplicateCardEvent() async {
        guard let current = card, let form = current.form else { return }
        let copy = form.duplicateDraft()
        closeCard()
        await newEvent(start: copy.start, end: copy.end)
        guard sidebar.draft != nil else { return }
        var merged = copy
        merged.sendUpdates = CalendarEventDraft.defaultSendUpdates(attendees: copy.attendees)
        sidebar.draft = merged
    }


    var confirmsMoves: Bool {
        get async {
            if let confirmsMovesOverride { return confirmsMovesOverride }
            return await read(AppSettings.calendarConfirmMoves)
        }
    }

    func beginPendingMove(_ event: CalendarEvent, start: Date, end: Date) {
        openEvent(event)
        guard var opened = card else { return }
        opened.pendingMove = CalendarPendingMove(event: event, proposedStart: start, proposedEnd: end)
        opened.start = start
        opened.end = opened.pendingMove?.proposedEnd ?? end
        if opened.form != nil {
            opened.form?.start = opened.start
            opened.form?.end = opened.end
        }
        card = opened
    }

    public func acceptPendingMove() async { await saveCard() }

    public func cancelPendingMove() { closeCard() }
}
