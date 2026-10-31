import Foundation
import MailActions
import MailModel
import OpenHumanCore

public struct CalendarEventCard: Sendable, Hashable {
    public let identity = UUID()
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
    /// Removing takes only the user's copy of someone else's event off their calendar; no answer goes out.
    public var removesInvite = false
    // A meeting on several connected calendars: one row per copy, and why the shown time may differ from another copy's
    public var copies: [CalendarCopyRow] = []
    public var copiesNote: String?

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

    // Changes to the event itself go to this copy's calendar
    public var changesAccount: String? { copies.first(where: \.receivesChanges)?.account }
}

// One connected calendar that holds a copy of the card's meeting, with that account's own answer
public struct CalendarCopyRow: Sendable, Hashable, Identifiable {
    public let event: CalendarEvent
    public var response: CalendarResponse?
    public let canRespond: Bool
    public let receivesChanges: Bool
    // Set when this copy shows a time other than the card's
    public let timeText: String?
    // Another copy than the shown one that its own calendar can take off alone, without answering
    public let canRemove: Bool

    public init(event: CalendarEvent, response: CalendarResponse?, canRespond: Bool, receivesChanges: Bool,
                timeText: String? = nil, canRemove: Bool = false) {
        self.event = event
        self.response = response
        self.canRespond = canRespond
        self.receivesChanges = receivesChanges
        self.timeText = timeText
        self.canRemove = canRemove
    }

    public var id: String { event.copyKey }
    public var account: String { event.account ?? "" }

    public var status: String {
        if event.organizerIsMe == true { return String(localized: "You organize it") }
        guard let response else { return String(localized: "Invited · answer not shown") }
        return String(localized: "Invited · \(response.title)")
    }
}

public struct CalendarCopyRemoval: Sendable, Hashable, Identifiable {
    public let copyKey: String
    public let title: String

    public init(copyKey: String, title: String) {
        self.copyKey = copyKey
        self.title = title
    }

    public var id: String { copyKey }
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
    public let id = UUID()
    public let eventID: String
    public let title: String
    public let emailsPeople: Bool
    public var isRecurring = false
    public var canRecreate = false
    public var isInvite = false
    public var availableScopes: [CalendarRecurrenceScope] = [.thisEvent]
    public var note: String?
    // A meeting on several connected calendars: the calendar this removal acts on, the user's other calendars that
    // keep their copy, and the invited ones that lose it too because the user deletes the meeting they organize
    public var account: String?
    public var keptOn: [String] = []
    public var alsoOn: [String] = []
    public var organizerKept = false

    public var confirmTitle: String { isInvite ? String(localized: "Remove") : String(localized: "Delete") }

    public var text: String {
        if isInvite {
            guard let account, !keptOn.isEmpty else {
                return isRecurring ? Self.inviteSeriesText(title) : Self.inviteText(title)
            }
            return Self.copyText(title, from: account, keptOn: Self.list(keptOn), series: isRecurring,
                                 organizerKept: organizerKept)
        }
        let base: String
        if isRecurring {
            base = String(localized: "Delete \(title)? Choose which events to remove. Google will notify guests. You can undo for a few seconds before your calendar changes.")
        } else if !emailsPeople && !canRecreate {
            base = String(localized: "Delete \(title)? You can undo for a few seconds before your calendar changes.")
        } else {
            base = emailsPeople
                ? String(localized: "Delete \(title)? Google will email the guests that it is canceled. You can undo for a few seconds; after that the emails are sent and Undo cannot take them back.")
                : String(localized: "Delete \(title)? You can undo for a few seconds, and Undo brings it back as a new event.")
        }
        guard !alsoOn.isEmpty else { return base }
        let also = Self.list(alsoOn)
        return base + " " + (isRecurring
            ? String(localized: "The events you delete are canceled on \(also) too, since that calendar is invited.")
            : String(localized: "It is canceled on \(also) too, since that calendar is invited."))
    }

    // Google records a removed invitation as declined on the organizer's guest list; Mail sends no reply itself.
    public static func inviteText(_ title: String) -> String {
        String(localized: "Remove \(title) from your calendar? It stays on the organizer's calendar. Mail sends no reply, but Google may show the organizer that you declined. You can undo for a few seconds before your calendar changes.")
    }

    public static func inviteSeriesText(_ title: String) -> String {
        String(localized: "Remove \(title) from your calendar? Choose which events to remove. They stay on the organizer's calendar. Mail sends no reply, but Google may show the organizer that you declined. You can undo for a few seconds before your calendar changes.")
    }

    // One invited copy of a meeting the user also has on another connected calendar: only this copy leaves
    static func copyText(_ title: String, from account: String, keptOn: String, series: Bool, organizerKept: Bool) -> String {
        let head = series ? String(localized: "Remove \(title) from \(account)? Choose which events to remove.")
                          : String(localized: "Remove \(title) from \(account)?")
        let tail = organizerKept
            ? String(localized: "It stays on \(keptOn), where you organize it, and its guest list may show \(account) as declined. Mail sends no reply. You can undo for a few seconds before your calendar changes.")
            : String(localized: "It stays on \(keptOn) and on the organizer's calendar. Mail sends no reply, but Google may show the organizer that you declined. You can undo for a few seconds before your calendar changes.")
        return head + " " + tail
    }

    static func list(_ accounts: [String]) -> String {
        accounts.formatted(.list(type: .and))
    }

    public static var organizerOnlyFuture: String {
        String(localized: "Only the organizer can end this series early.")
    }
}

struct CalendarRemovalKey: Sendable, Hashable {
    let source: CalendarCacheKey
    let account: String
    let eventID: String
}

struct CalendarRemovalContext: Sendable {
    let questionID: UUID
    let cardID: UUID
    let activeAccount: AccountID?
    let key: CalendarRemovalKey
    let target: any CalendarProviding
}

// The copy a removal acts on, with the account and calendar it is removed from
struct CalendarRemovalSubject {
    let event: CalendarEvent
    let isInvite: Bool
    let account: String
    let provider: (any CalendarProviding)?
}

public enum CalendarEditScope: Sendable, Hashable { case thisEvent, allEvents }

extension CalendarWindowModel {
    enum Overlay: Sendable, Hashable {
        case times(id: String, start: Date, end: Date)
        case removed(CalendarRemovalKey, CalendarRemovalResult)
        case response(id: String, CalendarResponse)
    }

    func provider(for event: CalendarEvent) -> (key: String, provider: (any CalendarProviding)?) {
        let key = event.account?.lowercased() ?? sources.first?.key ?? ""
        if let found = providers[key] { return (key, found) }
        // Why: a meeting drawn for several calendars must never fall back to another account's calendar
        guard providers.count <= 1, !event.isMerged else { return (key, nil) }
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
        let removesInvite = refusal == nil && !mine && event.isInvitationCopy && abilities.contains(.removeInvite)
        let canRemove = refusal == nil && ((mine && abilities.contains(.remove)) || removesInvite)
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
        opened.removesInvite = removesInvite
        if let fullRights {
            opened.defaultZone = timeZone.identifier
            opened.form = CalendarEventForm(event: event, calendarKey: key, defaultZone: timeZone.identifier)
            opened.rights = fullRights
        }
        if event.isMerged {
            let editable = canMove || canEdit || canRemove || fullRights?.hasAnyEditable == true
            opened.copies = event.copies.map { copy in
                let isShown = copy.copyKey == event.copyKey
                let answers = isShown ? canRespond : copyProvider(for: copy).map { found in
                    found.info.createRefusal == nil && copy.canRespond && found.abilities.contains(.respond)
                } ?? false
                return CalendarCopyRow(event: copy, response: copy.myResponse, canRespond: answers,
                                       receivesChanges: editable && isShown, timeText: copyTime(copy, shown: event),
                                       canRemove: !isShown && canRemoveCopyAlone(copy))
            }
            opened.copiesNote = CalendarCopyGroups.timeNote(for: event)
        }
        card = opened
    }

    // Each copy of a meeting is answered on its own account's calendar only
    func copyProvider(for copy: CalendarEvent) -> (any CalendarProviding)? {
        guard let account = copy.account?.lowercased(), !account.isEmpty else { return nil }
        return providers[account]
    }

    func copyTime(_ copy: CalendarEvent, shown: CalendarEvent) -> String? {
        guard copy.start != shown.start || copy.end != shown.end || copy.isAllDay != shown.isAllDay else { return nil }
        if copy.isAllDay { return String(localized: "All day") }
        let range = CalendarSidebarModel.range(copy.start, copy.end, timeZone)
        guard !calendar.isDate(copy.start, inSameDayAs: shown.start) else { return range }
        let day = copy.start.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).month(.abbreviated).day())
        return "\(day), \(range)"
    }

    public func closeCard() {
        card = nil
        scopeQuestion = nil
        removeQuestion = nil
        removalContext = nil
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
        if let row = current.copies.firstIndex(where: { $0.id == event.copyKey }) { current.copies[row].response = response }
        current.note = nil
        card = current
        let id = UUID()
        overlays[id] = .response(id: event.copyKey, response)
        noteCopies(event, id)
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

    // From an event's context menu: the same card, question and held change as the card's own buttons.
    public func respond(_ response: CalendarResponse, to event: CalendarEvent) async {
        openEvent(event)
        await respond(response)
    }

    public func askToRemove(_ event: CalendarEvent) {
        openEvent(event)
        askToRemoveCardEvent()
    }

    /// What the event's menus offer: Delete for the user's own event, Remove for someone else's invitation, or nothing.
    public func removalTitle(for event: CalendarEvent) -> String? {
        guard !event.id.isEmpty, let found = provider(for: event).provider, found.info.createRefusal == nil else {
            return nil
        }
        let mine = event.organizerIsMe == true || (event.organizerIsMe == nil && event.attendees.isEmpty)
        if mine { return found.abilities.contains(.remove) ? String(localized: "Delete…") : nil }
        guard event.isInvitationCopy && found.abilities.contains(.removeInvite) else { return nil }
        if event.isMerged, let account = event.account { return String(localized: "Remove from \(account)…") }
        return String(localized: "Remove from Calendar…")
    }

    /// The other copies of a meeting on several calendars that the menus offer to remove alone, each from its own account.
    public func copyRemovals(for event: CalendarEvent) -> [CalendarCopyRemoval] {
        guard event.isMerged else { return [] }
        return event.copies.filter { $0.copyKey != event.copyKey && canRemoveCopyAlone($0) }.compactMap { copy in
            copy.account.map { CalendarCopyRemoval(copyKey: copy.copyKey, title: String(localized: "Remove from \($0)…")) }
        }
    }

    public func askToRemove(_ event: CalendarEvent, copy copyKey: String) {
        openEvent(event)
        askToRemoveCardEvent(copy: copyKey)
    }

    public func canRespond(to event: CalendarEvent) -> Bool {
        guard let found = provider(for: event).provider, found.info.createRefusal == nil else { return false }
        return event.canRespond && found.abilities.contains(.respond)
    }

    public func askToRemoveCardEvent() {
        guard let current = card else { return }
        askToRemoveCardEvent(copy: current.event.copyKey)
    }

    /// Removal of one copy of the card's meeting: the shown copy, or another connected calendar's invited copy alone.
    public func askToRemoveCardEvent(copy copyKey: String) {
        guard var current = card else { return }
        guard let subject = removalSubject(copyKey, in: current) else {
            current.note = copyKey == current.event.copyKey
                ? current.reason ?? String(localized: "This calendar can't remove events from Mail yet.")
                : String(localized: "Mail can't remove this copy from its calendar.")
            card = current
            return
        }
        scopeQuestion = nil
        do {
            guard let provider = subject.provider else { throw CalendarError.notConfigured }
            let target = try provider.removalProvider(for: subject.event)
            guard let source = storeKey(for: subject.event) else { throw CalendarError.notConfigured }
            guard CalendarEventStore.key(for: target) == source else {
                throw CalendarError.refused("This calendar can't keep deletion bound to the selected source. Open the event again.")
            }
            let key = CalendarRemovalKey(source: source, account: subject.account, eventID: subject.event.id)
            guard !pendingRemovals.contains(key) else {
                current.note = String(localized: "A deletion for this event is already pending.")
                card = current
                return
            }
            var question = CalendarRemoveQuestion(eventID: subject.event.copyKey, title: subject.event.title,
                                                  emailsPeople: !subject.event.attendees.isEmpty)
            question.isInvite = subject.isInvite
            question.isRecurring = subject.event.isRecurringForRemoval
            question.canRecreate = !question.isInvite && !question.isRecurring && !question.emailsPeople
                && !subject.event.isAllDay
            question.availableScopes = question.isRecurring ? target.removalScopes : [.thisEvent]
            if question.isInvite && question.isRecurring {
                question.availableScopes = question.availableScopes.filter {
                    CalendarRecurrenceScope.invitationRemovalOptions.contains($0)
                }
                if question.availableScopes == CalendarRecurrenceScope.invitationRemovalOptions {
                    question.note = CalendarRemoveQuestion.organizerOnlyFuture
                }
            }
            if question.isRecurring, question.note == nil,
               question.availableScopes != CalendarRecurrenceScope.removalOptions {
                question.note = String(localized: "This calendar can't remove some repeating-event scopes from Mail.")
            }
            if target.removalIdentity == nil {
                question.availableScopes = []
                question.note = String(localized: "This calendar can't keep deletion bound to the selected source.")
            }
            if current.event.isMerged {
                let others = current.event.copies.filter { $0.copyKey != subject.event.copyKey }
                question.account = subject.account
                if question.isInvite {
                    question.keptOn = others.compactMap(\.account)
                    question.organizerKept = others.contains { $0.organizerIsMe == true }
                } else if subject.event.organizerIsMe == true {
                    question.alsoOn = others.compactMap(\.account)
                }
            }
            removalContext = CalendarRemovalContext(questionID: question.id, cardID: current.identity,
                activeAccount: environment.router.activeAccountID, key: key, target: target)
            removeQuestion = question
        } catch {
            current.note = CalendarSidebarModel.message(error)
            card = current
        }
    }

    // The copy of the card's meeting a removal acts on: the shown event, with its card's rights, or another copy whose
    // own calendar takes the invitation off alone. Each is removed only through its own account's calendar.
    func removalSubject(_ copyKey: String, in current: CalendarEventCard) -> CalendarRemovalSubject? {
        if copyKey == current.event.copyKey {
            guard current.canRemove else { return nil }
            return CalendarRemovalSubject(event: current.event, isInvite: current.removesInvite,
                                          account: current.calendarKey.lowercased(),
                                          provider: provider(for: current.event).provider)
        }
        guard let row = current.copies.first(where: { $0.id == copyKey }), row.canRemove,
              let found = copyProvider(for: row.event) else { return nil }
        return CalendarRemovalSubject(event: row.event, isInvite: true, account: row.account.lowercased(), provider: found)
    }

    // Another copy than the shown one can leave alone only when it is an invitation its own calendar removes silently
    func canRemoveCopyAlone(_ copy: CalendarEvent) -> Bool {
        guard copy.isInvitationCopy, let found = copyProvider(for: copy) else { return false }
        return found.info.createRefusal == nil && found.abilities.contains(.removeInvite)
    }

    // Answers the invitation on one copy of a meeting, as that copy's own account
    public func respond(_ response: CalendarResponse, onCopy copyKey: String) async {
        guard var current = card else { return }
        guard copyKey != current.event.copyKey else { return await respond(response) }
        guard let index = current.copies.firstIndex(where: { $0.id == copyKey }) else { return }
        let row = current.copies[index]
        let copy = row.event
        guard response != .needsAction, row.canRespond, let target = copyProvider(for: copy) else {
            current.note = copyProvider(for: copy) == nil
                ? String(localized: "\(row.account) is no longer connected, so Mail can't answer for it.")
                : String(localized: "Mail can't answer this invitation for \(row.account).")
            card = current
            return
        }
        current.copies[index].response = response
        current.note = nil
        card = current
        let id = UUID()
        overlays[id] = .response(id: copy.copyKey, response)
        settling.insert(id)
        let account = row.account
        let series = copy.isRecurring ? String(localized: " (this event only)") : ""
        hold(id, title: String(localized: "Answering \(response.title) to \(copy.title) as \(account)\(series)… Google tells the organizer.")) {
            [weak self] in
            do {
                let answer = try await target.respond(to: copy, with: response, sendUpdates: .all)
                self?.store(answer, replacing: copy)
            } catch {
                self?.failed(String(localized: "Couldn't answer \(copy.title) as \(account). \(CalendarSidebarModel.message(error))"), id)
                return
            }
            await self?.changed(id, line: String(localized: "Answered \(response.title) to \(copy.title) as \(account)."))
        }
    }

    public func confirmRemove() async {
        guard let question = removeQuestion, !question.isRecurring else { return }
        await confirmRemove(.thisEvent, questionID: question.id)
    }

    public func confirmRemove(_ scope: CalendarRecurrenceScope, questionID: UUID) async {
        guard let question = removeQuestion, question.id == questionID,
              let context = removalContext, context.questionID == questionID,
              let current = card, current.identity == context.cardID,
              let subject = removalSubject(question.eventID, in: current), subject.account == context.key.account,
              environment.router.activeAccountID == context.activeAccount,
              !pendingRemovals.contains(context.key) else { return }
        do {
            guard let provider = subject.provider,
                  context.target.removalIdentity != nil,
                  try provider.removalProvider(for: subject.event).removalIdentity == context.target.removalIdentity,
                  storeKey(for: subject.event) == context.key.source else {
                throw CalendarError.refused("The selected calendar changed. Open the event again.")
            }
            guard question.availableScopes.contains(scope), !question.isRecurring || context.target.removalScopes.contains(scope),
                  question.isRecurring || scope == .thisEvent else {
                throw CalendarError.refused("This calendar doesn't support that deletion scope from Mail.")
            }
        } catch {
            removeQuestion?.note = CalendarSidebarModel.message(error)
            return
        }
        removeQuestion = nil
        removalContext = nil
        commitRemove(current, subject, scope: scope, context: context)
    }

    public func removeCardEvent() async {
        askToRemoveCardEvent()
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
            askToRemoveCardEvent()
        case .move(let start, let end):
            if let event = shownEvents.first(where: { $0.copyKey == question.eventID }) { await commitMove(event, start: start, end: end) }
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
        noteCopies(event, id)
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

    private func commitRemove(_ current: CalendarEventCard, _ subject: CalendarRemovalSubject,
                              scope: CalendarRecurrenceScope, context: CalendarRemovalContext) {
        let target = context.target
        let event = subject.event.single
        let id = UUID()
        let recurring = event.isRecurringForRemoval
        let known = CalendarRemovalResult(selectedID: event.id, parentID: event.recurringEventID
            ?? (recurring ? event.id : nil), scope: scope, originalCutoff: event.originalStartTime)
        overlays[id] = .removed(context.key, known)
        pendingRemovals.insert(context.key)
        noteCopies(current.event, id)
        let invite = subject.isInvite
        // Why: deleting a meeting the user organizes cancels it for their invited calendars too, so those copies leave
        // with it (and stay hidden until the later re-read shows Google removed them). Removing one invited copy hides
        // only that copy: the meeting stays drawn from the others.
        var cancelled: [String] = []
        if !invite, current.event.isMerged, subject.event.organizerIsMe == true {
            var linked: [UUID] = []
            for copy in current.event.copies where copy.copyKey != subject.event.copyKey {
                guard let account = copy.account?.lowercased(), let source = storeKey(for: copy) else { continue }
                let parent = copy.recurringEventID ?? (copy.isRecurringForRemoval ? copy.id : nil)
                let linkedID = UUID()
                overlays[linkedID] = .removed(CalendarRemovalKey(source: source, account: account, eventID: copy.id),
                                              CalendarRemovalResult(selectedID: copy.id, parentID: parent, scope: scope,
                                                                    originalCutoff: copy.originalStartTime))
                linked.append(linkedID)
                cancelled.append(copy.account ?? account)
            }
            linkedOverlays[id] = linked
        }
        let alsoOn = cancelled
        closeCard()
        let named = current.event.isMerged ? subject.account : nil
        let emails = !invite && (recurring || !event.attendees.isEmpty)
        let also = CalendarRemoveQuestion.list(alsoOn)
        let title: String
        if invite {
            title = named.map { String(localized: "Removing \(event.title) from \($0)…") }
                ?? String(localized: "Removing \(event.title) from your calendar…")
        } else if !alsoOn.isEmpty {
            title = String(localized: "Deleting \(event.title)… Google emails the attendees and cancels it on \(also).")
        } else {
            title = emails ? String(localized: "Deleting \(event.title)… Google emails the attendees.")
                           : String(localized: "Deleting \(event.title)…")
        }
        hold(id, title: title) { [weak self] in
            defer { self?.pendingRemovals.remove(context.key) }
            var confirmedRecurring = recurring
            do {
                let result = try await target.removeEvent(event, scope: scope, sendUpdates: emails ? .all : .none)
                confirmedRecurring = confirmedRecurring || result.parentID != nil
                self?.eventStore.applyRemoval(context.key.source, result: result)
            } catch {
                if case CalendarError.unclear = error {
                    self?.eventStore.invalidateRemoval(context.key.source)
                    await self?.load(force: true)
                }
                if self?.card == nil {
                    var failedCard = current
                    failedCard.note = CalendarSidebarModel.message(error)
                    self?.card = failedCard
                }
                let failure = invite
                    ? named.map { String(localized: "Couldn't remove \(event.title) from \($0).") }
                        ?? String(localized: "Couldn't remove \(event.title) from your calendar.")
                    : String(localized: "Couldn't delete \(event.title).")
                self?.failed("\(failure) \(CalendarSidebarModel.message(error))", id)
                return
            }
            if invite {
                let line = named.map { String(localized: "Removed \(event.title) from \($0).") }
                    ?? String(localized: "Removed \(event.title) from your calendar.")
                await self?.changed(id, line: line)
                return
            }
            if !confirmedRecurring, !emails, !event.isAllDay {
                self?.offerUndo(String(localized: "Deleted \(event.title).")) { [weak self] in
                    let draft = CalendarEventDraft(title: event.title, start: event.start, end: event.end,
                                                   timeZone: event.timeZone ?? TimeZone.current.identifier,
                                                   sendUpdates: .none, location: event.location ?? "",
                                                   notes: event.notes ?? "")
                    let made = try await target.createEvent(draft)
                    self?.eventStore.applyLocal(context.key.source, upsert: Self.untagged(made))
                }
                await self?.changed(id, line: nil)
                return
            }
            let line = alsoOn.isEmpty ? String(localized: "Deleted \(event.title).")
                : String(localized: "Deleted \(event.title). It is canceled on \(also) too.")
            await self?.changed(id, line: line)
        }
    }

    private func commitMove(_ event: CalendarEvent, start: Date, end: Date) async {
        guard let target = provider(for: event).provider else { return }
        let id = UUID()
        overlays[id] = .times(id: event.copyKey, start: start, end: end)
        noteCopies(event, id)
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
        settleOverlays += linkedOverlays.removeValue(forKey: id) ?? []
        if settling.remove(id) != nil { rereadCopiesLater() }
    }

    func failed(_ message: String, _ id: UUID) {
        overlays[id] = nil
        dropLinkedOverlays(of: id)
        settling.remove(id)
        environment.notices.post(message, style: .error)
    }

    func dropLinkedOverlays(of id: UUID) {
        for linked in linkedOverlays.removeValue(forKey: id) ?? [] { overlays[linked] = nil }
    }

    func noteCopies(_ event: CalendarEvent, _ id: UUID) {
        if event.isMerged { settling.insert(id) }
    }

    func rereadCopiesLater() {
        settleTask?.cancel()
        let delay = copySettleDelay
        let sleep = self.sleep
        settleTask = Task { [weak self, weak owner = environment] in
            try? await sleep(delay)
            guard let self else { return }
            guard !Task.isCancelled, let owner, self.isOpen else {
                if !Task.isCancelled { self.clearSettleOverlays() }
                return
            }
            defer { withExtendedLifetime(owner) {} }
            await self.load(force: true)
            guard !Task.isCancelled else { return }
            self.clearSettleOverlays()
        }
    }

    func clearSettleOverlays() {
        for linked in settleOverlays { overlays[linked] = nil }
        settleOverlays = []
    }

    func hold(_ id: UUID, title: String, perform: @escaping @MainActor @Sendable () async -> Void) {
        let window = holdWindow
        let sleep = self.sleep
        held[id] = Task { [weak self, weak owner = environment] in
            try? await sleep(window)
            guard let self, self.held.removeValue(forKey: id) != nil else { return }
            guard let owner else {
                self.overlays[id] = nil
                self.dropLinkedOverlays(of: id)
                self.settling.remove(id)
                return
            }
            // Terminal handling can suspend again in the forced reload after the write.
            defer { withExtendedLifetime(owner) {} }
            await perform()
        }
        pushUndo(id, title: title)
    }

    public var hasQuitWork: Bool { !held.isEmpty }

    public func prepareForQuit() async {
        settleTask?.cancel()
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
            if case .removed(let key, _)? = overlays[id] { pendingRemovals.remove(key) }
            overlays[id] = nil
            dropLinkedOverlays(of: id)
            settling.remove(id)
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
