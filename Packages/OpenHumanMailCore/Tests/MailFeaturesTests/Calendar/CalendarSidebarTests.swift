import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private let newYork = TimeZone(identifier: "America/New_York")!
private let hour: TimeInterval = 3_600

private func at(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ tz: TimeZone = newYork) -> Date {
    CalendarDateMentions.calendar(tz).date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
}

@MainActor
private struct CalendarFixture {
    let env: AppEnvironment
    let calendar: FakeCalendar
    let corpus: FakeCorpus
    let thread: ThreadKey

    init(provider: Bool = true, flags: FeatureFlags = FeatureFlags(),
         events: [CalendarEvent] = [], info: CalendarProviderInfo? = nil, connection: FakeCalendarConnection? = nil) {
        corpus = .make(threadCount: 6, now: fixedNow)
        calendar = info.map { FakeCalendar(events: events, info: $0) } ?? FakeCalendar(events: events)
        env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate),
                                  featureFlags: flags, calendar: provider ? calendar : nil, calendarConnection: connection)
        thread = corpus.threads[0].row.id
    }

    var me: String { corpus.account.email }

    func sidebar(_ text: CalendarThreadText? = nil) -> CalendarSidebarModel {
        let model = env.calendarSidebar!
        model.timeZone = newYork
        model.now = { at(10, 10, 9) }
        let shown = text
        model.loadText = { _ in shown }
        return model
    }

    func text(_ bodies: [String], subject: String = "Planning", people: [EmailAddress] = []) -> CalendarThreadText {
        CalendarThreadText(subject: subject, texts: [subject] + bodies, participants: people)
    }

    func run(_ id: ActionID, context: ActionContext) async -> Bool {
        await env.actions.run(id, source: .palette, host: nil, context: context)
    }
}

@MainActor
@Suite struct CalendarModuleTests {
    @Test func withoutAProviderTheModuleIsAbsentAndSettingsSaysItIsNotConnected() {
        let f = CalendarFixture(provider: false)
        #expect(!f.env.modules.modules.contains(.calendar))
        #expect(f.env.calendarSidebar == nil)
        for id in [ActionID.calendarToggleSidebar, .calendarCreateEvent] {
            #expect(!f.env.actions.contains(id), "\(id)")
            #expect(f.env.actions.availability(id, host: nil) == .hidden)
        }
        let shell = SettingsShellModel(environment: f.env)
        #expect(shell.pages.contains { $0.id == "calendar" && $0.builtIn == .calendar }, "the page that explains why")
        let settings = CalendarSettingsModel(environment: f.env)
        #expect(!settings.isConfigured && !settings.isRunning && !settings.canConnect, "fake data never reaches Google")
        #expect(settings.status == "Google Calendar is not connected.")
        #expect(CalendarSettingsModel.unavailableNote.contains("connects only on a real Google account"))
        #expect(!FeaturesSettingsModel(environment: f.env).rows.contains { $0.id == .calendar }, "no switch without a provider")
    }

    @Test func withAProviderTheKeysPaletteEntriesAndSwitchAppear() async {
        let f = CalendarFixture()
        #expect(f.env.modules.modules.contains(.calendar))
        #expect(f.env.actions.contains(.calendarToggleSidebar) && f.env.actions.contains(.calendarCreateEvent))
        #expect(f.env.actions.descriptor(.calendarToggleSidebar)?.shortcutHint == "0")
        #expect(f.env.actions.descriptor(.calendarCreateEvent)?.appearsInPalette == true)
        let features = FeaturesSettingsModel(environment: f.env)
        #expect(features.rows.contains { $0.id == .calendar && $0.isRunning && !$0.needsRestart })
        #expect(CalendarSettingsModel(environment: f.env).status.hasPrefix("Connected: Sample calendar (fake data)."))
        let sidebar = f.sidebar()
        #expect(!sidebar.isVisible)
        #expect(await f.run(.calendarToggleSidebar, context: ActionContext(scope: .list)))
        #expect(sidebar.isVisible)
        #expect(await f.run(.calendarToggleSidebar, context: ActionContext(scope: .list)))
        #expect(!sidebar.isVisible)
    }

    @Test func theModuleFlagSwitchesItOffEvenWithAProvider() {
        let f = CalendarFixture(flags: FeatureFlags().with(.calendar, false))
        #expect(!f.env.modules.modules.contains(.calendar))
        #expect(f.env.calendarSidebar == nil && !f.env.actions.contains(.calendarToggleSidebar))
        #expect(FeaturesSettingsModel(environment: f.env).rows.contains { $0.id == .calendar && !$0.isRunning })
    }

    @Test func bothActionsAreViewOnly() {
        for id in [ActionID.calendarToggleSidebar, .calendarCreateEvent] {
            let descriptor = ActionCatalog.descriptor(id)
            #expect(descriptor?.module == .calendar && descriptor?.changesMail == false, "\(id)")
        }
        let f = CalendarFixture()
        let context = ActionContext(scope: .reader, focusedThread: f.thread)
        #expect(f.env.actions.availability(.calendarCreateEvent, host: nil, context: context) == .enabled)
        #expect(f.env.actions.availability(.calendarCreateEvent, host: nil,
                                           context: ActionContext(scope: .reader)) == .disabled(.noSelection))
    }
}

@MainActor
@Suite struct CalendarSidebarModelTests {
    @Test func theSidebarShowsEventsAndFreeBusyForTheDaysTheConversationMentions() async throws {
        let f = CalendarFixture(events: [
            CalendarEvent(id: "standup", title: "Standup", start: at(10, 14, 10), end: at(10, 14, 11)),
            CalendarEvent(id: "lunch", title: "Lunch", start: at(10, 15, 12), end: at(10, 15, 13)),
            CalendarEvent(id: "other", title: "Elsewhere", start: at(10, 16, 12), end: at(10, 16, 13)),
        ])
        let model = f.sidebar(f.text(["Can we meet on October 14, 2026 at 3:00 PM? Or October 15, 2026."]))
        await model.show(thread: f.thread)
        #expect(model.state == .loaded && model.thread == f.thread && model.mentionCount == 2)
        #expect(model.days.map(\.start) == [at(10, 14), at(10, 15)] && model.days.allSatisfy(\.isMentioned))
        #expect(model.days[0].events.map(\.id) == ["standup"] && model.days[1].events.map(\.id) == ["lunch"])
        #expect(model.days[0].busy == [CalendarBusyInterval(start: at(10, 14, 10), end: at(10, 14, 11))])
        #expect(model.days[0].free == [CalendarBusyInterval(start: at(10, 14, 9), end: at(10, 14, 10)),
                                       CalendarBusyInterval(start: at(10, 14, 11), end: at(10, 14, 18))])
        #expect(f.calendar.calls == [.window(from: at(9, 26), to: at(11, 24))])
        #expect(f.calendar.createCalls == 0)
    }

    @Test func noDatesOrNoConversationShowsToday() async {
        let f = CalendarFixture(events: [CalendarEvent(id: "today", title: "Today", start: at(10, 10, 15), end: at(10, 10, 16))])
        let model = f.sidebar(f.text(["Thanks, that works for me."]))
        await model.show(thread: f.thread)
        #expect(model.mentionCount == 0 && model.days.map(\.start) == [at(10, 10)] && !model.days[0].isMentioned)
        #expect(model.days[0].events.map(\.id) == ["today"])
        await model.show(thread: nil)
        #expect(model.thread == nil && model.days.map(\.start) == [at(10, 10)])
        #expect(model.dayTitle(model.days[0]).hasPrefix("Today"))
    }

    @Test func daysAndTimesFollowTheSidebarsZone() async throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let f = CalendarFixture()
        let model = f.sidebar(f.text(["Let's talk on October 14, 2026 at 9:00 AM."]))
        model.timeZone = tokyo
        await model.show(thread: f.thread)
        #expect(model.days.map(\.start) == [at(10, 14, 0, 0, tokyo)])
        #expect(f.calendar.calls.contains(.window(from: at(9, 26, 0, 0, tokyo), to: at(11, 24, 0, 0, tokyo))))
        await model.beginDraft(for: f.thread)
        #expect(model.draft?.start == at(10, 14, 9, 0, tokyo) && model.draft?.timeZone == "Asia/Tokyo")
    }

    @Test func theSecondTimeZoneShowsBesideEveryTime() async throws {
        let f = CalendarFixture()
        let model = f.sidebar()
        #expect(model.secondTimeZone == nil && model.secondTimeText(at(10, 14, 15), at(10, 14, 16)) == nil)
        #expect(model.zonesText == "Times in New York")
        try await f.env.settings!.set(AppSettings.calendarSecondTimeZone, "Europe/London")
        model.setVisible(true)
        await eventually { model.secondTimeZone?.identifier == "Europe/London" }
        let london = try #require(TimeZone(identifier: "Europe/London"))
        let text = try #require(model.secondTimeText(at(10, 14, 15), at(10, 14, 16)))
        #expect(text == CalendarSidebarModel.range(at(10, 14, 15), at(10, 14, 16), london) + " London")
        #expect(text != model.timeText(at(10, 14, 15), at(10, 14, 16)), "20:00 in London, not 15:00")
        #expect(model.secondTimeText(at(10, 14), at(10, 15), allDay: true) == nil)
        #expect(model.zonesText == "Times in New York · London")
        try await f.env.settings!.set(AppSettings.calendarSecondTimeZone, "America/New_York")
        await eventually { model.secondTimeZoneSetting.value == "America/New_York" }
        #expect(model.secondTimeZone == nil)
    }

    @Test func theDraftTakesTitleTimeAndAttendeesFromTheConversation() async throws {
        let f = CalendarFixture()
        let people = [EmailAddress(name: "Me", email: f.me.uppercased()), EmailAddress(name: "Alice", email: "alice@example.com"),
                      EmailAddress(email: "bob@example.org")]
        let model = f.sidebar(f.text(["Does October 14, 2026 from 2pm to 4pm work?"], subject: "Re: Fwd: Quarterly planning",
                                     people: people))
        await model.beginDraft(for: f.thread)
        let draft = try #require(model.draft)
        #expect(model.isVisible)
        #expect(draft.title == "Quarterly planning")
        #expect(draft.start == at(10, 14, 14) && draft.end == at(10, 14, 16), "the mention's span")
        #expect(draft.attendees.map(\.email) == ["alice@example.com", "bob@example.org"], "never the user's own address")
        #expect(draft.timeZone == "America/New_York" && draft.sendUpdates == .all, "guests are invited unless turned off")
        #expect(f.calendar.createCalls == 0, "opening a draft creates nothing")
        model.cancelDraft()
        #expect(model.draft == nil)
    }

    @Test func draftTimesFallBackToTheMentionedDayThenTheNextHour() async throws {
        let f = CalendarFixture()
        let day = f.sidebar(f.text(["Free on 2026-10-22?"]))
        await day.beginDraft(for: f.thread)
        #expect(day.draft?.start == at(10, 22, CalendarEventDraftBuilder.defaultHour))
        #expect(day.draft.map { $0.end.timeIntervalSince($0.start) } == CalendarEventDraftBuilder.defaultDuration)
        let other = CalendarFixture()
        let none = other.sidebar(other.text(["No dates here."], subject: ""))
        await none.beginDraft(for: other.thread)
        #expect(none.draft?.start == at(10, 10, 10), "the next full hour after 9:00")
        #expect(none.draft?.title == "Meeting")
        #expect(CalendarEventDraftBuilder.title("RE[3]: AW: Budget") == "Budget")
    }

    @Test func createsTheEventOnceAndShowsIt() async throws {
        let f = CalendarFixture()
        let model = f.sidebar(f.text(["How about October 15, 2026 at 12:30 PM?"], subject: "Lunch?"))
        await model.show(thread: f.thread)
        #expect(model.days.first?.events.isEmpty == true)
        await model.beginDraft(for: nil)
        #expect(model.canCreate)
        #expect(await model.createEvent())
        #expect(f.calendar.createCalls == 1)
        let created = try #require(f.calendar.created.first)
        #expect(created.title == "Lunch?" && created.start == at(10, 15, 12, 30) && created.attendees.isEmpty)
        guard case .create(let sent) = f.calendar.calls.first(where: { if case .create = $0 { true } else { false } }) else {
            Issue.record("no create call")
            return
        }
        #expect(sent.sendUpdates == .none)
        #expect(model.draft == nil && model.days.first?.events.map(\.id) == [created.id])
        #expect(f.env.notices.toasts.contains { $0.message == "Event created." })
    }

    @Test func anIncompleteDraftOrAFailingCalendarCreatesNothingAndSaysWhy() async throws {
        let f = CalendarFixture()
        let model = f.sidebar(f.text(["October 15, 2026 at 12:30 PM"]))
        await model.beginDraft(for: f.thread)
        model.draft?.title = " "
        #expect(!model.canCreate)
        #expect(await model.createEvent() == false)
        #expect(model.draftNote == "Add a title." && f.calendar.createCalls == 0)
        model.draft?.title = "Lunch"
        f.calendar.failure = "The calendar is offline."
        #expect(await model.createEvent() == false)
        #expect(model.draftNote == "Couldn't create the event. The calendar is offline." && model.draft != nil)
        await model.refresh()
        #expect(model.state == .failed("Couldn't load events: The calendar is offline."))
        #expect(model.days.first?.note?.contains("Couldn't read this day") == true)
    }

    @Test func aNewerConversationWinsOverASlowerOlderLoad() async throws {
        let f = CalendarFixture()
        let model = f.sidebar()
        let slow = f.corpus.threads[1].row.id
        model.loadText = { thread in
            if thread == slow {
                try? await Task.sleep(for: .milliseconds(300))
                return CalendarThreadText(subject: "Old", texts: ["October 20, 2026"], participants: [])
            }
            return CalendarThreadText(subject: "New", texts: ["October 14, 2026"], participants: [])
        }
        let older = Task { await model.show(thread: slow) }
        await Task.yield()
        await model.show(thread: f.thread)
        await older.value
        #expect(model.thread == f.thread && model.days.map(\.start) == [at(10, 14)])
    }

    @Test func aDraftBelongsToItsConversation() async throws {
        let f = CalendarFixture()
        let mine = f.thread
        let other = f.corpus.threads[1].row.id
        let model = f.sidebar()
        model.loadText = { thread in
            thread == mine ? CalendarThreadText(subject: "Mine", texts: ["October 14, 2026 at 3:00 PM"], participants: [])
                           : CalendarThreadText(subject: "Other", texts: ["October 20, 2026 at 9:00 AM"], participants: [])
        }
        await model.show(thread: other)
        await model.beginDraft(for: mine)
        #expect(model.draft?.title == "Mine" && model.draft?.start == at(10, 14, 15))
        await model.show(thread: mine)
        #expect(model.draft?.title == "Mine")
        await model.show(thread: other)
        #expect(model.draft == nil)
    }

    @Test func freeGapsAreInsideTheWorkdayAndAtLeastAQuarterHour() {
        let calendar = CalendarDateMentions.calendar(newYork)
        let day = at(10, 14)
        let busy = [CalendarBusyInterval(start: at(10, 14, 7), end: at(10, 14, 9, 10)),
                    CalendarBusyInterval(start: at(10, 14, 9, 20), end: at(10, 14, 12)),
                    CalendarBusyInterval(start: at(10, 14, 17), end: at(10, 14, 20))]
        let free = CalendarSidebarModel.free(day: day, busy: busy, calendar: calendar)
        #expect(free == [CalendarBusyInterval(start: at(10, 14, 12), end: at(10, 14, 17))], "the 10-minute gap is dropped")
        #expect(CalendarSidebarModel.free(day: day, busy: [], calendar: calendar)
                    == [CalendarBusyInterval(start: at(10, 14, 9), end: at(10, 14, 18))])
    }
}

@MainActor
@Suite struct CalendarSettingsTests {
    @Test func theSecondTimeZoneIsALocalSetting() async throws {
        let f = CalendarFixture(provider: false)
        let model = CalendarSettingsModel(environment: f.env)
        model.start()
        #expect(model.canChangeZone && model.secondTimeZone.value == nil)
        await model.setSecondTimeZone("Asia/Kolkata")
        #expect(model.secondTimeZone.errorMessage == nil)
        #expect(try await f.env.settings!.get(AppSettings.calendarSecondTimeZone) == "Asia/Kolkata")
        #expect(AppSettings.calendarSecondTimeZone.name == "calendar.second_time_zone")
        let choices = model.zoneChoices(now: fixedNow)
        #expect(choices.first?.identifier == nil && choices.first?.title == "None")
        #expect(choices.contains { $0.identifier == "Asia/Kolkata" && $0.title == "Asia/Kolkata — GMT+5:30" })
        #expect(CalendarSettingsModel.title("UTC", now: fixedNow) == "UTC — GMT")
        await model.setSecondTimeZone(nil)
        #expect(try await f.env.settings!.get(AppSettings.calendarSecondTimeZone) == nil)
    }

    @Test func theMeetDefaultIsALocalSetting() async throws {
        let f = CalendarFixture(provider: false)
        let model = CalendarSettingsModel(environment: f.env)
        model.start()
        #expect(model.addMeetLink.value && model.canChangeMeetDefault, "on by default")
        await model.setAddMeetLink(false)
        #expect(model.addMeetLink.errorMessage == nil)
        #expect(try await f.env.settings!.get(AppSettings.calendarAddMeetLink) == false)
        #expect(AppSettings.calendarAddMeetLink.name == "calendar.add_meet_link")
    }

    @Test func theConnectSwitchGoesThroughItsPortAndSaysWhatHappened() async throws {
        let connection = FakeCalendarConnection(account: "robin@example.com")
        let f = CalendarFixture(provider: false, connection: connection)
        let model = CalendarSettingsModel(environment: f.env)
        model.start()
        await eventually { model.connection != nil }
        #expect(model.canConnect && !model.isConnected)
        #expect(model.status == "Off. Mail asks Google for calendar access only when you turn this on.")
        #expect(CalendarSettingsModel.connectNote.contains("your Gmail sign-in and its permission don't change"))
        await model.setConnected(true)
        #expect(connection.connectCalls == 1)
        await eventually { model.isConnected }
        #expect(model.status == "Connected. Quit and reopen Mail to show the calendar sidebar.")
        #expect(!f.env.modules.modules.contains(.calendar), "the module registers at the next launch")
        await model.setConnected(false)
        #expect(connection.disconnectCalls == 1)
        await eventually { !model.isConnected }
        connection.failure = "Google didn't answer in time. Try again."
        await model.setConnected(true)
        #expect(model.connectError == "Google didn't answer in time. Try again." && !model.isConnected)
        connection.expire()
        await eventually { model.status == CalendarSettingsModel.reconnectText }
    }

    @Test func disconnectingWhileTheSidebarRunsSaysItGoesAtTheNextLaunch() async throws {
        let connection = FakeCalendarConnection(connected: true)
        let f = CalendarFixture(connection: connection)
        let model = CalendarSettingsModel(environment: f.env)
        model.start()
        await eventually { model.isConnected }
        #expect(model.status.hasPrefix("Connected: Sample calendar (fake data)."))
        await model.setConnected(false)
        await eventually { model.status == "Disconnected. The calendar sidebar goes away when Mail reopens." }
    }
}

private final class WakeCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

@MainActor
@Suite struct CalendarCreateUndoTests {
    private let alice = EmailAddress(name: "Alice", email: "alice@example.com")

    @Test func undoInsideTheWindowOfAnEmailingCreateCreatesNothing() async throws {
        let f = CalendarFixture()
        let model = f.sidebar(f.text(["How about October 15, 2026 at 12:30 PM?"], subject: "Lunch?", people: [alice]))
        let woke = WakeCounter()
        model.sleep = { _ in
            defer { woke.increment() }
            try await Task.sleep(for: .seconds(3_600))
        }
        await model.show(thread: f.thread)
        await model.beginDraft(for: nil)
        model.draft?.sendUpdates = .all
        #expect(model.draft?.emailsAttendees == true)
        #expect(await model.createEvent())
        #expect(model.draft == nil && model.heldCreateCount == 1)
        #expect(f.calendar.createCalls == 0, "nothing reaches the calendar inside the window")
        let toast = try #require(f.env.notices.toasts.first { $0.message == "Creating event…" })
        #expect(toast.style == .undo && toast.actionTitle == "Undo" && toast.shortcut == "⌘Z")
        await f.env.undo?.undoLast()
        await eventually { woke.value == 1 }
        #expect(model.heldCreateCount == 0)
        #expect(f.calendar.createCalls == 0 && f.calendar.created.isEmpty, "undone: never created")
        #expect(model.draft?.title == "Lunch?" && model.draft?.sendUpdates == .all, "the draft is back in the editor")
        #expect(f.env.notices.toasts.contains { $0.message == "Event canceled. Nothing was created." })
    }

    @Test func afterTheWindowTheEventGoesOutOnceAsAllAndIsNeverDeleted() async throws {
        let f = CalendarFixture()
        let model = f.sidebar(f.text(["October 15, 2026 at 12:30 PM"], subject: "Lunch?", people: [alice]))
        let window = TestGate()
        model.sleep = { _ in await window.wait() }
        await model.beginDraft(for: f.thread)
        model.draft?.sendUpdates = .all
        #expect(await model.createEvent())
        #expect(f.calendar.createCalls == 0)
        window.release()
        await eventually { f.calendar.createCalls == 1 }
        guard case .create(let sent)? = f.calendar.calls.first(where: { if case .create = $0 { true } else { false } }) else {
            Issue.record("no create call")
            return
        }
        #expect(sent.sendUpdates == .all && sent.attendees.map(\.email) == ["alice@example.com"])
        await eventually { f.env.notices.toasts.contains { $0.message == "Event created. Google emails the invitations." } }
        #expect(model.heldCreateCount == 0)
        await f.env.undo?.undoLast()
        #expect(f.calendar.deleteCalls == 0, "an event that emailed its attendees is never deleted by undo")
        #expect(f.calendar.createCalls == 1)
    }

    @Test func undoDeletesAnEventThatWasCreatedAtOnce() async throws {
        let f = CalendarFixture()
        let model = f.sidebar(f.text(["How about October 15, 2026 at 12:30 PM?"], subject: "Lunch?"))
        await model.show(thread: f.thread)
        await model.beginDraft(for: nil)
        #expect(model.draft?.sendUpdates == CalendarSendUpdates.none)
        #expect(await model.createEvent())
        let created = try #require(f.calendar.created.first)
        #expect(model.days.first?.events.map(\.id) == [created.id])
        let toast = try #require(f.env.notices.toasts.first { $0.message == "Event created." })
        #expect(toast.style == .undo && toast.shortcut == "⌘Z")
        await f.env.undo?.undoLast()
        #expect(f.calendar.deleted == [created.id] && f.calendar.deleteCalls == 1)
        #expect(model.days.first?.events.isEmpty == true, "the day is read again after the undo")
        #expect(f.env.notices.toasts.contains { $0.message == "Event removed." })
    }

    @Test func anEventWithAttendeesIsHeldEvenWithInvitationsOff() async throws {
        let f = CalendarFixture()
        let model = f.sidebar(f.text(["October 15, 2026 at 12:30 PM"], subject: "Lunch?", people: [alice]))
        let window = TestGate()
        model.sleep = { _ in await window.wait() }
        await model.beginDraft(for: f.thread)
        #expect(model.draft?.sendUpdates == .all, "a draft with guests invites them by default")
        model.draft?.sendUpdates = CalendarSendUpdates.none
        #expect(model.draft?.emailsAttendees == false && model.draft?.mayEmailAttendees == true)
        #expect(await model.createEvent())
        #expect(model.heldCreateCount == 1 && f.calendar.createCalls == 0, "held, invitations off")
        window.release()
        await eventually { f.calendar.createCalls == 1 }
        await eventually { f.env.notices.toasts.contains { $0.message == "Event created." } }
        #expect(!f.env.notices.toasts.contains { $0.message == "Event created. Google emails the invitations." })
        await f.env.undo?.undoLast()
        #expect(f.calendar.deleteCalls == 0, "an event with attendees is never deleted by undo")
    }

    @Test func aGuestAddedToABlankDraftGetsAnInvitationByEmail() async throws {
        let f = CalendarFixture()
        let model = f.sidebar()
        let window = TestGate()
        model.sleep = { _ in await window.wait() }
        await model.beginDraft(for: nil)
        let blank = try #require(model.draft)
        #expect(blank.attendees.isEmpty && blank.sendUpdates == CalendarSendUpdates.none)
        var form = CalendarEventForm(draft: blank)
        form.addGuest(alice)
        model.draft = form.applying(to: blank)
        #expect(model.draft?.sendUpdates == .all, "the first guest turns invitations on")
        #expect(await model.createEvent())
        #expect(model.heldCreateCount == 1 && f.calendar.createCalls == 0)
        window.release()
        await eventually { f.calendar.createCalls == 1 }
        let sent = try #require(f.calendar.calls.compactMap { call -> CalendarEventDraft? in
            if case .create(let draft) = call { draft } else { nil }
        }.first)
        #expect(sent.sendUpdates == .all && sent.attendees.map(\.email) == ["alice@example.com"])
        await eventually { f.env.notices.toasts.contains { $0.message == "Event created. Google emails the invitations." } }
    }

    @Test func anAddressLeftInTheGuestFieldIsAddedOnSave() async throws {
        let f = CalendarFixture()
        let model = f.sidebar()
        let window = TestGate()
        model.sleep = { _ in await window.wait() }
        await model.beginDraft(for: nil)
        model.pendingGuest = "Alice <alice@example.com>"
        #expect(model.draft?.attendees.isEmpty == true, "typed, not yet added with Return")
        #expect(await model.createEvent())
        #expect(model.pendingGuest.isEmpty && model.heldCreateCount == 1)
        window.release()
        await eventually { f.calendar.createCalls == 1 }
        let sent = try #require(f.calendar.calls.compactMap { call -> CalendarEventDraft? in
            if case .create(let draft) = call { draft } else { nil }
        }.first)
        #expect(sent.attendees == [alice] && sent.extras.guests.map(\.email) == ["alice@example.com"])
        #expect(sent.sendUpdates == .all)
    }

    @Test func textInTheGuestFieldThatIsNotAnAddressStopsTheSave() async throws {
        let f = CalendarFixture()
        let model = f.sidebar()
        await model.beginDraft(for: nil)
        model.pendingGuest = "Alice"
        #expect(await model.createEvent() == false)
        #expect(model.pendingGuestNote == CalendarPendingGuest.notAnAddress && model.pendingGuest == "Alice", "kept, not dropped")
        #expect(model.draft?.attendees.isEmpty == true && f.calendar.createCalls == 0)
        model.pendingGuest = ""
        #expect(model.pendingGuestNote == nil)
        #expect(await model.createEvent())
        #expect(f.calendar.createCalls == 1)
    }

    @Test func theGuestFieldTextIsReadAsAddressesOrRefusedWhole() {
        #expect(CalendarPendingGuest.addresses(in: "  ") == [])
        #expect(CalendarPendingGuest.addresses(in: "bob@example.org, Alice <alice@example.com>")?.map(\.email)
                == ["bob@example.org", "alice@example.com"])
        #expect(CalendarPendingGuest.addresses(in: "Alice") == nil)
        #expect(CalendarPendingGuest.addresses(in: "bob@example.org, Alice") == nil, "nothing is added when part is not an address")
    }

    @Test func anUnclearCreateThatTheDayShowsCountsAsCreated() async throws {
        let f = CalendarFixture()
        let model = f.sidebar(f.text(["October 15, 2026 at 12:30 PM"], subject: "Lunch?", people: [alice]))
        let window = TestGate()
        model.sleep = { _ in await window.wait() }
        await model.show(thread: f.thread)
        await model.beginDraft(for: nil)
        model.draft?.sendUpdates = .all
        f.calendar.createOutcome = .unclear(created: true)
        #expect(await model.createEvent())
        window.release()
        await eventually { f.env.notices.toasts.contains { $0.message == "Event created." } }
        #expect(f.calendar.createCalls == 1 && f.calendar.allEvents.count == 1)
        await eventually { model.days.first?.events.map(\.title) == ["Lunch?"] }
        #expect(model.draft == nil && model.heldCreateCount == 0, "nothing to create again")
        #expect(f.calendar.createCalls == 1)
    }

    @Test func anUnclearCreateWithAttendeesIsNeverOfferedAgain() async throws {
        let f = CalendarFixture()
        let model = f.sidebar(f.text(["October 15, 2026 at 12:30 PM"], subject: "Lunch?", people: [alice]))
        let window = TestGate()
        model.sleep = { _ in await window.wait() }
        await model.show(thread: f.thread)
        await model.beginDraft(for: nil)
        model.draft?.sendUpdates = .all
        f.calendar.createOutcome = .unclear(created: false)
        #expect(await model.createEvent())
        window.release()
        await eventually { f.env.notices.toasts.contains { $0.message == CalendarSidebarModel.unclearWithAttendees } }
        #expect(model.draft == nil, "no draft to press Create on again")
        #expect(await model.createEvent() == false, "nothing to create")
        #expect(f.calendar.createCalls == 1)
    }

    @Test func anUnclearAttendeeLessCreateIsLookedForFirst() async throws {
        let f = CalendarFixture()
        let model = f.sidebar(f.text(["October 15, 2026 at 12:30 PM"], subject: "Focus"))
        await model.beginDraft(for: f.thread)
        f.calendar.createOutcome = .unclear(created: false)
        #expect(await model.createEvent() == false)
        #expect(model.draft != nil && model.draftNote == CalendarSidebarModel.unclearNotFound)
        f.calendar.createOutcome = .unclear(created: true)
        #expect(await model.createEvent())
        #expect(model.draft == nil && f.calendar.createCalls == 2 && f.calendar.allEvents.count == 1)
        #expect(f.env.notices.toasts.contains { $0.message == "Event created." })
        await f.env.undo?.undoLast()
        #expect(f.calendar.deleteCalls == 0, "an event found after an unclear create is not deleted by undo")
    }

    @Test func aDraftFromAnotherAccountsConversationIsNeverCreated() async throws {
        let other = CalendarFixture(info: CalendarProviderInfo(name: "Google Calendar", account: "robin@example.net"))
        let refused = other.sidebar(other.text(["October 15, 2026 at 12:30 PM"], subject: "Lunch?"))
        await refused.beginDraft(for: other.thread)
        #expect(refused.calendarLine == "Google Calendar · robin@example.net")
        let refusal = try #require(refused.draftAccountRefusal)
        #expect(refused.createRefusal == refusal && !refused.canCreate)
        #expect(await refused.createEvent() == false)
        #expect(other.calendar.createCalls == 0 && refused.draftNote == refusal)
        refused.cancelDraft()
        #expect(refused.createRefusal == nil, "the refusal belongs to the draft")

        let probe = CalendarFixture()
        let mine = CalendarFixture(info: CalendarProviderInfo(name: "Google Calendar", account: probe.me.uppercased()))
        let model = mine.sidebar(mine.text(["October 15, 2026 at 12:30 PM"], subject: "Lunch?",
                                           people: [alice, EmailAddress(email: mine.me)]))
        await model.beginDraft(for: mine.thread)
        #expect(model.draftAccountRefusal == nil && model.canCreate)
        #expect(model.draft?.attendees.map(\.email) == ["alice@example.com"], "never the calendar's own address")
    }

    @Test func aDeleteThatFailsSaysToRemoveItInTheCalendar() async throws {
        let f = CalendarFixture()
        let model = f.sidebar(f.text(["October 15, 2026 at 12:30 PM"]))
        await model.beginDraft(for: f.thread)
        #expect(await model.createEvent())
        f.calendar.failure = "The calendar is offline."
        await f.env.undo?.undoLast()
        #expect(f.calendar.deleteCalls == 1)
        #expect(f.env.notices.toasts.contains {
            $0.message == "Couldn't remove the event: The calendar is offline. Remove it in your calendar."
        })
    }

    @Test func aProviderThatCannotCreateIsNeverAsked() async throws {
        let refusal = "Reconnect Google Calendar to create events: turn Connect Google Calendar off and on again."
        let f = CalendarFixture(info: CalendarProviderInfo(name: "Google Calendar", account: "robin@example.com",
                                                           createRefusal: refusal))
        let model = f.sidebar(f.text(["October 15, 2026 at 12:30 PM"]))
        await model.beginDraft(for: f.thread)
        #expect(model.createRefusal == refusal && !model.canCreate)
        #expect(await model.createEvent() == false)
        #expect(f.calendar.createCalls == 0 && model.draftNote == refusal && model.draft != nil)
        #expect(CalendarSettingsModel(environment: f.env).createStatus == refusal)
    }

    @Test func theDraftTakesTheMeetDefaultFromSettings() async throws {
        let f = CalendarFixture()
        let model = f.sidebar(f.text(["October 15, 2026 at 12:30 PM"]))
        await model.beginDraft(for: f.thread)
        #expect(model.draft?.addMeetLink == true, "on by default")
        #expect(await model.createEvent())
        guard case .create(let sent)? = f.calendar.calls.first(where: { if case .create = $0 { true } else { false } }) else {
            Issue.record("no create call")
            return
        }
        #expect(sent.addMeetLink && f.calendar.created.first?.meetLink != nil)
        try await f.env.settings!.set(AppSettings.calendarAddMeetLink, false)
        await model.beginDraft(for: f.thread)
        #expect(model.draft?.addMeetLink == false)
    }
}

@MainActor
@Suite struct CalendarLoadTests {
    @Test func aDayIsReadOnceAMinuteAndRefreshReadsAgain() async throws {
        let f = CalendarFixture()
        let model = f.sidebar(f.text(["Can we meet on October 14, 2026 at 3:00 PM?"]))
        await model.show(thread: f.thread)
        #expect(f.calendar.readCalls == 1, "one window read")
        let other = f.corpus.threads[1].row.id
        await model.show(thread: other)
        await model.show(thread: f.thread)
        #expect(f.calendar.readCalls == 1, "the same day comes from the cache")
        #expect(model.days.map(\.start) == [at(10, 14)])
        await model.refresh()
        #expect(f.calendar.readCalls == 2 && f.calendar.changeCalls == 1, "the refresh button reads what changed")
        model.now = { at(10, 10, 9, 2) }
        await model.show(thread: other)
        #expect(f.calendar.readCalls == 3 && f.calendar.changeCalls == 2, "after a minute the calendar is refreshed")
    }

    @Test func aShowWhoseTaskWasCancelledReadsNothing() async throws {
        let f = CalendarFixture()
        let model = f.sidebar(f.text(["October 14, 2026"]))
        let thread = f.thread
        let hidden = Task { @MainActor in await model.show(thread: thread) }
        hidden.cancel()
        await hidden.value
        #expect(f.calendar.readCalls == 0, "a hidden sidebar's load stops")
    }

    @Test func aDraftMadeWhileTheSidebarMovedOnIsDropped() async throws {
        let f = CalendarFixture()
        let first = f.thread
        let second = f.corpus.threads[1].row.id
        let model = f.sidebar()
        let slow = TestGate()
        model.loadText = { thread in
            if thread == first { await slow.wait() }
            return CalendarThreadText(subject: thread == first ? "First" : "Second", texts: ["October 14, 2026"],
                                      participants: [])
        }
        let drafting = Task { @MainActor in await model.beginDraft(for: first) }
        await eventually { model.isVisible }
        await model.show(thread: second)
        slow.release()
        await drafting.value
        #expect(model.thread == second && model.draft == nil, "a draft for the first conversation never sits under the second")
    }
}
