import Foundation
import MailActions
import MailModel

public struct CalendarEventCard: Sendable, Hashable {
    public let event: CalendarEvent
    public let calendarKey: String
    public var title: String
    public var location: String
    public var notes: String
    public var start: Date
    public var end: Date
    public var response: CalendarResponse?
    public let canMove: Bool
    public let canEditDetails: Bool
    public let canRemove: Bool
    public let canRespond: Bool
    public let reason: String?
    public var note: String?
    public var form: CalendarEventForm?
    public var rights: CalendarFieldRights = .all
    public var sendUpdatesChoice: CalendarSendUpdates?
    public var pendingMove: CalendarPendingMove?
    public var defaultZone: String = ""
    public var pendingGuest = "" { didSet { if pendingGuest != oldValue { pendingGuestNote = nil } } }
    public var pendingGuestNote: String?

    public var formPatch: CalendarEventPatch {
        form?.patch(from: event, defaultZone: defaultZone) ?? CalendarEventPatch()
    }

    public var changes: CalendarEventChanges {
        CalendarEventChanges(title: title != event.title ? title : nil,
                             location: location != (event.location ?? "") ? location : nil,
                             notes: notes != (event.notes ?? "") ? notes : nil)
    }

    public var timesChanged: Bool { start != event.start || end != event.end }
    public var hasChanges: Bool {
        guard form != nil else { return timesChanged || !changes.isEmpty }
        return !formPatch.isEmpty || !pendingGuest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // An address still in the guest field joins the guests on Save; other text stops the save and says why
    mutating func commitPendingGuest() -> Bool {
        guard var edited = form else { return true }
        guard let typed = CalendarPendingGuest.addresses(in: pendingGuest) else {
            pendingGuestNote = CalendarPendingGuest.notAnAddress
            return false
        }
        guard !typed.isEmpty else { return true }
        for address in typed { edited.addGuest(address) }
        form = edited
        pendingGuest = ""
        return true
    }
    public var emailsPeople: Bool { !event.attendees.isEmpty }
}

public struct CalendarScopeQuestion: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        case save
        case remove
        case move(start: Date, end: Date)
    }

    public let eventID: String
    public let action: Action
    public var scopes: [CalendarRecurrenceScope] = [.thisEvent, .allEvents]

    public var text: String {
        switch action {
        case .remove: String(localized: "This event repeats. Delete only this event, or all events in the series?")
        default: String(localized: "This event repeats. Change only this event, or all events in the series?")
        }
    }
}

public struct CalendarRemoveQuestion: Sendable, Hashable {
    public let eventID: String
    public let title: String
    public let emailsPeople: Bool

    public var text: String {
        emailsPeople
            ? String(localized: "Delete \(title)? Google will email the guests that it is canceled. You can undo for a few seconds; after that the emails are sent and Undo cannot take them back.")
            : String(localized: "Delete \(title)? You can undo for a few seconds, and Undo brings it back as a new event.")
    }
}

public enum CalendarEditScope: Sendable, Hashable { case thisEvent, allEvents }

extension CalendarWindowModel {
    enum Overlay: Sendable, Hashable {
        case times(id: String, start: Date, end: Date)
        case removed(id: String)
        case response(id: String, CalendarResponse)
    }

    func provider(for event: CalendarEvent) -> (key: String, provider: (any CalendarProviding)?) {
        let key = event.account?.lowercased() ?? sources.first?.key ?? ""
        if let found = providers[key] { return (key, found) }
        guard providers.count <= 1 else { return (key, nil) }
        let only: any CalendarProviding = providers.values.first ?? sidebar.provider
        return (key, only)
    }

    public func openEvent(_ event: CalendarEvent) {
        noteUnsavedMove(keeping: event.copyKey)
        scopeQuestion = nil
        removeQuestion = nil
        selectedEventID = event.copyKey
        let (key, found) = provider(for: event)
        let refusal = found?.info.createRefusal
            ?? (found == nil ? CalendarError.notConfigured.description : nil)
        let abilities = found?.abilities ?? []
        let mine = !event.id.isEmpty
            && (event.organizerIsMe == true || (event.organizerIsMe == nil && event.attendees.isEmpty))
        let canMove = refusal == nil && event.isMovableByMe
        let canEdit = refusal == nil && mine && abilities.contains(.editDetails)
        let canRemove = refusal == nil && mine && abilities.contains(.remove)
        let canRespond = refusal == nil && event.canRespond && abilities.contains(.respond)
        var reason = refusal
        if reason == nil, !mine, !event.canRespond {
            reason = String(localized: "Someone else organizes this event: only they can change it.")
        } else if reason == nil, mine, !canEdit {
            reason = String(localized: "Mail can change this event's time here. Change its details in your calendar.")
        }
        let fullRights = abilities.contains(.editFull)
            ? CalendarFieldRights.make(for: event, abilities: abilities, refusal: refusal) : nil
        if let fullRights { reason = fullRights.summary }
        var opened = CalendarEventCard(event: event, calendarKey: key, title: event.title, location: event.location ?? "",
                                       notes: event.notes ?? "", start: event.start, end: event.end,
                                       response: event.myResponse, canMove: canMove, canEditDetails: canEdit,
                                       canRemove: canRemove, canRespond: canRespond, reason: reason, note: nil)
        if let fullRights {
            opened.defaultZone = timeZone.identifier
            opened.form = CalendarEventForm(event: event, calendarKey: key, defaultZone: timeZone.identifier)
            opened.rights = fullRights
        }
        card = opened
    }

    public func closeCard() {
        card = nil
        scopeQuestion = nil
        removeQuestion = nil
    }

    public func saveCard() async {
        guard var current = card else { return }
        if current.form != nil {
            let committed = current.commitPendingGuest()
            card = current
            guard committed else { return }
        }
        guard current.hasChanges else {
            closeCard()
            return
        }
        if current.form != nil {
            await saveFormCard(current)
            return
        }
        if current.timesChanged, !current.canMove {
            current.note = current.reason ?? String(localized: "Mail moves only your own events.")
            card = current
            return
        }
        if !current.changes.isEmpty, !current.canEditDetails {
            current.note = current.reason ?? String(localized: "This calendar can't change event details from Mail yet.")
            card = current
            return
        }
        if current.event.isRecurring {
            scopeQuestion = CalendarScopeQuestion(eventID: current.event.copyKey, action: .save)
            return
        }
        await commitSave(current)
    }

    public func respond(_ response: CalendarResponse) async {
        guard var current = card else { return }
        guard current.canRespond, let target = provider(for: current.event).provider else {
            current.note = current.reason ?? String(localized: "This calendar can't answer invitations from Mail.")
            card = current
            return
        }
        let event = current.event
        current.response = response
        current.note = nil
        card = current
        let id = UUID()
        overlays[id] = .response(id: event.copyKey, response)
        let series = event.isRecurring ? String(localized: " (this event only)") : ""
        hold(id, title: String(localized: "Answering \(response.title) to \(event.title)\(series)… Google tells the organizer.")) {
            [weak self] in
            do {
                let answer = try await target.respond(to: event, with: response, sendUpdates: .all)
                self?.store(answer, replacing: event)
            } catch {
                self?.failed(String(localized: "Couldn't answer \(event.title). \(CalendarSidebarModel.message(error))"), id)
                return
            }
            await self?.changed(id, line: String(localized: "Answered \(response.title) to \(event.title)."))
        }
    }

    public func askToRemoveCardEvent() {
        guard var current = card else { return }
        guard current.canRemove else {
            current.note = current.reason ?? String(localized: "This calendar can't remove events from Mail yet.")
            card = current
            return
        }
        removeQuestion = CalendarRemoveQuestion(eventID: current.event.copyKey, title: current.event.title,
                                                emailsPeople: current.emailsPeople)
    }

    public func confirmRemove() async {
        guard let question = removeQuestion, card?.event.copyKey == question.eventID else {
            removeQuestion = nil
            return
        }
        removeQuestion = nil
        await removeCardEvent()
    }

    public func removeCardEvent() async {
        guard var current = card else { return }
        guard current.canRemove else {
            current.note = current.reason ?? String(localized: "This calendar can't remove events from Mail yet.")
            card = current
            return
        }
        if current.event.isRecurring {
            scopeQuestion = CalendarScopeQuestion(eventID: current.event.copyKey, action: .remove)
            return
        }
        commitRemove(current)
    }

    public func answerScope(_ scope: CalendarEditScope) async {
        guard let question = scopeQuestion else { return }
        if let current = card, current.form != nil, question.action == .save {
            await answerRecurrenceScope(scope == .thisEvent ? .thisEvent : .allEvents)
            return
        }
        scopeQuestion = nil
        guard scope == .thisEvent else {
            let why = String(localized: "Mail changes one event of a series at a time. Change the whole series in your calendar.")
            if card != nil { card?.note = why } else { environment.notices.post(why, duration: NoticeCenter.infoDuration) }
            return
        }
        switch question.action {
        case .save:
            if let current = card { await commitSave(current) }
        case .remove:
            if let current = card { commitRemove(current) }
        case .move(let start, let end):
            if let event = events.first(where: { $0.copyKey == question.eventID }) { await commitMove(event, start: start, end: end) }
        }
    }

    public func moveEvent(_ event: CalendarEvent, to start: Date, end: Date) async {
        guard start != event.start || end != event.end else { return }
        guard event.isMovableByMe, let target = provider(for: event).provider else {
            environment.notices.post(String(localized: "Mail moves only your own events. Someone else organizes this one."),
                                     duration: NoticeCenter.infoDuration)
            return
        }
        if let refusal = target.info.createRefusal {
            environment.notices.post(refusal, duration: NoticeCenter.infoDuration)
            return
        }
        if await confirmsMoves {
            beginPendingMove(event, start: start, end: end)
            return
        }
        if event.isRecurring {
            scopeQuestion = CalendarScopeQuestion(eventID: event.copyKey, action: .move(start: start, end: end))
            return
        }
        await commitMove(event, start: start, end: end)
    }

    private func commitSave(_ current: CalendarEventCard) async {
        guard let target = provider(for: current.event).provider else { return }
        let event = current.event
        let changes = current.changes
        let (start, end) = (current.start, current.end)
        let timesChanged = current.timesChanged
        let id = UUID()
        if timesChanged { overlays[id] = .times(id: event.copyKey, start: start, end: end) }
        closeCard()
        if current.emailsPeople {
            hold(id, title: String(localized: "Saving \(event.title)… Google emails the attendees.")) { [weak self] in
                do {
                    var latest: CalendarEvent?
                    if timesChanged { latest = try await target.moveEvent(event, to: start, end: end, sendUpdates: .all) }
                    if !changes.isEmpty { latest = try await target.updateEvent(event, with: changes, sendUpdates: .all) }
                    if let latest { self?.store(latest, replacing: event) }
                } catch {
                    self?.failed(String(localized: "Couldn't save \(event.title). \(CalendarSidebarModel.message(error))"), id)
                    return
                }
                await self?.changed(id, line: String(localized: "Saved \(event.title). Google emailed the attendees."))
            }
            return
        }
        do {
            var latest: CalendarEvent?
            if timesChanged { latest = try await target.moveEvent(event, to: start, end: end, sendUpdates: .none) }
            if !changes.isEmpty { latest = try await target.updateEvent(event, with: changes, sendUpdates: .none) }
            if let latest { store(latest, replacing: event) }
        } catch {
            failed(String(localized: "Couldn't save \(event.title). \(CalendarSidebarModel.message(error))"), id)
            return
        }
        let before = CalendarEventChanges(title: changes.title.map { _ in event.title },
                                          location: changes.location.map { _ in event.location ?? "" },
                                          notes: changes.notes.map { _ in event.notes ?? "" })
        let moved = event.with(start: start, end: end)
        offerUndo(String(localized: "Saved \(event.title).")) { [weak self] in
            var latest: CalendarEvent?
            if timesChanged { latest = try await target.moveEvent(moved, to: event.start, end: event.end, sendUpdates: .none) }
            if !before.isEmpty { latest = try await target.updateEvent(moved, with: before, sendUpdates: .none) }
            if let latest { self?.store(latest, replacing: event) }
        }
        await changed(id, line: nil)
    }

    private func commitRemove(_ current: CalendarEventCard) {
        guard let target = provider(for: current.event).provider else { return }
        let event = current.event
        let id = UUID()
        overlays[id] = .removed(id: event.copyKey)
        closeCard()
        let emails = current.emailsPeople
        let title = emails ? String(localized: "Deleting \(event.title)… Google emails the attendees.")
                           : String(localized: "Deleting \(event.title)…")
        hold(id, title: title) { [weak self] in
            do {
                try await target.removeEvent(event, sendUpdates: emails ? .all : .none)
                self?.dropFromStore(event)
            } catch {
                self?.failed(String(localized: "Couldn't delete \(event.title). \(CalendarSidebarModel.message(error))"), id)
                return
            }
            if !emails, !event.isAllDay {
                self?.offerUndo(String(localized: "Deleted \(event.title).")) { [weak self] in
                    let draft = CalendarEventDraft(title: event.title, start: event.start, end: event.end,
                                                   timeZone: event.timeZone ?? TimeZone.current.identifier,
                                                   sendUpdates: .none, location: event.location ?? "",
                                                   notes: event.notes ?? "")
                    let made = try await target.createEvent(draft)
                    self?.store(made, replacing: event)
                }
                await self?.changed(id, line: nil)
                return
            }
            await self?.changed(id, line: String(localized: "Deleted \(event.title)."))
        }
    }

    private func commitMove(_ event: CalendarEvent, start: Date, end: Date) async {
        guard let target = provider(for: event).provider else { return }
        let id = UUID()
        overlays[id] = .times(id: event.copyKey, start: start, end: end)
        let clock = start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone))
        if !event.attendees.isEmpty {
            hold(id, title: String(localized: "Moving \(event.title) to \(clock)… Google emails the attendees.")) { [weak self] in
                do {
                    let answer = try await target.moveEvent(event, to: start, end: end, sendUpdates: .all)
                    self?.store(answer, replacing: event)
                } catch {
                    self?.failed(String(localized: "Couldn't move \(event.title). \(CalendarSidebarModel.message(error))"), id)
                    return
                }
                await self?.changed(id, line: String(localized: "Moved \(event.title) to \(clock). Google emailed the attendees."))
            }
            return
        }
        let moved: CalendarEvent
        do {
            moved = try await target.moveEvent(event, to: start, end: end, sendUpdates: .none)
            store(moved, replacing: event)
        } catch {
            failed(String(localized: "Couldn't move \(event.title). \(CalendarSidebarModel.message(error))"), id)
            return
        }
        offerUndo(String(localized: "Moved \(event.title) to \(clock).")) { [weak self] in
            let back = try await target.moveEvent(moved, to: event.start, end: event.end, sendUpdates: .none)
            self?.store(back, replacing: event)
        }
        await changed(id, line: nil)
    }

    func store(_ answer: CalendarEvent, replacing event: CalendarEvent) {
        guard let key = storeKey(for: event) else { return }
        eventStore.applyLocal(key, upsert: Self.untagged(answer))
    }

    func dropFromStore(_ event: CalendarEvent) {
        guard let key = storeKey(for: event) else { return }
        eventStore.removeLocal(key, id: event.id)
    }

    func changed(_ id: UUID, line: String?) async {
        if let line { environment.notices.post(line, duration: NoticeCenter.infoDuration) }
        await load(force: true)
        overlays[id] = nil
    }

    func failed(_ message: String, _ id: UUID) {
        overlays[id] = nil
        environment.notices.post(message, style: .error)
    }

    func hold(_ id: UUID, title: String, perform: @escaping @MainActor @Sendable () async -> Void) {
        let window = holdWindow
        let sleep = self.sleep
        held[id] = Task { [weak self] in
            try? await sleep(window)
            guard let self, self.held.removeValue(forKey: id) != nil else { return }
            await perform()
        }
        pushUndo(id, title: title)
    }

    public var hasQuitWork: Bool { !held.isEmpty }

    public func prepareForQuit() async {
        let pending = Array(held.values)
        for task in pending { task.cancel() }
        for task in pending { await task.value }
    }

    func offerUndo(_ title: String, revert: @escaping @MainActor () async throws -> Void) {
        let id = UUID()
        undoable[id] = revert
        pushUndo(id, title: title)
    }

    private func pushUndo(_ id: UUID, title: String) {
        guard let undo = environment.undo else {
            environment.notices.post(title, duration: holdWindow)
            return
        }
        if undoerStorage == nil { undoerStorage = CalendarWindowUndoer(model: self) }
        guard let undoer = undoerStorage else { return }
        undo.push(UndoCoordinator.Entry(title: LocalizedStringResource(stringLiteral: title),
                                        token: UndoToken(payload: Data(id.uuidString.utf8)),
                                        expiresAt: Date().addingTimeInterval(NoticeCenter.seconds(holdWindow)),
                                        undoer: undoer))
    }

    func undo(_ id: UUID) async {
        if let task = held.removeValue(forKey: id) {
            task.cancel()
            overlays[id] = nil
            environment.notices.post(String(localized: "Canceled. Nothing on your calendar changed."),
                                     duration: NoticeCenter.infoDuration)
            return
        }
        guard let revert = undoable.removeValue(forKey: id) else {
            environment.notices.post(String(localized: "Too late to undo: your calendar already changed."),
                                     duration: NoticeCenter.infoDuration)
            return
        }
        do {
            try await revert()
        } catch {
            environment.notices.post(String(localized: "Couldn't undo it: \(CalendarSidebarModel.message(error)) Check your calendar."),
                                     style: .error)
            return
        }
        await load(force: true)
        environment.notices.post(String(localized: "Undone. Your calendar is as it was."), duration: NoticeCenter.infoDuration)
    }

    var heldCount: Int { held.count }
    var undoableCount: Int { undoable.count }
}

@MainActor
final class CalendarWindowUndoer: MailUndoing {
    private weak var model: CalendarWindowModel?

    init(model: CalendarWindowModel) {
        self.model = model
    }

    nonisolated func undo(_ token: UndoToken) async throws -> UndoToken? {
        guard let id = UUID(uuidString: String(decoding: token.payload, as: UTF8.self)) else { return nil }
        await undo(id)
        return nil
    }

    private func undo(_ id: UUID) async { await model?.undo(id) }
}
