import Foundation
import MailModel

struct RoutedCalendarProvider: CalendarProviding {
    let connections: any CalendarConnectionsProviding

    static let noneConnected = String(localized: "No calendar is connected yet. Connect one in Settings › Calendar.")

    var info: CalendarProviderInfo {
        connections.windowCalendarProvider()?.info
            ?? CalendarProviderInfo(name: String(localized: "Calendar"), createRefusal: Self.noneConnected)
    }

    func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        try await current().events(from: from, to: to)
    }

    func freeBusy(from: Date, to: Date) async throws -> CalendarFreeBusy {
        try await current().freeBusy(from: from, to: to)
    }

    func eventWindow(from: Date, to: Date) async throws -> CalendarEventWindow {
        try await current().eventWindow(from: from, to: to)
    }

    func eventDelta(since token: String) async throws -> CalendarEventDelta {
        try await current().eventDelta(since: token)
    }

    var abilities: CalendarAbilities { connections.windowCalendarProvider()?.abilities ?? [] }
    var removalScopes: [CalendarRecurrenceScope] { connections.windowCalendarProvider()?.removalScopes ?? [] }
    var removalIdentity: ObjectIdentifier? {
        connections.windowCalendarProvider()?.removalIdentity
    }

    func removalProvider(for event: CalendarEvent) throws -> any CalendarProviding {
        let captured = try current()
        guard event.account == nil || event.account?.lowercased() == captured.info.account?.lowercased() else {
            throw CalendarError.refused("The selected calendar account changed. Open the event again.")
        }
        return try captured.removalProvider(for: event)
    }

    func removeEvent(_ event: CalendarEvent, scope: CalendarRecurrenceScope,
                     sendUpdates: CalendarSendUpdates) async throws -> CalendarRemovalResult {
        try await removalProvider(for: event).removeEvent(event, scope: scope, sendUpdates: sendUpdates)
    }

    func respond(to event: CalendarEvent, with response: CalendarResponse,
                 sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        try await current().respond(to: event, with: response, sendUpdates: sendUpdates)
    }

    func updateEvent(_ event: CalendarEvent, with changes: CalendarEventChanges,
                     sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        try await current().updateEvent(event, with: changes, sendUpdates: sendUpdates)
    }

    func removeEvent(_ event: CalendarEvent, sendUpdates: CalendarSendUpdates) async throws {
        try await current().removeEvent(event, sendUpdates: sendUpdates)
    }

    func invitedEvent(_ query: CalendarInviteQuery, wholeSeries: Bool) async throws -> CalendarEvent? {
        try await current().invitedEvent(query, wholeSeries: wholeSeries)
    }

    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEvent {
        try await current().createEvent(draft)
    }

    func deleteEvent(_ event: CalendarEvent) async throws {
        try await current().deleteEvent(event)
    }

    func moveEvent(_ event: CalendarEvent, to start: Date, end: Date,
                   sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        try await current().moveEvent(event, to: start, end: end, sendUpdates: sendUpdates)
    }

    func patchEvent(_ event: CalendarEvent, with patch: CalendarEventPatch, scope: CalendarRecurrenceScope,
                    sendUpdates: CalendarSendUpdates) async throws -> CalendarEvent {
        try await current().patchEvent(event, with: patch, scope: scope, sendUpdates: sendUpdates)
    }

    private func current() throws -> any CalendarProviding {
        guard let found = connections.windowCalendarProvider() else { throw CalendarError.notConfigured }
        return found
    }
}
