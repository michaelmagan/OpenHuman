import Foundation
import MailModel
import OpenHumanCore
import Synchronization

public final class FakeCalendar: CalendarProviding, Sendable {
    public enum Call: Sendable, Hashable {
        case events(from: Date, to: Date)
        case freeBusy(from: Date, to: Date)
        case create(CalendarEventDraft)
        case delete(id: String)
        case move(id: String, start: Date, end: Date, sendUpdates: CalendarSendUpdates)
        case window(from: Date, to: Date)
        case changes(token: String)
        case respond(id: String, response: CalendarResponse, sendUpdates: CalendarSendUpdates)
        case update(id: String, changes: CalendarEventChanges, sendUpdates: CalendarSendUpdates)
        case remove(id: String, sendUpdates: CalendarSendUpdates)
        case patch(id: String, patch: CalendarEventPatch, scope: CalendarRecurrenceScope, sendUpdates: CalendarSendUpdates)
    }

    public enum CreateOutcome: Sendable, Hashable {
        case normal
        case unclear(created: Bool)
    }

    private struct State {
        var events: [CalendarEvent]
        var calls: [Call] = []
        var created: [CalendarEvent] = []
        var deleted: [String] = []
        var failure: String?
        var createOutcome = CreateOutcome.normal
        var freeBusyErrors: [String] = []
        var nextID = 1
        var version = 0
        var versions: [String: Int] = [:]
        var changes: [(version: Int, id: String)] = []
        var tokensExpired = false
        var supportsTokens = true
        var declined: Set<String> = []
        var series: [String: String] = [:]
        var iCalUIDs: [String: String] = [:]
        var lookups: [Lookup] = []

        mutating func touch(_ id: String) {
            version += 1
            versions[id] = version
            changes.append((version, id))
        }
    }
    private let state: Mutex<State>
    public let info: CalendarProviderInfo
    public let abilities: CalendarAbilities

    public init(events: [CalendarEvent] = [], info: CalendarProviderInfo = CalendarProviderInfo(name: "Sample calendar",
                                                                                                isSample: true),
                abilities: CalendarAbilities = [.respond, .editDetails, .remove]) {
        self.info = info
        self.abilities = abilities
        state = Mutex(State(events: events))
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        try state.withLock { s in
            s.calls.append(.events(from: from, to: to))
            if let failure = s.failure { throw CalendarError.failed(failure) }
            return s.events.filter { $0.overlaps(from: from, to: to) }.sorted(by: Self.soonestFirst)
        }
    }

    public func freeBusy(from: Date, to: Date) async throws -> CalendarFreeBusy {
        try state.withLock { s in
            s.calls.append(.freeBusy(from: from, to: to))
            if let failure = s.failure { throw CalendarError.failed(failure) }
            let blocks = s.events.filter { !$0.isAllDay && $0.overlaps(from: from, to: to) }
                .map { CalendarBusyInterval(start: max($0.start, from), end: min($0.end, to)) }
                .sorted { $0.start < $1.start }
            return CalendarFreeBusy(busy: Self.merged(blocks), errors: s.freeBusyErrors)
        }
    }

    public func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEvent {
        try state.withLock { s in
            s.calls.append(.create(draft))
            if let failure = s.failure { throw CalendarError.failed(failure) }
            let id = "fake-event-\(s.nextID)"
            let event = CalendarEvent(id: id, title: draft.title, start: draft.start, end: draft.end,
                                      timeZone: draft.timeZone, attendees: draft.attendees, calendarName: info.name,
                                      meetLink: draft.addMeetLink ? URL(string: "https://meet.example/\(id)") : nil)
            s.nextID += 1
            if case .unclear(let kept) = s.createOutcome {
                if kept {
                    s.events.append(event)
                    s.touch(id)
                }
                throw CalendarError.unclear("The calendar may have created the event.")
            }
            s.events.append(event)
            s.touch(id)
            s.created.append(event)
            return event
        }
    }

    public func deleteEvent(_ event: CalendarEvent) async throws {
        try state.withLock { s in
            s.calls.append(.delete(id: event.id))
            if let failure = s.failure { throw CalendarError.failed(failure) }
            s.events.removeAll { $0.id == event.id }
            s.touch(event.id)
            s.deleted.append(event.id)
        }
    }

    public func moveEvent(_ event: CalendarEvent, to start: Date, end: Date,
                          sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        try state.withLock { s in
            s.calls.append(.move(id: event.id, start: start, end: end, sendUpdates: sendUpdates))
            if let failure = s.failure { throw CalendarError.failed(failure) }
            guard let index = s.events.firstIndex(where: { $0.id == event.id }) else {
                throw CalendarError.failed("The calendar didn't find the event.")
            }
            let old = s.events[index]
            let moved = CalendarEvent(id: old.id, title: old.title, start: start, end: end, isAllDay: old.isAllDay,
                                      timeZone: old.timeZone, attendees: old.attendees, calendarName: old.calendarName,
                                      meetLink: old.meetLink, organizerIsMe: old.organizerIsMe, location: old.location,
                                      notes: old.notes, myResponse: old.myResponse,
                                      recurringEventID: old.recurringEventID)
            s.events[index] = moved
            s.touch(moved.id)
            return moved
        }
    }

    public func respond(to event: CalendarEvent, with response: CalendarResponse,
                        sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        try state.withLock { s in
            s.calls.append(.respond(id: event.id, response: response, sendUpdates: sendUpdates))
            if let failure = s.failure { throw CalendarError.failed(failure) }
            guard let index = s.events.firstIndex(where: { $0.id == event.id }) else {
                throw CalendarError.failed("The calendar didn't find the event.")
            }
            if let alias = event.respondsAs?.lowercased(), s.events[index].myResponse == nil {
                for guest in s.events[index].extras.guests.indices
                    where s.events[index].extras.guests[guest].email.lowercased() == alias {
                    s.events[index].extras.guests[guest].response = response
                }
                s.touch(event.id)
                var answered = s.events[index]
                answered.myResponse = response
                answered.respondsAs = event.respondsAs
                return answered
            }
            s.events[index].myResponse = response
            s.touch(event.id)
            return s.events[index]
        }
    }

    public func updateEvent(_ event: CalendarEvent, with changes: CalendarEventChanges,
                            sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        try state.withLock { s in
            s.calls.append(.update(id: event.id, changes: changes, sendUpdates: sendUpdates))
            if let failure = s.failure { throw CalendarError.failed(failure) }
            guard let index = s.events.firstIndex(where: { $0.id == event.id }) else {
                throw CalendarError.failed("The calendar didn't find the event.")
            }
            let old = s.events[index]
            let changed = CalendarEvent(id: old.id, title: changes.title ?? old.title, start: old.start, end: old.end,
                                        isAllDay: old.isAllDay, timeZone: old.timeZone,
                                        attendees: changes.attendees ?? old.attendees, calendarName: old.calendarName,
                                        meetLink: old.meetLink, organizerIsMe: old.organizerIsMe,
                                        location: changes.location ?? old.location, notes: changes.notes ?? old.notes,
                                        myResponse: old.myResponse, recurringEventID: old.recurringEventID)
            s.events[index] = changed
            s.touch(changed.id)
            return changed
        }
    }

    public func patchEvent(_ event: CalendarEvent, with patch: CalendarEventPatch, scope: CalendarRecurrenceScope,
                           sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        try state.withLock { s in
            s.calls.append(.patch(id: event.id, patch: patch, scope: scope, sendUpdates: sendUpdates))
            if let failure = s.failure { throw CalendarError.failed(failure) }
            guard let index = s.events.firstIndex(where: { $0.id == event.id }) else {
                throw CalendarError.failed("The calendar didn't find the event.")
            }
            let old = s.events[index]
            var extras = old.extras
            if let guests = patch.guests { extras.guests = guests }
            if let permissions = patch.permissions { extras.permissions = permissions }
            if let recurrence = patch.recurrence { extras.recurrence = recurrence }
            if let reminders = patch.reminders { extras.reminders = reminders }
            if let busy = patch.busy { extras.busy = busy }
            if let visibility = patch.visibility { extras.visibility = visibility }
            if let color = patch.colorID { extras.colorID = color.isEmpty ? nil : color }
            let meet: URL? = switch patch.meet {
            case .add?: URL(string: "https://meet.google.com/abc-defg-hij")
            case .remove?: nil
            case nil: old.meetLink
            }
            let changed = CalendarEvent(id: old.id, title: patch.title ?? old.title, start: patch.time?.start ?? old.start,
                                        end: patch.time?.end ?? old.end, isAllDay: patch.time?.isAllDay ?? old.isAllDay,
                                        timeZone: patch.time?.timeZone ?? old.timeZone,
                                        attendees: patch.guests?.map(\.address) ?? old.attendees,
                                        calendarName: old.calendarName, meetLink: meet, organizerIsMe: old.organizerIsMe,
                                        location: patch.location ?? old.location, notes: patch.notes ?? old.notes,
                                        myResponse: old.myResponse, recurringEventID: old.recurringEventID, extras: extras)
            s.events[index] = changed
            s.touch(changed.id)
            return changed
        }
    }

    public func removeEvent(_ event: CalendarEvent, sendUpdates: CalendarSendUpdates) async throws {
        try state.withLock { s in
            s.calls.append(.remove(id: event.id, sendUpdates: sendUpdates))
            if let failure = s.failure { throw CalendarError.failed(failure) }
            s.events.removeAll { $0.id == event.id }
        }
    }

    public var moveCalls: Int {
        state.withLock { s in s.calls.filter { if case .move = $0 { true } else { false } }.count }
    }

    public var calls: [Call] { state.withLock { $0.calls } }
    public var created: [CalendarEvent] { state.withLock { $0.created } }
    public var allEvents: [CalendarEvent] { state.withLock { $0.events } }
    public var createCalls: Int {
        state.withLock { s in s.calls.filter { if case .create = $0 { true } else { false } }.count }
    }
    public var deleteCalls: Int {
        state.withLock { s in s.calls.filter { if case .delete = $0 { true } else { false } }.count }
    }
    public var deleted: [String] { state.withLock { $0.deleted } }
    public var readCalls: Int {
        state.withLock { s in
            s.calls.filter {
                switch $0 {
                case .events, .freeBusy, .window, .changes: true
                case .create, .delete, .move, .respond, .update, .remove, .patch: false
                }
            }.count
        }
    }
    public var failure: String? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }
    public var createOutcome: CreateOutcome {
        get { state.withLock { $0.createOutcome } }
        set { state.withLock { $0.createOutcome = newValue } }
    }
    public var freeBusyErrors: [String] {
        get { state.withLock { $0.freeBusyErrors } }
        set { state.withLock { $0.freeBusyErrors = newValue } }
    }

    public struct Lookup: Sendable, Hashable {
        public let iCalUID: String
        public let wholeSeries: Bool

        public init(iCalUID: String, wholeSeries: Bool) {
            self.iCalUID = iCalUID
            self.wholeSeries = wholeSeries
        }
    }

    public var lookups: [Lookup] { state.withLock { $0.lookups } }

    public func setICalUID(_ uid: String, for id: String) {
        state.withLock { $0.iCalUIDs[id] = uid }
    }

    public func invitedEvent(_ query: CalendarInviteQuery, wholeSeries: Bool) async throws -> CalendarEvent? {
        try state.withLock { s in
            s.lookups.append(Lookup(iCalUID: query.uid, wholeSeries: wholeSeries))
            if let failure = s.failure { throw CalendarError.failed(failure) }
            let uids = s.iCalUIDs
            let series = s.series
            switch query.pick(s.events, start: \.start, uid: { uids[$0.id] },
                              looksLike: { query.looksLike(title: $0.title, organizer: nil) }) {
            case .found(let event): return wholeSeries ? event.seriesReference : event
            case .ambiguous: throw CalendarError.refused(CalendarInviteQuery.ambiguousRefusal)
            case .missing: break
            }
            let moved = query.pickMoved(s.events, wholeSeries: wholeSeries, uid: { uids[$0.id] }, role: { event in
                if event.recurringEventID != nil || series[event.id] != nil { return .occurrence(originalStart: nil) }
                return event.extras.recurrence.isEmpty ? .single : .series
            })
            switch moved {
            case .found(let event): return event
            case .missing: return nil
            case .ambiguous: throw CalendarError.refused(CalendarInviteQuery.ambiguousRefusal)
            }
        }
    }

    public func add(_ event: CalendarEvent, series: String? = nil) {
        state.withLock { s in
            s.events.append(event)
            if let series { s.series[event.id] = series }
            s.touch(event.id)
        }
    }

    public func eventWindow(from: Date, to: Date) async throws -> CalendarEventWindow {
        try state.withLock { s in
            s.calls.append(.window(from: from, to: to))
            if let failure = s.failure { throw CalendarError.failed(failure) }
            s.tokensExpired = false
            let records = s.events.filter { $0.overlaps(from: from, to: to) }.sorted(by: Self.soonestFirst)
                .map { Self.record($0, in: s) }
            return CalendarEventWindow(records: records, syncToken: s.supportsTokens ? "fake-\(s.version)" : nil)
        }
    }

    public func eventDelta(since token: String) async throws -> CalendarEventDelta {
        try state.withLock { s in
            s.calls.append(.changes(token: token))
            if let failure = s.failure { throw CalendarError.failed(failure) }
            guard s.supportsTokens else { throw CalendarSyncError.unsupported }
            guard !s.tokensExpired, token.hasPrefix("fake-"), let since = Int(token.dropFirst(5)) else {
                throw CalendarSyncError.tokenExpired
            }
            var seen: Set<String> = []
            var changed: [CalendarEventRecord] = []
            var removed: [String] = []
            for change in s.changes where change.version > since && seen.insert(change.id).inserted {
                if let event = s.events.first(where: { $0.id == change.id }) {
                    changed.append(Self.record(event, in: s))
                } else {
                    removed.append(change.id)
                }
            }
            return CalendarEventDelta(changed: changed, removed: removed, syncToken: "fake-\(s.version)")
        }
    }

    public func update(_ event: CalendarEvent) {
        state.withLock { s in
            guard let index = s.events.firstIndex(where: { $0.id == event.id }) else { return }
            s.events[index] = event
            s.touch(event.id)
        }
    }

    public func remove(id: String) {
        state.withLock { s in
            s.events.removeAll { $0.id == id }
            s.touch(id)
        }
    }

    public func decline(id: String) {
        state.withLock { s in
            s.declined.insert(id)
            s.touch(id)
        }
    }

    public func expireTokens() {
        state.withLock { $0.tokensExpired = true }
    }

    public var supportsChangeTokens: Bool {
        get { state.withLock { $0.supportsTokens } }
        set { state.withLock { $0.supportsTokens = newValue } }
    }

    public var windowCalls: Int {
        state.withLock { s in s.calls.filter { if case .window = $0 { true } else { false } }.count }
    }
    public var changeCalls: Int {
        state.withLock { s in s.calls.filter { if case .changes = $0 { true } else { false } }.count }
    }

    private static func record(_ event: CalendarEvent, in s: State) -> CalendarEventRecord {
        var shown = event
        let declined = s.declined.contains(event.id)
        if declined { shown.myResponse = .declined }
        if shown.recurringEventID == nil { shown.recurringEventID = s.series[event.id] }
        return CalendarEventRecord(event: shown, etag: "v\(s.versions[event.id] ?? 0)",
                                   recurringEventID: s.series[event.id] ?? shown.recurringEventID, declinedByMe: declined)
    }

    public static func sample(now: Date = Date(), timeZone: TimeZone = .current) -> FakeCalendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let titles = ["Team standup", "Design review", "1:1", "Customer call", "Planning", "Lunch", "Focus time"]
        var events: [CalendarEvent] = []
        func at(_ day: Date, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        let notes: [Int: String] = [
            1: "<p>Agenda &amp; notes</p><ul><li>Roadmap</li><li>Budget</li></ul><p>Plan: <a href=\"https://example.com/plan\">the plan</a></p>",
            2: "Bring notes\\nRoom 4\\, floor 2\\; side door",
        ]
        let sam = EmailAddress(name: "Sam Rivera", email: "sam@example.com")
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let first = titles[offset % titles.count]
            let second = titles[(offset + 3) % titles.count]
            events.append(CalendarEvent(id: "sample-\(offset)-a", title: first, start: at(day, 9, 30), end: at(day, 10),
                                        timeZone: timeZone.identifier, notes: notes[offset]))
            events.append(CalendarEvent(id: "sample-\(offset)-b", title: second, start: at(day, 13), end: at(day, 14),
                                        timeZone: timeZone.identifier, attendees: [sam], organizerIsMe: false,
                                        myResponse: .accepted))
            if offset % 2 == 0 {
                var extras = CalendarEventExtras()
                if offset == 0 { extras.recurrence = ["RRULE:FREQ=DAILY;INTERVAL=2;COUNT=4"] }
                events.append(CalendarEvent(id: "sample-\(offset)-c", title: "Interview", start: at(day, 15, 30),
                                            end: at(day, 16, 30), timeZone: timeZone.identifier, organizerIsMe: true,
                                            recurringEventID: "sample-interviews", extras: extras))
            }
            if offset == 1 {
                events.append(CalendarEvent(id: "sample-1-d", title: "Dinner", start: at(day, 19), end: at(day, 20, 30),
                                            timeZone: timeZone.identifier, location: "Harbor Room"))
            }
        }
        if let day = calendar.date(byAdding: .day, value: 2, to: today), let next = calendar.date(byAdding: .day, value: 1, to: day) {
            events.append(CalendarEvent(id: "sample-allday", title: "Company offsite", start: day, end: next, isAllDay: true,
                                        timeZone: timeZone.identifier))
        }
        return FakeCalendar(events: events, abilities: [.respond, .editDetails, .remove, .editFull, .removeMeet])
    }

    private static func soonestFirst(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        a.start != b.start ? a.start < b.start : a.id < b.id
    }

    static func merged(_ blocks: [CalendarBusyInterval]) -> [CalendarBusyInterval] {
        var out: [CalendarBusyInterval] = []
        for block in blocks where block.end > block.start {
            if let last = out.last, block.start <= last.end {
                out[out.count - 1] = CalendarBusyInterval(start: last.start, end: max(last.end, block.end))
            } else {
                out.append(block)
            }
        }
        return out
    }
}
