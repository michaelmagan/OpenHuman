import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing

private func removalInstant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

private func occurrence(_ id: String, _ original: String, display: String? = nil,
                        parent: String = "weekly", account: String = "robin@example.com") -> CalendarEvent {
    let start = removalInstant(display ?? original)
    return CalendarEvent(id: id, title: "Weekly", start: start, end: start.addingTimeInterval(1800),
        timeZone: "America/Los_Angeles", organizerIsMe: true, account: account, recurringEventID: parent,
        originalStartTime: .timed(removalInstant(original), timeZone: "America/Los_Angeles"))
}

@Suite struct FakeCalendarRecurringRemovalTests {
    private var oracle: [CalendarEvent] {
        [occurrence("first", "2026-10-25T16:00:00Z"),
         occurrence("middle", "2026-11-01T17:00:00Z"),
         occurrence("last", "2026-11-08T17:00:00Z"),
         occurrence("earlier-moved-later", "2026-10-18T16:00:00Z", display: "2026-11-15T17:00:00Z"),
         occurrence("later-moved-earlier", "2026-11-15T17:00:00Z", display: "2026-10-20T16:00:00Z"),
         occurrence("other-parent", "2026-11-01T17:00:00Z", parent: "different"),
         occurrence("middle", "2026-11-01T17:00:00Z", account: "other@example.org")]
    }

    @Test func eachScopeHasConcreteSurvivorsAndTheSameSyncRemovals() async throws {
        let cases: [(CalendarRecurrenceScope, [String], [String])] = [
            (.thisEvent, ["earlier-moved-later", "first", "last", "later-moved-earlier", "other-parent"], ["middle"]),
            (.allEvents, ["other-parent"], ["earlier-moved-later", "first", "last", "later-moved-earlier", "middle"]),
            (.thisAndFollowing, ["earlier-moved-later", "first", "other-parent"], ["last", "later-moved-earlier", "middle"])]
        for (scope, survivors, removed) in cases {
            // One provider models one account; a separate account with colliding IDs stays independently intact.
            let source = oracle.filter { $0.account == "robin@example.com" }
            let calendar = FakeCalendar(events: source)
            let other = FakeCalendar(events: oracle.filter { $0.account == "other@example.org" })
            let before = try await calendar.eventWindow(from: removalInstant("2026-10-01T00:00:00Z"),
                                                         to: removalInstant("2026-12-01T00:00:00Z"))
            let selected = try #require(source.first { $0.id == "middle" })
            let result = try await calendar.removeEvent(selected, scope: scope, sendUpdates: .all)
            #expect(calendar.allEvents.map(\.id).sorted() == survivors)
            #expect(other.allEvents.map(\.id) == ["middle"])
            let delta = try await calendar.eventDelta(since: #require(before.syncToken))
            #expect(delta.removed.sorted() == removed && delta.changed.isEmpty)
            #expect(delta.cancellations.map(\.id).sorted() == removed)
            #expect(delta.cancellations.first { $0.id == "middle" }?.originalStartTime == selected.originalStartTime)
            #expect(result.parentID == "weekly" && result.originalCutoff == selected.originalStartTime)
            #expect(calendar.calls.contains(.scopedRemove(id: "middle", scope: scope, sendUpdates: .all)))
        }
    }

    @Test func firstMiddleAndLastCutoffsDoNotDependOnDisplayedTimeOrCacheOrder() async throws {
        for (selection, survivors) in [("first", [String]()), ("middle", ["first"]), ("last", ["first", "middle"])] {
            let events = Array(oracle.prefix(3).reversed())
            let calendar = FakeCalendar(events: events)
            _ = try await calendar.removeEvent(#require(events.first { $0.id == selection }), scope: .thisAndFollowing,
                                                sendUpdates: .all)
            #expect(calendar.allEvents.map(\.id).sorted() == survivors)
        }
    }

    @Test func allDayPositionsAcrossDSTKeepEarlierDatesAndMissingPositionsRefuseWithoutChanges() async throws {
        let start = removalInstant("2026-10-31T07:00:00Z")
        let events = ["2026-10-31", "2026-11-01", "2026-11-02"].enumerated().map { index, date in
            CalendarEvent(id: "day-\(index)", title: "Offsite", start: start, end: start.addingTimeInterval(3600),
                isAllDay: true, organizerIsMe: true, recurringEventID: "days", originalStartTime: .date(date))
        }
        let calendar = FakeCalendar(events: events)
        _ = try await calendar.removeEvent(events[1], scope: .thisAndFollowing, sendUpdates: .all)
        #expect(calendar.allEvents.map(\.id) == ["day-0"])
        let unknown = CalendarEvent(id: "old-cache", title: "Weekly", start: start, end: start.addingTimeInterval(1800),
                                    organizerIsMe: true, recurringEventID: "days")
        let incomplete = FakeCalendar(events: events + [unknown])
        await #expect(throws: CalendarError.self) {
            _ = try await incomplete.removeEvent(events[1], scope: .thisAndFollowing, sendUpdates: .all)
        }
        #expect(incomplete.allEvents == events + [unknown])
    }
}

@Suite struct FakeCalendarInvitationRemovalTests {
    private func invitation(_ id: String, parent: String? = "weekly", original: String = "2026-11-01T17:00:00Z") -> CalendarEvent {
        let start = removalInstant(original)
        return CalendarEvent(id: id, title: "Supplier sync", start: start, end: start.addingTimeInterval(1800),
            timeZone: "America/Los_Angeles", attendees: [EmailAddress(email: "sam@example.org")], organizerIsMe: false,
            myResponse: .needsAction, recurringEventID: parent,
            originalStartTime: parent == nil ? nil : .timed(start, timeZone: "America/Los_Angeles"))
    }

    @Test func aGuestCopyLeavesOnlyWithTheAbilitySilentlyAndNeverForTheFuture() async throws {
        let series = [invitation("first", original: "2026-10-25T16:00:00Z"), invitation("middle"),
                      invitation("last", original: "2026-11-08T17:00:00Z")]
        let plain = FakeCalendar(events: series)
        await #expect(throws: CalendarError.self, "a calendar without the ability refuses") {
            _ = try await plain.removeEvent(series[1], scope: .thisEvent, sendUpdates: .none)
        }
        let calendar = FakeCalendar(events: series, abilities: [.respond, .remove, .removeInvite])
        await #expect(throws: CalendarError.self, "a guest's removal never notifies") {
            _ = try await calendar.removeEvent(series[1], scope: .thisEvent, sendUpdates: .all)
        }
        await #expect(throws: CalendarError.self, "only the organizer can end a series early") {
            _ = try await calendar.removeEvent(series[1], scope: .thisAndFollowing, sendUpdates: .none)
        }
        #expect(calendar.allEvents.count == 3 && plain.allEvents.count == 3)
        let one = try await calendar.removeEvent(series[1], scope: .thisEvent, sendUpdates: .none)
        #expect(one.selectedID == "middle" && one.parentID == "weekly")
        #expect(calendar.allEvents.map(\.id) == ["first", "last"])
        _ = try await calendar.removeEvent(series[0], scope: .allEvents, sendUpdates: .none)
        #expect(calendar.allEvents.isEmpty)
    }

    @Test func anOwnEventCannotBeRemovedThroughTheGuestRule() async {
        let own = CalendarEvent(id: "own", title: "Planning", start: removalInstant("2026-11-01T17:00:00Z"),
                                end: removalInstant("2026-11-01T18:00:00Z"), organizerIsMe: true)
        let calendar = FakeCalendar(events: [own], abilities: [.respond, .removeInvite])
        await #expect(throws: CalendarError.self) {
            _ = try await calendar.removeEvent(own, scope: .thisEvent, sendUpdates: .none)
        }
        #expect(calendar.allEvents.map(\.id) == ["own"])
    }
}
