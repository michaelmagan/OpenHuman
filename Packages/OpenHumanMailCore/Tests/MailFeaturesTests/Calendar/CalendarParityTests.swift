import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let newYork = TimeZone(identifier: "America/New_York")!

private func at(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    CalendarDateMentions.calendar(newYork).date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
}

@MainActor
private struct ParityFixture {
    static let home = "robin.home@example.org"
    let env: AppEnvironment
    let store: FakeMailStore
    let work: FakeCalendar
    let homeCalendar: FakeCalendar
    let connections: FakeCalendarConnections
    let workID: AccountID
    let homeID: AccountID
    var workEmail: String { FakeCorpus.me.email }

    static func make(homeConnected: Bool = true) async throws -> ParityFixture {
        let corpus = FakeCorpus.make(threadCount: 3, now: at(10, 10, 9))
        let work = FakeCalendar(events: [CalendarEvent(id: "w1", title: "Work standup", start: at(10, 10, 10),
                                                       end: at(10, 10, 10, 30))],
                                info: CalendarProviderInfo(name: "Google Calendar", account: FakeCorpus.me.email))
        let home = FakeCalendar(events: [CalendarEvent(id: "h1", title: "Dentist", start: at(10, 10, 14),
                                                       end: at(10, 10, 15))],
                                info: CalendarProviderInfo(name: "Google Calendar", account: Self.home))
        var providers: [String: any CalendarProviding] = [FakeCorpus.me.email: work]
        if homeConnected { providers[Self.home] = home }
        let connections = FakeCalendarConnections(connected: Set(providers.keys), providers: providers)
        let env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate),
                                      calendar: work, calendarConnections: connections)
        let store = try #require(env.data as? FakeMailStore)
        store.enqueueSignIn(.succeed(email: Self.home, displayName: nil))
        let homeID = try await store.addAccount(loginHint: nil)
        return ParityFixture(env: env, store: store, work: work, homeCalendar: home, connections: connections,
                             workID: corpus.account.id, homeID: homeID)
    }

    func thread(_ account: AccountID) -> ThreadKey {
        ThreadKey(account: account, rowID: account == workID ? 1 : 9_001, gmailThreadID: GmailThreadID("t\(account.rawValue)"))
    }

    func sidebar(people: [EmailAddress] = []) -> CalendarSidebarModel {
        let model = env.calendarSidebar!
        model.timeZone = newYork
        model.now = { at(10, 10, 9) }
        model.loadText = { _ in CalendarThreadText(subject: "Planning", texts: ["Planning", "October 10, 2026 at 4:00 PM"],
                                                   participants: people) }
        return model
    }
}

@MainActor
@Suite struct CalendarParitySidebarTests {
    @Test func theSidebarShowsTheConversationsOwnAccountsCalendar() async throws {
        let f = try await ParityFixture.make()
        let model = f.sidebar()
        #expect(model.routesByAccount)
        await model.show(thread: f.thread(f.workID))
        #expect(model.days.flatMap(\.events).map(\.title) == ["Work standup"])
        #expect(f.homeCalendar.readCalls == 0, "the other account's calendar is never read for this conversation")

        await model.show(thread: f.thread(f.homeID))
        #expect(model.days.flatMap(\.events).map(\.title) == ["Dentist"])
        #expect(model.shownProvider?.info.account == ParityFixture.home && model.calendarNote == nil)

        await model.beginDraft(for: f.thread(f.homeID))
        #expect(model.calendarLine == "Google Calendar · \(ParityFixture.home)")
        #expect(model.createRefusal == nil)
        #expect(await model.createEvent())
        #expect(f.homeCalendar.createCalls == 1 && f.work.createCalls == 0)
    }

    @Test func anAccountWithoutACalendarShowsANoteAndNeverAnotherAccountsDay() async throws {
        let f = try await ParityFixture.make(homeConnected: false)
        let model = f.sidebar()
        await model.show(thread: f.thread(f.homeID))
        #expect(model.days.isEmpty && model.calendarNote == CalendarSidebarModel.notConnected(ParityFixture.home))
        #expect(f.work.readCalls == 0, "the work calendar is never shown beside home mail")
        await model.beginDraft(for: f.thread(f.homeID))
        #expect(model.createRefusal == CalendarSidebarModel.notConnected(ParityFixture.home))
        #expect(await model.createEvent() == false)
        #expect(f.work.createCalls == 0 && f.homeCalendar.createCalls == 0)
        #expect(await model.suggestTimes(account: f.homeID) == nil)
        #expect(model.suggestionNote == CalendarSidebarModel.notConnected(ParityFixture.home))
    }

    @Test func showAllMergesEveryCalendarWithItsAccount() async throws {
        let f = try await ParityFixture.make()
        let model = f.sidebar()
        model.setVisible(true)
        await model.show(thread: f.thread(f.workID))
        await model.setShowAll(true)
        #expect(model.showsAllCalendars)
        let events = model.days.flatMap(\.events)
        #expect(events.map(\.title) == ["Work standup", "Dentist"])
        #expect(events.map(\.account) == [f.workEmail, ParityFixture.home])
        let free = try #require(model.days.first?.free)
        #expect(!free.contains { $0.start < at(10, 10, 10, 30) && $0.end > at(10, 10, 10) })
        #expect(!free.contains { $0.start < at(10, 10, 15) && $0.end > at(10, 10, 14) })
        await model.beginDraft(for: f.thread(f.workID))
        #expect(await model.createEvent())
        #expect(f.work.createCalls == 1 && f.homeCalendar.createCalls == 0)

        await model.setShowAll(false)
        let own = model.days.flatMap(\.events)
        #expect(own.allSatisfy { $0.account == f.workEmail } && !own.map(\.title).contains("Dentist"), "the work calendar alone again")
    }

    @Test func freeTimesUseTheDraftsAccountsCalendar() async throws {
        let f = try await ParityFixture.make()
        let model = f.sidebar()
        _ = await model.suggestTimes(account: f.homeID)
        #expect(f.homeCalendar.calls.contains { if case .freeBusy = $0 { true } else { false } })
        #expect(!f.work.calls.contains { if case .freeBusy = $0 { true } else { false } })
    }

    @Test func aHeldInviteWaitsAndGoesToItsOwnAccountsCalendar() async throws {
        let f = try await ParityFixture.make()
        let model = f.sidebar(people: [EmailAddress(email: "alex@example.net")])
        let gate = AsyncStream<Void>.makeStream()
        model.sleep = { _ in for await _ in gate.stream { return } }
        await model.show(thread: f.thread(f.homeID))
        await model.beginDraft(for: f.thread(f.homeID))
        #expect(model.draft?.mayEmailAttendees == true)
        #expect(await model.createEvent())
        #expect(model.heldCreateCount == 1 && f.homeCalendar.createCalls == 0, "held behind its undo window")
        gate.continuation.yield(())
        await eventually { f.homeCalendar.createCalls == 1 }
        #expect(f.work.createCalls == 0)
        await eventually { f.env.notices.toasts.contains { $0.message.hasPrefix("Event created.") } }
        await eventually { model.state == .loaded }
        withExtendedLifetime(f) {}
    }
}

@MainActor
@Suite struct CalendarParitySettingsTests {
    @Test func everyAccountHasItsOwnRowConnectAndDisconnect() async throws {
        let f = try await ParityFixture.make(homeConnected: false)
        let settings = CalendarSettingsModel(environment: f.env)
        settings.start()
        await eventually { settings.calendarInboxes.count == 2 }
        let work = try #require(settings.calendarInboxes.first { $0.id == f.workID })
        let home = try #require(settings.calendarInboxes.first { $0.id == f.homeID })
        await eventually { work.state != nil && home.state != nil }
        #expect(CalendarSettingsModel.rowStatus(work) == "Connected")
        #expect(CalendarSettingsModel.rowStatus(home) == "Not connected")

        await settings.connect(home)
        #expect(f.connections.connection(ParityFixture.home).connectCalls == 1)
        #expect(f.connections.connection(ParityFixture.home).connectClients == [nil], "its Gmail client by default")
        #expect(f.connections.connection(f.workEmail).connectCalls == 0, "only that account's consent")
        await eventually { CalendarSettingsModel.rowStatus(home) == "Connected" }

        await settings.disconnect(work)
        #expect(f.connections.connection(f.workEmail).disconnectCalls == 1)
        #expect(f.connections.connection(ParityFixture.home).disconnectCalls == 0)
        await eventually { CalendarSettingsModel.rowStatus(work) == "Not connected" }
        #expect(CalendarSettingsModel.rowStatus(home) == "Connected")
    }

    @Test func aFailedConnectSaysWhyInWordsAndChangesNothingElse() async throws {
        let f = try await ParityFixture.make(homeConnected: false)
        f.connections.connection(ParityFixture.home).failure = "Google refused (HTTP 400, invalid_grant). Nothing was stored."
        let settings = CalendarSettingsModel(environment: f.env)
        settings.start()
        await eventually { settings.calendarInboxes.count == 2 }
        let home = try #require(settings.calendarInboxes.first { $0.id == f.homeID })
        await settings.connect(home)
        #expect(CalendarSettingsModel.rowProblem(home) == "Google refused (HTTP 400, invalid_grant). Nothing was stored.")
        var inboxes: [Account] = []
        for try await list in f.store.accounts() {
            inboxes = list
            break
        }
        #expect(inboxes.count == 2 && inboxes.allSatisfy { $0.health == .active }, "both inboxes' email stays as it was")
    }
}

@MainActor
@Suite struct SignInWaitingModelTests {
    @Test func copyPutsTheLinkOnTheClipboardAndClearsItOnlyWhileItIsStillThere() async throws {
        let port = FakeSignInBrowsing()
        let clipboard = FakeSignInClipboard()
        let model = SignInWaitingModel(port: port, clipboard: clipboard, sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        model.start()
        let pending = FakeSignInBrowsing.sampleSignIn()
        port.set(pending)
        await eventually { model.pending?.id == pending.id && !model.browsers.isEmpty }
        #expect(model.browsers.map(\.name) == ["Alpha Browser", "Beta Browser", "Gamma Browser"])

        model.copyLink()
        #expect(clipboard.text == pending.url.absoluteString && model.copiedNote == SignInWaitingModel.copiedText)
        port.set(nil)
        await eventually { model.pending == nil }
        #expect(clipboard.text == nil && clipboard.clears == 1, "cleared: it still held the link")

        let next = FakeSignInBrowsing.sampleSignIn(account: "sam@example.org")
        port.set(next)
        await eventually { model.pending?.id == next.id }
        model.copyLink()
        clipboard.somethingElseCopied("a note of the user's")
        port.set(nil)
        await eventually { model.pending == nil }
        #expect(clipboard.text == "a note of the user's" && clipboard.clears == 1)
    }

    @Test func aCopiedLinkIsClearedAfterItsLifetime() async throws {
        let port = FakeSignInBrowsing(pending: FakeSignInBrowsing.sampleSignIn())
        let clipboard = FakeSignInClipboard()
        let model = SignInWaitingModel(port: port, clipboard: clipboard, sleep: { _ in })
        model.start()
        await eventually { model.pending != nil }
        model.copyLink()
        await eventually { clipboard.clears == 1 }
        #expect(clipboard.text == nil && model.copiedNote == nil)
    }

    @Test func openInRemembersAndCancelStopsTheWait() async throws {
        let pending = FakeSignInBrowsing.sampleSignIn(purpose: .calendar)
        let port = FakeSignInBrowsing(pending: pending)
        let model = SignInWaitingModel(port: port, clipboard: FakeSignInClipboard())
        model.start()
        await eventually { model.pending != nil && !model.browsers.isEmpty }
        #expect(model.title == "Finish connecting the calendar in your browser")
        #expect(model.openedLine == "Opened in your default browser.")
        await model.open(in: "com.example.browser.beta")
        #expect(port.openedBrowsers == ["com.example.browser.beta"] && model.remembered == "com.example.browser.beta")
        #expect(await port.rememberedBrowser(for: pending.account) == "com.example.browser.beta")
        port.failOpening("Beta Browser didn't open. Pick another browser, or copy the link.")
        await model.openInDefaultBrowser()
        #expect(model.errorMessage == "Beta Browser didn't open. Pick another browser, or copy the link.")
        model.toggleLink()
        #expect(model.showsLink)
        await model.cancel()
        #expect(port.cancelled == [pending.id])
        await eventually { model.pending == nil }
        #expect(!model.showsLink)
    }
}

@MainActor
@Suite struct CalendarParityDiagnosticsTests {
    @Test func diagnosticsNumberEachAccountsCalendarWithoutAnAddress() async throws {
        let f = try await ParityFixture.make(homeConnected: false)
        let entries = await f.env.calendarDiagnostics()
        #expect(entries.map(\.index) == [1, 2])
        #expect(entries.map(\.status) == ["connected", "disconnected"])
        let encoded = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
        #expect(!encoded.contains("@"), "no address in the export")
    }
}
