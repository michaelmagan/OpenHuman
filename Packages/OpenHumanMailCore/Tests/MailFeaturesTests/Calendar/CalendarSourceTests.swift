import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let newYork = TimeZone(identifier: "America/New_York")!

private func at(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    CalendarDateMentions.calendar(newYork).date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
}

private let sam = EmailAddress(name: "Sam Rivera", email: "sam@example.org")
private let alex = EmailAddress(email: "alex@example.net")
private let every = Set(CalendarFormField.allCases)
private let notKept: Set<CalendarFormField> = [.guests, .guestPermissions, .meet, .visibility, .color]

private func account(_ id: Int64, _ email: String) -> Account {
    Account(id: AccountID(id), email: email, displayName: nil, alias: nil, health: .active)
}

// Only the per-account calls, so the listing of window sources is the protocol's own
private struct AccountCalendars: CalendarConnectionsProviding {
    let calendars: [String: any CalendarProviding]
    func calendarConnection(for account: Account) -> (any CalendarConnecting)? { nil }
    func calendarProvider(for account: Account) -> (any CalendarProviding)? { calendars[account.email.lowercased()] }
    var routesByAccount: Bool { true }
}

@MainActor
private struct SourceFixture {
    static let familyKey = "family"
    let env: AppEnvironment
    let corpus: FakeCorpus
    let work: FakeCalendar
    let family: FakeCalendar

    var workEmail: String { corpus.account.email.lowercased() }

    init(work: [CalendarEvent] = [], family: [CalendarEvent] = [], workFields: Set<CalendarFormField> = every,
         workHonoursSendUpdates: Bool = true, cache: InMemoryCalendarCache? = nil) {
        corpus = FakeCorpus.make(threadCount: 3, now: at(10, 10, 9))
        let email = corpus.account.email
        self.work = FakeCalendar(events: work, info: CalendarProviderInfo(name: "Google Calendar", account: email),
                                 abilities: [.respond, .editDetails, .remove, .editFull], formFields: workFields,
                                 honoursSendUpdates: workHonoursSendUpdates)
        self.family = FakeCalendar(events: family, info: CalendarProviderInfo(name: "Family"))
        let shared = CalendarSource(key: Self.familyKey, title: "Family", provider: self.family)
        let connections = FakeCalendarConnections(connected: [email], providers: [email: self.work], windowAccount: email,
                                                  otherSources: [shared])
        env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), featureFlags: FeatureFlags(),
                                  calendarConnections: connections, calendarCache: cache)
    }

    var thread: ThreadKey {
        ThreadKey(account: corpus.account.id, rowID: 1, gmailThreadID: GmailThreadID("t\(corpus.account.id.rawValue)"))
    }

    func sidebar() -> CalendarSidebarModel {
        let model = env.calendarSidebar!
        model.timeZone = newYork
        model.now = { at(10, 10, 9) }
        model.loadText = { _ in CalendarThreadText(subject: "Planning", texts: ["Planning", "October 10, 2026 at 4:00 PM"],
                                                   participants: []) }
        return model
    }

    func window() -> CalendarWindowModel {
        let sidebar = env.calendarSidebar!
        sidebar.timeZone = newYork
        sidebar.now = { at(10, 12, 11) }
        let model = env.calendarWindow!
        model.timeZone = newYork
        model.firstWeekday = 1
        model.now = { at(10, 12, 11) }
        model.confirmsMovesOverride = false
        return model
    }
}

@Suite struct CalendarSourceListingTests {
    @Test func byDefaultEachAccountWithACalendarIsOneSourceInAccountOrder() throws {
        let work = FakeCalendar(info: CalendarProviderInfo(name: "Google Calendar", account: "robin@example.org"))
        let home = FakeCalendar(info: CalendarProviderInfo(name: "Google Calendar", account: "robin.home@example.org"))
        let accounts = [account(1, "Robin@Example.org"), account(2, "sam@example.net"), account(3, "robin.home@example.org")]
        let sources = AccountCalendars(calendars: ["robin@example.org": work, "robin.home@example.org": home])
            .windowSources(accounts: accounts)
        #expect(sources.map(\.key) == ["robin@example.org", "robin.home@example.org"], "an account without a calendar is left out")
        #expect(sources.map(\.title) == ["Robin@Example.org", "robin.home@example.org"], "the address as the account has it")
        #expect(sources.map(\.account) == [AccountID(1), AccountID(3)])
        let first = try #require(sources.first?.provider as? FakeCalendar)
        let last = try #require(sources.last?.provider as? FakeCalendar)
        #expect(first === work && last === home)

        let fake = FakeCalendarConnections(providers: ["robin@example.org": work, "robin.home@example.org": home])
        #expect(fake.windowSources(accounts: accounts).map(\.key) == sources.map(\.key), "the fake lists the same calendars")
    }

    @Test func aCalendarWithNoInboxHasNoAccountAndALowercasedKey() {
        let shared = CalendarSource(key: "Club-7F3A", title: "Club", provider: FakeCalendar())
        #expect(shared.key == "club-7f3a" && shared.title == "Club" && shared.account == nil)
        let fake = FakeCalendarConnections(providers: [:], otherSources: [shared])
        #expect(fake.windowSources(accounts: [account(1, "robin@example.org")]).map(\.key) == ["club-7f3a"])
    }
}

@MainActor
@Suite struct CalendarSourceWindowTests {
    @Test func aCalendarWithNoInboxIsDrawnBesideTheAccountsAndCanBeTickedOff() async throws {
        let f = SourceFixture(work: [CalendarEvent(id: "w1", title: "Standup", start: at(10, 13, 9), end: at(10, 13, 10))],
                              family: [CalendarEvent(id: "f1", title: "Piano lesson", start: at(10, 13, 17),
                                                     end: at(10, 13, 18))])
        let model = f.window()
        await model.open()
        #expect(model.sources.map(\.key) == [f.workEmail, SourceFixture.familyKey])
        #expect(model.sources.map(\.title) == [f.corpus.account.email, "Family"])
        #expect(model.sources.last?.colorIndex == CalendarDayTimeline.colorIndex(forCalendar: SourceFixture.familyKey))
        #expect(model.events.map(\.id) == ["w1", "f1"])
        #expect(model.events.map(\.account) == [f.workEmail, SourceFixture.familyKey], "each event carries its calendar's key")
        #expect(f.family.readCalls == 1)

        model.openEvent(try #require(model.events.last))
        #expect(model.card?.calendarKey == SourceFixture.familyKey && model.card?.canEditDetails == true,
                "the card writes to the family calendar, not to an account's")
        model.closeCard()

        await model.setVisible(SourceFixture.familyKey, false)
        #expect(model.events.map(\.id) == ["w1"])
        let reads = f.family.readCalls
        await model.move(by: 1)
        #expect(f.family.readCalls == reads, "a hidden calendar is not read")
        #expect(try await f.env.settings?.get(AppSettings.calendarHiddenCalendars) == [SourceFixture.familyKey])
    }

    @Test func theCardLeavesOutWhatItsCalendarCannotKeepAndAsksNothingAboutGuests() async throws {
        let meeting = CalendarEvent(id: "m1", title: "Planning", start: at(10, 13, 9), end: at(10, 13, 10),
                                    attendees: [sam], organizerIsMe: true)
        let google = SourceFixture(work: [meeting])
        let full = google.window()
        await full.open()
        full.openEvent(try #require(full.events.first))
        #expect(full.card?.rights.hidden.isEmpty == true, "a calendar with every field shows the whole form")
        full.card?.form?.setStart(at(10, 13, 15))
        #expect(full.asksSendUpdates(for: try #require(full.card)), "and asks whether to email the guests")

        let f = SourceFixture(work: [meeting], workFields: every.subtracting(notKept), workHonoursSendUpdates: false)
        let model = f.window()
        await model.open()
        model.openEvent(try #require(model.events.first))
        let card = try #require(model.card)
        #expect(card.form != nil && card.rights.hidden == notKept)
        #expect(!card.rights.shows(.meet) && card.rights.access(.meet) == .readOnly(CalendarFieldRights.unsupported))
        #expect(card.rights.access(.title) == .editable && card.rights.shows(.title))
        model.card?.form?.setStart(at(10, 13, 15))
        #expect(!model.asksSendUpdates(for: try #require(model.card)), "this calendar tells the guests itself")

        model.card?.form?.addGuest(alex)
        await model.saveCard()
        #expect(model.card?.note == CalendarFieldRights.unsupported, "a guest this calendar can't keep stops the save")
        #expect(!f.work.calls.contains { if case .patch = $0 { true } else { false } })
    }

    @Test func atLaunchTheCacheKeepsACalendarWithNoInboxAndDropsOneNoLongerListed() async throws {
        let familyKey = CalendarCacheKey(provider: CalendarProviderInfo(name: "Family"))
        let gone = CalendarCacheKey(account: "", calendar: "Old club")
        let range = CalendarCoveredRange(start: at(10, 5), end: at(10, 20), fetchedAt: at(10, 10, 8))
        func entry(_ key: CalendarCacheKey, _ id: String) -> CalendarCacheEntry {
            let record = CalendarEventRecord(event: CalendarEvent(id: id, title: "Lesson", start: at(10, 10, 12),
                                                                  end: at(10, 10, 13)), etag: "v1")
            return CalendarCacheEntry(key: key, records: [record], ranges: [range])
        }
        let cache = InMemoryCalendarCache(entries: [entry(familyKey, "f1"), entry(gone, "g1")])
        let f = SourceFixture(cache: cache)
        let store = f.env.calendarEvents
        await store.restore(now: at(10, 10, 9))
        #expect(Set(store.keys) == [familyKey, gone])
        f.env.startCalendarCache()
        await eventually { !store.keys.contains(gone) }
        #expect(!store.keys.contains(gone), "the launch never dropped the calendar that is no longer listed")
        #expect(store.keys.contains(familyKey), "the calendar with no inbox keeps what it has read")
    }
}

@MainActor
@Suite struct CalendarSourceSidebarTests {
    @Test func showAllAddsTheCalendarsWithNoInbox() async throws {
        let f = SourceFixture(work: [CalendarEvent(id: "w1", title: "Standup", start: at(10, 10, 10), end: at(10, 10, 10, 30))],
                              family: [CalendarEvent(id: "f1", title: "Piano lesson", start: at(10, 10, 12),
                                                     end: at(10, 10, 13))])
        let model = f.sidebar()
        model.setVisible(true)
        await model.show(thread: f.thread)
        #expect(model.days.flatMap(\.events).map(\.title) == ["Standup"], "a conversation shows its own account's calendar")
        #expect(f.family.readCalls == 0)
        await model.setShowAll(true)
        let events = model.days.flatMap(\.events)
        #expect(events.map(\.title) == ["Standup", "Piano lesson"])
        #expect(events.map(\.account) == [f.workEmail, SourceFixture.familyKey])
        let free = try #require(model.days.first?.free)
        #expect(!free.contains { $0.start < at(10, 10, 13) && $0.end > at(10, 10, 12) }, "the lesson blocks its hour")
    }

    @Test func aNewEventOffersOnlyWhatItsCalendarCanKeep() async throws {
        let google = SourceFixture()
        let full = google.sidebar()
        await full.beginDraft(for: google.thread)
        let draft = try #require(full.draft)
        #expect(full.draftRights == CalendarFieldRights.forNewEvent(refusal: full.createRefusal), "every field, as before")
        var alone = draft
        alone.setAttendees([])
        var invited = draft
        invited.setAttendees([sam])
        #expect(full.asksSendUpdates(for: invited) && !full.asksSendUpdates(for: alone))

        let f = SourceFixture(workFields: every.subtracting(notKept), workHonoursSendUpdates: false)
        let model = f.sidebar()
        await model.beginDraft(for: f.thread)
        #expect(model.draft != nil && model.createRefusal == nil)
        let rights = model.draftRights
        #expect(rights.hidden == notKept && !rights.shows(.guests) && rights.access(.title) == .editable)
        #expect(rights.access(.calendar) == CalendarFieldRights.forNewEvent(refusal: nil).access(.calendar),
                "a reason the field already had is kept")
        #expect(!model.asksSendUpdates(for: invited), "this calendar tells the guests itself")
    }

    @Test func theRoutedCalendarSpeaksForTheWindowsCalendar() throws {
        let f = SourceFixture(workFields: every.subtracting(notKept), workHonoursSendUpdates: false)
        let routed = try #require(f.env.calendar)
        #expect(routed.formFields == every.subtracting(notKept) && !routed.honoursSendUpdates)

        let none = AppEnvironment.fake(corpus: FakeCorpus.make(threadCount: 1, now: at(10, 10, 9)), featureFlags: FeatureFlags(),
                                       calendarConnections: FakeCalendarConnections(providers: [:]))
        let unconnected = try #require(none.calendar)
        #expect(unconnected.formFields == every && unconnected.honoursSendUpdates, "nothing connected: nothing is hidden")
    }
}
