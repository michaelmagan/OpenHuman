import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
private let laCalendar = CalendarDateMentions.calendar(losAngeles)

private func la(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    laCalendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
}

private let dana = EmailAddress(name: "Dana Ruiz", email: "dana@example.com")
private let sam = EmailAddress(name: "Sam Lee", email: "sam@example.org")
private let meetingUID = "planning-7f3a@example.com"

private func copy(_ id: String, account: String? = nil, at start: Date, minutes: Int = 60, uid: String? = meetingUID,
                  organizerIsMe: Bool?, response: CalendarResponse? = nil, attendees: [EmailAddress],
                  guests: [CalendarGuest] = [], series: String? = nil, originalStart: Date? = nil,
                  omitted: Bool = false) -> CalendarEvent {
    CalendarEvent(id: id, title: "Planning", start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                  attendees: attendees, organizerIsMe: organizerIsMe, account: account, myResponse: response,
                  recurringEventID: series, originalStartTime: originalStart.map { .timed($0, timeZone: nil) },
                  extras: CalendarEventExtras(guests: guests), uid: uid, guestsOmitted: omitted)
}

@MainActor
private final class MeetingClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
private struct MeetingFixture {
    let env: AppEnvironment
    let work: FakeCalendar
    let home: FakeCalendar
    let connections: FakeCalendarConnections
    let workEmail: String
    let homeEmail: String
    let holdGate = TestGate()
    let settleGate = TestGate()
    let clock = MeetingClock(la(10, 12, 11))

    static let hold: Duration = .seconds(1)
    static let settle: Duration = .seconds(2)

    // `work` and `home` build each account's own copies from the two account addresses; `removes` lets both calendars
    // take an invitation off silently, as Google does
    init(work: (_ work: EmailAddress, _ home: EmailAddress) -> [CalendarEvent],
         home: (_ work: EmailAddress, _ home: EmailAddress) -> [CalendarEvent], followsConnection: Bool = false,
         removes: Bool = false) {
        let corpus = FakeCorpus.rich(threadCount: 12, now: fixedNow)
        let accounts = corpus.accounts
        let workAddress = EmailAddress(name: "Robin Example", email: accounts[0].email.lowercased())
        let homeAddress = EmailAddress(name: "Robin Example", email: accounts[1].email.lowercased())
        workEmail = workAddress.email
        homeEmail = homeAddress.email
        let abilities: CalendarAbilities = removes ? [.respond, .editDetails, .remove, .removeInvite]
                                                   : [.respond, .editDetails, .remove]
        self.work = FakeCalendar(events: work(workAddress, homeAddress),
                                 info: CalendarProviderInfo(name: "Google Calendar", account: accounts[0].email),
                                 abilities: abilities)
        self.home = FakeCalendar(events: home(workAddress, homeAddress),
                                 info: CalendarProviderInfo(name: "Google Calendar", account: accounts[1].email),
                                 abilities: abilities)
        connections = FakeCalendarConnections(connected: [accounts[0].email, accounts[1].email],
                                              providers: [accounts[0].email: self.work, accounts[1].email: self.home],
                                              followsConnection: followsConnection)
        env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), featureFlags: FeatureFlags(),
                                  calendar: self.work, calendarConnections: connections)
    }

    func window() -> CalendarWindowModel {
        let clock = self.clock
        let sidebar = env.calendarSidebar!
        sidebar.timeZone = losAngeles
        sidebar.now = { clock.now }
        let model = env.calendarWindow!
        model.timeZone = losAngeles
        model.now = { clock.now }
        model.confirmsMovesOverride = false
        model.holdWindow = Self.hold
        model.copySettleDelay = Self.settle
        let holdGate = self.holdGate, settleGate = self.settleGate, settle = Self.settle
        model.sleep = { duration in
            if duration == settle { await settleGate.wait() } else { await holdGate.wait() }
        }
        return model
    }

    // Lets the held write run to its end, without the later re-read of the other calendars
    func finishHeld(_ model: CalendarWindowModel) async {
        let tasks = Array(model.held.values)
        holdGate.release()
        for task in tasks { await task.value }
    }

    func finishSettle(_ model: CalendarWindowModel) async {
        let task = model.settleTask
        settleGate.release()
        await task?.value
    }
}

private func organizedOnWork(_ work: EmailAddress, _ home: EmailAddress) -> [CalendarEvent] {
    [copy("work-copy", at: la(10, 13, 10), organizerIsMe: true, attendees: [home, sam],
          guests: [CalendarGuest(email: work.email, name: work.name, response: .accepted, isOrganizer: true),
                   CalendarGuest(email: home.email, name: home.name, response: .needsAction),
                   CalendarGuest(email: sam.email, name: sam.name, response: .accepted)])]
}

private func invitedOnHome(_ work: EmailAddress, _ home: EmailAddress) -> [CalendarEvent] {
    [copy("home-copy", at: la(10, 13, 10), organizerIsMe: nil, response: .needsAction, attendees: [work, home],
          guests: [CalendarGuest(email: work.email, name: work.name, response: .accepted, isOrganizer: true),
                   CalendarGuest(email: home.email, name: home.name, response: .needsAction, isOrganizer: false)],
          omitted: true)]
}

// The invited copy as Google marks it when it names an organizer other than this calendar
private func guestOnHome(_ work: EmailAddress, _ home: EmailAddress) -> [CalendarEvent] {
    [copy("home-copy", at: la(10, 13, 10), organizerIsMe: false, response: .needsAction, attendees: [work, home])]
}

private func guestOnWork(_ work: EmailAddress, _ home: EmailAddress) -> [CalendarEvent] {
    [copy("work-copy", at: la(10, 13, 10), organizerIsMe: false, response: .accepted, attendees: [dana, work, home])]
}

private func guestOfDanaOnHome(_ work: EmailAddress, _ home: EmailAddress) -> [CalendarEvent] {
    [copy("home-copy", at: la(10, 13, 10), organizerIsMe: false, response: .needsAction, attendees: [dana, work, home])]
}

private func scopedRemovals(_ calendar: FakeCalendar) -> [FakeCalendar.Call] {
    calendar.calls.filter { if case .scopedRemove = $0 { true } else { false } }
}

private func respondCalls(_ calendar: FakeCalendar) -> [FakeCalendar.Call] {
    calendar.calls.filter { if case .respond = $0 { true } else { false } }
}

private func writeCalls(_ calendar: FakeCalendar) -> [FakeCalendar.Call] {
    calendar.calls.filter {
        switch $0 {
        case .move, .update, .remove, .scopedRemove, .delete, .patch, .respond, .create: true
        case .events, .freeBusy, .window, .changes: false
        }
    }
}

@MainActor
@Suite struct CalendarCopyGroupingTests {
    private let order = ["work@example.com", "home@example.com"]

    @Test func copiesOfOneMeetingOnTwoAccountsBecomeOneEventShownAsTheOrganizersCopy() throws {
        let invited = copy("b", account: "home@example.com", at: la(10, 13, 10), organizerIsMe: nil,
                           response: .needsAction, attendees: [dana])
        let organized = copy("a", account: "work@example.com", at: la(10, 13, 10), organizerIsMe: true, attendees: [dana])
        let other = copy("c", account: "home@example.com", at: la(10, 13, 10), uid: "other@example.com",
                         organizerIsMe: true, attendees: [])
        let shown = CalendarCopyGroups.group([invited, organized, other], accountOrder: order)
        #expect(shown.count == 2)
        let meeting = try #require(shown.first)
        #expect(meeting.copyKey == organized.copyKey, "the copy the user organizes is shown and edited")
        #expect(meeting.copies.map(\.copyKey) == [organized.copyKey, invited.copyKey])
        #expect(meeting.copies.allSatisfy { $0.copies.isEmpty })
        #expect(meeting.isMerged && !shown[1].isMerged)
    }

    @Test func withoutAnOrganizerCopyTheFirstCalendarInTheListIsShown() {
        let onHome = copy("h", account: "home@example.com", at: la(10, 13, 10), organizerIsMe: nil, response: .accepted,
                          attendees: [dana])
        let onWork = copy("w", account: "work@example.com", at: la(10, 13, 10), organizerIsMe: nil,
                          response: .needsAction, attendees: [dana])
        let meeting = CalendarCopyGroups.group([onHome, onWork], accountOrder: order)
        #expect(meeting.count == 1 && meeting.first?.copyKey == onWork.copyKey)
        #expect(meeting.first?.copies.map(\.account) == ["work@example.com", "home@example.com"])
    }

    @Test func aMissingUIDOrAPlaceholderIsNeverGrouped() {
        let noUID = [copy("a", account: "work@example.com", at: la(10, 13, 10), uid: nil, organizerIsMe: true, attendees: []),
                     copy("b", account: "home@example.com", at: la(10, 13, 10), uid: nil, organizerIsMe: nil,
                          attendees: [dana])]
        #expect(CalendarCopyGroups.group(noUID, accountOrder: order).count == 2)
        let blank = [copy("a", account: "work@example.com", at: la(10, 13, 10), uid: "  ", organizerIsMe: true, attendees: []),
                     copy("b", account: "home@example.com", at: la(10, 13, 10), uid: "  ", organizerIsMe: nil,
                          attendees: [dana])]
        #expect(CalendarCopyGroups.group(blank, accountOrder: order).count == 2)
        let placeholder = [copy(CalendarSidebarModel.placeholderPrefix + "1", account: "work@example.com", at: la(10, 13, 10),
                                organizerIsMe: true, attendees: []),
                           copy("b", account: "home@example.com", at: la(10, 13, 10), organizerIsMe: nil, attendees: [dana])]
        #expect(CalendarCopyGroups.group(placeholder, accountOrder: order).count == 2)
        let untagged = [copy("a", at: la(10, 13, 10), organizerIsMe: true, attendees: []),
                        copy("b", at: la(10, 13, 10), organizerIsMe: nil, attendees: [dana])]
        #expect(CalendarCopyGroups.group(untagged, accountOrder: order).count == 2, "a copy needs its account")
    }

    @Test func occurrencesOfARepeatingMeetingAreGroupedPerOccurrenceAndNeverWithinOneAccount() {
        let first = la(10, 13, 10), second = la(10, 15, 10)
        let events = [
            copy("s_1", account: "work@example.com", at: first, organizerIsMe: true, attendees: [dana], series: "s",
                 originalStart: first),
            copy("s_2", account: "work@example.com", at: second.addingTimeInterval(3_600), organizerIsMe: true,
                 attendees: [dana], series: "s", originalStart: second),
            copy("t_1", account: "home@example.com", at: first, organizerIsMe: nil, response: .needsAction,
                 attendees: [dana], series: "t", originalStart: first),
            copy("t_2", account: "home@example.com", at: second, organizerIsMe: nil, response: .needsAction,
                 attendees: [dana], series: "t", originalStart: second),
            copy("t_3", account: "home@example.com", at: la(10, 17, 10), organizerIsMe: nil, response: .needsAction,
                 attendees: [dana], series: "t", originalStart: la(10, 17, 10)),
        ]
        let shown = CalendarCopyGroups.group(events, accountOrder: order)
        #expect(shown.map(\.id) == ["s_1", "s_2", "t_3"])
        #expect(shown.map(\.copies.count) == [2, 2, 0])
        #expect(shown[1].copies.map(\.id) == ["s_2", "t_2"], "a moved occurrence keeps its start in the series")
        #expect(shown[1].copiesDisagreeOnTime)
        let twins = [copy("x", account: "work@example.com", at: first, organizerIsMe: true, attendees: [dana]),
                     copy("y", account: "work@example.com", at: second, organizerIsMe: true, attendees: [dana])]
        #expect(CalendarCopyGroups.group(twins, accountOrder: order).allSatisfy { !$0.isMerged },
                "two events of one account with the same UID stay apart")
    }

    @Test func copiesThatDisagreeOnTimeShowTheOrganizersTimeAndSaySo() throws {
        let organized = copy("a", account: "work@example.com", at: la(10, 13, 11), organizerIsMe: true, attendees: [dana])
        let stale = copy("b", account: "home@example.com", at: la(10, 13, 10), organizerIsMe: nil, response: .accepted,
                         attendees: [dana])
        let meeting = try #require(CalendarCopyGroups.group([stale, organized], accountOrder: order).first)
        #expect(meeting.start == la(10, 13, 11) && meeting.copiesDisagreeOnTime)
        #expect(CalendarCopyGroups.timeNote(for: meeting)
                == "Your calendars show different times. This is the time on work@example.com, where you organize it.")
        let agreed = try #require(CalendarCopyGroups.group([organized, stale.with(start: organized.start, end: organized.end)],
                                                           accountOrder: order).first)
        #expect(!agreed.copiesDisagreeOnTime && CalendarCopyGroups.timeNote(for: agreed) == nil)
    }

    @Test func theMeetingIsDrawnWithTheBestAnswerOfItsCopies() throws {
        func drawn(_ responses: [CalendarResponse?], organizer: Bool = false) throws -> CalendarAttendance {
            var events: [CalendarEvent] = []
            for (index, response) in responses.enumerated() {
                events.append(copy("e\(index)", account: order[index], at: la(10, 13, 10),
                                   organizerIsMe: organizer && index == 0 ? true : nil, response: response,
                                   attendees: [dana]))
            }
            return try #require(CalendarCopyGroups.group(events, accountOrder: order).first).drawnAttendance
        }
        #expect(try drawn([nil, .needsAction], organizer: true) == .going, "the organizer's copy is filled")
        #expect(try drawn([nil, .declined], organizer: true) == .going, "declined on one copy only")
        #expect(try drawn([.declined, .needsAction]) == .invited)
        #expect(try drawn([.tentative, .needsAction]) == .maybe)
        #expect(try drawn([.declined, .declined]) == .declined, "declined only when every copy is")
        let single = copy("s", account: "work@example.com", at: la(10, 13, 10), organizerIsMe: nil,
                          response: .needsAction, attendees: [dana])
        #expect(single.drawnAttendance == .invited && single.drawnAttendance == single.attendance)
    }

    @Test func theFullestGuestListIsUsedAndTheOrganizersCopyWinsATie() throws {
        let full = [CalendarGuest(email: "work@example.com", isOrganizer: true), CalendarGuest(email: "home@example.com"),
                    CalendarGuest(sam)]
        let organized = copy("a", account: "work@example.com", at: la(10, 13, 10), organizerIsMe: true,
                             attendees: [sam], guests: full)
        let partial = copy("b", account: "home@example.com", at: la(10, 13, 10), organizerIsMe: nil,
                           response: .needsAction, attendees: [dana], guests: [CalendarGuest(email: "work@example.com")],
                           omitted: true)
        let meeting = try #require(CalendarCopyGroups.group([partial, organized], accountOrder: order.reversed()).first)
        #expect(meeting.copyKey == organized.copyKey && meeting.fullestGuestList.copyKey == organized.copyKey)
        let same = copy("b", account: "home@example.com", at: la(10, 13, 10), organizerIsMe: nil, response: .accepted,
                        attendees: [dana], guests: full)
        let tie = try #require(CalendarCopyGroups.group([same, organized.with(start: organized.start, end: organized.end)],
                                                        accountOrder: order).first)
        #expect(tie.fullestGuestList.copyKey == organized.copyKey)
    }
}

@MainActor
@Suite struct CalendarMeetingCopiesWindowTests {
    @Test func theWindowDrawsOneBlockForTheMeetingInTheOrganizersColour() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: invitedOnHome)
        let model = f.window()
        await model.open()
        #expect(model.events.count == 2, "the store keeps both copies")
        let blocks = model.timeGrid.blocks
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(block.columns == 1 && block.event.isMerged)
        #expect(block.event.account == f.workEmail)
        #expect(block.colorIndex == model.sources.first { $0.key == f.workEmail }?.colorIndex)
        #expect(!block.isInvited && !block.isDeclined && !block.isTentative, "the organizer's copy is filled")
        #expect(block.event.copies.map(\.account) == [f.workEmail, f.homeEmail])
    }

    @Test func theCardNamesEachCopyAndWhereChangesAreSaved() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: invitedOnHome)
        let model = f.window()
        await model.open()
        let meeting = try #require(model.shownEvents.first)
        model.openEvent(meeting)
        let card = try #require(model.card)
        #expect(model.selectedEventID == meeting.copyKey)
        #expect(card.calendarKey == f.workEmail && !card.canRespond)
        #expect(card.copies.map(\.account) == [f.workEmail, f.homeEmail])
        #expect(card.copies.map(\.status) == ["You organize it", "Invited · Not answered"])
        #expect(card.copies.map(\.canRespond) == [false, true])
        #expect(card.copies.map(\.receivesChanges) == [true, false])
        #expect(card.changesAccount == f.workEmail && card.copiesNote == nil)
    }

    @Test func answeringOnTheInvitedCopyGoesToThatAccountOnlyAndReadsTheCalendarsAgainLater() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: invitedOnHome)
        let model = f.window()
        await model.open()
        model.openEvent(try #require(model.shownEvents.first))
        let homeRow = try #require(model.card?.copies.last)
        await model.respond(.accepted, onCopy: homeRow.id)
        #expect(model.card?.copies.last?.response == .accepted && model.card?.copies.last?.status == "Invited · Yes")
        #expect(model.shownEvents.first?.copies.last?.myResponse == .accepted, "shown while the answer is held")
        #expect(respondCalls(f.home).isEmpty, "nothing is sent during the hold")
        await f.finishHeld(model)
        #expect(respondCalls(f.home) == [.respond(id: "home-copy", response: .accepted, sendUpdates: .all)])
        #expect(writeCalls(f.work).isEmpty, "the organizer's calendar is not written")
        #expect(f.home.allEvents.first?.myResponse == .accepted)
        #expect(model.overlays.isEmpty && model.heldCount == 0)
        #expect(model.settleTask != nil, "one later re-read of the meeting's calendars")
        let readAfterWrite = model.lastRead
        f.clock.now = la(10, 12, 11, 1)
        let homeReads = f.home.readCalls
        await f.finishSettle(model)
        #expect(f.home.readCalls > homeReads && model.lastRead == la(10, 12, 11, 1) && model.lastRead != readAfterWrite)
        #expect(model.shownEvents.first?.copies.last?.myResponse == .accepted)
    }

    @Test func movingTheMeetingWritesOnlyTheOrganizersCopy() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: invitedOnHome)
        let model = f.window()
        await model.open()
        let meeting = try #require(model.shownEvents.first)
        await model.moveEvent(meeting, to: la(10, 13, 14), end: la(10, 13, 15))
        #expect(model.shownEvents.count == 1 && model.shownEvents.first?.start == la(10, 13, 14),
                "still one meeting while the copies disagree")
        #expect(model.shownEvents.first?.copiesDisagreeOnTime == true)
        await f.finishHeld(model)
        #expect(writeCalls(f.work) == [.move(id: "work-copy", start: la(10, 13, 14), end: la(10, 13, 15), sendUpdates: .all)])
        #expect(writeCalls(f.home).isEmpty)
        #expect(model.settleTask != nil)
        await f.finishSettle(model)
    }

    @Test func aCopyShowingAnotherTimeIsNamedAndTheOrganizersTimeIsShown() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: { work, home in
            [copy("home-copy", at: la(10, 13, 9), organizerIsMe: nil, response: .accepted, attendees: [work, home])]
        })
        let model = f.window()
        await model.open()
        let meeting = try #require(model.shownEvents.first)
        #expect(model.shownEvents.count == 1 && meeting.start == la(10, 13, 10))
        model.openEvent(meeting)
        let card = try #require(model.card)
        #expect(card.copiesNote
                == "Your calendars show different times. This is the time on \(f.workEmail), where you organize it.")
        #expect(card.copies.map(\.timeText) == [nil, CalendarSidebarModel.range(la(10, 13, 9), la(10, 13, 10), losAngeles)])
    }

    @Test func deletingTheMeetingYouOrganizeSaysTheInvitedCalendarLosesItToo() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: invitedOnHome)
        let model = f.window()
        await model.open()
        model.openEvent(try #require(model.shownEvents.first))
        model.askToRemoveCardEvent()
        let question = try #require(model.removeQuestion)
        #expect(question.alsoOn == [f.homeEmail] && question.text.contains("canceled on \(f.homeEmail) too"))
        #expect(question.account == f.workEmail && question.keptOn.isEmpty && !question.isInvite)
        await model.confirmRemove()
        #expect(model.shownEvents.isEmpty, "both copies leave while the delete is held")
        #expect(model.linkedOverlays.values.first?.count == 1)
        await f.finishHeld(model)
        #expect(writeCalls(f.work) == [.scopedRemove(id: "work-copy", scope: .thisEvent, sendUpdates: .all)])
        #expect(writeCalls(f.home).isEmpty, "the invited copy is never deleted from Mail")
        #expect(model.shownEvents.isEmpty, "until the later re-read")
        f.home.remove(id: "home-copy")
        await f.finishSettle(model)
        #expect(model.shownEvents.isEmpty && model.overlays.isEmpty)
    }

    @Test func undoingAHeldDeleteBringsBackBothCopies() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: invitedOnHome)
        let model = f.window()
        await model.open()
        model.openEvent(try #require(model.shownEvents.first))
        await model.removeCardEvent()
        #expect(model.removeQuestion != nil && model.heldCount == 0, "Delete always asks first")
        await model.confirmRemove()
        #expect(model.shownEvents.isEmpty)
        let tasks = Array(model.held.values)
        await f.env.undo?.undoLast()
        #expect(model.overlays.isEmpty && model.linkedOverlays.isEmpty && model.settling.isEmpty)
        #expect(model.pendingRemovals.isEmpty)
        #expect(model.shownEvents.count == 1 && model.shownEvents.first?.isMerged == true)
        f.holdGate.release()
        for task in tasks { await task.value }
        #expect(writeCalls(f.work).isEmpty && writeCalls(f.home).isEmpty && model.settleTask == nil)
    }

    @Test func whenBothCopiesHaveTheSameEventIDEachAnswerStillGoesToItsOwnAccount() async throws {
        let f = MeetingFixture(work: { work, home in
            [copy("shared", at: la(10, 13, 10), organizerIsMe: nil, response: .needsAction, attendees: [dana, work, home])]
        }, home: { work, home in
            [copy("shared", at: la(10, 13, 10), organizerIsMe: nil, response: .needsAction, attendees: [dana, work, home])]
        })
        let model = f.window()
        await model.open()
        #expect(model.timeGrid.blocks.count == 1 && model.timeGrid.blocks.first?.isInvited == true)
        model.openEvent(try #require(model.shownEvents.first))
        let card = try #require(model.card)
        #expect(card.calendarKey == f.workEmail && card.copies.map(\.canRespond) == [true, true])
        #expect(card.copies.map(\.receivesChanges) == [false, false], "someone else organizes it")
        await model.respond(.declined, onCopy: card.copies[1].id)
        await f.finishHeld(model)
        #expect(respondCalls(f.home) == [.respond(id: "shared", response: .declined, sendUpdates: .all)])
        #expect(respondCalls(f.work).isEmpty)
        #expect(model.timeGrid.blocks.first?.isInvited == true, "still waiting for the work account's answer")
        await f.finishSettle(model)
    }

    @Test func declinedOnOneCopyIsStillDrawnAndDeclinedOnEveryCopyIsStruckThrough() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: { work, home in
            [copy("home-copy", at: la(10, 13, 10), organizerIsMe: nil, response: .declined, attendees: [work, home])]
        })
        let model = f.window()
        await model.open()
        let block = try #require(model.timeGrid.blocks.first)
        #expect(model.timeGrid.blocks.count == 1 && !block.isDeclined)
        model.openEvent(block.event)
        #expect(model.card?.copies.last?.status == "Invited · No")

        let both = MeetingFixture(work: { _, _ in
            [copy("w", at: la(10, 13, 10), organizerIsMe: nil, response: .declined, attendees: [dana])]
        }, home: { _, _ in
            [copy("h", at: la(10, 13, 10), organizerIsMe: nil, response: .declined, attendees: [dana])]
        })
        let declined = both.window()
        await declined.open()
        #expect(declined.timeGrid.blocks.count == 1 && declined.timeGrid.blocks.first?.isDeclined == true)
    }

    @Test func aHiddenCalendarsCopyIsLeftOut() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: invitedOnHome)
        let model = f.window()
        await model.open()
        #expect(model.shownEvents.first?.isMerged == true)
        await model.setVisible(f.homeEmail, false)
        #expect(model.shownEvents.count == 1 && model.shownEvents.first?.isMerged == false)
        #expect(model.shownEvents.first?.account == f.workEmail)
        await model.setVisible(f.homeEmail, true)
        #expect(model.shownEvents.first?.isMerged == true)
    }

    @Test func afterAnAccountIsDisconnectedItsCopyIsNotAnsweredOnAnotherAccount() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: invitedOnHome, followsConnection: true)
        let model = f.window()
        await model.open()
        model.openEvent(try #require(model.shownEvents.first))
        let homeRow = try #require(model.card?.copies.last)
        try await f.connections.connection(f.homeEmail).disconnect()
        await model.load(force: false)
        #expect(model.sources.map(\.key) == [f.workEmail])
        #expect(model.shownEvents.count == 1 && model.shownEvents.first?.isMerged == false)
        await model.respond(.accepted, onCopy: homeRow.id)
        #expect(model.card?.note == "\(f.homeEmail) is no longer connected, so Mail can't answer for it.")
        #expect(model.heldCount == 0 && respondCalls(f.home).isEmpty && respondCalls(f.work).isEmpty)
    }

    @Test func openingTheInvitedCopyFromTheSidebarOpensTheWholeMeeting() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: invitedOnHome)
        let model = f.window()
        let homeCopy = try #require(f.home.allEvents.first)
        await model.openEditor(for: homeCopy, calendarKey: f.homeEmail)
        let card = try #require(model.card)
        #expect(card.event.isMerged && card.copies.map(\.account) == [f.workEmail, f.homeEmail])
    }

    @Test func eventsWithoutAUIDStayOneBlockPerCopy() async throws {
        let f = MeetingFixture(work: { _, home in
            [copy("work-copy", at: la(10, 13, 10), uid: nil, organizerIsMe: true, attendees: [home])]
        }, home: { work, _ in
            [copy("home-copy", at: la(10, 13, 10), uid: nil, organizerIsMe: nil, response: .needsAction, attendees: [work])]
        })
        let model = f.window()
        await model.open()
        #expect(model.timeGrid.blocks.count == 2 && model.timeGrid.blocks.allSatisfy { !$0.event.isMerged })
        model.openEvent(try #require(model.shownEvents.first))
        #expect(model.card?.copies.isEmpty == true)
    }
}

@MainActor
@Suite struct CalendarMeetingCopiesRemovalTests {
    @Test func removingOnlyTheInvitedCopyLeavesTheMeetingOnTheOrganizersCalendar() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: guestOnHome, removes: true)
        let model = f.window()
        await model.open()
        let meeting = try #require(model.shownEvents.first)
        #expect(meeting.isMerged && model.removalTitle(for: meeting) == "Delete…")
        #expect(model.copyRemovals(for: meeting).map(\.title) == ["Remove from \(f.homeEmail)…"])
        model.openEvent(meeting)
        let card = try #require(model.card)
        #expect(card.canRemove && !card.removesInvite, "the card's own Delete is the organizer's")
        #expect(card.copies.map(\.canRemove) == [false, true])
        let homeRow = try #require(card.copies.last)
        model.askToRemoveCardEvent(copy: homeRow.id)
        let question = try #require(model.removeQuestion)
        #expect(question.isInvite && question.confirmTitle == "Remove" && question.eventID == homeRow.id)
        #expect(question.account == f.homeEmail && question.keptOn == [f.workEmail] && question.organizerKept)
        #expect(question.alsoOn.isEmpty && !question.canRecreate)
        #expect(question.text.hasPrefix("Remove Planning from \(f.homeEmail)?"))
        #expect(question.text.contains("It stays on \(f.workEmail), where you organize it"))
        await model.confirmRemove()
        #expect(model.card == nil && model.heldCount == 1)
        let shown = try #require(model.shownEvents.first)
        #expect(model.shownEvents.count == 1 && !shown.isMerged && shown.account == f.workEmail,
                "only the removed copy is hidden; the meeting stays drawn from the organizer's copy")
        #expect(model.linkedOverlays.values.allSatisfy { $0.isEmpty })
        #expect(writeCalls(f.home).isEmpty && writeCalls(f.work).isEmpty, "nothing leaves during the hold")
        await f.finishHeld(model)
        #expect(scopedRemovals(f.home) == [.scopedRemove(id: "home-copy", scope: .thisEvent, sendUpdates: .none)])
        #expect(writeCalls(f.home) == scopedRemovals(f.home), "removing never answers")
        #expect(writeCalls(f.work).isEmpty, "the organizer's copy is never touched")
        #expect(f.home.allEvents.isEmpty && f.work.allEvents.map(\.id) == ["work-copy"])
        #expect(model.shownEvents.map(\.copyKey) == [shown.copyKey] && model.pendingRemovals.isEmpty)
        #expect(model.settleTask != nil, "the organizer's guest list is read again later")
        await f.finishSettle(model)
        #expect(model.overlays.isEmpty && model.shownEvents.count == 1)
    }

    @Test func removingTheShownCopyOfAMeetingBothCalendarsAreInvitedToKeepsTheOther() async throws {
        let f = MeetingFixture(work: guestOnWork, home: guestOfDanaOnHome, removes: true)
        let model = f.window()
        await model.open()
        let meeting = try #require(model.shownEvents.first)
        #expect(meeting.isMerged && meeting.account == f.workEmail)
        #expect(model.removalTitle(for: meeting) == "Remove from \(f.workEmail)…")
        #expect(model.copyRemovals(for: meeting).map(\.title) == ["Remove from \(f.homeEmail)…"])
        model.askToRemove(meeting)
        let question = try #require(model.removeQuestion)
        #expect(model.card?.removesInvite == true && question.isInvite)
        #expect(question.account == f.workEmail && question.keptOn == [f.homeEmail] && !question.organizerKept)
        #expect(question.text.contains("It stays on \(f.homeEmail) and on the organizer's calendar"))
        await model.confirmRemove()
        #expect(model.shownEvents.count == 1 && model.shownEvents.first?.account == f.homeEmail
                && model.shownEvents.first?.isMerged == false)
        await f.finishHeld(model)
        #expect(scopedRemovals(f.work) == [.scopedRemove(id: "work-copy", scope: .thisEvent, sendUpdates: .none)])
        #expect(writeCalls(f.home).isEmpty)
        await f.finishSettle(model)
        #expect(model.shownEvents.map(\.account) == [f.homeEmail])
    }

    @Test func undoingTheRemovalOfOneCopyBringsTheMeetingBackWhole() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: guestOnHome, removes: true)
        let model = f.window()
        await model.open()
        let meeting = try #require(model.shownEvents.first)
        let homeCopy = try #require(meeting.copies.last)
        model.askToRemove(meeting, copy: homeCopy.copyKey)
        await model.confirmRemove()
        #expect(model.shownEvents.first?.isMerged == false)
        model.askToRemove(meeting, copy: homeCopy.copyKey)
        #expect(model.removeQuestion == nil, "a removal already held is not asked about twice")
        let tasks = Array(model.held.values)
        await f.env.undo?.undoLast()
        #expect(model.overlays.isEmpty && model.pendingRemovals.isEmpty && model.settling.isEmpty)
        #expect(model.shownEvents.count == 1 && model.shownEvents.first?.isMerged == true)
        f.holdGate.release()
        for task in tasks { await task.value }
        #expect(writeCalls(f.home).isEmpty && writeCalls(f.work).isEmpty && model.settleTask == nil)
    }

    @Test func deletingARepeatingMeetingYouOrganizeHidesTheInvitedOccurrencesInTheSameScope() async throws {
        let first = la(10, 13, 10), second = la(10, 15, 10)
        func organized(_ work: EmailAddress, _ home: EmailAddress) -> [CalendarEvent] {
            [copy("s_1", at: first, organizerIsMe: true, attendees: [home], series: "s", originalStart: first),
             copy("s_2", at: second, organizerIsMe: true, attendees: [home], series: "s", originalStart: second)]
        }
        func invited(_ work: EmailAddress, _ home: EmailAddress) -> [CalendarEvent] {
            [copy("t_1", at: first, organizerIsMe: false, response: .needsAction, attendees: [work, home], series: "t",
                  originalStart: first),
             copy("t_2", at: second, organizerIsMe: false, response: .needsAction, attendees: [work, home], series: "t",
                  originalStart: second)]
        }
        for (scope, left) in [(CalendarRecurrenceScope.thisEvent, ["s_1"]), (.allEvents, [String]())] {
            let f = MeetingFixture(work: organized, home: invited, removes: true)
            let model = f.window()
            await model.open()
            #expect(model.shownEvents.map(\.id) == ["s_1", "s_2"] && model.shownEvents.allSatisfy { $0.isMerged })
            model.openEvent(try #require(model.shownEvents.last))
            model.askToRemoveCardEvent()
            let question = try #require(model.removeQuestion)
            #expect(question.isRecurring && question.alsoOn == [f.homeEmail])
            #expect(question.text.contains("The events you delete are canceled on \(f.homeEmail) too"))
            await model.confirmRemove(scope, questionID: question.id)
            #expect(model.shownEvents.map(\.id) == left, "the invited copies in scope leave with the organizer's")
            #expect(model.shownEvents.allSatisfy { $0.isMerged }, "a copy out of scope keeps its invited copy")
            await f.finishHeld(model)
            #expect(scopedRemovals(f.work) == [.scopedRemove(id: "s_2", scope: scope, sendUpdates: .all)])
            #expect(writeCalls(f.home).isEmpty, "the invited copies are never removed from Mail")
            #expect(model.shownEvents.map(\.id) == left, "until the later re-read")
            for id in scope == .allEvents ? ["t_1", "t_2"] : ["t_2"] { f.home.remove(id: id) }
            await f.finishSettle(model)
            #expect(model.shownEvents.map(\.id) == left && model.overlays.isEmpty)
        }
    }

    @Test func aFailedDeleteBringsBackEveryCopyAndSaysSo() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: guestOnHome, removes: true)
        let model = f.window()
        await model.open()
        model.openEvent(try #require(model.shownEvents.first))
        model.askToRemoveCardEvent()
        await model.confirmRemove()
        #expect(model.shownEvents.isEmpty)
        f.work.failure = "The calendar is offline."
        await f.finishHeld(model)
        #expect(model.overlays.isEmpty && model.linkedOverlays.isEmpty && model.settling.isEmpty)
        #expect(model.pendingRemovals.isEmpty && model.settleTask == nil)
        #expect(model.shownEvents.count == 1 && model.shownEvents.first?.isMerged == true)
        #expect(f.home.allEvents.count == 1 && writeCalls(f.home).isEmpty)
    }

    @Test func aDisconnectedAccountsCopyIsNotRemovedThroughAnotherAccount() async throws {
        let f = MeetingFixture(work: organizedOnWork, home: guestOnHome, followsConnection: true, removes: true)
        let model = f.window()
        await model.open()
        model.openEvent(try #require(model.shownEvents.first))
        let homeRow = try #require(model.card?.copies.last)
        #expect(homeRow.canRemove)
        try await f.connections.connection(f.homeEmail).disconnect()
        await model.load(force: false)
        model.askToRemoveCardEvent(copy: homeRow.id)
        #expect(model.removeQuestion == nil && model.card?.note == "Mail can't remove this copy from its calendar.")
        #expect(model.heldCount == 0 && writeCalls(f.home).isEmpty && writeCalls(f.work).isEmpty)
    }
}

@MainActor
@Suite struct CalendarMeetingCopiesDetailsTests {
    @Test func theGuestListComesFromTheOrganizersCopyWithEachConnectedAccountAsYou() throws {
        let work = EmailAddress(name: "Robin Example", email: "work@example.com")
        let home = EmailAddress(name: "Robin Example", email: "home@example.com")
        let organized = organizedOnWork(work, home).map { event -> CalendarEvent in
            var tagged = event
            tagged.account = work.email
            return tagged
        }
        var invited = invitedOnHome(work, home)
        invited[0].account = home.email
        invited[0].myResponse = .tentative
        let meeting = try #require(CalendarCopyGroups.group(invited + organized, accountOrder: [work.email, home.email]).first)
        let details = CalendarEventDetails(event: meeting, timeZone: losAngeles, calendarName: work.email,
                                           calendarKey: work.email, myAddresses: [work.email])
        #expect(details.guests.map(\.email) == [work.email, home.email, sam.email])
        #expect(details.guests.map(\.isMe) == [true, true, false])
        #expect(details.guests.map(\.isOrganizer) == [true, false, false])
        #expect(details.guests.map(\.response) == [.accepted, .tentative, .accepted], "each account's own answer")
        #expect(details.guestListNote == nil && details.organizerText == "You organize this event.")

        let alone = CalendarEventDetails(event: invited[0], timeZone: losAngeles, calendarName: home.email,
                                         calendarKey: home.email, myAddresses: [home.email])
        #expect(alone.guests.map(\.isOrganizer) == [true, false])
        #expect(alone.guestListNote == "Google shows only part of the guest list.")
        var hidden = invited[0]
        hidden.extras.permissions = CalendarGuestPermissions(canSeeGuestList: false)
        let hiddenDetails = CalendarEventDetails(event: hidden, timeZone: losAngeles, calendarName: home.email,
                                                 calendarKey: home.email, myAddresses: [home.email])
        #expect(hiddenDetails.guestListNote == "The organizer hid the guest list.")
    }
}
