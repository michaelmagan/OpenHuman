import Foundation
import MailModel
import OpenHumanCore
import SQLite3

actor SQLiteCalendarCache: CalendarCachePersisting {
    enum StoreError: Error { case open(Int32) }

    static let fileName = "calendar-cache.sqlite"
    // Why: an older file is emptied once and re-read from Google, since it lacks the new row fields (4: the meeting's
    // UID and organizer, which join the copies of one meeting on several accounts; the re-read also replaces who
    // organizes each copy as decoded before Google's omitted `organizer.self` was read as false)
    static let schemaVersion: Int32 = 4

    private var db: OpaquePointer?

    init(url: URL) throws {
        db = try SQLiteFileRecovery.open(url, status: Self.openStatus, Self.open)
    }

    isolated deinit {
        sqlite3_close_v2(db)
    }

    private static func openStatus(_ error: any Error) -> Int32? {
        guard case .open(let status)? = error as? StoreError else { return nil }
        return status
    }

    private static func open(_ url: URL) throws -> OpaquePointer? {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            _ = manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var file = url
        try? file.setResourceValues(excluded)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            throw StoreError.open(status)
        }
        sqlite3_busy_timeout(handle, 2_000)
        let upgrade = (1..<schemaVersion).contains(userVersion(handle))
            ? "DELETE FROM calendar_events; DELETE FROM calendar_ranges; DELETE FROM calendar_state;" : ""
        let setup = """
            CREATE TABLE IF NOT EXISTS calendar_events (
                account TEXT NOT NULL,
                calendar TEXT NOT NULL,
                event_id TEXT NOT NULL,
                etag TEXT,
                updated REAL,
                start_utc REAL NOT NULL,
                end_utc REAL NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY (account, calendar, event_id)
            );
            CREATE TABLE IF NOT EXISTS calendar_ranges (
                account TEXT NOT NULL,
                calendar TEXT NOT NULL,
                start_utc REAL NOT NULL,
                end_utc REAL NOT NULL,
                fetched_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS calendar_state (
                account TEXT NOT NULL,
                calendar TEXT NOT NULL,
                sync_token TEXT,
                PRIMARY KEY (account, calendar)
            );
            \(upgrade)
            PRAGMA user_version = \(schemaVersion);
            PRAGMA secure_delete = ON;
            """
        let check = SQLiteFileRecovery.quickCheck(handle)
        guard check == SQLITE_OK,
              sqlite3_exec(handle, setup, nil, nil, nil) == SQLITE_OK else {
            let code = check == SQLITE_OK ? sqlite3_errcode(handle) : check
            sqlite3_close_v2(handle)
            throw StoreError.open(code)
        }
        return handle
    }

    private static func userVersion(_ handle: OpaquePointer?) -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }

    func load() async -> [CalendarCacheEntry] {
        let events = rows("SELECT account, calendar, event_id, etag, updated, start_utc, end_utc, payload FROM calendar_events",
                          []) { row -> (CalendarCacheKey, CalendarEventRecord)? in
            guard let account = row.text(0), let calendar = row.text(1), let id = row.text(2), let payload = row.text(7),
                  let stored = try? JSONDecoder().decode(StoredEvent.self, from: Data(payload.utf8)) else { return nil }
            return (CalendarCacheKey(account: account, calendar: calendar),
                    stored.record(id: id, etag: row.text(3), updated: row.real(4).map(Date.init(timeIntervalSince1970:)),
                                  start: Date(timeIntervalSince1970: row.real(5) ?? 0),
                                  end: Date(timeIntervalSince1970: row.real(6) ?? 0)))
        }
        let ranges = rows("SELECT account, calendar, start_utc, end_utc, fetched_at FROM calendar_ranges ORDER BY start_utc",
                          []) { row -> (CalendarCacheKey, CalendarCoveredRange)? in
            guard let account = row.text(0), let calendar = row.text(1), let start = row.real(2), let end = row.real(3),
                  let fetched = row.real(4) else { return nil }
            return (CalendarCacheKey(account: account, calendar: calendar),
                    CalendarCoveredRange(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end),
                                         fetchedAt: Date(timeIntervalSince1970: fetched)))
        }
        let tokens = rows("SELECT account, calendar, sync_token FROM calendar_state", []) { row -> (CalendarCacheKey, String?)? in
            guard let account = row.text(0), let calendar = row.text(1) else { return nil }
            return (CalendarCacheKey(account: account, calendar: calendar), row.text(2))
        }
        var entries: [CalendarCacheKey: CalendarCacheEntry] = [:]
        for (key, record) in events { entries[key, default: CalendarCacheEntry(key: key)].records.append(record) }
        for (key, range) in ranges { entries[key, default: CalendarCacheEntry(key: key)].ranges.append(range) }
        for (key, token) in tokens { entries[key, default: CalendarCacheEntry(key: key)].syncToken = token }
        let out = entries.values.sorted { $0.key < $1.key }
        Log(.app).notice("calendar cache file read: \(out.count) calendar(s), \(events.count) event(s)")
        return out
    }

    func apply(_ write: CalendarCacheWrite) async {
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        switch write {
        case .save(let key, let upserted, let removed, let ranges, let token):
            for id in removed {
                run("DELETE FROM calendar_events WHERE account = ? AND calendar = ? AND event_id = ?",
                    [.text(key.account), .text(key.calendar), .text(id)])
            }
            for record in upserted { put(record, key) }
            putRanges(ranges, token: token, key)
        case .replace(let entry):
            forget(entry.key)
            for record in entry.records { put(record, entry.key) }
            putRanges(entry.ranges, token: entry.syncToken, entry.key)
        case .forgetCalendar(let key):
            forget(key)
        case .forgetAccount(let account):
            for table in ["calendar_events", "calendar_ranges", "calendar_state"] {
                run("DELETE FROM \(table) WHERE account = ?", [.text(account.lowercased())])
            }
        case .forgetAll:
            for table in ["calendar_events", "calendar_ranges", "calendar_state"] { run("DELETE FROM \(table)", []) }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    var eventCount: Int {
        rows("SELECT COUNT(*) FROM calendar_events", []) { $0.real(0) }.first.map { Int($0) } ?? 0
    }

    private func put(_ record: CalendarEventRecord, _ key: CalendarCacheKey) {
        guard !record.event.id.isEmpty, let payload = try? JSONEncoder().encode(StoredEvent(record)),
              let text = String(data: payload, encoding: .utf8) else { return }
        run("""
            INSERT OR REPLACE INTO calendar_events
                (account, calendar, event_id, etag, updated, start_utc, end_utc, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(key.account), .text(key.calendar), .text(record.event.id), record.etag.map(Value.text) ?? .null,
                  record.updated.map { .real($0.timeIntervalSince1970) } ?? .null,
                  .real(record.event.start.timeIntervalSince1970), .real(record.event.end.timeIntervalSince1970),
                  .text(text)])
    }

    private func putRanges(_ ranges: [CalendarCoveredRange], token: String?, _ key: CalendarCacheKey) {
        run("DELETE FROM calendar_ranges WHERE account = ? AND calendar = ?", [.text(key.account), .text(key.calendar)])
        for range in ranges {
            run("INSERT INTO calendar_ranges (account, calendar, start_utc, end_utc, fetched_at) VALUES (?, ?, ?, ?, ?)",
                [.text(key.account), .text(key.calendar), .real(range.start.timeIntervalSince1970),
                 .real(range.end.timeIntervalSince1970), .real(range.fetchedAt.timeIntervalSince1970)])
        }
        run("INSERT OR REPLACE INTO calendar_state (account, calendar, sync_token) VALUES (?, ?, ?)",
            [.text(key.account), .text(key.calendar), token.map(Value.text) ?? .null])
    }

    private func forget(_ key: CalendarCacheKey) {
        for table in ["calendar_events", "calendar_ranges", "calendar_state"] {
            run("DELETE FROM \(table) WHERE account = ? AND calendar = ?", [.text(key.account), .text(key.calendar)])
        }
    }

    private enum Value { case real(Double), text(String), null }

    private struct Row {
        let statement: OpaquePointer
        func text(_ column: Int32) -> String? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil
                : sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        func real(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }
    }

    private func rows<T>(_ sql: String, _ arguments: [Value], _ read: (Row) -> T?) -> [T] {
        guard let statement = prepare(sql, arguments) else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = read(Row(statement: statement)) { out.append(value) }
        }
        return out
    }

    private func run(_ sql: String, _ arguments: [Value]) {
        guard let statement = prepare(sql, arguments) else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_step(statement)
    }

    private func prepare(_ sql: String, _ arguments: [Value]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        for (offset, value) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, calendarCacheTransient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
}

private struct StoredEvent: Codable {
    var title: String
    var isAllDay: Bool
    var timeZone: String?
    var attendees: [EmailAddress]
    var calendarName: String?
    var meetLink: String?
    var organizerIsMe: Bool?
    var recurringEventID: String?
    var originalStartTime: CalendarOriginalStart?
    var location: String?
    var notes: String?
    var myResponse: String?
    var eventSeries: String?
    var isBusy: Bool
    var declinedByMe: Bool
    var allDayDates: CalendarAllDayDates?
    var extras: StoredExtras?
    var uid: String?
    var organizer: EmailAddress?
    var guestsOmitted: Bool?

    init(_ record: CalendarEventRecord) {
        let event = record.event
        title = event.title
        isAllDay = event.isAllDay
        timeZone = event.timeZone
        attendees = event.attendees
        calendarName = event.calendarName
        meetLink = event.meetLink?.absoluteString
        organizerIsMe = event.organizerIsMe
        recurringEventID = record.recurringEventID
        originalStartTime = event.originalStartTime
        location = event.location
        notes = event.notes
        myResponse = event.myResponse?.rawValue
        eventSeries = event.recurringEventID
        isBusy = record.isBusy
        declinedByMe = record.declinedByMe
        allDayDates = record.allDayDates
        extras = StoredExtras(event.extras)
        uid = event.uid
        organizer = event.organizer
        guestsOmitted = event.guestsOmitted ? true : nil
    }

    func record(id: String, etag: String?, updated: Date?, start: Date, end: Date) -> CalendarEventRecord {
        let event = CalendarEvent(id: id, title: title, start: start, end: end, isAllDay: isAllDay, timeZone: timeZone,
                                  attendees: attendees, calendarName: calendarName, meetLink: meetLink.flatMap(URL.init(string:)),
                                  organizerIsMe: organizerIsMe, location: location, notes: notes,
                                  myResponse: myResponse.flatMap(CalendarResponse.init(rawValue:)),
                                  recurringEventID: eventSeries, originalStartTime: originalStartTime,
                                  extras: extras?.value ?? CalendarEventExtras(), uid: uid, organizer: organizer,
                                  guestsOmitted: guestsOmitted == true)
        var record = CalendarEventRecord(event: event, etag: etag, updated: updated, recurringEventID: recurringEventID,
                                         isBusy: isBusy, declinedByMe: declinedByMe)
        record.allDayDates = allDayDates ?? record.allDayDates
        return record
    }
}

private struct StoredExtras: Codable {
    struct Guest: Codable {
        var email: String
        var name: String?
        var isOptional: Bool
        var response: String?
    }

    struct Permissions: Codable {
        var canModify: Bool
        var canInviteOthers: Bool
        var canSeeGuestList: Bool
    }

    struct Reminder: Codable {
        var method: String
        var minutes: Int
    }

    var guests: [Guest]
    var permissions: Permissions?
    var recurrence: [String]
    var reminders: [Reminder]?
    var free: Bool
    var visibility: String
    var colorID: String?

    init(_ extras: CalendarEventExtras) {
        guests = extras.guests.map {
            Guest(email: $0.email, name: $0.name, isOptional: $0.isOptional, response: $0.response?.rawValue)
        }
        permissions = extras.permissions.map {
            Permissions(canModify: $0.canModify, canInviteOthers: $0.canInviteOthers, canSeeGuestList: $0.canSeeGuestList)
        }
        recurrence = extras.recurrence
        switch extras.reminders {
        case .calendarDefault: reminders = nil
        case .custom(let list): reminders = list.map { Reminder(method: $0.method.rawValue, minutes: $0.minutesBefore) }
        }
        free = extras.busy == .free
        visibility = extras.visibility.rawValue
        colorID = extras.colorID
    }

    var value: CalendarEventExtras {
        CalendarEventExtras(
            guests: guests.map {
                CalendarGuest(email: $0.email, name: $0.name, isOptional: $0.isOptional,
                              response: $0.response.flatMap(CalendarResponse.init(rawValue:)),
                              isOrganizer: nil)
            },
            permissions: permissions.map {
                CalendarGuestPermissions(canModify: $0.canModify, canInviteOthers: $0.canInviteOthers,
                                         canSeeGuestList: $0.canSeeGuestList)
            },
            recurrence: recurrence,
            reminders: reminders.map { list in
                .custom(list.map {
                    CalendarReminder(method: CalendarReminder.Method(rawValue: $0.method) ?? .popup, minutesBefore: $0.minutes)
                })
            } ?? .calendarDefault,
            busy: free ? .free : .busy,
            visibility: CalendarVisibility(rawValue: visibility) ?? .calendarDefault,
            colorID: colorID)
    }
}

private var calendarCacheTransient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
