import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let newYork = TimeZone(identifier: "America/New_York")!
private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

private func ny(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    CalendarDateMentions.calendar(newYork).date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
}

private let me = "robin@example.test"
private let sam = EmailAddress(name: "Sam Rivera", email: "sam@example.test")
private let priya = EmailAddress(name: "Priya Natarajan", email: "priya@example.test")
private let theo = EmailAddress(email: "theo@example.test")
private let robin = EmailAddress(name: "Robin Example", email: me)
private let meetLink = URL(string: "https://meet.example.test/abc-defg-hij")!
private let dayStyle = Date.FormatStyle(timeZone: newYork).weekday(.wide).month(.wide).day()

private func review(id: String = "review") -> CalendarEvent {
    var extras = CalendarEventExtras()
    extras.guests = [CalendarGuest(email: sam.email, name: sam.name, response: .accepted),
                     CalendarGuest(email: priya.email, name: priya.name, response: .declined),
                     CalendarGuest(email: theo.email, isOptional: true, response: .needsAction),
                     CalendarGuest(email: robin.email, name: robin.name, response: .tentative)]
    return CalendarEvent(id: id, title: "Vendor review", start: ny(10, 14, 14), end: ny(10, 14, 15),
                         timeZone: losAngeles.identifier, attendees: [sam, priya, theo, robin], meetLink: meetLink,
                         organizerIsMe: false, location: "Juniper room, 200 Example Avenue",
                         notes: "Agenda for the hour\nPre-read: https://docs.example.test/plan", myResponse: .tentative,
                         extras: extras)
}

private func designSync() -> CalendarEvent {
    CalendarEvent(id: "sync", title: "Design sync", start: ny(10, 14, 10), end: ny(10, 14, 10, 30), attendees: [sam],
                  organizerIsMe: true)
}

private func offsite() -> CalendarEvent {
    CalendarEvent(id: "offsite", title: "Team offsite", start: ny(10, 14), end: ny(10, 15), isAllDay: true,
                  timeZone: newYork.identifier)
}

@MainActor
private func details(_ event: CalendarEvent, mine: Set<String> = [me]) -> CalendarEventDetails {
    CalendarEventDetails(event: event, timeZone: newYork, calendarName: "Google Calendar · \(me)", calendarKey: me,
                         myAddresses: mine)
}

@MainActor
@Suite struct CalendarEventDetailsTests {
    @Test func anOrganizerOnlyGuestListDoesNotSupplyTheInviteesAnswer() {
        let organizer = "work@example.test"
        var event = CalendarEvent(id: "copy", title: "Review", start: ny(10, 14, 14), end: ny(10, 14, 15),
                                  attendees: [EmailAddress(email: organizer)], organizerIsMe: false,
                                  account: me)
        event.extras.guests = [CalendarGuest(email: organizer, response: .accepted, isOrganizer: true)]
        let resolved = event.resolvingMyResponse(addresses: [me, organizer])
        let shown = details(resolved, mine: [me, organizer])
        #expect(resolved.myResponse == nil && resolved.respondsAs == nil && !resolved.canRespond)
        #expect(shown.guests.count == 1 && !shown.guests[0].isMe)
        #expect(shown.guests[0].line == organizer && shown.answerText == CalendarEvent.responseNotShown)
    }

    @Test func theDetailsShowTheTimeAndZonePlaceJoinLinkGuestsNotesAndCalendar() {
        let shown = details(review())
        #expect(shown.title == "Vendor review")
        #expect(shown.dayText == ny(10, 14, 14).formatted(dayStyle))
        #expect(shown.timeText == CalendarSidebarModel.range(ny(10, 14, 14), ny(10, 14, 15), newYork))
        #expect(shown.zoneText == "Times in New York")
        #expect(shown.eventZoneText == "\(CalendarSidebarModel.range(ny(10, 14, 14), ny(10, 14, 15), losAngeles)) in Los Angeles",
                "the event's own zone when it differs from the shown one")
        #expect(shown.location == "Juniper room, 200 Example Avenue")
        #expect(shown.joinLink == meetLink)
        #expect(shown.guests.map(\.email) == [sam.email, priya.email, theo.email, robin.email])
        #expect(shown.guests.map(\.response) == [.accepted, .declined, .needsAction, .tentative])
        #expect(shown.guests.map(\.isMe) == [false, false, false, true])
        #expect(shown.guests.map(\.isOptional) == [false, false, true, false])
        #expect(shown.guests.map(\.responseText) == ["Yes", "No", "Not answered", "Maybe"])
        #expect(shown.guests[0].line == "Sam Rivera <sam@example.test>")
        #expect(shown.guests[3].line == "Robin Example <robin@example.test> (you)")
        #expect(shown.guests[2].line == "theo@example.test")
        #expect(shown.guestSummary == "4 guests · 1 yes, 1 maybe, 1 no, 1 not answered")
        #expect(shown.notes?.editableText == "Agenda for the hour\nPre-read: https://docs.example.test/plan")
        #expect(shown.calendarName == "Google Calendar · robin@example.test" && shown.calendarKey == me)
        #expect(shown.colorIndex == CalendarDayTimeline.colorIndex(for: review()))
        #expect(shown.repeatText == nil)
    }

    @Test func voiceOverHearsEachGuestsAnswerAndTheWholeTime() {
        let shown = details(review())
        #expect(shown.guests.map(\.spokenText) == [
            "Sam Rivera, sam@example.test, accepted",
            "Priya Natarajan, priya@example.test, declined",
            "theo@example.test, optional, not answered yet",
            "Robin Example, robin@example.test, you, maybe",
        ])
        #expect(shown.spokenTime == [shown.dayText, shown.timeText, shown.zoneText, shown.eventZoneText]
            .compactMap { $0 }.joined(separator: ", "))
    }

    @Test func someoneElsesEventIsReadOnlyAndSaysMyAnswer() {
        let shown = details(review())
        #expect(!shown.organizedByMe && !shown.canOpenEditor)
        #expect(shown.organizerText == "Someone else organizes this event: only they can change it.")
        #expect(shown.answerText == "Your answer: Maybe")
        let unknown = CalendarEvent(id: "x", title: "Board", start: ny(10, 14, 9), end: ny(10, 14, 10), attendees: [sam])
        #expect(!details(unknown).organizedByMe && !details(unknown).canOpenEditor,
                "with guests and no organizer flag it is not treated as mine")
    }

    @Test func myOwnEventsMayOpenTheEditorButPlaceholdersAndUnsavedOnesMayNot() {
        let organized = details(designSync())
        #expect(organized.organizedByMe && organized.canOpenEditor)
        #expect(organized.organizerText == "You organize this event." && organized.answerText == nil)
        let personal = details(CalendarEvent(id: "focus", title: "Focus", start: ny(10, 14, 11), end: ny(10, 14, 12)))
        #expect(personal.organizedByMe && personal.canOpenEditor && personal.organizerText == nil)
        let placeholder = details(CalendarEvent(id: CalendarSidebarModel.placeholderPrefix + "1", title: "Lunch",
                                                start: ny(10, 14, 12), end: ny(10, 14, 13), organizerIsMe: true))
        #expect(placeholder.organizedByMe && !placeholder.canOpenEditor, "still being created")
        let unsaved = details(CalendarEvent(id: "", title: "Draft", start: ny(10, 14, 12), end: ny(10, 14, 13),
                                            organizerIsMe: true))
        #expect(!unsaved.canOpenEditor)
    }

    @Test func plainAttendeesFallBackToMyOwnAnswerAndOthersHaveNone() {
        let event = CalendarEvent(id: "plain", title: "Catch-up", start: ny(10, 14, 9), end: ny(10, 14, 9, 30),
                                  attendees: [sam, robin], organizerIsMe: false, myResponse: .accepted)
        let shown = details(event)
        #expect(shown.guests.map(\.response) == [nil, .accepted])
        #expect(shown.guests.map(\.isMe) == [false, true])
        #expect(shown.guests[0].responseText == nil && shown.guests[0].spokenText == "Sam Rivera, sam@example.test")
        #expect(shown.guestSummary == "2 guests · 1 yes")
        #expect(details(event, mine: []).guests.allSatisfy { $0.response == nil && !$0.isMe })
        let single = CalendarEvent(id: "one", title: "1:1", start: ny(10, 14, 9), end: ny(10, 14, 9, 30), attendees: [sam])
        #expect(details(single).guestSummary == "1 guest")
    }

    @Test func allDayAndMultiDayEventsNameTheirDays() {
        let day = details(offsite())
        #expect(day.dayText == ny(10, 14).formatted(dayStyle) && day.timeText == "All day")
        #expect(day.zoneText == nil && day.eventZoneText == nil)
        let long = details(CalendarEvent(id: "conf", title: "Conference", start: ny(10, 14), end: ny(10, 17), isAllDay: true))
        #expect(long.dayText == "\(ny(10, 14).formatted(dayStyle)) – \(ny(10, 16).formatted(dayStyle))")
        #expect(long.timeText == "All day")
        let overnight = details(CalendarEvent(id: "late", title: "Release", start: ny(10, 14, 22), end: ny(10, 15, 1)))
        #expect(overnight.dayText == (ny(10, 14, 22)..<ny(10, 15, 1))
            .formatted(Date.IntervalFormatStyle(date: .abbreviated, time: .shortened, timeZone: newYork)))
        #expect(overnight.timeText == nil && overnight.zoneText == "Times in New York")
    }

    @Test func theEventsOwnZoneShowsItsDayWhenItDiffersAndHidesWhenTheClockIsTheSame() {
        let early = CalendarEvent(id: "early", title: "Call", start: ny(10, 15, 1), end: ny(10, 15, 2),
                                  timeZone: losAngeles.identifier)
        let weekday = ny(10, 15, 1).formatted(Date.FormatStyle(timeZone: losAngeles).weekday(.abbreviated))
        let range = CalendarSidebarModel.range(ny(10, 15, 1), ny(10, 15, 2), losAngeles)
        #expect(details(early).eventZoneText == "\(weekday) \(range) in Los Angeles", "10 PM the evening before")
        let sameClock = CalendarEvent(id: "same", title: "Call", start: ny(10, 14, 9), end: ny(10, 14, 10),
                                      timeZone: "America/Detroit")
        #expect(details(sameClock).eventZoneText == nil)
        let unknown = CalendarEvent(id: "odd", title: "Call", start: ny(10, 14, 9), end: ny(10, 14, 10), timeZone: "Mars/Base")
        #expect(details(unknown).eventZoneText == nil)
    }

    @Test func emptyFieldsStayHiddenAndOnlyAWebLinkJoins() {
        let bare = CalendarEvent(id: "bare", title: "  ", start: ny(10, 14, 9), end: ny(10, 14, 10),
                                 meetLink: URL(string: "javascript:alert(1)"), location: "  ", notes: "")
        let shown = details(bare)
        #expect(shown.title == "(No title)")
        #expect(shown.joinLink == nil && shown.location == nil && shown.notes == nil)
        #expect(shown.guests.isEmpty && shown.guestSummary == nil)
    }

    @Test func repeatingEventsSayHowTheyRepeat() {
        var weekly = designSync()
        weekly.extras.recurrence = ["RRULE:FREQ=WEEKLY"]
        #expect(details(weekly).repeatText == "Every week")
        var instance = designSync()
        instance.recurringEventID = "series-1"
        #expect(details(instance).repeatText == "Repeats")
        var custom = designSync()
        custom.extras.recurrence = ["RRULE:FREQ=WEEKLY;INTERVAL=3"]
        #expect(details(custom).repeatText == "Repeats")
    }
}

@MainActor
private struct DetailsFixture {
    let env: AppEnvironment
    let calendar: FakeCalendar
    let corpus: FakeCorpus

    init(events: [CalendarEvent]) {
        corpus = .make(threadCount: 3, now: fixedNow)
        calendar = FakeCalendar(events: events, info: CalendarProviderInfo(name: "Google Calendar", account: me))
        env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), featureFlags: FeatureFlags(),
                                  calendar: calendar)
    }

    func sidebar() async -> CalendarSidebarModel {
        let model = env.calendarSidebar!
        model.timeZone = newYork
        model.now = { ny(10, 14, 9) }
        model.loadText = { _ in nil }
        await model.show(thread: nil)
        return model
    }

    var wroteNothing: Bool { calendar.readCalls == calendar.calls.count }
}

@MainActor
@Suite struct CalendarSidebarEventDetailsTests {
    @Test func clickingAnEventShowsItsDetailsAndEscapeKeepsItChosen() async throws {
        let f = DetailsFixture(events: [review(), designSync(), offsite()])
        let model = await f.sidebar()
        #expect(model.state == .loaded)
        #expect(model.focusableEvents.map(\.id) == ["offsite", "sync", "review"], "all-day first, then by start")
        let event = try #require(model.focusableEvents.first { $0.id == "review" })
        model.openEvent(event)
        let shown = try #require(model.openedDetails)
        #expect(shown.title == "Vendor review" && shown.calendarName == "Google Calendar · robin@example.test")
        #expect(shown.calendarKey == me && shown.guests.last?.isMe == true)
        #expect(model.isOpened(event) && model.isFocused(event))
        model.closeEvent(keepsFocus: true)
        #expect(model.openedDetails == nil && model.isFocused(event), "Escape leaves the keyboard on the event")
        #expect(model.openFocusedEvent() && model.openedEvent?.id == "review", "Return opens it again")
        model.closeEvent()
        #expect(model.openedEvent == nil && model.focusedEventKey == nil, "the close button lets go of it")
        #expect(f.wroteNothing)
    }

    @Test func theArrowsChooseEventsInOrderAndAnOpenCardFollowsThem() async throws {
        let f = DetailsFixture(events: [review(), designSync(), offsite()])
        let model = await f.sidebar()
        let shown = model.focusableEvents
        #expect(shown.map(\.id) == ["offsite", "sync", "review"])
        let first = try #require(shown.first)
        let second = try #require(shown.dropFirst().first)
        let last = try #require(shown.last)
        #expect(model.moveEventFocus(by: 1) && model.focusedEventKey == first.copyKey)
        #expect(model.moveEventFocus(by: 1) && model.focusedEventKey == second.copyKey)
        #expect(model.openedEvent == nil, "choosing alone opens nothing")
        #expect(model.openFocusedEvent() && model.openedEvent?.id == "sync")
        #expect(model.moveEventFocus(by: 1) && model.openedEvent?.id == "review")
        #expect(model.moveEventFocus(by: 1) && model.openedEvent?.id == "review", "the last event stays chosen")
        #expect(model.moveEventFocus(by: -5) && model.openedEvent?.id == "offsite")
        model.closeEvent()
        #expect(model.moveEventFocus(by: -1) && model.focusedEventKey == last.copyKey,
                "up with nothing chosen starts at the last event")
        #expect(f.wroteNothing)
    }

    @Test func returnWithNothingChosenOpensTheFirstEventAndAnEmptyDayDoesNothing() async {
        let f = DetailsFixture(events: [designSync(), review()])
        let model = await f.sidebar()
        #expect(model.openFocusedEvent() && model.openedEvent?.id == "sync")
        let emptyDay = DetailsFixture(events: [])
        let empty = await emptyDay.sidebar()
        #expect(!empty.moveEventFocus(by: 1) && !empty.openFocusedEvent())
        #expect(empty.openedEvent == nil && empty.focusedEventKey == nil)
        #expect(f.wroteNothing && emptyDay.wroteNothing)
    }

    @Test func theCardShowsTheLatestCopyOfItsEvent() async throws {
        let f = DetailsFixture(events: [review()])
        let model = await f.sidebar()
        model.openEvent(try #require(model.focusableEvents.first))
        var moved = review()
        moved.location = "Cedar room"
        model.eventStore.applyLocal(CalendarEventStore.key(for: f.calendar), upsert: moved)
        #expect(model.openedDetails?.location == "Cedar room")
        #expect(f.wroteNothing)
    }

    @Test func anotherDayAConversationADraftOrHidingTheSidebarClosesTheCard() async throws {
        let f = DetailsFixture(events: [review(), designSync()])
        let model = await f.sidebar()
        model.openEvent(try #require(model.focusableEvents.first))
        await model.moveDayInstantly(by: 1)?.value
        #expect(model.openedEvent == nil && model.focusedEventKey == nil, "the event is not on the new day")
        await model.goToTodayInstantly().value
        model.openEvent(try #require(model.focusableEvents.first))
        await model.show(thread: nil)
        #expect(model.openedEvent?.id == "sync", "the same conversation keeps it")
        await model.show(thread: f.corpus.threads[0].row.id)
        #expect(model.openedEvent == nil, "another conversation closes it")
        model.openEvent(try #require(model.focusableEvents.first))
        await model.beginDraft(for: nil)
        #expect(model.draft != nil && model.openedEvent == nil, "a new event takes the sidebar")
        model.cancelDraft()
        model.openEvent(try #require(model.focusableEvents.first))
        model.setVisible(false)
        #expect(model.openedEvent == nil && model.focusedEventKey == nil)
        #expect(f.wroteNothing)
    }
}

@MainActor
@Suite struct CalendarWindowEditorFromDetailsTests {
    @Test func editOpensTheExistingEditorOnTheEventsCalendarAndDayWithoutWriting() async throws {
        let corpus = FakeCorpus.rich(threadCount: 6, now: fixedNow)
        let workEmail = corpus.accounts[0].email
        let homeEmail = corpus.accounts[1].email
        func planning(_ title: String) -> CalendarEvent {
            CalendarEvent(id: "shared", title: title, start: ny(10, 21, 10), end: ny(10, 21, 11), organizerIsMe: true)
        }
        let work = FakeCalendar(events: [planning("Work planning")],
                                info: CalendarProviderInfo(name: "Google Calendar", account: workEmail))
        let home = FakeCalendar(events: [planning("Home planning")],
                                info: CalendarProviderInfo(name: "Google Calendar", account: homeEmail))
        let connections = FakeCalendarConnections(providers: [workEmail: work, homeEmail: home])
        let env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), featureFlags: FeatureFlags(),
                                      calendar: work, calendarConnections: connections)
        let sidebar = try #require(env.calendarSidebar)
        sidebar.timeZone = newYork
        sidebar.now = { ny(10, 21, 9) }
        sidebar.loadText = { _ in nil }
        let workAccount = corpus.accounts[0].id
        sidebar.activeAccount = { workAccount }
        await sidebar.show(thread: nil)
        let event = try #require(sidebar.focusableEvents.first)
        sidebar.openEvent(event)
        let shown = try #require(sidebar.openedDetails)
        #expect(shown.title == "Work planning" && shown.canOpenEditor)
        #expect(shown.calendarKey == workEmail.lowercased())

        let window = try #require(env.calendarWindow)
        window.timeZone = newYork
        window.now = { ny(10, 14, 9) }
        window.confirmsMovesOverride = false
        await window.openEditor(for: shown.event, calendarKey: shown.calendarKey)
        #expect(window.isOpen && window.period.contains(ny(10, 21, 10)), "on the event's week, not today's")
        #expect(window.card?.event.title == "Work planning")
        #expect(window.card?.event.account == workEmail.lowercased() && window.card?.canEditDetails == true)
        window.closeCard()
        await window.openEditor(for: shown.event, calendarKey: homeEmail.lowercased())
        #expect(window.card?.event.title == "Home planning", "the same id on another calendar is that calendar's event")
        #expect(work.readCalls == work.calls.count && home.readCalls == home.calls.count, "opening writes nothing")
        withExtendedLifetime(env) {}
    }
}
