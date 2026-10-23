import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private let utc = TimeZone(identifier: "UTC")!
private let utcCalendar = CalendarDateMentions.calendar(utc)
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
private let alias = "robin@team.example"
private let sam = EmailAddress(name: "Sam Rivera", email: "sam@example.org")
private let group = EmailAddress(name: "Design team", email: "design@groups.example.org")

private func at(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

private func invitation(_ id: String, _ start: Date, guests: [CalendarGuest]) -> CalendarEvent {
    var event = CalendarEvent(id: id, title: "Event \(id)", start: start, end: start.addingTimeInterval(3_600),
                              attendees: guests.map(\.address))
    event.extras.guests = guests
    return event
}

private func own(_ id: String, _ start: Date, series: String? = nil) -> CalendarEvent {
    CalendarEvent(id: id, title: "Event \(id)", start: start, end: start.addingTimeInterval(3_600), organizerIsMe: true,
                  recurringEventID: series)
}

private let work = Account(id: AccountID(1), email: "robin@example.com", displayName: nil, alias: nil, health: .active,
                           sendAs: [SenderIdentity(email: "robin@example.com", isDefault: true, isPrimary: true),
                                    SenderIdentity(email: alias, isDefault: false, isPrimary: false)])

// Reads answer at once but hand their answer back only when the gate opens, like a read under way during a save
private final class HeldReads: CalendarProviding, Sendable {
    let inner: FakeCalendar
    private let gate = Mutex<Checkpoint?>(nil)

    init(_ inner: FakeCalendar) { self.inner = inner }

    func hold(_ next: Checkpoint) { gate.withLock { $0 = next } }

    var info: CalendarProviderInfo { inner.info }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] { try await inner.events(from: from, to: to) }
    func freeBusy(from: Date, to: Date) async throws -> CalendarFreeBusy { try await inner.freeBusy(from: from, to: to) }
    func eventWindow(from: Date, to: Date) async throws -> CalendarEventWindow {
        let answer = try await inner.eventWindow(from: from, to: to)
        if let held = gate.withLock({ $0 }) { await held.pass() }
        return answer
    }
    func eventDelta(since token: String) async throws -> CalendarEventDelta {
        let answer = try await inner.eventDelta(since: token)
        if let held = gate.withLock({ $0 }) { await held.pass() }
        return answer
    }
    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEvent { try await inner.createEvent(draft) }
}

// Answers a change to a whole series the way Google does: with the series' own event, not the occurrence
private final class SeriesAnswers: CalendarProviding, Sendable {
    struct Sent: Sendable, Hashable {
        let id: String
        let patch: CalendarEventPatch
        let scope: CalendarRecurrenceScope
    }

    let inner: FakeCalendar
    let series: CalendarEvent
    private let sent = Mutex<[Sent]>([])

    init(_ inner: FakeCalendar, series: CalendarEvent) {
        self.inner = inner
        self.series = series
    }

    var patches: [Sent] { sent.withLock { $0 } }
    var info: CalendarProviderInfo { inner.info }
    var abilities: CalendarAbilities { inner.abilities }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] { try await inner.events(from: from, to: to) }
    func freeBusy(from: Date, to: Date) async throws -> CalendarFreeBusy { try await inner.freeBusy(from: from, to: to) }
    func eventWindow(from: Date, to: Date) async throws -> CalendarEventWindow { try await inner.eventWindow(from: from, to: to) }
    func eventDelta(since token: String) async throws -> CalendarEventDelta { try await inner.eventDelta(since: token) }
    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEvent { try await inner.createEvent(draft) }
    func patchEvent(_ event: CalendarEvent, with patch: CalendarEventPatch, scope: CalendarRecurrenceScope,
                    sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        sent.withLock { $0.append(Sent(id: event.id, patch: patch, scope: scope)) }
        guard scope == .allEvents else {
            return try await inner.patchEvent(event, with: patch, scope: scope, sendUpdates: sendUpdates)
        }
        return series
    }
}

@MainActor
private final class Changes {
    var all: [CalendarEventStoreChange] = []
}

@MainActor
private struct WindowSetup {
    let env: AppEnvironment
    let model: CalendarWindowModel

    init(_ provider: any CalendarProviding, account email: String) {
        let corpus = FakeCorpus.rich(threadCount: 12, now: fixedNow)
        let connections = FakeCalendarConnections(providers: [email: provider], windowAccount: email)
        env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), featureFlags: FeatureFlags(),
                                  calendar: provider, calendarConnections: connections)
        let sidebar = env.calendarSidebar!
        sidebar.timeZone = utc
        sidebar.now = { at(12, 9) }
        model = env.calendarWindow!
        model.timeZone = utc
        model.now = { at(12, 9) }
        model.confirmsMovesOverride = false
    }
}

@MainActor
@Suite struct CalendarOwnAddressTests {
    @Test func anAnswerOnAnAliasEntryIsTheAccountsOwnAndAGroupInvitationSaysSo() {
        let addresses = work.myAddresses
        let toAlias = invitation("a", at(13, 9), guests: [CalendarGuest(sam, isOptional: false),
                                                          CalendarGuest(email: "Robin@Team.example", response: .accepted)])
        let resolved = toAlias.resolvingMyResponse(addresses: addresses)
        #expect(resolved.myResponse == .accepted && resolved.respondsAs == "Robin@Team.example" && resolved.canRespond)
        #expect(!toAlias.canRespond && toAlias.hidesMyResponse, "unresolved, the event says why it offers no answer")

        let toGroup = invitation("g", at(13, 11), guests: [CalendarGuest(sam), CalendarGuest(group)])
        let unresolved = toGroup.resolvingMyResponse(addresses: addresses)
        #expect(unresolved.myResponse == nil && !unresolved.canRespond && unresolved.hidesMyResponse)

        let twice = invitation("t", at(13, 13), guests: [CalendarGuest(email: alias), CalendarGuest(email: "robin@example.com")])
        #expect(twice.resolvingMyResponse(addresses: addresses).myResponse == nil, "never a guess between two own entries")

        var marked = toAlias
        marked.myResponse = .declined
        #expect(marked.resolvingMyResponse(addresses: addresses) == marked, "the calendar's own mark wins")
        let organized = CalendarEvent(id: "o", title: "Mine", start: at(13, 9), end: at(13, 10), attendees: [sam],
                                      organizerIsMe: true, extras: toAlias.extras)
        #expect(organized.resolvingMyResponse(addresses: addresses).myResponse == nil && !organized.hidesMyResponse)
    }

    @Test func theStoreShowsAliasAnswersAndLeavesAnAliasDeclineOutOfTheDayAndTheBusyTime() async throws {
        let calendar = FakeCalendar(events: [
            invitation("yes", at(13, 9), guests: [CalendarGuest(sam), CalendarGuest(email: alias, response: .accepted)]),
            invitation("no", at(13, 11), guests: [CalendarGuest(sam), CalendarGuest(email: alias, response: .declined)]),
            invitation("group", at(13, 13), guests: [CalendarGuest(sam), CalendarGuest(group)]),
        ], info: CalendarProviderInfo(name: "Google Calendar", account: work.email))
        let store = CalendarEventStore(timeZone: utc)
        let key = CalendarEventStore.key(for: calendar)
        let seen = Changes()
        store.observe { seen.all.append($0) }
        await store.ensure(key, provider: calendar, from: at(13), to: at(14), today: at(12, 9), calendar: utcCalendar,
                           now: at(12, 9))
        let before = try #require(store.events(key, from: at(13), to: at(14), includeDeclined: true))
        #expect(before.allSatisfy { $0.myResponse == nil }, "the calendar marks no entry as its own")
        seen.all.removeAll()
        store.learnAddresses(of: [work])
        #expect(seen.all.contains { $0.updated.contains("yes") }, "what is drawn changes, so the views repaint")
        let all = try #require(store.events(key, from: at(13), to: at(14), includeDeclined: true))
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        #expect(byID["yes"]?.myResponse == .accepted && byID["yes"]?.respondsAs == alias && byID["yes"]?.canRespond == true)
        #expect(byID["no"]?.myResponse == .declined)
        #expect(byID["group"]?.hidesMyResponse == true)
        #expect(store.events(key, from: at(13), to: at(14))?.map(\.id) == ["yes", "group"], "declined as the alias")
        #expect(store.busy(key, from: at(13), to: at(14)) == [CalendarBusyInterval(start: at(13, 9), end: at(13, 10)),
                                                              CalendarBusyInterval(start: at(13, 13), end: at(13, 14))])
        seen.all.removeAll()
        store.learnAddresses(of: [work])
        #expect(seen.all.isEmpty, "the same addresses again change nothing")
    }

    @Test func detailsMarkTheAliasAsYouAndSayWhenTheAnswerIsNotShown() {
        let resolved = invitation("a", at(13, 9), guests: [CalendarGuest(sam), CalendarGuest(email: alias, response: .tentative)])
            .resolvingMyResponse(addresses: work.myAddresses)
        let shown = CalendarEventDetails(event: resolved, timeZone: utc, calendarName: work.email, calendarKey: work.email,
                                         myAddresses: [work.email])
        #expect(shown.guests.first { $0.email == alias }?.isMe == true && shown.answerText == "Your answer: Maybe")
        let hidden = CalendarEventDetails(event: invitation("g", at(13, 11), guests: [CalendarGuest(sam), CalendarGuest(group)]),
                                          timeZone: utc, calendarName: work.email, calendarKey: work.email,
                                          myAddresses: [work.email])
        #expect(hidden.answerText == "Your response is not shown for this event.")
        #expect(hidden.guests.allSatisfy { !$0.isMe })
    }

    @Test func anAllDayEventReadInAnotherZoneKeepsItsGuestsAndRepeat() {
        var extras = CalendarEventExtras(guests: [CalendarGuest(sam)], recurrence: ["RRULE:FREQ=YEARLY"])
        extras.colorID = "5"
        var offsite = CalendarEvent(id: "off", title: "Offsite", start: at(14), end: at(15), isAllDay: true, extras: extras)
        offsite.respondsAs = alias
        let record = CalendarEventRecord(event: offsite, readIn: utc)
        let moved = record.materialized(in: tokyo)
        #expect(moved.event.start != offsite.start, "drawn on Tokyo's midnight")
        #expect(moved.event.extras == extras && moved.event.respondsAs == alias)
    }

    @Test func theWindowAnswersAsTheAlias() async throws {
        let calendar = FakeCalendar(events: [
            invitation("team", at(13, 9), guests: [CalendarGuest(sam), CalendarGuest(email: alias, response: .needsAction)]),
        ], info: CalendarProviderInfo(name: "Google Calendar", account: work.email),
           abilities: [.respond, .editDetails, .remove, .editFull])
        let setup = WindowSetup(calendar, account: work.email)
        let model = setup.model
        let gate = TestGate()
        model.sleep = { _ in await gate.wait() }
        await model.open()
        let shown = try #require(model.events.first)
        #expect(shown.myResponse == .needsAction && shown.respondsAs == alias)
        model.openEvent(shown)
        #expect(model.card?.canRespond == true)
        await model.respond(.accepted)
        let tasks = Array(model.held.values)
        gate.release()
        for task in tasks { await task.value }
        #expect(calendar.calls.contains(.respond(id: "team", response: .accepted, sendUpdates: .all)))
        #expect(model.events.first?.myResponse == .accepted)
        #expect(calendar.allEvents.first?.extras.guests.last?.response == .accepted, "the alias's entry was answered")
    }
}

@MainActor
@Suite struct CalendarSaveRaceTests {
    private let span = DateInterval(start: at(13), end: at(14))

    private func refresh(_ store: CalendarEventStore, _ key: CalendarCacheKey, _ provider: any CalendarProviding) async {
        await store.revalidate(key, provider: provider, visible: span, today: at(12, 9), calendar: utcCalendar,
                               now: at(12, 9), force: true)
    }

    @Test func aReadThatBeganBeforeASaveLeavesTheSavedTimeAlone() async throws {
        let inner = FakeCalendar(events: [own("own", at(13, 9))])
        inner.supportsChangeTokens = false
        let held = HeldReads(inner)
        let store = CalendarEventStore(timeZone: utc)
        let key = CalendarEventStore.key(for: held)
        await store.ensure(key, provider: held, from: span.start, to: span.end, today: at(12, 9), calendar: utcCalendar,
                           now: at(12, 9))
        let gate = Checkpoint()
        held.hold(gate)
        let stale = Task { await refresh(store, key, held) }
        await gate.arrived()
        #expect(inner.windowCalls == 2)
        let saved = try await inner.moveEvent(try #require(inner.allEvents.first), to: at(13, 14), end: at(13, 15),
                                              sendUpdates: .none)
        store.applyLocal(key, upsert: saved)
        gate.release()
        await stale.value
        #expect(store.events(key, from: span.start, to: span.end)?.first?.start == at(13, 14),
                "the read under way carried the old version, so the saved time stays")
        await refresh(store, key, held)
        #expect(store.record(key, id: "own")?.etag == "v1" && store.events(key, from: span.start, to: span.end)?.first?.start
                == at(13, 14), "the calendar's next version replaces the saved copy")
    }

    @Test func aRefreshAfterASaveReadsAgainOnceTheReadUnderWayEnds() async throws {
        let inner = FakeCalendar(events: [own("own", at(13, 9))])
        inner.supportsChangeTokens = false
        let held = HeldReads(inner)
        let store = CalendarEventStore(timeZone: utc)
        let key = CalendarEventStore.key(for: held)
        await store.ensure(key, provider: held, from: span.start, to: span.end, today: at(12, 9), calendar: utcCalendar,
                           now: at(12, 9))
        let gate = Checkpoint()
        held.hold(gate)
        let stale = Task { await refresh(store, key, held) }
        await gate.arrived()
        #expect(inner.windowCalls == 2)
        let saved = try await inner.moveEvent(try #require(inner.allEvents.first), to: at(13, 14), end: at(13, 15),
                                              sendUpdates: .none)
        store.applyLocal(key, upsert: saved)
        let after = Task { await refresh(store, key, held) }
        await Task.yield()
        gate.release()
        await stale.value
        await after.value
        #expect(inner.windowCalls == 3, "one more read after the one that began before the save")
        #expect(store.record(key, id: "own")?.etag == "v1")
    }

    @Test func savingAllEventsOfASeriesNeverStoresTheSeriesAsAnOccurrenceAndUndoKeepsTheScope() async throws {
        let occurrence = own("w_20261013", at(13, 9), series: "w")
        let inner = FakeCalendar(events: [occurrence], info: CalendarProviderInfo(name: "Google Calendar", account: work.email),
                                 abilities: [.respond, .editDetails, .remove, .editFull])
        let series = own("w", at(6, 9))
        let calendar = SeriesAnswers(inner, series: series)
        let setup = WindowSetup(calendar, account: work.email)
        let model = setup.model
        await model.open()
        model.openEvent(try #require(model.events.first))
        model.card?.form?.setStart(at(13, 11))
        await model.saveCard()
        #expect(model.scopeQuestion?.scopes.contains(.allEvents) == true)
        await model.answerRecurrenceScope(.allEvents)
        let saved = try #require(calendar.patches.first)
        #expect(saved.id == occurrence.id && saved.scope == .allEvents && saved.patch.time?.start == at(13, 11))
        let key = CalendarEventStore.key(for: calendar)
        #expect(model.eventStore.record(key, id: "w") == nil, "the series' own event is not drawn as an occurrence")
        #expect(model.events.map(\.id) == [occurrence.id])
        await setup.env.undo?.undoLast()
        let back = try #require(calendar.patches.last)
        #expect(calendar.patches.count == 2)
        #expect(back.id == occurrence.id && back.scope == .allEvents, "undone on the occurrence for all events")
        #expect(back.patch.time?.start == at(13, 9) && back.patch.time?.end == at(13, 10))
        #expect(model.eventStore.record(key, id: "w") == nil)
    }

    @Test func leavingAProposedMoveSaysTheEventKeptItsTime() async throws {
        let first = own("one", at(13, 9))
        let second = own("two", at(14, 9))
        let calendar = FakeCalendar(events: [first, second], info: CalendarProviderInfo(name: "Google Calendar", account: work.email),
                                    abilities: [.respond, .editDetails, .remove, .editFull])
        let setup = WindowSetup(calendar, account: work.email)
        let model = setup.model
        model.confirmsMovesOverride = true
        await model.open()
        let notices = { setup.env.notices.toasts.filter { $0.message.hasPrefix("Didn't move") } }
        await model.moveEvent(try #require(model.events.first { $0.id == "one" }), to: at(13, 14), end: at(13, 15))
        #expect(model.card?.pendingMove != nil)
        model.openEvent(try #require(model.events.first { $0.id == "two" }))
        #expect(notices().map(\.message) == ["Didn't move Event one. Accept a move to save it."])
        #expect(calendar.moveCalls == 0 && model.shownEvents.first { $0.id == "one" }?.start == at(13, 9))

        await model.moveEvent(try #require(model.events.first { $0.id == "two" }), to: at(14, 14), end: at(14, 15))
        model.cancelPendingMove()
        #expect(notices().count == 1, "Cancel is the user's own choice: no notice")
        await model.moveEvent(try #require(model.events.first { $0.id == "two" }), to: at(14, 14), end: at(14, 15))
        await model.newEvent(start: at(15, 10), end: at(15, 11))
        #expect(notices().count == 2, "an empty slot clicked while a move waits says so too")
    }
}
