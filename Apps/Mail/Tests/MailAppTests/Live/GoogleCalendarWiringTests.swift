import Foundation
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

private let readScopes = CalendarScopes.request.read
private let writeScopes = CalendarScopes.request.write

private func query(_ url: URL?, _ name: String) -> String? {
    url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
}

private final class UndeletableTokenStore: TokenStore {
    let wrapped = InMemoryTokenStore()
    struct Refused: Error {}
    func load(account email: String) throws -> StoredToken? { try wrapped.load(account: email) }
    func save(_ token: StoredToken, account email: String) throws { try wrapped.save(token, account: email) }
    func delete(account email: String) throws { throw Refused() }
    func allAccounts() throws -> [String] { try wrapped.allAccounts() }
}

@MainActor
private final class CalendarHarness {
    static let address = "robin@example.com"
    var email: String { Self.address }
    let http: FakeHTTPTransport
    let mailTokens: InMemoryTokenStore
    let calendarTokens: InMemoryTokenStore
    let browser: RecordingBrowser
    let store: MailStore
    private let temp: TemporaryDirectory
    let directory: URL
    let backend: LiveBackend
    let account: AccountItem
    let mailToken: StoredToken

    init(mailScopes: [String] = [GmailScope.modify], grants: [String] = writeScopes,
         calendarStore: (any TokenStore)? = nil) throws {
        let temp = TemporaryDirectory("oh-gcal")
        let directory = temp.url
        let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .test,
                                                    appVersion: "0.0.0-test",
                                                    changeNotificationName: "dev.openhuman.tests.gcal.\(UUID().uuidString)"))
        let id = try store.addAccount(email: Self.address, displayName: nil, scopes: mailScopes)
        let mailToken = StoredToken(refreshToken: "synthetic-refresh-mail", grantedScopes: mailScopes,
                                    clientID: SyntheticClient.clientID)
        let mailTokens = InMemoryTokenStore([Self.address: mailToken])
        let calendarTokens = InMemoryTokenStore()
        let http = FakeHTTPTransport()
        let scope = grants.joined(separator: " ")
        http.on("POST", "/token") { _ in
            FakeHTTPTransport.json(200, ["access_token": "synthetic-access-cal", "refresh_token": "synthetic-refresh-cal",
                                         "expires_in": 3600, "scope": scope, "token_type": "Bearer"])
        }
        let browser = RecordingBrowser()
        let backend = LiveBackend(
            store: store,
            accountDependencies: LiveAccountManager.Dependencies(
                environment: ["OPENHUMAN_OAUTH_CLIENT_JSON": try SyntheticClient.writeJSON()],
                storeDirectory: directory.appendingPathComponent("none"), tokenStore: mailTokens,
                transport: http, makeReceiver: { AnsweringReceiver(browser: browser) }, browser: browser,
                clock: SystemClock(), signInTimeout: .seconds(30), calendarTokenStore: calendarStore ?? calendarTokens,
                developerClientFile: BuildFlavor.oauthClientFile),
            transports: LiveBackend.Transports(api: http, token: http),
            userAgent: "OpenHumanMail/test", pollInterval: .seconds(3600), makeSystemEvents: { AppSystemEvents.quiet() })
        let account = try #require(backend.account(id))
        self.temp = temp
        self.directory = directory
        self.store = store
        self.mailToken = mailToken
        self.mailTokens = mailTokens
        self.calendarTokens = calendarTokens
        self.http = http
        self.browser = browser
        self.backend = backend
        self.account = account
    }

    func session() async throws -> SyncSession {
        try await backend.makeSession(for: account)
    }

    func storeCalendarToken(_ scopes: [String]) throws {
        try calendarTokens.save(StoredToken(refreshToken: "synthetic-refresh-cal", accessToken: "synthetic-access-cal",
                                            accessTokenExpiry: Date().addingTimeInterval(3600), grantedScopes: scopes,
                                            clientID: SyntheticClient.clientID), account: email)
    }
}

@MainActor
@Test func aRealAccountGetsTheSwitchAndTheModuleWithOrWithoutAGrant() async throws {
    let h = try CalendarHarness()
    let none = try await h.session()
    #expect(none.environment.calendarConnection != nil, "Settings › Calendar has the switch")
    let routed = try #require(none.environment.calendar)
    #expect(none.environment.modules.modules.contains(.calendar), "the module runs before any calendar is connected")
    #expect(routed.info.account == nil && routed.info.createRefusal != nil, "nothing connected: nothing used")
    #expect(none.environment.calendarConnections?.windowCalendarProvider() == nil)
    #expect(h.http.requests.isEmpty, "nothing is asked of Google until the switch is turned on")

    try h.storeCalendarToken(readScopes)
    let connected = try await h.session()
    let provider = try #require(connected.environment.calendar)
    #expect(connected.environment.modules.modules.contains(.calendar), "a grant stored before the session: the module runs")
    #expect(provider.info.name == "Google Calendar" && provider.info.account == h.email && !provider.info.isSample)
    #expect(provider.info.createRefusal == GoogleCalendarSession.reconnectToCreate, "an older read grant: reconnect to create")
    #expect(GoogleCalendarSession.reconnectToCreate.hasPrefix("Reconnect Google Calendar to create events"))
    #expect(connected.environment.calendarSidebar?.createRefusal != nil)

    try h.storeCalendarToken(writeScopes)
    let writable = try #require(try await h.session().environment.calendar)
    #expect(writable.info.account == h.email && writable.info.createRefusal == nil, "a write grant creates events")

    try h.storeCalendarToken(readScopes + [GmailScope.modify])
    let unusable = try await h.session()
    #expect(unusable.environment.calendarConnections?.windowCalendarProvider() == nil)
    #expect(unusable.environment.calendar?.info.account == nil)
}

@MainActor
@Test func connectingStoresTheCalendarTokenApartFromGmail() async throws {
    let h = try CalendarHarness()
    let calendar = try #require(try await h.session().calendar)
    try await calendar.connect()
    let stored = try #require(try h.calendarTokens.load(account: h.email))
    #expect(stored.grantedScopes == writeScopes && stored.clientID == SyntheticClient.clientID)
    #expect(try h.mailTokens.load(account: h.email) == h.mailToken, "the Gmail token and its scope are untouched")
    #expect(try h.mailTokens.allAccounts() == [h.email])
    #expect(try h.store.accounts().first?.grantedScopes == [GmailScope.modify], "the Store keeps the Gmail grant only")
    let consent = try #require(h.browser.urls.last)
    #expect(query(consent, "scope") == writeScopes.joined(separator: " "))
    #expect(query(consent, "include_granted_scopes") == nil && query(consent, "login_hint") == h.email)
    #expect(h.http.requests.map { $0.url.path() } == ["/token"], "the token endpoint only: no Gmail call, no calendar call")
    var states = calendar.connectionStates().makeAsyncIterator()
    let state = await states.next()
    #expect(state?.status == .connected && state?.needsRestart == false && state?.canCreateEvents == true)
}

@MainActor
@Test func aCalendarConnectedWhileTheSessionRunsIsUsedAtOnce() async throws {
    let h = try CalendarHarness()
    let path = "/calendar/v3/calendars/robin@example.com/events"
    h.http.on("GET", path) { _ in
        FakeHTTPTransport.json(200, ["items": [["id": "ev1", "summary": "Standup",
                                                "start": ["dateTime": "2026-10-14T14:00:00Z"],
                                                "end": ["dateTime": "2026-10-14T14:30:00Z"]]]])
    }
    let session = try await h.session()
    let window = try #require(session.environment.calendar)
    let calendar = try #require(session.calendar)
    #expect(session.environment.modules.modules.contains(.calendar))
    let day = Date(timeIntervalSince1970: 1_791_000_000)
    await #expect(throws: CalendarError.notConfigured) { _ = try await window.events(from: day, to: day.addingTimeInterval(86_400)) }
    #expect(h.http.requests.isEmpty, "nothing connected: nothing contacted")

    try await calendar.connect()
    #expect(window.info.account == h.email && window.info.createRefusal == nil, "a write grant")
    #expect(try await window.events(from: day, to: day.addingTimeInterval(86_400)).map(\.title) == ["Standup"])
    let account = Account(id: h.account.id, email: h.email, displayName: nil, alias: nil, health: .active)
    #expect(session.environment.calendarConnections?.calendarProvider(for: account) != nil, "the sidebar's calendar too")

    var states = calendar.connectionStates().makeAsyncIterator()
    let connected = try #require(await states.next())
    #expect(connected.status == .connected && !connected.needsRestart && connected.canCreateEvents)
    #expect(Set(connected.scopes.map(CalendarConnectionState.scopeName)) == ["calendar.events", "calendar.freebusy"])
    #expect(connected.lastFetch != nil && connected.lastFetchError == nil && connected.lastRefreshed != nil)

    h.http.on("GET", path) { _ in FakeHTTPTransport.json(404, ["error": ["code": 404, "message": "Not Found"]]) }
    await #expect(throws: CalendarError.self) { _ = try await window.events(from: day, to: day.addingTimeInterval(86_400)) }
    var after = calendar.connectionStates().makeAsyncIterator()
    #expect(await after.next()?.lastFetchError == "not_found")

    let label = h.backend.accounts.calendarLogLabel(email: h.email)
    #expect(label == "account \(h.account.id.rawValue)")
    #expect(h.backend.accounts.calendarLogLabel(email: "nobody@example.net") == "an account")
    let connectLine = GoogleCalendarSession.connectLine(label, scopes: writeScopes)
    #expect(connectLine == "\(label): calendar connected (scopes calendar.events calendar.freebusy); used now, no relaunch")
    let read = CalendarFetchRecord(kind: .events, from: day, to: day.addingTimeInterval(86_400), duration: .milliseconds(182),
                                   count: 3, failure: nil)
    #expect(GoogleCalendarSession.fetchLine(label, read)
                == "\(label): events \(day.formatted(.iso8601)) +24h: 3 in 182 ms")
    let failed = CalendarFetchRecord(kind: .freeBusy, from: day, to: day.addingTimeInterval(86_400),
                                     duration: .milliseconds(90), count: nil, failure: "server_503")
    #expect(GoogleCalendarSession.fetchLine(label, failed).hasSuffix("freeBusy \(day.formatted(.iso8601)) +24h failed (server_503) after 90 ms"))
    for line in [connectLine, GoogleCalendarSession.fetchLine(label, read), GoogleCalendarSession.fetchLine(label, failed)] {
        #expect(!line.contains(h.email) && !line.contains("@") && !line.contains("synthetic") && Log.redact(line) == line)
    }

    try await calendar.disconnect()
    #expect(window.info.account == nil)
    #expect(session.environment.calendarConnections?.calendarProvider(for: account) == nil)
    await #expect(throws: CalendarError.notConfigured) { _ = try await window.events(from: day, to: day.addingTimeInterval(86_400)) }
}

@MainActor
@Test func aConsentCarryingAGmailScopeStoresNothing() async throws {
    for extra in [GmailScope.readonly, GmailScope.modify, "https://mail.google.com/"] {
        let h = try CalendarHarness(grants: writeScopes + [extra])
        let calendar = try #require(try await h.session().calendar)
        await #expect(throws: CalendarError.self, "\(extra)") { try await calendar.connect() }
        #expect(try h.calendarTokens.load(account: h.email) == nil, "nothing was stored")
        #expect(try h.mailTokens.load(account: h.email) == h.mailToken)
    }
}

@MainActor
@Test func disconnectAndSignOutDeleteOnlyTheCalendarItem() async throws {
    let h = try CalendarHarness()
    try h.storeCalendarToken(readScopes)
    let session = try await h.session()
    try await #require(session.calendar).disconnect()
    #expect(try h.calendarTokens.load(account: h.email) == nil)
    #expect(try h.mailTokens.load(account: h.email) == h.mailToken, "disconnecting the calendar keeps Gmail signed in")
    #expect(h.http.requests.isEmpty, "never contacts Google (nothing is revoked)")

    try h.storeCalendarToken(readScopes)
    try await h.backend.accounts.remove(h.account.id)
    #expect(try h.calendarTokens.load(account: h.email) == nil, "sign-out takes the calendar token too")
    #expect(try h.mailTokens.load(account: h.email) == nil)
    #expect(h.http.requests.isEmpty)
}

@MainActor
@Test func theProviderReadsAndNeverWritesWithAReadGrant() async throws {
    let h = try CalendarHarness()
    try h.storeCalendarToken(readScopes)
    h.http.on("GET", "/calendar/v3/calendars/robin@example.com/events") { _ in
        FakeHTTPTransport.json(200, ["items": [["id": "ev1", "summary": "Standup",
                                                "start": ["dateTime": "2026-10-14T14:00:00Z"],
                                                "end": ["dateTime": "2026-10-14T14:30:00Z"]]]])
    }
    let provider = try #require(try await h.session().environment.calendar)
    let day = Date(timeIntervalSince1970: 1_791_000_000)
    let events = try await provider.events(from: day, to: day.addingTimeInterval(86_400))
    #expect(events.map(\.title) == ["Standup"])
    let draft = CalendarEventDraft(title: "Lunch", start: day, end: day.addingTimeInterval(1_800), timeZone: "UTC",
                                   attendees: [EmailAddress(email: "alice@example.com")], sendUpdates: .all,
                                   addMeetLink: true)
    await #expect(throws: CalendarError.self) { _ = try await provider.createEvent(draft) }
    await #expect(throws: CalendarError.self) { try await provider.deleteEvent(events[0]) }
    #expect(h.http.requests.allSatisfy { $0.method == "GET" }, "a read grant: only reads left the process")
}

@MainActor
@Test func aWriteGrantCreatesWithMeetAndTheUndoDeletes() async throws {
    let h = try CalendarHarness()
    try h.storeCalendarToken(writeScopes)
    let path = "/calendar/v3/calendars/robin@example.com/events"
    h.http.on("POST", path) { _ in
        FakeHTTPTransport.json(200, ["id": "made1", "summary": "Lunch", "start": ["dateTime": "2026-10-14T14:00:00Z"],
                                     "end": ["dateTime": "2026-10-14T14:30:00Z"],
                                     "conferenceData": ["conferenceSolution": ["key": ["type": "hangoutsMeet"]],
                                                        "entryPoints": [["entryPointType": "video",
                                                                         "uri": "https://meet.google.com/xyz"]]]])
    }
    h.http.on("DELETE", path + "/made1") { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
    let provider = try #require(try await h.session().environment.calendar)
    #expect(provider.info.createRefusal == nil)
    let day = Date(timeIntervalSince1970: 1_791_000_000)
    let draft = CalendarEventDraft(title: "Lunch", start: day, end: day.addingTimeInterval(1_800), timeZone: "UTC",
                                   addMeetLink: true)
    let created = try await provider.createEvent(draft)
    #expect(created.id == "made1" && created.meetLink == URL(string: "https://meet.google.com/xyz"))
    let insert = try #require(h.http.requests.last)
    #expect(query(insert.url, "conferenceDataVersion") == "1" && query(insert.url, "sendUpdates") == "none")
    try await provider.deleteEvent(created)
    #expect(h.http.requests.last?.method == "DELETE")
    let before = h.http.requests.count
    await #expect(throws: CalendarError.self) {
        try await provider.deleteEvent(CalendarEvent(id: "someone-elses", title: "x", start: day, end: day))
    }
    #expect(h.http.requests.count == before)
}

@MainActor
@Test func attendeeEventsAreNeverDeletedAndLostAnswersAreUnclear() async throws {
    let h = try CalendarHarness()
    try h.storeCalendarToken(writeScopes)
    let path = "/calendar/v3/calendars/robin@example.com/events"
    h.http.on("POST", path) { _ in
        FakeHTTPTransport.json(200, ["id": "made1", "summary": "Lunch", "start": ["dateTime": "2026-10-14T14:00:00Z"],
                                     "end": ["dateTime": "2026-10-14T14:30:00Z"],
                                     "attendees": [["email": "alice@example.com"]]])
    }
    let provider = try #require(try await h.session().environment.calendar)
    let day = Date(timeIntervalSince1970: 1_791_000_000)
    let draft = CalendarEventDraft(title: "Lunch", start: day, end: day.addingTimeInterval(1_800), timeZone: "UTC",
                                   attendees: [EmailAddress(email: "alice@example.com")])
    let created = try await provider.createEvent(draft)
    let before = h.http.requests.count
    await #expect(throws: CalendarError.self) { try await provider.deleteEvent(created) }
    #expect(h.http.requests.count == before, "never deleted: it may have emailed alice")

    h.http.on("POST", path) { _ in FakeHTTPTransport.json(503, ["error": ["code": 503]]) }
    do {
        _ = try await provider.createEvent(draft)
        Issue.record("a 503 insert counted as created")
    } catch CalendarError.unclear {
    } catch {
        Issue.record("a 503 insert is unclear, not \(error)")
    }
    #expect(h.http.requests.filter { $0.method == "POST" && $0.url.path().hasSuffix("/events") }.count == 2,
            "the unclear insert is sent once")
}

@MainActor
@Test func aFailedCalendarDeleteLeavesTheAccountToSignOutAgain() async throws {
    let store = UndeletableTokenStore()
    let h = try CalendarHarness(calendarStore: store)
    await #expect(throws: (any Error).self) { try await h.backend.accounts.remove(h.account.id) }
    #expect(try h.store.accounts().contains { $0.id == h.account.id }, "the account is still here")
    #expect(try h.mailTokens.load(account: h.email) == h.mailToken)
}

@MainActor
@Test func fakeRunsNeverReachGoogleCalendar() async throws {
    #expect(CompositionRoot.liveCalendarTokenStore(arguments: ["-UseFakeCalendar"]) == nil)
    #expect(CompositionRoot.liveCalendarTokenStore(arguments: []) != nil)
    #expect(CompositionRoot.fakeCalendar(arguments: ["-UseFakeData", "-UseFakeCalendar"])?.info.isSample == true)
    let h = try CalendarHarness()
    let plain = LiveBackend(
        store: h.store,
        accountDependencies: LiveAccountManager.Dependencies(
            environment: ["OPENHUMAN_OAUTH_CLIENT_JSON": try SyntheticClient.writeJSON()],
            storeDirectory: h.directory.appendingPathComponent("none"), tokenStore: h.mailTokens,
            transport: h.http, makeReceiver: { AnsweringReceiver(browser: RecordingBrowser()) }, browser: RecordingBrowser(),
            clock: SystemClock(), developerClientFile: BuildFlavor.oauthClientFile),
        transports: LiveBackend.Transports(api: h.http, token: h.http),
        userAgent: "OpenHumanMail/test", pollInterval: .seconds(3600), makeSystemEvents: { AppSystemEvents.quiet() })
    let session = try await plain.makeSession(for: h.account)
    #expect(session.calendar == nil && session.environment.calendarConnection == nil && session.environment.calendar == nil)
}

@MainActor
@Test func aSecondInboxsCalendarIsItsOwnAndAFailureLeavesGmailAlone() async throws {
    let otherEmail = "sam@example.org"
    func secondInbox(_ h: CalendarHarness) throws -> (Account, StoredToken) {
        let id = try h.store.addAccount(email: otherEmail, displayName: nil, scopes: [GmailScope.modify])
        let token = StoredToken(refreshToken: "synthetic-refresh-mail-2", grantedScopes: [GmailScope.modify],
                                clientID: SyntheticClient.clientID)
        try h.mailTokens.save(token, account: otherEmail)
        return (Account(id: id, email: otherEmail, displayName: nil, alias: nil, health: .active), token)
    }

    do {
        let h = try CalendarHarness(grants: writeScopes + [GmailScope.modify])
        let (other, otherMail) = try secondInbox(h)
        let session = try await h.session()
        let connections = try #require(session.environment.calendarConnections)
        let own = try #require(connections.calendarConnection(for: Account(id: h.account.id, email: h.email,
                                                                           displayName: nil, alias: nil, health: .active)))
        #expect((own as? LiveInboxCalendar)?.primary === session.calendar, "the window's inbox: the same switch")
        let connection = try #require(connections.calendarConnection(for: other))
        #expect((connection as? LiveInboxCalendar)?.primary !== session.calendar)
        await #expect(throws: CalendarError.self) { try await connection.connect() }
        #expect(try h.calendarTokens.load(account: otherEmail) == nil, "nothing was stored")
        #expect(try h.mailTokens.load(account: otherEmail) == otherMail, "the inbox's Gmail token is untouched")
        #expect(try h.mailTokens.load(account: h.email) == h.mailToken)
        await #expect(throws: CalendarError.self) { try await connection.connect(client: "not-a-known-client") }
    }

    do {
        let h = try CalendarHarness()
        let (other, otherMail) = try secondInbox(h)
        let session = try await h.session()
        let connection = try #require(session.environment.calendarConnections?.calendarConnection(for: other))
        try await connection.connect(client: nil)
        let stored = try #require(try h.calendarTokens.load(account: otherEmail))
        #expect(stored.grantedScopes == writeScopes && stored.clientID == SyntheticClient.clientID)
        #expect(try h.calendarTokens.load(account: h.email) == nil, "the window's inbox is not connected by it")
        #expect(try h.mailTokens.load(account: otherEmail) == otherMail && h.mailTokens.load(account: h.email) == h.mailToken)
        let consent = try #require(h.browser.urls.last)
        #expect(query(consent, "scope") == writeScopes.joined(separator: " "))
        #expect(query(consent, "include_granted_scopes") == nil && query(consent, "login_hint") == otherEmail)
        #expect(h.http.requests.map { $0.url.path() } == ["/token"], "the token endpoint only")
        var states = connection.connectionStates().makeAsyncIterator()
        #expect(await states.next()?.status == .connected)

        try await h.backend.accounts.remove(other.id)
        #expect(try h.calendarTokens.load(account: otherEmail) == nil)
    }
}

@MainActor
@Test func theProviderMovesOnlyOwnEventsAndOnlyWithAWriteGrant() async throws {
    let path = "/calendar/v3/calendars/robin@example.com/events/ev1"
    let day = Date(timeIntervalSince1970: 1_791_000_000)
    let mine = CalendarEvent(id: "ev1", title: "Standup", start: day, end: day.addingTimeInterval(1_800), timeZone: "UTC",
                             organizerIsMe: true)
    let newStart = day.addingTimeInterval(3_600)

    do {
        let h = try CalendarHarness()
        try h.storeCalendarToken(readScopes)
        let provider = try #require(try await h.session().environment.calendar)
        await #expect(throws: CalendarError.self) {
            _ = try await provider.moveEvent(mine, to: newStart, end: newStart.addingTimeInterval(1_800), sendUpdates: .all)
        }
        #expect(!h.http.requests.contains { $0.method == "PATCH" }, "a read grant: no move left the process")
    }

    let h = try CalendarHarness()
    try h.storeCalendarToken(writeScopes)
    h.http.on("PATCH", path) { _ in
        FakeHTTPTransport.json(200, ["id": "ev1", "summary": "Standup", "start": ["dateTime": "2026-10-14T15:00:00Z"],
                                     "end": ["dateTime": "2026-10-14T15:30:00Z"], "organizer": ["self": true]])
    }
    let provider = try #require(try await h.session().environment.calendar)
    let moved = try await provider.moveEvent(mine, to: newStart, end: newStart.addingTimeInterval(1_800), sendUpdates: .all)
    #expect(moved.id == "ev1" && moved.organizerIsMe == true)
    let patch = try #require(h.http.requests.last)
    #expect(patch.method == "PATCH" && patch.url.path() == path)
    #expect(query(patch.url, "sendUpdates") == "all")
    let body = try #require(patch.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    #expect(Set(body.keys) == ["start", "end"], "only the times are sent")

    let before = h.http.requests.count
    let theirs = CalendarEvent(id: "ev2", title: "Review", start: day, end: day.addingTimeInterval(1_800),
                               attendees: [EmailAddress(email: "dana@example.org")], organizerIsMe: false)
    await #expect(throws: CalendarError.self) {
        _ = try await provider.moveEvent(theirs, to: newStart, end: newStart.addingTimeInterval(1_800), sendUpdates: .none)
    }
    #expect(h.http.requests.count == before, "someone else's meeting: nothing sent")

    h.http.on("PATCH", path) { _ in FakeHTTPTransport.json(503, ["error": ["code": 503]]) }
    do {
        _ = try await provider.moveEvent(mine, to: newStart, end: newStart.addingTimeInterval(1_800), sendUpdates: .none)
        Issue.record("a 503 move counted as moved")
    } catch CalendarError.unclear {
    } catch {
        Issue.record("a 503 move is unclear, not \(error)")
    }
    #expect(h.http.requests.filter { $0.method == "PATCH" }.count == 2, "the unclear move is sent once")
}

@MainActor
@Test func theProviderAnswersInvitationsOnlyWithAWriteGrantAndMapsTheAnswer() async throws {
    let path = "/calendar/v3/calendars/robin@example.com/events/ev7"
    let day = Date(timeIntervalSince1970: 1_791_000_000)
    let invite = CalendarEvent(id: "ev7", title: "Review", start: day, end: day.addingTimeInterval(1_800), timeZone: "UTC",
                               attendees: [EmailAddress(email: "dana@example.org"), EmailAddress(email: "robin@example.com")],
                               organizerIsMe: false, myResponse: .needsAction)
    @Sendable func invited() -> [[String: Any]] {
        [["email": "dana@example.org", "organizer": true, "responseStatus": "accepted"],
         ["email": "robin@example.com", "self": true, "responseStatus": "needsAction"]]
    }
    @Sendable func answered() -> [String: Any] {
        ["id": "ev7", "summary": "Review", "start": ["dateTime": "2026-10-14T15:00:00Z"],
         "end": ["dateTime": "2026-10-14T15:30:00Z"], "organizer": ["self": false],
         "attendees": [invited()[0], ["email": "robin@example.com", "self": true, "responseStatus": "accepted"]]]
    }
    let attendees = invited()

    do {
        let h = try CalendarHarness()
        try h.storeCalendarToken(readScopes)
        let provider = try #require(try await h.session().environment.calendar)
        #expect(provider.abilities == [.respond, .remove, .editFull, .removeMeet, .removeInvite],
                "answers, removing an event the user organizes or an invitation's copy, the full edit form and removing a Meet link")
        await #expect(throws: CalendarError.self) {
            _ = try await provider.respond(to: invite, with: .accepted, sendUpdates: .all)
        }
        #expect(!h.http.requests.contains { $0.method == "PATCH" }, "a read grant: no answer left the process")
    }

    let h = try CalendarHarness()
    try h.storeCalendarToken(writeScopes)
    h.http.on("GET", path) { _ in
        FakeHTTPTransport.json(200, ["id": "ev7", "summary": "Review", "start": ["dateTime": "2026-10-14T15:00:00Z"],
                                     "end": ["dateTime": "2026-10-14T15:30:00Z"], "attendees": invited()])
    }
    h.http.on("PATCH", path) { _ in FakeHTTPTransport.json(200, answered()) }
    let provider = try #require(try await h.session().environment.calendar)
    let result = try await provider.respond(to: invite, with: .accepted, sendUpdates: .all)
    #expect(result.myResponse == .accepted && result.organizerIsMe == false)
    let patch = try #require(h.http.requests.last)
    #expect(patch.method == "PATCH" && patch.url.path() == path && query(patch.url, "sendUpdates") == "all")
    let body = try #require(patch.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    #expect(Set(body.keys) == ["attendees"], "only the attendee list is sent")
    let sent = try #require(body["attendees"] as? [[String: Any]])
    #expect(sent.count == 2 && NSDictionary(dictionary: sent[0]).isEqual(to: attendees[0]), "the organizer's entry as read")
    #expect(sent[1]["responseStatus"] as? String == "accepted")

    let before = h.http.requests.count
    let mine = CalendarEvent(id: "ev8", title: "Standup", start: day, end: day.addingTimeInterval(1_800), organizerIsMe: true)
    await #expect(throws: CalendarError.self) { _ = try await provider.respond(to: mine, with: .declined, sendUpdates: .all) }
    #expect(h.http.requests.count == before)

    let mapped = GoogleCalendarProvider.event(GoogleCalendarEvent(
        id: "ev9", title: "Weekly", start: day, end: day.addingTimeInterval(1_800), organizerIsSelf: false,
        location: "Room 4", notes: "Agenda", recurringEventID: "series1", selfResponse: "tentative"))
    #expect(mapped.myResponse == .tentative && mapped.location == "Room 4" && mapped.notes == "Agenda")
    #expect(mapped.recurringEventID == "series1" && mapped.isRecurring && mapped.canRespond)
}

@MainActor
@Test func theProviderRemovesOnlyEventsTheAccountOrganizes() async throws {
    let path = "/calendar/v3/calendars/robin@example.com/events/ev5"
    let day = Date(timeIntervalSince1970: 1_791_000_000)
    let mine = CalendarEvent(id: "ev5", title: "Planning", start: day, end: day.addingTimeInterval(1_800), timeZone: "UTC",
                             organizerIsMe: true)

    do {
        let h = try CalendarHarness()
        try h.storeCalendarToken(readScopes)
        let provider = try #require(try await h.session().environment.calendar)
        await #expect(throws: CalendarError.self) { try await provider.removeEvent(mine, sendUpdates: .none) }
        #expect(h.http.requests.filter { $0.url.path() == path }.isEmpty, "a read grant: nothing about the event was asked")
    }

    let h = try CalendarHarness()
    try h.storeCalendarToken(writeScopes)
    h.http.on("GET", path) { _ in
        FakeHTTPTransport.json(200, ["id": "ev5", "summary": "Planning", "start": ["dateTime": "2026-10-14T15:00:00Z"],
                                     "end": ["dateTime": "2026-10-14T15:30:00Z"], "organizer": ["email": "robin@example.com", "self": true]])
    }
    h.http.on("DELETE", path) { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
    let provider = try #require(try await h.session().environment.calendar)
    try await provider.removeEvent(mine, sendUpdates: .none)
    let methods = h.http.requests.filter { $0.url.path() == path }.map(\.method)
    #expect(methods == ["GET", "DELETE"], "the guard read the event, then it was deleted")
    let delete = try #require(h.http.requests.last)
    #expect(query(delete.url, "sendUpdates") == "none")
    #expect(delete.headers[CalendarGuardTransport.removalRuleHeader] == nil, "the marker never leaves the guard")

    let before = h.http.requests.count
    let invited = CalendarEvent(id: "ev5", title: "Planning", start: day, end: day.addingTimeInterval(1_800), timeZone: "UTC",
                                organizerIsMe: false)
    await #expect(throws: CalendarError.self) { try await provider.removeEvent(invited, sendUpdates: .all) }
    let repeating = CalendarEvent(id: "ev5", title: "Planning", start: day, end: day.addingTimeInterval(1_800), timeZone: "UTC",
                                  organizerIsMe: true, recurringEventID: "series1")
    await #expect(throws: CalendarError.self) { try await provider.removeEvent(repeating, sendUpdates: .none) }
    #expect(h.http.requests.count == before)

    let other = try CalendarHarness()
    try other.storeCalendarToken(writeScopes)
    other.http.on("GET", path) { _ in
        FakeHTTPTransport.json(200, ["id": "ev5", "organizer": ["email": "pat@example.org"],
                                     "start": ["dateTime": "2026-10-14T15:00:00Z"], "end": ["dateTime": "2026-10-14T15:30:00Z"]])
    }
    other.http.on("DELETE", path) { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
    let strict = try #require(try await other.session().environment.calendar)
    await #expect(throws: CalendarError.self) { try await strict.removeEvent(mine, sendUpdates: .none) }
    #expect(!other.http.requests.contains { $0.method == "DELETE" })
}



@MainActor
@Test func theProviderSavesAThisAllOrThisAndFollowingChange() async throws {
    let events = "/calendar/v3/calendars/robin@example.com/events"
    let iso = ISO8601DateFormatter()
    let day = Date(timeIntervalSince1970: 1_791_000_000)
    let first = day.addingTimeInterval(-7 * 86_400)
    let instance = CalendarEvent(id: "inst1", title: "Weekly", start: day, end: day.addingTimeInterval(1_800), timeZone: "UTC",
                                 organizerIsMe: true, recurringEventID: "series1")
    func wire(_ id: String, _ start: Date, rules: [String] = []) -> [String: Any] {
        var out: [String: Any] = ["id": id, "summary": "Weekly", "start": ["dateTime": iso.string(from: start), "timeZone": "UTC"],
                                  "end": ["dateTime": iso.string(from: start.addingTimeInterval(1_800)), "timeZone": "UTC"],
                                  "organizer": ["email": "robin@example.com", "self": true]]
        if !rules.isEmpty { out["recurrence"] = rules }
        return out
    }
    func body(_ request: HTTPRequest?) -> [String: Any] {
        request?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    var retitle = CalendarEventPatch()
    retitle.title = "Retitled"

    do {
        let h = try CalendarHarness()
        try h.storeCalendarToken(readScopes)
        let provider = try #require(try await h.session().environment.calendar)
        await #expect(throws: CalendarError.self) {
            _ = try await provider.patchEvent(instance, with: retitle, scope: .thisEvent, sendUpdates: .none)
        }
        #expect(!h.http.requests.contains { $0.url.path().hasPrefix(events) }, "a read grant: nothing about the event was sent")
    }

    let h = try CalendarHarness()
    try h.storeCalendarToken(writeScopes)
    let patchedInstance = FakeHTTPTransport.json(200, wire("inst1", day))
    let series = FakeHTTPTransport.json(200, wire("series1", first, rules: ["RRULE:FREQ=WEEKLY;UNTIL=20271231T000000Z"]))
    let patchedSeries = FakeHTTPTransport.json(200, wire("series1", first))
    let made = FakeHTTPTransport.json(200, wire("new1", day, rules: ["RRULE:FREQ=WEEKLY"]))
    h.http.on("PATCH", events + "/inst1") { _ in patchedInstance }
    h.http.on("GET", events + "/series1") { _ in series }
    h.http.on("PATCH", events + "/series1") { _ in patchedSeries }
    h.http.on("POST", events) { _ in made }
    let provider = try #require(try await h.session().environment.calendar)
    func sent(after count: Int) -> [HTTPRequest] { Array(h.http.requests.dropFirst(count)).filter { $0.url.path().hasPrefix(events) } }

    var before = h.http.requests.count
    _ = try await provider.patchEvent(instance, with: retitle, scope: .thisEvent, sendUpdates: .none)
    var calls = sent(after: before)
    #expect(calls.map(\.method) == ["PATCH"] && calls.first?.url.path() == events + "/inst1")
    #expect(body(calls.first).keys.sorted() == ["summary"] && query(calls.first?.url, "sendUpdates") == "none")
    #expect(calls.first?.headers[CalendarGuardTransport.editRuleHeader] == nil, "the edit header never leaves the guard")

    var later = CalendarEventPatch()
    later.time = CalendarTimeChange(start: day.addingTimeInterval(3_600), end: day.addingTimeInterval(5_400), isAllDay: false,
                                    timeZone: "UTC")
    before = h.http.requests.count
    _ = try await provider.patchEvent(instance, with: later, scope: .allEvents, sendUpdates: .all)
    calls = sent(after: before)
    #expect(calls.map(\.method) == ["GET", "PATCH"] && calls.last?.url.path() == events + "/series1")
    let start = (body(calls.last)["start"] as? [String: Any])?["dateTime"] as? String
    #expect(start.flatMap { iso.date(from: $0) } == first.addingTimeInterval(3_600))
    #expect(query(calls.last?.url, "sendUpdates") == "all")

    before = h.http.requests.count
    _ = try await provider.patchEvent(instance, with: retitle, scope: .thisAndFollowing, sendUpdates: .none)
    calls = sent(after: before)
    #expect(calls.map(\.method) == ["GET", "GET", "POST", "PATCH"], "the rule, then the series itself for what the new events carry over")
    #expect(body(calls[2])["summary"] as? String == "Retitled" && body(calls[2])["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY;UNTIL=20271231T000000Z"])
    let cut = body(calls.last)["recurrence"] as? [String] ?? []
    #expect(calls.last?.url.path() == events + "/series1" && body(calls.last).keys.sorted() == ["recurrence"])
    #expect(cut.count == 1 && cut[0].contains("UNTIL=") && !cut[0].contains("COUNT="), "the old series ends before this one")
}

@MainActor
@Test func aSeriesThatEndsAfterACountIsNotSplit() async throws {
    let events = "/calendar/v3/calendars/robin@example.com/events"
    let iso = ISO8601DateFormatter()
    let day = Date(timeIntervalSince1970: 1_791_000_000)
    let first = day.addingTimeInterval(-7 * 86_400)
    let instance = CalendarEvent(id: "inst1", title: "Weekly", start: day, end: day.addingTimeInterval(1_800), timeZone: "UTC",
                                 organizerIsMe: true, recurringEventID: "series1")
    func wire(_ id: String, _ start: Date, rules: [String] = []) -> [String: Any] {
        var out: [String: Any] = ["id": id, "summary": "Weekly", "start": ["dateTime": iso.string(from: start), "timeZone": "UTC"],
                                  "end": ["dateTime": iso.string(from: start.addingTimeInterval(1_800)), "timeZone": "UTC"],
                                  "organizer": ["email": "robin@example.com", "self": true]]
        if !rules.isEmpty { out["recurrence"] = rules }
        return out
    }
    var retitle = CalendarEventPatch()
    retitle.title = "Retitled"
    let h = try CalendarHarness()
    try h.storeCalendarToken(writeScopes)
    let series = FakeHTTPTransport.json(200, wire("series1", first, rules: ["RRULE:FREQ=WEEKLY;COUNT=10"]))
    h.http.on("GET", events + "/series1") { _ in series }
    let provider = try #require(try await h.session().environment.calendar)
    do {
        _ = try await provider.patchEvent(instance, with: retitle, scope: .thisAndFollowing, sendUpdates: .none)
        Issue.record("a counted series must refuse a split")
    } catch CalendarError.refused(let why) {
        #expect(why.contains("set number of times") && why.contains("Change this event or all events"))
    }
    #expect(h.http.requests.filter { $0.method != "GET" && $0.url.path().hasPrefix(events) }.isEmpty)
}

@MainActor
@Test func recurringRemovalScopesReachTheWiredProviderWithoutChangingLegacyEditing() async throws {
    let path = "/calendar/v3/calendars/robin@example.com/events"
    let day = ISO8601DateFormatter().date(from: "2026-11-01T17:00:00Z")!
    for scope in CalendarRecurrenceScope.removalOptions {
        let h = try CalendarHarness()
        try h.storeCalendarToken(writeScopes)
        let instance = FakeHTTPTransport.json(200, ["id": "instance", "etag": "\"instance-v1\"", "organizer": ["self": true],
            "start": ["dateTime": "2026-11-01T17:00:00Z", "timeZone": "America/Los_Angeles"],
            "end": ["dateTime": "2026-11-01T18:00:00Z", "timeZone": "America/Los_Angeles"], "recurringEventId": "master",
            "originalStartTime": ["dateTime": "2026-11-01T17:00:00Z", "timeZone": "America/Los_Angeles"]])
        let master = FakeHTTPTransport.json(200, ["id": "master", "etag": "\"master-v1\"", "organizer": ["self": true],
            "start": ["dateTime": "2026-10-25T16:00:00Z", "timeZone": "America/Los_Angeles"],
            "end": ["dateTime": "2026-10-25T17:00:00Z", "timeZone": "America/Los_Angeles"], "recurrence": ["RRULE:FREQ=WEEKLY;COUNT=3"]])
        h.http.on("GET", path) { _ in FakeHTTPTransport.json(200, ["items": []]) }
        h.http.on("GET", path + "/instance") { _ in instance }
        h.http.on("GET", path + "/master") { _ in master }
        h.http.on("PATCH", path) { _ in master }
        h.http.on("DELETE", path) { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
        let provider = try #require(try await h.session().environment.calendar)
        #expect(provider.removalScopes == [.thisEvent, .allEvents, .thisAndFollowing])
        let event = CalendarEvent(id: "instance", title: "Weekly", start: day, end: day.addingTimeInterval(3600),
                                  organizerIsMe: true, recurringEventID: "master")
        let result = try await provider.removeEvent(event, scope: scope, sendUpdates: .none)
        #expect(result.parentID == "master" && result.originalCutoff == .timed(day, timeZone: "America/Los_Angeles"))
        let writes = h.http.requests.filter { ["PATCH", "DELETE", "POST"].contains($0.method) && $0.url.path().hasPrefix(path) }
        #expect(writes.count == 1 && writes[0].method == (scope == .thisAndFollowing ? "PATCH" : "DELETE"))
        #expect(writes[0].url.path().hasSuffix(scope == .thisEvent ? "/instance" : "/master"))
        #expect(query(writes[0].url, "sendUpdates") == "all" && writes[0].headers["If-Match"] != nil)
    }
}

@MainActor
@Test func anInvitationLeavesTheWiredCalendarWithASilentGuestDelete() async throws {
    let path = "/calendar/v3/calendars/robin@example.com/events"
    let day = ISO8601DateFormatter().date(from: "2026-11-01T17:00:00Z")!
    let h = try CalendarHarness()
    try h.storeCalendarToken(writeScopes)
    let invited = FakeHTTPTransport.json(200, ["id": "invited", "etag": "\"invited-v1\"",
        "organizer": ["email": "sam@example.org"],
        "attendees": [["email": "sam@example.org", "organizer": true], ["email": "robin@example.com", "self": true]],
        "start": ["dateTime": "2026-11-01T17:00:00Z", "timeZone": "America/Los_Angeles"],
        "end": ["dateTime": "2026-11-01T18:00:00Z", "timeZone": "America/Los_Angeles"]])
    h.http.on("GET", path + "/invited") { _ in invited }
    h.http.on("DELETE", path) { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
    let provider = try #require(try await h.session().environment.calendar)
    #expect(provider.abilities.contains(.removeInvite))
    let event = CalendarEvent(id: "invited", title: "Supplier sync", start: day, end: day.addingTimeInterval(3600),
                              attendees: [EmailAddress(email: "sam@example.org")], organizerIsMe: false,
                              myResponse: .needsAction)
    let result = try await provider.removeEvent(event, scope: .thisEvent, sendUpdates: .none)
    #expect(result.selectedID == "invited" && result.parentID == nil)
    let writes = h.http.requests.filter { ["PATCH", "DELETE", "POST"].contains($0.method) && $0.url.path().hasPrefix(path) }
    #expect(writes.count == 1 && writes[0].method == "DELETE" && writes[0].url.path().hasSuffix("/invited"))
    #expect(query(writes[0].url, "sendUpdates") == "none" && writes[0].headers["If-Match"] == "\"invited-v1\"")
}

@Suite struct GoogleCalendarFullEditMappingTests {
    @Test func theFormsPatchBecomesGooglesPatch() {
        var patch = CalendarEventPatch()
        patch.title = "Planning"
        patch.guests = [CalendarGuest(email: "sam@example.org", name: "Sam Rivera", isOptional: true)]
        patch.permissions = CalendarGuestPermissions(canModify: true, canInviteOthers: false, canSeeGuestList: true)
        patch.reminders = .custom([CalendarReminder(method: .email, minutesBefore: 60)])
        patch.busy = .free
        patch.visibility = .private
        patch.colorID = ""
        patch.meet = .add
        patch.recurrence = ["RRULE:FREQ=DAILY"]
        let google = GoogleCalendarProvider.googlePatch(patch)
        #expect(google.title == "Planning" && google.meet == .add)
        #expect(google.guests == [GoogleGuestEdit(email: "sam@example.org", name: "Sam Rivera", isOptional: true)])
        #expect(google.details.guestsCanModify == true && google.details.guestsCanInviteOthers == false)
        #expect(google.details.useDefaultReminders == false && google.details.reminderOverrides == [GoogleReminder(method: "email", minutes: 60)])
        #expect(google.details.transparency == "transparent" && google.details.visibility == "private" && google.details.colorID == "")
        #expect(google.details.recurrence == ["RRULE:FREQ=DAILY"])
    }

    @Test func aNewEventSendsOnlyWhatDiffersFromGooglesDefaults() {
        #expect(GoogleCalendarProvider.insertDetails(CalendarEventExtras()) == GoogleEventDetails())
        var extras = CalendarEventExtras(permissions: CalendarGuestPermissions(canSeeGuestList: false))
        extras.busy = .free
        let details = GoogleCalendarProvider.insertDetails(extras)
        #expect(details.guestsCanSeeOtherGuests == false && details.transparency == "transparent" && details.visibility == nil)
    }

    @Test func whatGoogleReadsReachesTheForm() {
        var read = GoogleCalendarEvent(id: "ev1", title: "Planning", start: Date(timeIntervalSince1970: 1_800_000_000),
                                       end: Date(timeIntervalSince1970: 1_800_003_600), attendees: [
                                           GoogleCalendarAttendee(email: "sam@example.org", isOptional: true, responseStatus: "accepted")])
        read.extras.guestsCanModify = true
        read.extras.remindersUseDefault = false
        read.extras.reminderOverrides = [GoogleReminder(method: "popup", minutes: 15)]
        read.extras.transparency = "transparent"
        let shown = GoogleCalendarProvider.event(read)
        #expect(shown.extras.guests == [CalendarGuest(email: "sam@example.org", isOptional: true, response: .accepted, isOrganizer: nil)])
        #expect(shown.extras.permissions == CalendarGuestPermissions(canModify: true, canInviteOthers: true, canSeeGuestList: true))
        #expect(shown.extras.reminders == .custom([CalendarReminder(method: .popup, minutesBefore: 15)]) && shown.extras.busy == .free)
    }
}
