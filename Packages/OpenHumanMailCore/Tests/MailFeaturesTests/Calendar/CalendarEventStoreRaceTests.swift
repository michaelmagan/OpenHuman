import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private let utc = TimeZone(identifier: "UTC")!
private let day = Date(timeIntervalSince1970: 1_791_000_000)

private func event(_ id: String, hours: Double) -> CalendarEvent {
    CalendarEvent(id: id, title: "Event \(id)", start: day.addingTimeInterval(hours * 3_600),
                  end: day.addingTimeInterval(hours * 3_600 + 1_800))
}

private final class ScriptedCalendar: CalendarProviding, Sendable {
    let info = CalendarProviderInfo(name: "Google Calendar", account: "robin@example.com")
    private let answers: Mutex<[CalendarEventWindow]>
    private let asked = Mutex(0)
    let checkpoint: Checkpoint?

    init(_ answers: [CalendarEventWindow], checkpoint: Checkpoint? = nil) {
        self.answers = Mutex(answers)
        self.checkpoint = checkpoint
    }

    var reads: Int { asked.withLock { $0 } }

    func events(from: Date, to: Date) async throws -> [CalendarEvent] { [] }
    func freeBusy(from: Date, to: Date) async throws -> CalendarFreeBusy { CalendarFreeBusy(busy: []) }
    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEvent { throw CalendarError.notConfigured }

    func eventWindow(from: Date, to: Date) async throws -> CalendarEventWindow {
        asked.withLock { $0 += 1 }
        let answer = answers.withLock { $0.isEmpty ? CalendarEventWindow(records: []) : $0.removeFirst() }
        await checkpoint?.pass()
        return answer
    }
}

private final class RemovalSyncCalendar: CalendarProviding, Sendable {
    let info = CalendarProviderInfo(name: "Google Calendar", account: "robin@example.com")
    let expiryRead: Checkpoint?
    private let filtersWindows: Bool
    private struct State {
        var records: [CalendarEventRecord]
        var reads = 0
        var deltaReads = 0
        var expire = false
        var fail = false
        var truncate = false
    }
    private let state: Mutex<State>
    init(_ records: [CalendarEventRecord], expiryRead: Checkpoint? = nil, filtersWindows: Bool = false) {
        state = Mutex(State(records: records))
        self.expiryRead = expiryRead
        self.filtersWindows = filtersWindows
    }
    var records: [CalendarEventRecord] {
        get { state.withLock { $0.records } }
        set { state.withLock { $0.records = newValue } }
    }
    var expire: Bool {
        get { state.withLock { $0.expire } }
        set { state.withLock { $0.expire = newValue } }
    }
    var fail: Bool {
        get { state.withLock { $0.fail } }
        set { state.withLock { $0.fail = newValue } }
    }
    var truncate: Bool {
        get { state.withLock { $0.truncate } }
        set { state.withLock { $0.truncate = newValue } }
    }
    var reads: Int { state.withLock { $0.reads } }
    var deltaReads: Int { state.withLock { $0.deltaReads } }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] { records.map(\.event) }
    func freeBusy(from: Date, to: Date) async throws -> CalendarFreeBusy { CalendarFreeBusy(busy: []) }
    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEvent { throw CalendarError.notConfigured }
    func eventWindow(from: Date, to: Date) async throws -> CalendarEventWindow {
        let count = state.withLock { $0.reads += 1; return $0.reads }
        if count > 1 { await expiryRead?.pass() }
        if fail { throw CalendarError.failed("Synthetic offline") }
        let windowRecords = records.filter { !filtersWindows || $0.event.overlaps(from: from, to: to) }
        if truncate { return CalendarEventWindow(records: Array(windowRecords.suffix(1)), isComplete: false) }
        return CalendarEventWindow(records: windowRecords, syncToken: "old-window")
    }
    func eventDelta(since token: String) async throws -> CalendarEventDelta {
        state.withLock { $0.deltaReads += 1 }
        if expire { throw CalendarSyncError.tokenExpired }
        return CalendarEventDelta(changed: records, syncToken: "old-delta")
    }
}

@MainActor
@Suite struct CalendarEventStoreRaceTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    @Test func aReadThatFinishesAfterTheCalendarIsDisconnectedIsThrownAway() async throws {
        let checkpoint = Checkpoint()
        let provider = ScriptedCalendar([CalendarEventWindow(records: [CalendarEventRecord(event: event("secret", hours: 2))])],
                                        checkpoint: checkpoint)
        let cache = InMemoryCalendarCache()
        let store = CalendarEventStore(persistence: cache, timeZone: utc)
        let key = CalendarEventStore.key(for: provider)
        let reading = Task {
            await store.ensure(key, provider: provider, from: day, to: day.addingTimeInterval(86_400), today: day,
                               calendar: calendar, now: day)
        }
        await checkpoint.arrived()
        store.forget(account: "robin@example.com")
        checkpoint.release()
        await reading.value
        await store.flush()
        #expect(store.record(key, id: "secret") == nil && store.events(key, from: day, to: day.addingTimeInterval(86_400)) == nil)
        #expect(await cache.load().allSatisfy { $0.records.isEmpty }, "nothing is written back to disk")
    }

    @Test func aTruncatedReadKeepsTheEventsItDidNotReach() async throws {
        let first = CalendarEventWindow(records: [CalendarEventRecord(event: event("a", hours: 1)),
                                                 CalendarEventRecord(event: event("b", hours: 5))])
        let truncated = CalendarEventWindow(records: [CalendarEventRecord(event: event("a", hours: 1))], isComplete: false)
        let provider = ScriptedCalendar([first, truncated])
        let store = CalendarEventStore(persistence: InMemoryCalendarCache(), timeZone: utc)
        let key = CalendarEventStore.key(for: provider)
        let visible = DateInterval(start: day, end: day.addingTimeInterval(86_400))
        await store.ensure(key, provider: provider, from: visible.start, to: visible.end, today: day, calendar: calendar,
                           now: day)
        #expect(store.record(key, id: "b") != nil)
        await store.revalidate(key, provider: provider, visible: visible, today: day, calendar: calendar,
                               now: day.addingTimeInterval(600), force: true)
        #expect(provider.reads == 2)
        #expect(store.record(key, id: "b") != nil, "an incomplete answer is not proof that the event is gone")
    }

    private func occurrence(_ id: String, original: String, display: String? = nil, parent: String = "weekly") -> CalendarEventRecord {
        let iso = ISO8601DateFormatter()
        let start = iso.date(from: display ?? original)!
        let event = CalendarEvent(id: id, title: "Weekly", start: start, end: start.addingTimeInterval(1800),
            timeZone: "America/Los_Angeles", organizerIsMe: true, recurringEventID: parent,
            originalStartTime: .timed(iso.date(from: original)!, timeZone: "America/Los_Angeles"))
        return CalendarEventRecord(event: event, etag: "v1", recurringEventID: parent)
    }

    private var originalPositions: [CalendarEventRecord] {
        [occurrence("first", original: "2026-10-25T16:00:00Z"),
         occurrence("middle", original: "2026-11-01T17:00:00Z"),
         occurrence("last", original: "2026-11-08T17:00:00Z"),
         occurrence("early-moved", original: "2026-10-18T16:00:00Z", display: "2026-11-08T18:00:00Z"),
         occurrence("late-moved", original: "2026-11-15T17:00:00Z", display: "2026-10-25T18:00:00Z"),
         occurrence("separate", original: "2026-11-01T17:00:00Z", parent: "other-parent")]
    }

    @Test func confirmedScopesRemoveAcrossRangesPersistAndPreserveOtherAccountsAndParents() async throws {
        let provider = ScriptedCalendar([])
        let key = CalendarEventStore.key(for: provider)
        let other = CalendarCacheKey(account: "other@example.org", calendar: "other@example.org")
        let iso = ISO8601DateFormatter()
        let now = iso.date(from: "2026-10-26T12:00:00Z")!
        let ranges = [("2026-10-24T00:00:00Z", "2026-10-27T00:00:00Z"),
                      ("2026-10-31T00:00:00Z", "2026-11-03T00:00:00Z"),
                      ("2026-11-07T00:00:00Z", "2026-11-10T00:00:00Z")].map {
            CalendarCoveredRange(start: iso.date(from: $0.0)!, end: iso.date(from: $0.1)!, fetchedAt: now)
        }
        let cases: [(CalendarRecurrenceScope, [String])] = [
            (.thisEvent, ["early-moved", "first", "last", "late-moved", "separate"]),
            (.allEvents, ["separate"]), (.thisAndFollowing, ["early-moved", "first", "separate"])]
        for (scope, expected) in cases {
            let cache = InMemoryCalendarCache(entries: [
                CalendarCacheEntry(key: key, records: originalPositions, ranges: ranges, syncToken: "old"),
                CalendarCacheEntry(key: other, records: originalPositions, ranges: ranges, syncToken: "other")])
            let store = CalendarEventStore(persistence: cache, timeZone: utc)
            await store.restore(now: now)
            let result = CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: scope,
                originalCutoff: .timed(iso.date(from: "2026-11-01T17:00:00Z")!, timeZone: "America/Los_Angeles"))
            store.applyRemoval(key, result: result)
            await store.flush()
            let entry = try #require(await cache.load().first { $0.key == key })
            #expect(entry.records.map(\.event.id).sorted() == expected)
            #expect(store.record(other, id: "middle") != nil)
            let relaunched = CalendarEventStore(persistence: cache, timeZone: utc)
            await relaunched.restore(now: now)
            #expect(expected.allSatisfy { relaunched.record(key, id: $0) != nil })
            #expect(relaunched.record(key, id: "middle") == nil)
        }
    }

    @Test func recordOnlyParentsReachPresentedEventsAndScopedRemovalPersistsAcrossRanges() async throws {
        let records = originalPositions.map { source in
            var old = source
            old.event.recurringEventID = nil
            return old
        }
        let provider = ScriptedCalendar([])
        let key = CalendarEventStore.key(for: provider)
        let iso = ISO8601DateFormatter()
        let now = iso.date(from: "2026-10-26T12:00:00Z")!
        let ranges = [("2026-10-24T00:00:00Z", "2026-10-27T00:00:00Z"),
                      ("2026-10-31T00:00:00Z", "2026-11-03T00:00:00Z"),
                      ("2026-11-07T00:00:00Z", "2026-11-10T00:00:00Z")].map {
            CalendarCoveredRange(start: iso.date(from: $0.0)!, end: iso.date(from: $0.1)!, fetchedAt: now)
        }
        let cases: [(CalendarRecurrenceScope, [String])] = [(.allEvents, ["separate"]),
            (.thisAndFollowing, ["early-moved", "first", "separate"])]
        for (scope, expected) in cases {
            let cache = InMemoryCalendarCache(entries: [CalendarCacheEntry(key: key, records: records, ranges: ranges)])
            let store = CalendarEventStore(persistence: cache, timeZone: utc)
            await store.restore(now: now)
            let firstRange = ranges[0]
            let presented = try #require(store.events(key, from: firstRange.start, to: firstRange.end)?.first { $0.id == "first" })
            #expect(presented.recurringEventID == "weekly" && presented.isRecurringForRemoval && presented.isRecurring)
            store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: scope,
                originalCutoff: records[1].event.originalStartTime))
            await store.flush()
            let saved = try #require(await cache.load().first)
            #expect(saved.records.map(\.event.id).sorted() == expected)
            let relaunched = CalendarEventStore(persistence: cache, timeZone: utc)
            await relaunched.restore(now: now)
            #expect(relaunched.record(key, id: "middle") == nil && relaunched.record(key, id: "last") == nil)
            if scope == .thisAndFollowing {
                let restored = try #require(relaunched.events(key, from: firstRange.start, to: firstRange.end)?.first { $0.id == "first" })
                #expect(restored.recurringEventID == "weekly")
            }
        }
    }

    @Test func conflictingParentRowsInvalidateCoverageInBothDirectionsWithoutDeletingThem() async throws {
        for (eventParent, recordParent) in [("weekly", "other-parent"), ("other-parent", "weekly")] {
            var conflict = occurrence("conflict", original: "2026-11-08T17:00:00Z", parent: eventParent)
            conflict.recurringEventID = recordParent
            var selected = originalPositions[1]
            selected.recurringEventID = "other-parent"
            let from = selected.event.start.addingTimeInterval(-3600)
            let to = conflict.event.end.addingTimeInterval(3600)
            let provider = ScriptedCalendar([CalendarEventWindow(records: [conflict])])
            let key = CalendarEventStore.key(for: provider)
            let cache = InMemoryCalendarCache(entries: [CalendarCacheEntry(key: key, records: [selected, conflict],
                ranges: [CalendarCoveredRange(start: from, end: to, fetchedAt: from)])])
            let store = CalendarEventStore(persistence: cache, timeZone: utc)
            await store.restore(now: from)
            store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: .allEvents,
                originalCutoff: selected.event.originalStartTime))
            #expect(store.record(key, id: "middle") == nil, "the selected authoritative ID is removed even if its cached fields conflict")
            #expect(store.record(key, id: "conflict") == conflict && !store.covers(key, from: from, to: to))
            await store.fill(key, provider: provider, window: DateInterval(start: from, end: to), now: from)
            #expect(provider.reads == 1 && !store.covers(key, from: from, to: to))
            #expect(store.record(key, id: "conflict") == conflict, "a conflicting fresh response does not choose either parent")
            await store.flush()
            let saved = try #require(await cache.load().first)
            #expect(saved.records == [conflict] && saved.ranges.isEmpty)
        }
    }

    @Test func thisEventKeepsUnrelatedConflictingRowsCoveredAndPersisted() async throws {
        let known = originalPositions
        for (eventParent, recordParent) in [("weekly", "other-parent"), ("other-parent", "weekly")] {
            var conflict = occurrence("conflict", original: "2026-11-08T17:00:00Z", parent: eventParent)
            conflict.recurringEventID = recordParent
            let from = known[0].event.start.addingTimeInterval(-3600)
            let to = conflict.event.end.addingTimeInterval(3600)
            let span = DateInterval(start: from, end: to)
            let provider = ScriptedCalendar([CalendarEventWindow(records: [known[0], conflict])])
            let key = CalendarEventStore.key(for: provider)
            let cache = InMemoryCalendarCache(entries: [CalendarCacheEntry(key: key, records: [known[0], known[1], conflict],
                ranges: [CalendarCoveredRange(start: from, end: to, fetchedAt: from)])])
            let store = CalendarEventStore(persistence: cache, timeZone: utc)
            await store.restore(now: from)
            store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: .thisEvent,
                originalCutoff: known[1].event.originalStartTime))
            #expect(store.record(key, id: "middle") == nil && store.record(key, id: "conflict") == conflict)
            #expect(store.covers(key, from: from, to: to), "unrelated parent conflicts cannot invalidate an exact-ID removal")
            await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
            #expect(store.covers(key, from: from, to: to))
            await store.flush()
            let saved = try #require(await cache.load().first)
            #expect(saved.records.map(\.event.id).sorted() == ["conflict", "first"] && !saved.ranges.isEmpty)
            let relaunched = CalendarEventStore(persistence: cache, timeZone: utc)
            await relaunched.restore(now: from)
            #expect(relaunched.covers(key, from: from, to: to) && relaunched.record(key, id: "conflict") == conflict)
            #expect(relaunched.record(key, id: "middle") == nil)
        }
    }

    @Test func seriesRemovalKeepsADistinctMasterCoveredAndPersisted() async throws {
        let known = originalPositions
        let master = CalendarEventRecord(event: CalendarEvent(id: "other-master", title: "Weekly", start: known[2].event.end,
            end: known[2].event.end.addingTimeInterval(1800), extras: CalendarEventExtras(recurrence: ["RRULE:FREQ=WEEKLY"])), etag: "master-v1")
        let from = known[0].event.start.addingTimeInterval(-3600)
        let to = master.event.end.addingTimeInterval(3600)
        let span = DateInterval(start: from, end: to)
        for scope in [CalendarRecurrenceScope.allEvents, .thisAndFollowing] {
            let survivors = scope == .allEvents ? [master] : [known[0], master]
            let expected = scope == .allEvents ? ["other-master"] : ["first", "other-master"]
            let provider = ScriptedCalendar([CalendarEventWindow(records: survivors)])
            let key = CalendarEventStore.key(for: provider)
            let cache = InMemoryCalendarCache(entries: [CalendarCacheEntry(key: key, records: [known[0], known[1], known[2], master],
                ranges: [CalendarCoveredRange(start: from, end: to, fetchedAt: from)])])
            let store = CalendarEventStore(persistence: cache, timeZone: utc)
            await store.restore(now: from)
            store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: scope,
                originalCutoff: known[1].event.originalStartTime))
            #expect(store.record(key, id: "other-master") == master && store.record(key, id: "middle") == nil)
            #expect(store.record(key, id: "last") == nil && store.covers(key, from: from, to: to))
            #expect(store.events(key, from: from, to: to)?.map(\.id).sorted() == expected)
            await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
            #expect(store.covers(key, from: from, to: to) && store.record(key, id: "other-master") == master)
            await store.flush()
            let saved = try #require(await cache.load().first)
            #expect(saved.records.map(\.event.id).sorted() == expected && !saved.ranges.isEmpty)
            let relaunched = CalendarEventStore(persistence: cache, timeZone: utc)
            await relaunched.restore(now: from)
            #expect(relaunched.events(key, from: from, to: to)?.map(\.id).sorted() == expected)
        }
    }

    @Test func aReadStartedBeforeRemovalCannotResurrectRowsOrPersistThem() async throws {
        let records = originalPositions
        let from = records.map(\.event.start).min()!.addingTimeInterval(-3600)
        let to = records.map(\.event.end).max()!.addingTimeInterval(3600)
        let checkpoint = Checkpoint()
        let provider = ScriptedCalendar([CalendarEventWindow(records: records)], checkpoint: checkpoint)
        let cache = InMemoryCalendarCache()
        let store = CalendarEventStore(persistence: cache, timeZone: utc)
        let key = CalendarEventStore.key(for: provider)
        let reading = Task { await store.fill(key, provider: provider, window: DateInterval(start: from, end: to), now: from) }
        await checkpoint.arrived()
        store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: .allEvents,
                                                              originalCutoff: records[1].event.originalStartTime))
        checkpoint.release()
        await reading.value
        await store.flush()
        #expect(store.record(key, id: "first") == nil && store.record(key, id: "last") == nil)
        #expect(await cache.load().allSatisfy { $0.records.isEmpty })
    }

    @Test func unknownOldIdentityInvalidatesCoverageAndActuallyReadsItAgain() async throws {
        let records = originalPositions
        let from = records[2].event.start.addingTimeInterval(-3600)
        let to = records[2].event.end.addingTimeInterval(3600)
        let unknown = CalendarEventRecord(event: CalendarEvent(id: "old-cache", title: "Weekly", start: from,
            end: to, recurringEventID: "weekly"))
        let provider = ScriptedCalendar([CalendarEventWindow(records: [records[3]])])
        let key = CalendarEventStore.key(for: provider)
        let cache = InMemoryCalendarCache(entries: [CalendarCacheEntry(key: key, records: [unknown, records[2], records[3]],
            ranges: [CalendarCoveredRange(start: from, end: to, fetchedAt: from)], syncToken: "old")])
        let store = CalendarEventStore(persistence: cache, timeZone: utc)
        await store.restore(now: from)
        store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: .thisAndFollowing,
                                                              originalCutoff: records[1].event.originalStartTime))
        #expect(!store.covers(key, from: from, to: to) && store.syncToken(key) == nil)
        await store.fill(key, provider: provider, window: DateInterval(start: from, end: to), now: from)
        #expect(provider.reads == 1 && store.covers(key, from: from, to: to))
        #expect(store.record(key, id: "old-cache") == nil && store.record(key, id: "last") == nil)
        #expect(store.record(key, id: "early-moved") != nil)
    }

    @Test(arguments: ["window", "delta", "expiry"])
    func freshOriginalIdentityAtADifferentEtagRemovesAnUnknownTail(_ path: String) async throws {
        let known = originalPositions
        let from = known[0].event.start.addingTimeInterval(-3600)
        let to = known[2].event.end.addingTimeInterval(3600)
        let span = DateInterval(start: from, end: to)
        let prefix = DateInterval(start: from, end: known[0].event.end.addingTimeInterval(3600))
        for hasUpdatedTime in [false, true] {
            var fresh = occurrence("last", original: "2026-11-08T17:00:00Z", display: "2026-10-28T16:00:00Z")
            fresh.etag = "fresh-v2"
            fresh.updated = hasUpdatedTime ? from.addingTimeInterval(1) : nil
            let unknown = CalendarEventRecord(event: CalendarEvent(id: "last", title: "Weekly", start: fresh.event.start,
                end: fresh.event.end, recurringEventID: "weekly"), etag: "old-v1", recurringEventID: "weekly")
            let provider = RemovalSyncCalendar([known[0]])
            let key = CalendarEventStore.key(for: provider)
            let cache = InMemoryCalendarCache(entries: [CalendarCacheEntry(key: key, records: [known[0], known[1], unknown],
                ranges: [CalendarCoveredRange(start: from, end: to, fetchedAt: from)], syncToken: "before")])
            let store = CalendarEventStore(persistence: cache, timeZone: utc)
            await store.restore(now: from)
            store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: .thisAndFollowing,
                originalCutoff: known[1].event.originalStartTime))
            #expect(store.record(key, id: "middle") == nil && store.record(key, id: "last") == unknown)
            #expect(!store.covers(key, from: from, to: to) && store.syncToken(key) == nil,
                "an original-less row displayed before the cutoff must wait for identity evidence")
            // The unresolved tail clears the prefix token, so revalidation must fall back to a full window.
            await store.fill(key, provider: provider, window: prefix, now: from)
            #expect(store.record(key, id: "last") == unknown && store.covers(key, from: prefix.start, to: prefix.end))
            #expect(store.syncToken(key) == nil)
            provider.records = [known[0], fresh]
            if path == "window" {
                await store.fill(key, provider: provider, window: span, now: from.addingTimeInterval(2))
            } else {
                provider.expire = path == "expiry"
                await store.revalidate(key, provider: provider, visible: prefix, today: from, calendar: calendar,
                    now: from.addingTimeInterval(2), force: true)
            }
            #expect(provider.reads == 2)
            #expect(provider.deltaReads == 0)
            #expect(store.record(key, id: "last") == nil && store.record(key, id: "middle") == nil)
            #expect(store.record(key, id: "first") == known[0], "fresh original identity removes the tail despite its earlier displayed time")
            provider.records = [known[0]]
            provider.expire = false
            await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar,
                now: from.addingTimeInterval(CalendarEventStore.fullReadAfter + 5), force: true)
            #expect(store.covers(key, from: from, to: to))
            // The discarded cache version must also stay fenced after clean reconciliation settles the barrier.
            provider.records = [known[0], unknown]
            let later = from.addingTimeInterval(2 * CalendarEventStore.fullReadAfter + 10)
            await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: later, force: true)
            #expect(store.record(key, id: "last") == nil && store.covers(key, from: from, to: to))
            await store.flush()
            let saved = try #require(await cache.load().first)
            #expect(saved.records.map(\.event.id) == ["first"])
            let relaunched = CalendarEventStore(persistence: cache, timeZone: utc)
            await relaunched.restore(now: later)
            #expect(relaunched.record(key, id: "last") == nil && relaunched.record(key, id: "middle") == nil)
            #expect(relaunched.events(key, from: from, to: to)?.map(\.id) == ["first"])
        }
    }

    @Test(arguments: ["delta", "expiry"])
    func freshOriginalIdentityAtADifferentEtagCannotResurrectAKnownTailThroughDeltaOrExpiry(_ path: String) async throws {
        let known = originalPositions
        let from = known[0].event.start.addingTimeInterval(-3600)
        let to = known[2].event.end.addingTimeInterval(3600)
        let span = DateInterval(start: from, end: to)
        for hasUpdatedTime in [false, true] {
            var old = occurrence("last", original: "2026-11-08T17:00:00Z", display: "2026-10-28T16:00:00Z")
            old.etag = "old-v1"
            var fresh = old
            fresh.etag = "fresh-v2"
            fresh.updated = hasUpdatedTime ? from.addingTimeInterval(1) : nil
            let provider = RemovalSyncCalendar([known[0], known[1], old])
            let key = CalendarEventStore.key(for: provider)
            let cache = InMemoryCalendarCache(entries: [CalendarCacheEntry(key: key, records: [known[0], known[1], old],
                ranges: [CalendarCoveredRange(start: from, end: to, fetchedAt: from)], syncToken: "before")])
            let store = CalendarEventStore(persistence: cache, timeZone: utc)
            await store.restore(now: from)
            store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: .thisAndFollowing,
                originalCutoff: known[1].event.originalStartTime))
            #expect(store.record(key, id: "middle") == nil && store.record(key, id: "last") == nil)
            #expect(store.record(key, id: "first") == known[0] && store.syncToken(key) == nil)
            // A complete stale answer restores a token while its affected rows keep the removal pending.
            await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
            #expect(provider.reads == 1 && provider.deltaReads == 0)
            #expect(store.syncToken(key) == "old-window" && store.covers(key, from: from, to: to))
            #expect(store.record(key, id: "middle") == nil && store.record(key, id: "last") == nil)
            #expect(store.record(key, id: "first") == known[0])
            #expect(store.events(key, from: from, to: to)?.map(\.id) == ["first"])
            provider.records = [known[0], fresh]
            provider.expire = path == "expiry"
            let readAt = from.addingTimeInterval(2)
            await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: readAt, force: true)
            #expect(provider.deltaReads == 1)
            #expect(provider.reads == (path == "expiry" ? 2 : 1))
            #expect(store.syncToken(key) == (path == "expiry" ? "old-window" : "old-delta"))
            #expect(store.record(key, id: "last") == nil && store.record(key, id: "middle") == nil)
            #expect(store.record(key, id: "first") == known[0], "the original tail position remains affected despite its earlier displayed time")
            #expect(store.covers(key, from: from, to: to))
            #expect(store.events(key, from: from, to: to)?.map(\.id) == ["first"])
            await store.flush()
            let saved = try #require(await cache.load().first)
            #expect(saved.records == [known[0]])
            let relaunched = CalendarEventStore(persistence: cache, timeZone: utc)
            await relaunched.restore(now: readAt)
            #expect(relaunched.record(key, id: "last") == nil && relaunched.record(key, id: "middle") == nil)
            #expect(relaunched.record(key, id: "first") == known[0] && relaunched.covers(key, from: from, to: to))
            #expect(relaunched.events(key, from: from, to: to)?.map(\.id) == ["first"])
        }
    }

    @Test func staleFullDeltaAndExpiredTokenAnswersCannotResurrectConfirmedRemovals() async throws {
        let records = originalPositions
        let provider = RemovalSyncCalendar(records)
        let store = CalendarEventStore(persistence: InMemoryCalendarCache(), timeZone: utc)
        let key = CalendarEventStore.key(for: provider)
        let from = records.map(\.event.start).min()!.addingTimeInterval(-3600)
        let to = records.map(\.event.end).max()!.addingTimeInterval(3600)
        let span = DateInterval(start: from, end: to)
        await store.fill(key, provider: provider, window: span, now: from)
        store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: .thisAndFollowing,
                                                              originalCutoff: records[1].event.originalStartTime))
        for expire in [false, false, true] {
            provider.expire = expire
            await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
            #expect(store.record(key, id: "middle") == nil && store.record(key, id: "last") == nil)
            #expect(store.record(key, id: "late-moved") == nil)
            #expect(store.record(key, id: "early-moved") != nil && store.record(key, id: "separate") != nil)
        }
        provider.truncate = true
        await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
        #expect(store.record(key, id: "first") != nil && store.record(key, id: "early-moved") != nil)
        #expect(store.record(key, id: "last") == nil && store.syncToken(key) == nil)
        provider.truncate = false
        // Restore a token so the next failure occurs inside the expiry reread.
        await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
        provider.fail = true
        await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
        #expect(store.record(key, id: "middle") == nil && store.record(key, id: "first") != nil)
        #expect(store.lastError(key) != nil, "expiry refresh failure retains survivors and confirmed removals")
    }

    @Test(arguments: ["window", "delta", "expiry"])
    func confirmedTrimAuthorityRecoversBeforeCleanReconciliationAndNewParentVersionsPersist(_ firstPath: String) async throws {
        let records = originalPositions
        let survivors = records.filter { ["first", "early-moved", "separate"].contains($0.event.id) }
        let from = records.map(\.event.start).min()!.addingTimeInterval(-3600)
        let to = records.map(\.event.end).max()!.addingTimeInterval(3600)
        let span = DateInterval(start: from, end: to)
        let step = CalendarEventStore.fullReadAfter + 1
        let trimTime = ISO8601DateFormatter().date(from: "2026-10-26T12:01:00Z")!
        var unverifiedExtension = records[2]
        unverifiedExtension.etag = "changed-etag-without-server-time"
        var laterExtension = records[2]
        laterExtension.etag = "native-extension-before-reconciliation"
        laterExtension.updated = trimTime.addingTimeInterval(1)
        var ambiguous = occurrence("ambiguous", original: "2026-11-08T17:00:00Z", parent: "other-parent")
        ambiguous.recurringEventID = "weekly"
        let provider = RemovalSyncCalendar(records)
        let cache = InMemoryCalendarCache()
        let store = CalendarEventStore(persistence: cache, timeZone: utc)
        let key = CalendarEventStore.key(for: provider)
        func fullRead(_ number: Int) async {
            await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar,
                now: from.addingTimeInterval(Double(number) * step), force: true)
        }
        await store.fill(key, provider: provider, window: span, now: from)
        store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: .thisAndFollowing,
            originalCutoff: records[1].event.originalStartTime,
            confirmedMasterVersion: CalendarConfirmedMasterVersion(etag: "trimmed-master", updated: trimTime)))
        provider.fail = true
        await fullRead(1)
        #expect(store.lastError(key) != nil && store.record(key, id: "first") == records[0])
        #expect(store.record(key, id: "last") == nil, "the first reconciliation failed")
        provider.fail = false
        await fullRead(2) // A complete stale answer must not settle the barrier.
        #expect(store.record(key, id: "last") == nil && store.record(key, id: "late-moved") == nil)
        provider.records = survivors + [unverifiedExtension]
        await fullRead(3)
        #expect(store.record(key, id: "last") == nil, "a failed answer cannot settle the barrier")
        provider.records = survivors
        provider.truncate = true
        await fullRead(4)
        #expect(store.record(key, id: "first") == records[0] && store.record(key, id: "early-moved") == records[3])
        provider.truncate = false
        provider.records = survivors + [unverifiedExtension]
        await fullRead(5)
        #expect(store.record(key, id: "last") == nil, "a truncated clean answer cannot settle the barrier")
        provider.records = survivors + [ambiguous]
        await fullRead(6)
        #expect(!store.covers(key, from: from, to: to), "conflicting parent evidence invalidates coverage")
        provider.records = survivors + [unverifiedExtension]
        await fullRead(7)
        #expect(store.record(key, id: "last") == nil, "an ambiguous full answer cannot settle the barrier")
        var readAt = from.addingTimeInterval(7 * step)
        func read(_ path: String) async {
            readAt = readAt.addingTimeInterval(path == "window" ? step : 1)
            provider.expire = path == "expiry"
            let windows = provider.reads
            let deltas = provider.deltaReads
            await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: readAt, force: true)
            #expect(provider.reads == windows + (path == "delta" ? 0 : 1))
            #expect(provider.deltaReads == deltas + (path == "window" ? 0 : 1))
        }
        func expectExtension() {
            #expect(store.record(key, id: "last") == laterExtension)
            #expect(store.record(key, id: "middle") == nil && store.record(key, id: "late-moved") == nil)
            #expect(store.record(key, id: "first") == records[0] && store.record(key, id: "early-moved") == records[3])
            #expect(store.events(key, from: from, to: to)?.map(\.id).sorted() == ["early-moved", "first", "last", "separate"])
        }
        provider.records = survivors + [laterExtension]
        // The same authoritative version must recover through each read path without a clean-absent full answer.
        for path in [firstPath, firstPath, "window", "delta", "expiry", "window", "delta", "expiry"] {
            await read(path)
            expectExtension()
        }
        // Exact old versions remain stale after settlement, for both delta and expired-token full reads.
        provider.records = records
        for path in ["window", "delta", "expiry", "window", "delta", "expiry"] {
            await read(path)
            expectExtension()
        }
        #expect(store.events(key, from: records[2].event.start.addingTimeInterval(-60),
            to: records[2].event.end.addingTimeInterval(60))?.contains { $0.id == "last" } == true)
        await store.flush()
        let saved = try #require(await cache.load().first { $0.key == key })
        #expect(saved.records.map(\.event.id).sorted() == ["early-moved", "first", "last", "separate"])
        #expect(saved.records.first { $0.event.id == "last" } == laterExtension)
        let relaunched = CalendarEventStore(persistence: cache, timeZone: utc)
        await relaunched.restore(now: readAt)
        #expect(relaunched.record(key, id: "last") == laterExtension)
        #expect(relaunched.events(key, from: from, to: to)?.map(\.id).sorted() == ["early-moved", "first", "last", "separate"])
    }

    @Test func cleanReconciliationMustReachEveryPreviouslyCachedRangeBeforeSettlement() async throws {
        let first = originalPositions[0]
        let future = occurrence("remote-extension", original: "2027-03-07T17:00:00Z")
        var prematureExtension = future
        prematureExtension.etag = "changed-etag-only"
        let trimTime = ISO8601DateFormatter().date(from: "2026-10-26T12:01:00Z")!
        var laterExtension = future
        laterExtension.etag = "authoritative-before-reconciliation"
        laterExtension.updated = trimTime.addingTimeInterval(1)
        var nearExtension = occurrence("near-extension", original: "2026-11-08T17:00:00Z", display: "2026-10-25T16:45:00Z")
        nearExtension.etag = "native-extension-in-reconciled-range"
        let provider = RemovalSyncCalendar([first], filtersWindows: true)
        let key = CalendarEventStore.key(for: provider)
        let early = DateInterval(start: first.event.start.addingTimeInterval(-3600), end: first.event.end.addingTimeInterval(3600))
        let late = DateInterval(start: future.event.start.addingTimeInterval(-3600), end: future.event.end.addingTimeInterval(3600))
        let ranges = [early, late].map { CalendarCoveredRange(start: $0.start, end: $0.end, fetchedAt: early.start) }
        let cache = InMemoryCalendarCache(entries: [CalendarCacheEntry(key: key, records: [first, future], ranges: ranges)])
        let store = CalendarEventStore(persistence: cache, timeZone: utc)
        await store.restore(now: early.start)
        store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: .thisAndFollowing,
            originalCutoff: originalPositions[1].event.originalStartTime,
            confirmedMasterVersion: CalendarConfirmedMasterVersion(etag: "trimmed-master", updated: trimTime)))
        await store.revalidate(key, provider: provider, visible: early, today: early.start, calendar: calendar, now: early.start, force: true)
        provider.records = [first, nearExtension, prematureExtension]
        await store.revalidate(key, provider: provider, visible: early, today: early.start, calendar: calendar, now: early.start, force: true)
        #expect(store.record(key, id: "near-extension") == nearExtension,
            "a reconciled range permits a legitimate new version while another range is still pending")
        #expect(store.record(key, id: "remote-extension") == nil, "one clean range cannot settle the other range's barrier")
        provider.records = [first, nearExtension, laterExtension]
        for offset in [1.0, 2.0] {
            await store.revalidate(key, provider: provider, visible: early, today: early.start, calendar: calendar,
                now: early.start.addingTimeInterval(offset), force: true)
            #expect(store.record(key, id: "remote-extension") == laterExtension)
            #expect(store.events(key, from: late.start, to: late.end)?.map(\.id) == ["remote-extension"])
        }
        #expect(provider.reads == 1 && provider.deltaReads == 3, "the second month has had no full reconciliation")
        provider.records = [first, nearExtension, future]
        await store.revalidate(key, provider: provider, visible: early, today: early.start, calendar: calendar,
            now: early.start.addingTimeInterval(3), force: true)
        #expect(store.record(key, id: "remote-extension") == laterExtension, "a pending range must retain its qualified new version on a stale delta")
        let step = CalendarEventStore.fullReadAfter + 1
        await store.revalidate(key, provider: provider, visible: late, today: late.start, calendar: calendar,
            now: early.start.addingTimeInterval(step), force: true)
        #expect(store.record(key, id: "remote-extension") == laterExtension && store.record(key, id: "first") == first,
            "the still-pending month must also retain its extension on a stale complete full answer")
        let earlyRangesBeforeExpiry = store.ranges(key).filter { $0.start < early.end && $0.end > early.start }
        let windowsBeforeExpiry = provider.reads
        let deltasBeforeExpiry = provider.deltaReads
        provider.expire = true
        await store.revalidate(key, provider: provider, visible: late, today: late.start, calendar: calendar,
            now: early.start.addingTimeInterval(step + 1), force: true)
        #expect(provider.reads == windowsBeforeExpiry + 1 && provider.deltaReads == deltasBeforeExpiry + 1)
        #expect(store.record(key, id: "remote-extension") == laterExtension,
            "a stale expiry answer cannot fence the accepted version while this month is still pending")
        #expect(store.record(key, id: "first") == first && store.record(key, id: "near-extension") == nearExtension)
        #expect(store.events(key, from: early.start, to: early.end)?.map(\.id).sorted() == ["first", "near-extension"])
        #expect(store.ranges(key).filter { $0.start < early.end && $0.end > early.start } == earlyRangesBeforeExpiry,
            "an expiry answer for the second month must not advance the first month's freshness")
        provider.expire = false
        provider.records = [first, nearExtension, laterExtension]
        for multiple in [2.0, 3.0] {
            await store.revalidate(key, provider: provider, visible: late, today: late.start, calendar: calendar,
                now: early.start.addingTimeInterval(multiple * step), force: true)
        }
        #expect(store.record(key, id: "remote-extension") == laterExtension && store.record(key, id: "first") == first)
        await store.flush()
        let saved = try #require(await cache.load().first)
        #expect(saved.records.map(\.event.id).sorted() == ["first", "near-extension", "remote-extension"])
        #expect(saved.records.first { $0.event.id == "remote-extension" } == laterExtension)
        let relaunched = CalendarEventStore(persistence: cache, timeZone: utc)
        await relaunched.restore(now: early.start.addingTimeInterval(3 * step))
        #expect(relaunched.record(key, id: "remote-extension") == laterExtension && relaunched.record(key, id: "first") == first)
    }

    @Test(arguments: ["window", "delta", "expiry"])
    func pendingRemovalRequiresServerAuthorityAndExactIdentity(_ path: String) async throws {
        let records = originalPositions
        let from = records.map(\.event.start).min()!.addingTimeInterval(-3600)
        let to = records.map(\.event.end).max()!.addingTimeInterval(3600)
        let span = DateInterval(start: from, end: to)
        let trimTime = ISO8601DateFormatter().date(from: "2026-10-26T12:01:00Z")!
        for kind in ["missing-master-version", "empty-master-etag", "invalid-master-time", "wrong-scope", "wrong-authority-parent",
                     "changed-only-etag", "equal-time", "older-time", "invalid-time", "missing-etag", "empty-etag", "known-stale-etag",
                     "wrong-parent", "conflicting-event-parent", "conflicting-record-parent", "missing-parent", "missing-original",
                     "invalid-original", "mixed-original", "before-cutoff-selected", "master-shaped"] {
            let provider = RemovalSyncCalendar(records)
            let cache = InMemoryCalendarCache()
            let store = CalendarEventStore(persistence: cache, timeZone: utc)
            let key = CalendarEventStore.key(for: provider)
            await store.fill(key, provider: provider, window: span, now: from)
            var version: CalendarConfirmedMasterVersion? = CalendarConfirmedMasterVersion(etag: "trimmed-master", updated: trimTime)
            if kind == "missing-master-version" { version = nil }
            if kind == "empty-master-etag" { version = CalendarConfirmedMasterVersion(etag: " ", updated: trimTime) }
            if kind == "invalid-master-time" { version = CalendarConfirmedMasterVersion(etag: "trimmed-master", updated: Date(timeIntervalSince1970: .infinity)) }
            let scope: CalendarRecurrenceScope = kind == "wrong-scope" ? .allEvents : .thisAndFollowing
            store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle",
                parentID: kind == "wrong-authority-parent" ? "other-parent" : "weekly", scope: scope,
                originalCutoff: records[1].event.originalStartTime, confirmedMasterVersion: version))
            // A stale full answer supplies a delta token while leaving the range's barrier pending.
            await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
            var candidate = records[1]
            candidate.etag = "unverified-version"
            candidate.updated = trimTime.addingTimeInterval(1)
            var original = candidate.event.originalStartTime
            switch kind {
            case "changed-only-etag": candidate.updated = nil
            case "equal-time": candidate.updated = trimTime
            case "older-time": candidate.updated = trimTime.addingTimeInterval(-1)
            case "invalid-time": candidate.updated = Date(timeIntervalSince1970: .infinity)
            case "missing-etag": candidate.etag = nil
            case "empty-etag": candidate.etag = " "
            case "known-stale-etag": candidate.etag = "v1"; candidate.updated = trimTime.addingTimeInterval(1000)
            case "wrong-parent": candidate.event.recurringEventID = "other-parent"; candidate.recurringEventID = "other-parent"
            case "conflicting-event-parent": candidate.event.recurringEventID = "other-parent"
            case "conflicting-record-parent": candidate.recurringEventID = "other-parent"
            case "missing-parent": candidate.event.recurringEventID = nil; candidate.recurringEventID = nil
            case "missing-original": original = nil
            case "invalid-original": original = .date("2026-02-30")
            case "mixed-original": original = .date("2026-11-01")
            case "before-cutoff-selected": original = records[0].event.originalStartTime
            case "master-shaped": candidate.event.extras.recurrence = ["RRULE:FREQ=WEEKLY"]
            default: break
            }
            let source = candidate.event
            candidate.event = CalendarEvent(id: source.id, title: source.title, start: source.start, end: source.end,
                timeZone: source.timeZone, organizerIsMe: source.organizerIsMe, recurringEventID: source.recurringEventID,
                originalStartTime: original, extras: source.extras)
            provider.records = [candidate]
            provider.expire = path == "expiry"
            let readAt = from.addingTimeInterval(path == "window" ? CalendarEventStore.fullReadAfter + 1 : 1)
            let windows = provider.reads
            let deltas = provider.deltaReads
            await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: readAt, force: true)
            #expect(provider.reads == windows + (path == "delta" ? 0 : 1) && provider.deltaReads == deltas + (path == "window" ? 0 : 1))
            #expect(store.record(key, id: "middle") == nil, "\(kind) cannot recover the exact selected ID through \(path)")
            #expect(store.events(key, from: from, to: to)?.contains { $0.id == "middle" } != true)
            await store.flush()
            #expect(await cache.load().allSatisfy { $0.records.allSatisfy { $0.event.id != "middle" } })
            if kind == "known-stale-etag" || kind == "invalid-time" {
                var legitimate = records[1]
                legitimate.etag = "legitimate-after-trim"
                legitimate.updated = trimTime.addingTimeInterval(1)
                provider.records = [legitimate]
                await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar,
                    now: readAt.addingTimeInterval(path == "window" ? CalendarEventStore.fullReadAfter + 1 : 1), force: true)
                #expect(store.record(key, id: "middle") == legitimate,
                    "a stale or invalid timestamp must not poison the authoritative version boundary")
            }
        }
    }

    @Test func evidenceForAnotherAccountOrCalendarCannotReleaseAPendingRemoval() async throws {
        let records = originalPositions
        let from = records[0].event.start.addingTimeInterval(-3600)
        let to = records[2].event.end.addingTimeInterval(3600)
        let span = DateInterval(start: from, end: to)
        let trimTime = ISO8601DateFormatter().date(from: "2026-10-26T12:01:00Z")!
        for other in [CalendarCacheKey(account: "other@example.org", calendar: "robin@example.com"),
                      CalendarCacheKey(account: "robin@example.com", calendar: "other@example.org")] {
            let provider = RemovalSyncCalendar(records)
            let key = CalendarEventStore.key(for: provider)
            let store = CalendarEventStore(timeZone: utc)
            await store.fill(key, provider: provider, window: span, now: from)
            store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: .thisAndFollowing,
                originalCutoff: records[1].event.originalStartTime))
            store.applyRemoval(other, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: .thisAndFollowing,
                originalCutoff: records[1].event.originalStartTime,
                confirmedMasterVersion: CalendarConfirmedMasterVersion(etag: "other-calendar-trim", updated: trimTime)))
            var extensionRecord = records[2]
            extensionRecord.etag = "new-version"
            extensionRecord.updated = trimTime.addingTimeInterval(1)
            provider.records = [records[0], extensionRecord]
            await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
            #expect(store.record(key, id: "last") == nil && store.record(key, id: "first") == records[0])
        }
    }

    @Test func aRecoveredVersionMustSatisfyEveryPendingTrimAndMayUseARecordOnlyParent() async throws {
        let records = originalPositions
        let from = records[0].event.start.addingTimeInterval(-3600)
        let to = records[2].event.end.addingTimeInterval(3600)
        let span = DateInterval(start: from, end: to)
        let trimTime = ISO8601DateFormatter().date(from: "2026-10-26T12:01:00Z")!
        let provider = RemovalSyncCalendar(records)
        let cache = InMemoryCalendarCache()
        let store = CalendarEventStore(persistence: cache, timeZone: utc)
        let key = CalendarEventStore.key(for: provider)
        await store.fill(key, provider: provider, window: span, now: from)
        for (selected, cutoff, offset) in [("middle", records[1].event.originalStartTime, 0.0),
                                            ("last", records[2].event.originalStartTime, 2.0)] {
            store.applyRemoval(key, result: CalendarRemovalResult(selectedID: selected, parentID: "weekly", scope: .thisAndFollowing,
                originalCutoff: cutoff, confirmedMasterVersion: CalendarConfirmedMasterVersion(etag: "trim-\(selected)",
                    updated: trimTime.addingTimeInterval(offset))))
        }
        var betweenTrims = records[2]
        betweenTrims.event.recurringEventID = nil
        betweenTrims.etag = "between-trims"
        betweenTrims.updated = trimTime.addingTimeInterval(1)
        provider.records = [records[0], betweenTrims]
        await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
        #expect(store.record(key, id: "last") == nil, "being newer than only one pending master PATCH is insufficient")
        var afterBoth = betweenTrims
        afterBoth.etag = "after-both-trims"
        afterBoth.updated = trimTime.addingTimeInterval(3)
        provider.records = [records[0], afterBoth]
        for offset in [1.0, 2.0] {
            await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar,
                now: from.addingTimeInterval(offset), force: true)
            #expect(store.record(key, id: "last") == afterBoth)
            let presented = try #require(store.events(key, from: from, to: to)?.first { $0.id == "last" })
            #expect(presented.recurringEventID == "weekly" && presented.originalStartTime == afterBoth.event.originalStartTime)
        }
        await store.flush()
        #expect(await cache.load().first?.records.first { $0.event.id == "last" } == afterBoth)
    }

    @Test func settledRemovalStillRetainsItsPrefixOnIncompleteExpiryAndRefreshFailure() async throws {
        let records = originalPositions
        let survivors = records.filter { ["first", "early-moved", "separate"].contains($0.event.id) }
        let provider = RemovalSyncCalendar(records)
        let cache = InMemoryCalendarCache()
        let store = CalendarEventStore(persistence: cache, timeZone: utc)
        let key = CalendarEventStore.key(for: provider)
        let from = records.map(\.event.start).min()!.addingTimeInterval(-3600)
        let to = records.map(\.event.end).max()!.addingTimeInterval(3600)
        let span = DateInterval(start: from, end: to)
        await store.fill(key, provider: provider, window: span, now: from)
        store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: .thisAndFollowing,
            originalCutoff: records[1].event.originalStartTime))
        provider.records = survivors
        await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
        provider.expire = true
        provider.truncate = true
        await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
        #expect(store.record(key, id: "first") != nil && store.record(key, id: "early-moved") != nil)
        #expect(store.record(key, id: "last") == nil && store.syncToken(key) == nil)
        provider.truncate = false
        // A complete full read restores the token, then its expiry reread fails.
        await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
        provider.fail = true
        await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
        #expect(store.lastError(key) != nil && store.covers(key, from: from, to: to))
        #expect(store.record(key, id: "first") != nil && store.record(key, id: "early-moved") != nil)
        await store.flush()
        let saved = try #require(await cache.load().first)
        #expect(saved.records.map(\.event.id).sorted() == ["early-moved", "first", "separate"])
    }

    @Test func removalDuringAnExpiredTokenRereadFencesThatWholeAnswer() async throws {
        let records = originalPositions
        let checkpoint = Checkpoint()
        let provider = RemovalSyncCalendar(records, expiryRead: checkpoint)
        let store = CalendarEventStore(persistence: InMemoryCalendarCache(), timeZone: utc)
        let key = CalendarEventStore.key(for: provider)
        let from = records.map(\.event.start).min()!.addingTimeInterval(-3600)
        let to = records.map(\.event.end).max()!.addingTimeInterval(3600)
        let span = DateInterval(start: from, end: to)
        await store.fill(key, provider: provider, window: span, now: from)
        provider.expire = true
        let reading = Task {
            await store.revalidate(key, provider: provider, visible: span, today: from, calendar: calendar, now: from, force: true)
        }
        await checkpoint.arrived()
        store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: .allEvents,
                                                              originalCutoff: records[1].event.originalStartTime))
        checkpoint.release()
        await reading.value
        #expect(store.record(key, id: "first") == nil && store.record(key, id: "last") == nil)
        #expect(store.record(key, id: "separate") != nil)
    }

    @Test func oldRowsGainIdentityAtTheSameEtagWithoutLosingLocalFieldsAndFreshEvidenceRemovesTheTail() async throws {
        let known = originalPositions
        func old(_ source: CalendarEventRecord) -> CalendarEventRecord {
            CalendarEventRecord(event: CalendarEvent(id: source.event.id, title: "Locally saved title", start: source.event.start,
                end: source.event.end, recurringEventID: source.event.recurringEventID), etag: "v1", recurringEventID: "weekly")
        }
        let before = old(known[0])
        let following = old(known[2])
        let from = before.event.start.addingTimeInterval(-3600)
        let to = following.event.end.addingTimeInterval(3600)
        let provider = ScriptedCalendar([CalendarEventWindow(records: [known[0], known[2]])])
        let key = CalendarEventStore.key(for: provider)
        let cache = InMemoryCalendarCache(entries: [CalendarCacheEntry(key: key, records: [before, following],
            ranges: [CalendarCoveredRange(start: from, end: to, fetchedAt: from)], syncToken: "old")])
        let store = CalendarEventStore(persistence: cache, timeZone: utc)
        await store.restore(now: from)
        store.applyRemoval(key, result: CalendarRemovalResult(selectedID: "middle", parentID: "weekly", scope: .thisAndFollowing,
                                                              originalCutoff: known[1].event.originalStartTime))
        #expect(!store.covers(key, from: from, to: to))
        await store.fill(key, provider: provider, window: DateInterval(start: from, end: to), now: from)
        #expect(store.record(key, id: "last") == nil)
        #expect(store.record(key, id: "first")?.event.originalStartTime == known[0].event.originalStartTime)
        #expect(store.record(key, id: "first")?.event.title == "Locally saved title")
        #expect(store.covers(key, from: from, to: to))
        await store.flush()
        let saved = try #require(await cache.load().first?.records.first)
        #expect(saved.event.id == "first" && saved.event.title == "Locally saved title")
        #expect(saved.event.originalStartTime == known[0].event.originalStartTime)
    }
}
