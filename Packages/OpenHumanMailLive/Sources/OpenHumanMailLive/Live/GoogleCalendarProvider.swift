import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail

struct CalendarFetchRecord: Sendable, Hashable {
    enum Kind: String, Sendable { case events, freeBusy }
    let kind: Kind
    let from: Date
    let to: Date
    let duration: Duration
    let count: Int?
    let failure: String?
}

final class GoogleCalendarProvider: CalendarProviding {
    let info: CalendarProviderInfo
    let client: GoogleCalendarClient
    private let onFetch: (@Sendable (CalendarFetchRecord) -> Void)?

    init(client: GoogleCalendarClient, account: String, createRefusal: String?,
         onFetch: (@Sendable (CalendarFetchRecord) -> Void)? = nil) {
        self.client = client
        self.onFetch = onFetch
        info = CalendarProviderInfo(name: "Google Calendar", account: account,
                                    createRefusal: client.allowsWrites ? nil : createRefusal ?? Self.cannotWrite)
    }

    static let cannotWrite = "Mail can't create events with this calendar connection."

    func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        let started = ContinuousClock.now
        do {
            let events = try await client.listEvents(from: from, to: to).map(Self.event)
            onFetch?(CalendarFetchRecord(kind: .events, from: from, to: to, duration: ContinuousClock.now - started,
                                         count: events.count, failure: nil))
            return events
        } catch {
            onFetch?(CalendarFetchRecord(kind: .events, from: from, to: to, duration: ContinuousClock.now - started,
                                         count: nil, failure: Self.reasonCode(error)))
            throw Self.calendarError(error, doing: "read the calendar")
        }
    }

    func freeBusy(from: Date, to: Date) async throws -> CalendarFreeBusy {
        let started = ContinuousClock.now
        do {
            let answer = try await client.freeBusy(from: from, to: to)
            onFetch?(CalendarFetchRecord(kind: .freeBusy, from: from, to: to, duration: ContinuousClock.now - started,
                                         count: answer.busy.count, failure: nil))
            return CalendarFreeBusy(busy: answer.busy.map { CalendarBusyInterval(start: $0.start, end: $0.end) },
                                    errors: answer.errors)
        } catch {
            onFetch?(CalendarFetchRecord(kind: .freeBusy, from: from, to: to, duration: ContinuousClock.now - started,
                                         count: nil, failure: Self.reasonCode(error)))
            throw Self.calendarError(error, doing: "read free/busy")
        }
    }

    static func reasonCode(_ error: Error) -> String {
        if let failure = error as? GoogleCalendarError { return failure.code }
        if error is CancellationError { return "cancelled" }
        return String(describing: type(of: error))
    }

    private func reportFailure(from: Date, to: Date, started: ContinuousClock.Instant, error: Error) {
        onFetch?(CalendarFetchRecord(kind: .events, from: from, to: to, duration: ContinuousClock.now - started,
                                     count: nil, failure: Self.reasonCode(error)))
    }

    func eventWindow(from: Date, to: Date) async throws -> CalendarEventWindow {
        let started = ContinuousClock.now
        do {
            let page = try await client.listEventWindow(from: from, to: to)
            onFetch?(CalendarFetchRecord(kind: .events, from: from, to: to, duration: ContinuousClock.now - started,
                                         count: page.events.count, failure: nil))
            return CalendarEventWindow(records: page.events.map(Self.record), syncToken: page.nextSyncToken,
                                       isComplete: page.isComplete)
        } catch GoogleCalendarError.rateLimited {
            reportFailure(from: from, to: to, started: started, error: GoogleCalendarError.rateLimited)
            throw CalendarSyncError.rateLimited(retryAfter: nil)
        } catch {
            reportFailure(from: from, to: to, started: started, error: error)
            throw Self.calendarError(error, doing: "read the calendar")
        }
    }

    func eventDelta(since token: String) async throws -> CalendarEventDelta {
        let started = ContinuousClock.now
        let now = Date()
        do {
            let page = try await client.listEventChanges(syncToken: token)
            onFetch?(CalendarFetchRecord(kind: .events, from: now, to: now, duration: ContinuousClock.now - started,
                                         count: page.events.count + page.removed.count, failure: nil))
            return CalendarEventDelta(changed: page.events.map(Self.record), removed: page.removed,
                                      syncToken: page.nextSyncToken)
        } catch GoogleCalendarError.gone {
            reportFailure(from: now, to: now, started: started, error: GoogleCalendarError.gone)
            throw CalendarSyncError.tokenExpired
        } catch GoogleCalendarError.badRequest(reason: let detail) {
            reportFailure(from: now, to: now, started: started, error: GoogleCalendarError.badRequest(reason: detail))
            throw CalendarSyncError.unsupported
        } catch GoogleCalendarError.rateLimited {
            reportFailure(from: now, to: now, started: started, error: GoogleCalendarError.rateLimited)
            throw CalendarSyncError.rateLimited(retryAfter: nil)
        } catch {
            reportFailure(from: now, to: now, started: started, error: error)
            throw Self.calendarError(error, doing: "refresh the calendar")
        }
    }

    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEvent {
        if let refusal = info.createRefusal { throw CalendarError.refused(refusal) }
        var insert = GoogleEventInsert(title: draft.title, start: draft.start, end: draft.end, timeZone: draft.timeZone,
                                       attendees: draft.attendees.map(\.email),
                                       location: draft.location.isEmpty ? nil : draft.location,
                                       description: draft.notes.isEmpty ? nil : draft.notes)
        insert.isAllDay = draft.isAllDay
        insert.optionalAttendees = Set(draft.extras.guests.filter(\.isOptional).map { $0.email.lowercased() })
        insert.details = Self.insertDetails(draft.extras)
        do {
            let created = try await client.insertEvent(insert, sendUpdates: Self.sendUpdates(draft.sendUpdates),
                                                       addMeet: draft.addMeetLink)
            return Self.event(created)
        } catch {
            throw Self.calendarError(error, doing: draft.addMeetLink ? "create the event with a Google Meet link"
                                                                     : "create the event")
        }
    }

    func deleteEvent(_ event: CalendarEvent) async throws {
        if let refusal = info.createRefusal { throw CalendarError.refused(refusal) }
        guard !event.id.isEmpty else { throw CalendarError.failed("Google didn't say which event it created.") }
        do {
            try await client.deleteEvent(id: event.id)
        } catch {
            throw Self.calendarError(error, doing: "remove the event")
        }
    }

    func moveEvent(_ event: CalendarEvent, to start: Date, end: Date,
                   sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        if let refusal = info.createRefusal { throw CalendarError.refused(refusal) }
        guard !event.id.isEmpty, event.isMovableByMe else {
            throw CalendarError.refused("Mail moves only your own meetings.")
        }
        do {
            let moved = try await client.moveEvent(id: event.id, start: start, end: end,
                                                   timeZone: event.timeZone ?? TimeZone.current.identifier,
                                                   sendUpdates: Self.sendUpdates(sendUpdates))
            return moved.map(Self.event) ?? CalendarEvent(id: event.id, title: event.title, start: start, end: end,
                                                          timeZone: event.timeZone, attendees: event.attendees,
                                                          meetLink: event.meetLink, organizerIsMe: event.organizerIsMe)
        } catch GoogleCalendarError.unclear {
            throw CalendarError.unclear("Google may have moved the event. Check your calendar.")
        } catch {
            throw Self.calendarError(error, doing: "move the event")
        }
    }

    var abilities: CalendarAbilities { [.respond, .remove, .editFull, .removeMeet] }

    func removeEvent(_ event: CalendarEvent, sendUpdates: CalendarSendUpdates) async throws {
        if let refusal = info.createRefusal { throw CalendarError.refused(refusal) }
        guard !event.id.isEmpty, event.organizerIsMe == true || (event.organizerIsMe == nil && event.attendees.isEmpty) else {
            throw CalendarError.refused("Mail deletes only events you organize. Delete it in your calendar.")
        }
        guard !event.isRecurring else {
            throw CalendarError.refused("Mail doesn't delete repeating events yet. Delete it in your calendar.")
        }
        do {
            try await client.removeEvent(id: event.id, sendUpdates: Self.sendUpdates(sendUpdates))
        } catch GoogleCalendarError.unclear {
            throw CalendarError.unclear("Google may have deleted the event. Check your calendar.")
        } catch {
            throw Self.calendarError(error, doing: "delete the event")
        }
    }

    func respond(to event: CalendarEvent, with response: CalendarResponse,
                 sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        if let refusal = info.createRefusal { throw CalendarError.refused(refusal) }
        guard event.canRespond, response != .needsAction else {
            throw CalendarError.refused("Mail answers only invitations someone else sent you.")
        }
        do {
            let answered = try await client.respond(eventID: event.id, response: response.rawValue,
                                                    sendUpdates: Self.sendUpdates(sendUpdates), as: event.respondsAs)
            var shown = answered.map(Self.event) ?? event
            if shown.myResponse == nil || answered == nil { shown.myResponse = response }
            shown.respondsAs = event.respondsAs
            return shown
        } catch GoogleCalendarError.unclear {
            throw CalendarError.unclear("Google may have sent your answer. Check your calendar.")
        } catch {
            throw Self.calendarError(error, doing: "answer the invitation")
        }
    }


    func patchEvent(_ event: CalendarEvent, with patch: CalendarEventPatch, scope: CalendarRecurrenceScope,
                    sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        if let refusal = info.createRefusal { throw CalendarError.refused(refusal) }
        guard !event.id.isEmpty, !patch.isEmpty else { throw CalendarError.refused("There is nothing to change.") }
        guard patch.calendarKey == nil else {
            throw CalendarError.refused("Mail can't move events between calendars on this connection.")
        }
        let updates = Self.sendUpdates(sendUpdates)
        let masterID = event.recurringEventID ?? event.id
        do {
            switch (event.isRecurring, scope) {
            case (false, _), (true, .thisEvent):
                let written = try await client.patchEvent(id: event.id, patch: Self.googlePatch(patch), sendUpdates: updates)
                return written.map(Self.event) ?? Self.applying(patch, to: event)
            case (true, .allEvents):
                var wire = Self.googlePatch(patch)
                if let time = wire.time {
                    guard let first = try await client.readEvent(id: masterID) else { throw CalendarError.failed("Couldn't read the series.") }
                    let zone = TimeZone(identifier: time.timeZone)
                        ?? first.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
                    let shifted = Self.shiftedSeriesStart(first.start, instant: event.start, movedTo: time.start, zone: zone)
                    wire.time = GoogleEventPatch.Time(start: shifted, end: shifted.addingTimeInterval(time.end.timeIntervalSince(time.start)),
                                                      isAllDay: time.isAllDay, timeZone: time.timeZone)
                }
                let written = try await client.patchEvent(id: masterID, patch: wire, sendUpdates: updates)
                return written.map(Self.event) ?? Self.applying(patch, to: event)
            case (true, .thisAndFollowing):
                return try await splitSeries(event, masterID: masterID, patch: patch, sendUpdates: updates)
            }
        } catch GoogleCalendarError.unclear {
            throw CalendarError.unclear("Google may have saved the change. Check your calendar.")
        } catch let error as CalendarError {
            throw error
        } catch {
            throw Self.calendarError(error, doing: "save the event")
        }
    }

    // The series keeps its wall-clock time across a daylight-saving change: days and time of day, not seconds
    static func shiftedSeriesStart(_ first: Date, instant: Date, movedTo start: Date, zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: instant),
                                           to: calendar.startOfDay(for: start)).day ?? 0
        let wall = calendar.dateComponents([.hour, .minute, .second], from: start)
        guard let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: first)),
              let shifted = calendar.date(bySettingHour: wall.hour ?? 0, minute: wall.minute ?? 0, second: wall.second ?? 0,
                                          of: day) else {
            return first.addingTimeInterval(start.timeIntervalSince(instant))
        }
        return shifted
    }

    private func splitSeries(_ event: CalendarEvent, masterID: String, patch: CalendarEventPatch,
                             sendUpdates: GoogleSendUpdates) async throws -> CalendarEvent {
        let rules = try await client.seriesRecurrence(id: masterID)
        guard !rules.isEmpty else { throw CalendarError.failed("Couldn't read how the series repeats.") }
        let zoneID = patch.time?.timeZone ?? event.timeZone ?? TimeZone.current.identifier
        let zone = TimeZone(identifier: zoneID) ?? .current
        let following: [String]
        if let chosen = patch.recurrence {
            following = chosen
        } else if let kept = CalendarRepeat.continuing(rules, from: event.start, isAllDay: event.isAllDay, zone: zone) {
            following = kept
        } else {
            throw CalendarError.refused(Self.countedSeriesRefusal)
        }
        let master = try await client.readEvent(id: masterID)
        let series = master.map(Self.extras) ?? event.extras
        let times = patch.time
        var insert = GoogleEventInsert(title: patch.title ?? event.title, start: times?.start ?? event.start,
                                       end: times?.end ?? event.end, timeZone: zoneID,
                                       attendees: (patch.guests ?? event.extras.guests).map(\.email),
                                       location: patch.location ?? event.location, description: patch.notes ?? event.notes)
        insert.isAllDay = times?.isAllDay ?? event.isAllDay
        let wanted = patch.guests ?? (event.extras.guests.isEmpty ? event.attendees.map { CalendarGuest($0) } : event.extras.guests)
        insert.attendees = wanted.map(\.email)
        insert.optionalAttendees = Set(wanted.filter(\.isOptional).map { $0.email.lowercased() })
        var details = Self.merged(Self.insertDetails(series), with: Self.googlePatch(patch).details)
        details.recurrence = following
        insert.details = details
        let keepMeet = event.meetLink != nil && patch.meet != .remove
        let made = try await client.insertEvent(insert, sendUpdates: sendUpdates, addMeet: patch.meet == .add || keepMeet)
        var cut = GoogleEventPatch()
        cut.details.recurrence = CalendarRepeat.endingBefore(rules, instantStart: event.start, isAllDay: event.isAllDay, zone: zone)
        do {
            _ = try await client.patchEvent(id: masterID, patch: cut, sendUpdates: .none)
        } catch {
            throw CalendarError.failed("Saved the new events, but couldn't end the old series. Check your calendar.")
        }
        return Self.event(made)
    }

    static let countedSeriesRefusal = "This series ends after a set number of times, so Mail can't split it. "
        + "Change this event or all events."

    static func merged(_ base: GoogleEventDetails, with patch: GoogleEventDetails) -> GoogleEventDetails {
        var out = base
        if let value = patch.guestsCanModify { out.guestsCanModify = value }
        if let value = patch.guestsCanInviteOthers { out.guestsCanInviteOthers = value }
        if let value = patch.guestsCanSeeOtherGuests { out.guestsCanSeeOtherGuests = value }
        if let value = patch.recurrence { out.recurrence = value }
        if let value = patch.useDefaultReminders {
            out.useDefaultReminders = value
            out.reminderOverrides = patch.reminderOverrides
        }
        if let value = patch.transparency { out.transparency = value }
        if let value = patch.visibility { out.visibility = value }
        if let value = patch.colorID { out.colorID = value }
        return out
    }

    static func googlePatch(_ patch: CalendarEventPatch) -> GoogleEventPatch {
        var out = GoogleEventPatch()
        out.title = patch.title
        out.location = patch.location
        out.description = patch.notes
        if let time = patch.time {
            out.time = GoogleEventPatch.Time(start: time.start, end: time.end, isAllDay: time.isAllDay, timeZone: time.timeZone)
        }
        out.guests = patch.guests?.map { GoogleGuestEdit(email: $0.email, name: $0.name, isOptional: $0.isOptional) }
        switch patch.meet {
        case .add?: out.meet = .add
        case .remove?: out.meet = .remove
        case nil: break
        }
        if let permissions = patch.permissions {
            out.details.guestsCanModify = permissions.canModify
            out.details.guestsCanInviteOthers = permissions.canInviteOthers
            out.details.guestsCanSeeOtherGuests = permissions.canSeeGuestList
        }
        out.details.recurrence = patch.recurrence
        if let reminders = patch.reminders { Self.set(reminders, in: &out.details) }
        if let busy = patch.busy { out.details.transparency = busy == .free ? "transparent" : "opaque" }
        if let visibility = patch.visibility { out.details.visibility = visibility.rawValue }
        out.details.colorID = patch.colorID
        return out
    }

    private static func set(_ reminders: CalendarReminders, in details: inout GoogleEventDetails) {
        switch reminders {
        case .calendarDefault:
            details.useDefaultReminders = true
        case .custom(let list):
            details.useDefaultReminders = false
            details.reminderOverrides = list.map { GoogleReminder(method: $0.method.rawValue, minutes: $0.minutesBefore) }
        }
    }

    static func insertDetails(_ extras: CalendarEventExtras) -> GoogleEventDetails {
        var details = GoogleEventDetails()
        if let permissions = extras.permissions, permissions != CalendarGuestPermissions() {
            details.guestsCanModify = permissions.canModify
            details.guestsCanInviteOthers = permissions.canInviteOthers
            details.guestsCanSeeOtherGuests = permissions.canSeeGuestList
        }
        if !extras.recurrence.isEmpty { details.recurrence = extras.recurrence }
        if case .custom = extras.reminders { Self.set(extras.reminders, in: &details) }
        if extras.busy == .free { details.transparency = "transparent" }
        if extras.visibility != .calendarDefault { details.visibility = extras.visibility.rawValue }
        if let color = extras.colorID, !color.isEmpty { details.colorID = color }
        return details
    }

    static func applying(_ patch: CalendarEventPatch, to event: CalendarEvent) -> CalendarEvent {
        CalendarEvent(id: event.id, title: patch.title ?? event.title, start: patch.time?.start ?? event.start,
                      end: patch.time?.end ?? event.end, isAllDay: patch.time?.isAllDay ?? event.isAllDay,
                      timeZone: patch.time?.timeZone ?? event.timeZone, attendees: event.attendees,
                      calendarName: event.calendarName, meetLink: event.meetLink, organizerIsMe: event.organizerIsMe,
                      account: event.account, location: patch.location ?? event.location, notes: patch.notes ?? event.notes,
                      myResponse: event.myResponse, recurringEventID: event.recurringEventID, extras: event.extras)
    }

    static func extras(_ event: GoogleCalendarEvent) -> CalendarEventExtras {
        let read = event.extras
        var out = CalendarEventExtras()
        out.guests = event.attendees.map {
            CalendarGuest(email: $0.email, name: $0.name, isOptional: $0.isOptional,
                          response: $0.responseStatus.flatMap(CalendarResponse.init(rawValue:)))
        }
        if read.guestsCanModify != nil || read.guestsCanInviteOthers != nil || read.guestsCanSeeOtherGuests != nil {
            out.permissions = CalendarGuestPermissions(canModify: read.guestsCanModify ?? false,
                                                       canInviteOthers: read.guestsCanInviteOthers ?? true,
                                                       canSeeGuestList: read.guestsCanSeeOtherGuests ?? true)
        }
        out.recurrence = read.recurrence
        if read.remindersUseDefault == false {
            out.reminders = .custom(read.reminderOverrides.map {
                CalendarReminder(method: CalendarReminder.Method(rawValue: $0.method) ?? .popup, minutesBefore: $0.minutes)
            })
        }
        out.busy = read.transparency == "transparent" ? .free : .busy
        out.visibility = read.visibility.flatMap(CalendarVisibility.init(rawValue:)) ?? .calendarDefault
        out.colorID = read.colorID
        return out
    }

    static func event(_ event: GoogleCalendarEvent) -> CalendarEvent {
        CalendarEvent(id: event.id, title: event.title ?? String(localized: "(No title)"), start: event.start, end: event.end,
                      isAllDay: event.isAllDay, timeZone: event.timeZone,
                      attendees: event.attendees.map { EmailAddress(name: $0.name, email: $0.email) },
                      calendarName: nil, meetLink: event.meetLink, organizerIsMe: event.organizerIsSelf,
                      location: event.location, notes: event.notes,
                      myResponse: event.selfResponse.flatMap(CalendarResponse.init(rawValue:)),
                      recurringEventID: event.recurringEventID, extras: extras(event))
    }

    static func record(_ synced: GoogleSyncedEvent) -> CalendarEventRecord {
        var shown = event(synced.event)
        shown.recurringEventID = shown.recurringEventID ?? synced.recurringEventID
        if synced.selfDeclined { shown.myResponse = .declined }
        return CalendarEventRecord(event: shown, etag: synced.etag, updated: synced.updated,
                                   recurringEventID: synced.recurringEventID ?? shown.recurringEventID,
                                   isBusy: !synced.isTransparent, declinedByMe: synced.selfDeclined)
    }

    static func sendUpdates(_ value: CalendarSendUpdates) -> GoogleSendUpdates {
        switch value {
        case .all: .all
        case .externalOnly: .externalOnly
        case .none: .none
        }
    }

    static func calendarError(_ error: Error, doing what: String) -> CalendarError {
        guard let failure = error as? GoogleCalendarError else {
            return .failed("Couldn't \(what).")
        }
        switch failure {
        case .refusedByGuard:
            return .refused("Mail never sends that calendar change, so nothing was changed.")
        case .reauthRequired, .unauthorized:
            return .failed("Google Calendar needs to be connected again (Settings › Calendar).")
        case .rateLimited:
            return .failed("Google is limiting calendar requests. Try again in a minute.")
        case .forbidden(let reason):
            return .failed("Google refused to \(what) (\(reason)).")
        case .notFound, .gone:
            return .failed("Google Calendar didn't find the calendar (or the event).")
        case .badRequest(let reason):
            return .failed("Google refused to \(what) (\(reason)).")
        case .server(let status):
            return .failed("Google Calendar had a problem (HTTP \(status)). Try again.")
        case .transport:
            return .failed("Couldn't reach Google Calendar. Check the connection.")
        case .unclear:
            return .unclear("Google may have created the event, but its answer was lost. Check your calendar.")
        case .decoding:
            return .failed("Google Calendar's answer couldn't be read.")
        case .cancelled:
            return .failed("Stopped.")
        }
    }
}
