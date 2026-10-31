import Foundation
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanMailLive

private struct OwnershipFixture: Sendable {
    enum Removal: Sendable { case delete, invitation, unavailable }

    let id: String
    var calendar = "robin@example.com"
    let identity: String
    let organizes: Bool?
    let removal: Removal

    var body: Data {
        Data("""
        {"kind":"calendar#event","id":"\(id)","status":"confirmed","etag":"\\"v1\\"",
         "summary":"Planning","iCalUID":"\(id)@example.com",
         "start":{"dateTime":"2026-10-30T17:00:00Z"},"end":{"dateTime":"2026-10-30T18:00:00Z"},
         \(identity)}
        """.utf8)
    }

    static let cases = [
        OwnershipFixture(id: "invited", identity: """
            "organizer":{"email":"sam@example.com"},"creator":{"email":"sam@example.com"},
            "attendees":[{"email":"sam@example.com","organizer":true,"responseStatus":"accepted"},
                         {"email":"robin@example.com","self":true,"responseStatus":"needsAction"}]
            """, organizes: false, removal: .invitation),
        OwnershipFixture(id: "organized", identity: """
            "organizer":{"email":"robin@example.com","self":true},
            "attendees":[{"email":"robin@example.com","self":true,"organizer":true,"responseStatus":"accepted"},
                         {"email":"sam@example.com","responseStatus":"needsAction"}]
            """, organizes: true, removal: .delete),
        OwnershipFixture(id: "created-no-organizer", identity: """
            "creator":{"email":"robin@example.com","self":true}
            """, organizes: nil, removal: .delete),
        OwnershipFixture(id: "created-no-self", identity: """
            "organizer":{"email":"Robin@Example.com"},"creator":{"email":"robin@example.com","self":true}
            """, organizes: true, removal: .delete),
        // The signed-in user is robin; Google marks the shared calendar's attendee row as self.
        OwnershipFixture(id: "shared-invitation", calendar: "team@example.com", identity: """
            "organizer":{"email":"sam@example.com"},"creator":{"email":"robin@example.com"},
            "attendees":[{"email":"sam@example.com","organizer":true,"responseStatus":"accepted"},
                         {"email":"team@example.com","self":true,"responseStatus":"accepted"}]
            """, organizes: false, removal: .invitation),
        OwnershipFixture(id: "delegated-organizer", calendar: "team@example.com", identity: """
            "organizer":{"email":"team@example.com","self":true},"creator":{"email":"robin@example.com"},
            "attendees":[{"email":"sam@example.com","responseStatus":"needsAction"}]
            """, organizes: true, removal: .delete),
        OwnershipFixture(id: "shared-organizer-no-self", calendar: "team@example.com", identity: """
            "organizer":{"email":"team@example.com"},"creator":{"email":"robin@example.com"},
            "attendees":[{"email":"sam@example.com","responseStatus":"needsAction"}]
            """, organizes: true, removal: .delete),
        // Creator identity does not establish who organizes the event now.
        OwnershipFixture(id: "creator-is-guest", identity: """
            "organizer":{"email":"sam@example.com"},"creator":{"email":"robin@example.com","self":true}
            """, organizes: false, removal: .invitation),
        OwnershipFixture(id: "unknown-organizer", identity: """
            "creator":{"email":"robin@example.com","self":true},
            "attendees":[{"email":"robin@example.com","self":true,"responseStatus":"needsAction"}]
            """, organizes: nil, removal: .unavailable),
        OwnershipFixture(id: "unknown-identity", identity: """
            "organizer":{},"attendees":[{"email":"robin@example.com","self":true,"responseStatus":"accepted"}]
            """, organizes: nil, removal: .unavailable),
    ]

    func client() -> GoogleCalendarClient {
        let http = FakeHTTPTransport()
        let page = HTTPResponse(status: 200, headers: [:], body: Data("{\"items\":[".utf8) + body + Data("]}".utf8))
        let event = HTTPResponse(status: 200, headers: [:], body: body)
        let path = "/calendar/v3/calendars/\(calendar)/events"
        http.on("GET", path) { request in request.url.path.hasSuffix("/\(id)") ? event : page }
        return GoogleCalendarClient(calendarID: calendar, grantedScopes: CalendarScopes.request.write,
            tokens: StaticTokenProvider(token: "synthetic-calendar-token"), transport: http,
            clock: InstantClock(), timeZone: .gmt)
    }
}

@MainActor
@Suite struct GoogleCalendarOwnershipDecodingTests {
    private let start = Date(timeIntervalSince1970: 1_793_379_600)

    @Test func realGoogleJSONSelectsCardMenuAndActionRights() async throws {
        for fixture in OwnershipFixture.cases {
            let provider = GoogleCalendarProvider(client: fixture.client(), account: fixture.calendar, createRefusal: nil)
            let event = try #require(try await provider.events(from: start, to: start.addingTimeInterval(86_400)).first)
            #expect(event.organizerIsMe == fixture.organizes, "\(fixture.id)")
            #expect(event.isInvitationCopy == (fixture.removal == .invitation), "\(fixture.id)")
            let rights = CalendarFieldRights.make(for: event, abilities: provider.abilities, refusal: nil)
            let environment = AppEnvironment.fake(featureFlags: FeatureFlags(), calendar: provider)
            // The window and sidebar hold unowned environment references.
            defer { withExtendedLifetime(environment) {} }
            let window = try #require(environment.calendarWindow)
            window.openEvent(event)
            let card = try #require(window.card)
            switch fixture.removal {
            case .invitation:
                #expect(rights.delete == .removeInvite, "\(fixture.id)")
                #expect(card.canRemove && card.removesInvite, "\(fixture.id)")
                #expect(window.removalTitle(for: event) == String(localized: "Remove from Calendar…"), "\(fixture.id)")
            case .delete:
                #expect(rights.delete == .delete, "\(fixture.id)")
                #expect(card.canRemove && !card.removesInvite, "\(fixture.id)")
                #expect(window.removalTitle(for: event) == String(localized: "Delete…"), "\(fixture.id)")
            case .unavailable:
                #expect(rights.delete != .removeInvite && rights.delete != .delete, "\(fixture.id)")
                #expect(!card.canRemove && !card.removesInvite, "\(fixture.id)")
                #expect(window.removalTitle(for: event) == nil, "\(fixture.id)")
            }
        }
    }

    @Test func syncAndReaderLookupDecodeTheSameOwnership() async throws {
        for fixture in OwnershipFixture.cases {
            let client = fixture.client()
            let page = try await client.listEventWindow(from: start, to: start.addingTimeInterval(86_400))
            let synced = try #require(page.events.first)
            let candidates = try await client.inviteCandidates(iCalUID: "\(fixture.id)@example.com", from: nil, to: nil)
            let candidate = try #require(candidates.first)
            let read = try #require(try await client.readEvent(id: fixture.id))
            for decoded in [synced.event, candidate.event, read] {
                let event = GoogleCalendarProvider.event(decoded)
                #expect(event.organizerIsMe == fixture.organizes, "\(fixture.id)")
                #expect(event.isInvitationCopy == (fixture.removal == .invitation), "\(fixture.id)")
            }
        }
    }
}
