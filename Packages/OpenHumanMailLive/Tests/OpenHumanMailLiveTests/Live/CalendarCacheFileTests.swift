import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import SQLite3
import Testing
@testable import OpenHumanMailLive

@Suite struct CalendarCacheFileTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("oh-calendar-cache-\(UUID().uuidString)", isDirectory: true)
    }

    static let key = CalendarCacheKey(account: "robin@example.com", calendar: "robin@example.com")
    static let start = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func originalPositionsRoundTripAndOlderPayloadsRemainReadable() async throws {
        let directory = TemporaryDirectory("calendar-original-positions", isDirectory: true)
        let url = directory.url.appendingPathComponent(SQLiteCalendarCache.fileName)
        let cache = try SQLiteCalendarCache(url: url)
        let identities: [CalendarOriginalStart] = [.date("2026-11-01"),
            .timed(ISO8601DateFormatter().date(from: "2026-11-01T17:00:00Z")!, timeZone: "America/Los_Angeles")]
        let records = identities.enumerated().map { index, identity in
            CalendarEventRecord(event: CalendarEvent(id: "identity-\(index)", title: "Moved occurrence", start: Self.start,
                end: Self.start.addingTimeInterval(1800), recurringEventID: "parent", originalStartTime: identity),
                recurringEventID: "parent")
        }
        let range = CalendarCoveredRange(start: Self.start, end: Self.start.addingTimeInterval(86400), fetchedAt: Self.start)
        await cache.apply(.save(Self.key, upserted: records, removed: [], ranges: [range], syncToken: "before"))
        let back = try #require(await SQLiteCalendarCache(url: url).load().first)
        #expect(back.records.sorted { $0.event.id < $1.event.id }.map(\.event.originalStartTime) == identities.map(Optional.some))
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "UPDATE calendar_events SET payload = json_remove(payload, '$.originalStartTime')", nil, nil, nil) == SQLITE_OK)
        let older = try #require(await SQLiteCalendarCache(url: url).load().first)
        #expect(older.records.count == 2 && older.records.allSatisfy { $0.event.originalStartTime == nil })
        #expect(older.records.allSatisfy { $0.event.recurringEventID == "parent" })
        #expect(SQLiteCalendarCache.schemaVersion == 3, "optional identity adds no schema migration")
        await cache.apply(.save(Self.key, upserted: [], removed: ["identity-0", "identity-1"], ranges: [range], syncToken: nil))
        #expect(try await SQLiteCalendarCache(url: url).load().first?.records.isEmpty == true)
    }

    static func record(_ id: String, offset: TimeInterval = 0, etag: String? = "v1") -> CalendarEventRecord {
        CalendarEventRecord(event: CalendarEvent(id: id, title: "Event \(id)", start: start.addingTimeInterval(offset),
                                                 end: start.addingTimeInterval(offset + 1_800), timeZone: "America/New_York",
                                                 attendees: [EmailAddress(name: "Alex", email: "alex@example.com")],
                                                 meetLink: URL(string: "https://meet.google.com/abc-defg"),
                                                 organizerIsMe: true),
                            etag: etag, updated: start.addingTimeInterval(-60), recurringEventID: "series")
    }

    @Test func anOlderPayloadWithOnlyARecordParentMaterializesAsARecurringEvent() async throws {
        let directory = TemporaryDirectory("calendar-record-parent", isDirectory: true)
        let url = directory.url.appendingPathComponent(SQLiteCalendarCache.fileName)
        let cache = try SQLiteCalendarCache(url: url)
        var record = Self.record("old-instance")
        record.event.myResponse = .tentative
        record.event.extras = CalendarEventExtras(guests: [CalendarGuest(email: "alex@example.com", response: .tentative)], colorID: "5")
        let range = CalendarCoveredRange(start: Self.start, end: Self.start.addingTimeInterval(86400), fetchedAt: Self.start)
        await cache.apply(.save(Self.key, upserted: [record], removed: [], ranges: [range], syncToken: "old"))
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "UPDATE calendar_events SET payload = json_remove(payload, '$.eventSeries', '$.originalStartTime')",
                            nil, nil, nil) == SQLITE_OK)
        let loaded = try #require(await SQLiteCalendarCache(url: url).load().first?.records.first)
        #expect(loaded.event.recurringEventID == nil && loaded.recurringEventID == "series")
        let presented = loaded.materialized(in: TimeZone(identifier: "America/Los_Angeles")!).event
        #expect(presented.recurringEventID == "series" && presented.isRecurringForRemoval && presented.isRecurring)
        #expect(presented.originalStartTime == nil, "missing occurrence identity is never guessed")
        var expectedExtras = record.event.extras
        expectedExtras.guests = expectedExtras.guests.map { guest in
            var unknown = guest
            unknown.isOrganizer = nil
            return unknown
        }
        #expect(presented.myResponse == .tentative && presented.extras == expectedExtras,
                "guest roles need a live read; other details survive the cache")
        #expect(presented.attendees == record.event.attendees && presented.meetLink == record.event.meetLink)
    }

    @Test func eventsSpansAndTheTokenRoundTripAndSurviveARelaunch() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SQLiteCalendarCache.fileName)
        #expect(SQLiteCalendarCache.fileName == "calendar-cache.sqlite")
        let cache = try SQLiteCalendarCache(url: url)
        let allDay = CalendarEventRecord(event: CalendarEvent(id: "offsite", title: "Offsite", start: Self.start,
                                                              end: Self.start.addingTimeInterval(86_400), isAllDay: true),
                                         readIn: TimeZone(identifier: "UTC")!)
        var quiet = Self.record("quiet")
        quiet.isBusy = false
        quiet.declinedByMe = true
        let range = CalendarCoveredRange(start: Self.start.addingTimeInterval(-86_400 * 14),
                                         end: Self.start.addingTimeInterval(86_400 * 45), fetchedAt: Self.start)
        await cache.apply(.save(Self.key, upserted: [Self.record("a"), allDay, quiet], removed: [], ranges: [range],
                                syncToken: "synthetic-sync-1"))
        await cache.apply(.save(Self.key, upserted: [Self.record("a", offset: 3_600, etag: "v2")], removed: ["quiet"],
                                ranges: [range], syncToken: "synthetic-sync-2"))
        #expect(await cache.eventCount == 2)
        let reopened = try SQLiteCalendarCache(url: url)
        let entry = try #require(await reopened.load().first)
        #expect(entry.key == Self.key && entry.syncToken == "synthetic-sync-2" && entry.ranges == [range])
        let a = try #require(entry.records.first { $0.event.id == "a" })
        #expect(a == Self.record("a", offset: 3_600, etag: "v2"), "every field back, the newer version")
        let offsite = try #require(entry.records.first { $0.event.id == "offsite" })
        #expect(offsite.event.isAllDay && offsite.allDayDates == allDay.allDayDates && offsite.event.start == Self.start)
        #expect(!entry.records.contains { $0.event.id == "quiet" })
    }

    @Test func theCalendarWindowsFieldsRoundTripAndAnOldFileIsReadAgainFromGoogle() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SQLiteCalendarCache.fileName)
        let range = CalendarCoveredRange(start: Self.start, end: Self.start.addingTimeInterval(86_400), fetchedAt: Self.start)
        let detailed = CalendarEventRecord(
            event: CalendarEvent(id: "full", title: "Review", start: Self.start, end: Self.start.addingTimeInterval(1_800),
                                 location: "Room 4", notes: "Bring the draft", myResponse: .tentative, recurringEventID: "weekly"),
            etag: "v1", recurringEventID: "weekly")
        var declined = Self.record("no")
        declined.declinedByMe = true
        declined.event.myResponse = .declined
        let cache = try SQLiteCalendarCache(url: url)
        await cache.apply(.save(Self.key, upserted: [detailed, declined], removed: [], ranges: [range], syncToken: "t1"))
        let back = try #require(await SQLiteCalendarCache(url: url).load().first)
        #expect(back.records.first { $0.event.id == "full" } == detailed, "place, notes, answer and series come back")
        let kept = try #require(back.records.first { $0.event.id == "no" })
        #expect(kept == declined && kept.declinedByMe && kept.event.myResponse == .declined, "declined events are kept")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        sqlite3_exec(handle, "PRAGMA user_version = 1", nil, nil, nil)
        sqlite3_close(handle)
        let upgraded = try SQLiteCalendarCache(url: url)
        let afterUpgrade = await upgraded.load()
        let rowsAfterUpgrade = await upgraded.eventCount
        #expect(afterUpgrade.isEmpty && rowsAfterUpgrade == 0)
        await upgraded.apply(.save(Self.key, upserted: [detailed], removed: [], ranges: [range], syncToken: "t2"))
        #expect(try #require(await SQLiteCalendarCache(url: url).load().first).records == [detailed], "version 2 is kept")
    }

    @Test func calendarsAndAccountsAreForgotten() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try SQLiteCalendarCache(url: dir.appendingPathComponent(SQLiteCalendarCache.fileName))
        let other = CalendarCacheKey(account: "sam@example.com", calendar: "sam@example.com")
        let range = CalendarCoveredRange(start: Self.start, end: Self.start.addingTimeInterval(86_400), fetchedAt: Self.start)
        await cache.apply(.save(Self.key, upserted: [Self.record("a")], removed: [], ranges: [range], syncToken: "t1"))
        await cache.apply(.save(other, upserted: [Self.record("b")], removed: [], ranges: [range], syncToken: "t2"))
        await cache.apply(.forgetAccount("Robin@Example.com"))
        #expect(await cache.load().map(\.key) == [other], "a disconnected account's calendar is gone")
        await cache.apply(.replace(CalendarCacheEntry(key: other, records: [Self.record("c")], ranges: [range], syncToken: nil)))
        let replaced = try #require(await cache.load().first)
        #expect(replaced.records.map(\.event.id) == ["c"] && replaced.syncToken == nil)
        await cache.apply(.forgetCalendar(other))
        #expect(await cache.load().isEmpty)
        #expect(await cache.eventCount == 0)
        await cache.apply(.save(Self.key, upserted: [Self.record("a")], removed: [], ranges: [range], syncToken: "t1"))
        await cache.apply(.forgetAll)
        #expect(await cache.load().isEmpty)
    }

    @Test func theFileIsPrivateOutOfBackupsAndADamagedOneIsSetAside() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SQLiteCalendarCache.fileName)
        _ = try SQLiteCalendarCache(url: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try Data("not a database".utf8).write(to: url)
        let fresh = try SQLiteCalendarCache(url: url)
        #expect(await fresh.load().isEmpty)
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("damaged") }
        #expect(aside.count == 1)
    }
}

@Suite struct GoogleCalendarCacheReadsTests {
    static let path = "/calendar/v3/calendars/robin@example.com/events"

    static func provider(_ http: FakeHTTPTransport) -> GoogleCalendarProvider {
        let client = GoogleCalendarClient(calendarID: "robin@example.com",
                                          grantedScopes: CalendarScopes.request.read,
                                          tokens: StaticTokenProvider(token: "synthetic-cal-access"), transport: http,
                                          clock: InstantClock(), timeZone: TimeZone(identifier: "America/New_York")!)
        return GoogleCalendarProvider(client: client, account: "robin@example.com",
                                      createRefusal: GoogleCalendarSession.reconnectToCreate)
    }

    @Test func aWindowReadKeepsVersionsSeriesTransparencyAndTheOwnersAnswer() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", Self.path) { _ in
            FakeHTTPTransport.json(200, [
                "items": [
                    ["id": "inst_1", "summary": "Standup", "etag": "\"e1\"", "recurringEventId": "inst",
                     "transparency": "transparent", "start": ["dateTime": "2026-10-14T14:00:00Z"],
                     "end": ["dateTime": "2026-10-14T14:15:00Z"]],
                    ["id": "no", "summary": "Declined", "start": ["dateTime": "2026-10-14T16:00:00Z"],
                     "end": ["dateTime": "2026-10-14T17:00:00Z"],
                     "attendees": [["email": "robin@example.com", "self": true, "responseStatus": "declined"]]],
                ],
                "nextSyncToken": "synthetic-sync-1",
            ])
        }
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        let window = try await Self.provider(http).eventWindow(from: start, to: start.addingTimeInterval(86_400 * 59))
        #expect(window.syncToken == "synthetic-sync-1")
        let standup = try #require(window.records.first)
        #expect(standup.etag == "\"e1\"" && standup.recurringEventID == "inst" && !standup.isBusy && !standup.declinedByMe)
        #expect(window.records.last?.declinedByMe == true && window.records.last?.isBusy == true)
        #expect(http.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func aWindowReadCarriesThePlaceNotesAndTheOwnersAnswerForTheCalendarWindow() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", Self.path) { _ in
            FakeHTTPTransport.json(200, [
                "items": [
                    ["id": "inst_1", "summary": "Review", "etag": "\"e1\"", "recurringEventId": "inst",
                     "location": "Room 4", "description": "Bring the draft",
                     "start": ["dateTime": "2026-10-14T14:00:00Z"], "end": ["dateTime": "2026-10-14T15:00:00Z"],
                     "attendees": [["email": "robin@example.com", "self": true, "responseStatus": "tentative"]]],
                    ["id": "no", "summary": "Declined", "start": ["dateTime": "2026-10-14T16:00:00Z"],
                     "end": ["dateTime": "2026-10-14T17:00:00Z"],
                     "attendees": [["email": "robin@example.com", "self": true, "responseStatus": "declined"]]],
                ],
                "nextSyncToken": "synthetic-sync-1",
            ])
        }
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        let window = try await Self.provider(http).eventWindow(from: start, to: start.addingTimeInterval(86_400 * 59))
        let review = try #require(window.records.first)
        #expect(review.event.location == "Room 4" && review.event.notes == "Bring the draft")
        #expect(review.event.myResponse == .tentative && review.event.recurringEventID == "inst")
        #expect(review.recurringEventID == "inst" && !review.declinedByMe)
        let declined = try #require(window.records.last)
        #expect(declined.declinedByMe && declined.event.myResponse == .declined, "kept, flagged and drawn declined")
    }

    @Test func aChangeReadMaps410ToAnExpiredTokenAnd400ToUnsupported() async throws {
        let gone = FakeHTTPTransport()
        gone.on("GET", Self.path) { _ in FakeHTTPTransport.json(410, ["error": ["code": 410]]) }
        await #expect(throws: CalendarSyncError.tokenExpired) {
            _ = try await Self.provider(gone).eventDelta(since: "synthetic-old")
        }
        let refused = FakeHTTPTransport()
        refused.on("GET", Self.path) { _ in
            FakeHTTPTransport.json(400, ["error": ["code": 400, "errors": [["reason": "invalid"]]]])
        }
        await #expect(throws: CalendarSyncError.unsupported) {
            _ = try await Self.provider(refused).eventDelta(since: "synthetic-sync-1")
        }
        let changed = FakeHTTPTransport()
        changed.on("GET", Self.path) { _ in
            FakeHTTPTransport.json(200, ["items": [["id": "gone", "status": "cancelled"],
                                                   ["id": "new", "summary": "New", "etag": "\"e5\"",
                                                    "start": ["dateTime": "2026-10-14T18:00:00Z"],
                                                    "end": ["dateTime": "2026-10-14T19:00:00Z"]]],
                                         "nextSyncToken": "synthetic-sync-2"])
        }
        let delta = try await Self.provider(changed).eventDelta(since: "synthetic-sync-1")
        #expect(delta.removed == ["gone"] && delta.changed.map(\.event.id) == ["new"] && delta.syncToken == "synthetic-sync-2")
    }
}
