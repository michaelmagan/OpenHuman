import Foundation
import MailModel
import OpenHumanCore
import SQLite3
import Testing
@testable import OpenHumanMailLive

@Suite struct CalendarCacheExtrasTests {
    static let key = CalendarCacheKey(account: "robin@example.com", calendar: "robin@example.com")
    static let start = Date(timeIntervalSince1970: 1_791_000_000)

    static let extras = CalendarEventExtras(
        guests: [CalendarGuest(email: "sam@example.org", name: "Sam Rivera", isOptional: true, response: .tentative),
                 CalendarGuest(email: "robin@example.com", response: .accepted)],
        permissions: CalendarGuestPermissions(canModify: true, canInviteOthers: false, canSeeGuestList: true),
        recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=TU", "EXDATE:20261117T170000Z"],
        reminders: .custom([CalendarReminder(method: .email, minutesBefore: 1_440), CalendarReminder(minutesBefore: 10)]),
        busy: .free, visibility: .private, colorID: "5")

    static func detailed() -> CalendarEventRecord {
        CalendarEventRecord(event: CalendarEvent(id: "series1_20261110", title: "Weekly sync", start: start,
                                                 end: start.addingTimeInterval(1_800), timeZone: "America/New_York",
                                                 attendees: [EmailAddress(name: "Sam Rivera", email: "sam@example.org")],
                                                 organizerIsMe: false, recurringEventID: "series1",
                                                 originalStartTime: .timed(start, timeZone: "America/New_York"), extras: extras),
                            etag: "v1", recurringEventID: "series1")
    }

    @Test func editingDetailsSurviveARelaunch() async throws {
        let dir = TemporaryDirectory("oh-calendar-extras", isDirectory: true)
        let url = dir.url.appendingPathComponent(SQLiteCalendarCache.fileName)
        let range = CalendarCoveredRange(start: Self.start, end: Self.start.addingTimeInterval(86_400), fetchedAt: Self.start)
        let cache = try SQLiteCalendarCache(url: url)
        await cache.apply(.save(Self.key, upserted: [Self.detailed()], removed: [], ranges: [range], syncToken: "t1"))
        let back = try #require(await SQLiteCalendarCache(url: url).load().first?.records.first)
        var expected = Self.detailed()
        expected.event.extras.guests = expected.event.extras.guests.map { guest in
            var unknown = guest
            unknown.isOrganizer = nil
            return unknown
        }
        #expect(back.event.extras == expected.event.extras,
                "guest roles need a live read; other details survive the cache")
        #expect(back == expected)
    }

    @Test func aFileWrittenWithoutTheDetailsIsReadAgainFromGoogle() async throws {
        let dir = TemporaryDirectory("oh-calendar-extras", isDirectory: true)
        let url = dir.url.appendingPathComponent(SQLiteCalendarCache.fileName)
        let range = CalendarCoveredRange(start: Self.start, end: Self.start.addingTimeInterval(86_400), fetchedAt: Self.start)
        let cache = try SQLiteCalendarCache(url: url)
        await cache.apply(.save(Self.key, upserted: [Self.detailed()], removed: [], ranges: [range], syncToken: "t1"))
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        sqlite3_exec(handle, "PRAGMA user_version = 2", nil, nil, nil)
        sqlite3_close(handle)
        let upgraded = try SQLiteCalendarCache(url: url)
        let afterUpgrade = await upgraded.load()
        #expect(afterUpgrade.isEmpty && SQLiteCalendarCache.schemaVersion == 4)
    }

    @Test func theMeetingsUIDAndOrganizerSurviveARelaunch() async throws {
        let dir = TemporaryDirectory("oh-calendar-extras", isDirectory: true)
        let url = dir.url.appendingPathComponent(SQLiteCalendarCache.fileName)
        var record = Self.detailed()
        record.event.uid = "weekly-1@example.com"
        record.event.organizer = EmailAddress(name: "Dana Ruiz", email: "dana@example.com")
        record.event.guestsOmitted = true
        let plain = CalendarEventRecord(event: CalendarEvent(id: "focus", title: "Focus", start: Self.start,
                                                             end: Self.start.addingTimeInterval(3_600)))
        let cache = try SQLiteCalendarCache(url: url)
        await cache.apply(.save(Self.key, upserted: [record, plain], removed: [], ranges: [], syncToken: nil))
        let back = try #require(await SQLiteCalendarCache(url: url).load().first?.records)
        let meeting = try #require(back.first { $0.event.id == record.event.id }?.event)
        #expect(meeting.uid == "weekly-1@example.com" && meeting.organizer == record.event.organizer)
        #expect(meeting.guestsOmitted)
        let alone = try #require(back.first { $0.event.id == "focus" }?.event)
        #expect(alone.uid == nil && alone.organizer == nil && !alone.guestsOmitted,
                "an event without a UID is kept as it is and is never joined with another")
    }

    @Test func aFileWithoutTheMeetingFieldsIsEmptiedOnceAndThenKept() async throws {
        let dir = TemporaryDirectory("oh-calendar-extras", isDirectory: true)
        let url = dir.url.appendingPathComponent(SQLiteCalendarCache.fileName)
        let range = CalendarCoveredRange(start: Self.start, end: Self.start.addingTimeInterval(86_400), fetchedAt: Self.start)
        let cache = try SQLiteCalendarCache(url: url)
        await cache.apply(.save(Self.key, upserted: [Self.detailed()], removed: [], ranges: [range], syncToken: "t1"))
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        sqlite3_exec(handle, "PRAGMA user_version = 3", nil, nil, nil)
        sqlite3_close(handle)
        let upgraded = try SQLiteCalendarCache(url: url)
        #expect(await upgraded.load().isEmpty, "schema 3 rows have no UID, so Google is read again")
        await upgraded.apply(.save(Self.key, upserted: [Self.detailed()], removed: [], ranges: [range], syncToken: "t2"))
        let reopened = try SQLiteCalendarCache(url: url)
        #expect(await reopened.load().first?.records.count == 1, "a schema 4 file is not emptied again")
    }

    @Test func anAllDayEventKeepsItsDetailsWhenTheZoneChanges() throws {
        let allDay = CalendarEvent(id: "offsite", title: "Offsite", start: Self.start, end: Self.start.addingTimeInterval(86_400),
                                   isAllDay: true, originalStartTime: .date("2026-11-01"), extras: Self.extras)
        let moved = CalendarEventRecord(event: allDay, readIn: TimeZone(identifier: "America/Los_Angeles")!)
            .materialized(in: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(moved.event.start != allDay.start, "the dates are placed in the new zone")
        #expect(moved.event.extras == Self.extras)
        #expect(moved.event.originalStartTime == .date("2026-11-01"))
    }
}
