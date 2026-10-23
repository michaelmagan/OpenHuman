import Foundation
import OpenHumanCore
import Testing
@testable import MailModel

private let la = TimeZone(identifier: "America/Los_Angeles")!

private func at(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, year: Int = 2026) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = la
    return calendar.date(from: DateComponents(year: year, month: m, day: d, hour: h, minute: min))!
}

private let sam = EmailAddress(name: "Sam Rivera", email: "sam@example.org")
private let robin = EmailAddress(name: "Robin Hale", email: "robin@example.org")

private func event(organizer: Bool? = true, guests: [EmailAddress] = [], permissions: CalendarGuestPermissions? = nil,
                   recurring: Bool = false, response: CalendarResponse? = nil, meet: URL? = nil) -> CalendarEvent {
    CalendarEvent(id: "ev1", title: "Planning", start: at(12, 4, 18), end: at(12, 4, 19, 30), timeZone: la.identifier,
                  attendees: guests, meetLink: meet, organizerIsMe: organizer, location: "Room 4", notes: "Agenda",
                  myResponse: response, recurringEventID: recurring ? "series1" : nil,
                  extras: CalendarEventExtras(permissions: permissions))
}

private func form(_ event: CalendarEvent) -> CalendarEventForm {
    CalendarEventForm(event: event, calendarKey: "me@example.org", defaultZone: la.identifier)
}

private let full: CalendarAbilities = [.respond, .editDetails, .remove, .editFull]


@Suite struct CalendarFormPatchTests {
    @Test func anUntouchedFormMakesAnEmptyPatch() {
        let e = event(guests: [sam])
        #expect(form(e).patch(from: e, defaultZone: la.identifier).isEmpty)
    }

    @Test func eachFieldChangesOnlyItsPartOfThePatch() {
        let e = event(guests: [sam])
        var f = form(e)
        f.title = "Planning (moved)"
        f.location = ""
        f.busy = .free
        f.visibility = .private
        f.colorID = "4"
        f.reminders = .custom([CalendarReminder(minutesBefore: 10)])
        f.wantsMeet = true
        let patch = f.patch(from: e, defaultZone: la.identifier)
        #expect(patch.title == "Planning (moved)" && patch.location == "" && patch.notes == nil)
        #expect(patch.busy == .free && patch.visibility == .private && patch.colorID == "4" && patch.meet == .add)
        #expect(patch.time == nil && patch.guests == nil && patch.recurrence == nil)
        #expect(patch.fields == [.title, .location, .busy, .visibility, .color, .reminders, .meet])
    }

    @Test func movingAnEventKeepsItsLengthAndTheWallClockInItsZone() {
        let e = event()
        var f = form(e)
        f.setStart(at(12, 5, 10))
        #expect(f.end == at(12, 5, 11, 30), "the 90 minute length is kept")
        let patch = f.patch(from: e, defaultZone: la.identifier)
        #expect(patch.time == CalendarTimeChange(start: at(12, 5, 10), end: at(12, 5, 11, 30), isAllDay: false, timeZone: la.identifier))
        #expect(patch.fields == [.time])
    }

    @Test func allDayAndMultiDayEventsUseWholeDaysWithAnExclusiveEnd() {
        var f = form(event())
        f.setAllDay(true)
        #expect(f.isAllDay && f.start == at(12, 4) && f.end == at(12, 5), "one whole day, exclusive end")
        f.setLastDay(at(12, 6))
        #expect(f.end == at(12, 7) && f.lastDay == at(12, 6) && f.isMultiDay)
        f.setStart(at(12, 10, 15))
        #expect(f.start == at(12, 10) && f.end == at(12, 13), "three days kept, start snapped to midnight")
        f.setAllDay(false)
        #expect(f.start == at(12, 10, 9) && f.end == at(12, 12, 10), "back to timed: 9:00 on the first day to 10:00 on the last")
    }

    @Test func aTimeZoneChangeKeepsTheInstantsAndStillResendsTheTimes() {
        let e = event()
        var f = form(e)
        f.setTimeZone("Europe/Berlin")
        f.setTimeZone("Not/AZone")
        #expect(f.timeZone == "Europe/Berlin", "an unknown zone is ignored")
        let patch = f.patch(from: e, defaultZone: la.identifier)
        #expect(patch.time?.start == e.start && patch.time?.timeZone == "Europe/Berlin" && patch.fields == [.timeZone])
    }

    @Test func guestsAddedRemovedAndMarkedOptionalAreNamed() {
        let e = event(guests: [sam, robin])
        var f = form(e)
        f.addGuest(EmailAddress(name: nil, email: "ALEX@example.org"))
        f.addGuest(EmailAddress(name: nil, email: "alex@example.org"))
        f.removeGuest("robin@example.org")
        f.setOptional("sam@example.org", true)
        let patch = f.patch(from: e, defaultZone: la.identifier)
        #expect(patch.guestsAdded == ["ALEX@example.org"] && patch.guestsRemoved == ["robin@example.org"])
        #expect(patch.guestOptionalChanged && patch.guests?.count == 2)
        #expect(patch.fields == [.guests])
    }

    @Test func permissionsRepeatAndMeetRemovalAreDiffed() {
        var e = event(guests: [sam])
        e.extras.permissions = CalendarGuestPermissions(canModify: false, canInviteOthers: true, canSeeGuestList: true)
        let withMeet = CalendarEvent(id: e.id, title: e.title, start: e.start, end: e.end, timeZone: e.timeZone,
                                     attendees: e.attendees, meetLink: URL(string: "https://meet.google.com/aaa-bbbb-ccc"),
                                     organizerIsMe: true, extras: e.extras)
        var f = form(withMeet)
        #expect(f.wantsMeet)
        f.wantsMeet = false
        f.permissions.canSeeGuestList = false
        f.recurrence = CalendarRepeat.rules(.weekly)
        let patch = f.patch(from: withMeet, defaultZone: la.identifier)
        #expect(patch.meet == .remove && patch.recurrence == ["RRULE:FREQ=WEEKLY"])
        #expect(patch.permissions == CalendarGuestPermissions(canModify: false, canInviteOthers: true, canSeeGuestList: false))
    }

    @Test func atMostFiveRemindersEachWithinFourWeeks() {
        var f = form(event())
        f.reminders = .custom([0, 5, 10, 30, 60].map { CalendarReminder(minutesBefore: $0) })
        #expect(f.problem == nil)
        f.reminders = .custom([0, 5, 10, 30, 60, 1_440].map { CalendarReminder(minutesBefore: $0) })
        #expect(f.problem == "Up to five reminders.")
        f.reminders = .custom([CalendarReminder(minutesBefore: 40_321)])
        #expect(f.problem == "A reminder can be at most four weeks before.")
    }

    @Test func aDescriptionLeftAloneIsNeverRewritten() {
        var e = event()
        e.notes = "<p>Hello &amp; welcome</p>"
        let f = form(e)
        #expect(f.notes == "<p>Hello &amp; welcome</p>")
        #expect(f.patch(from: e, defaultZone: la.identifier).notes == nil)
    }

    @Test func aFormIsValidatedInWords() {
        var f = form(event())
        #expect(f.problem == nil)
        f.title = "  "
        #expect(f.problem == "Add a title.")
        f.title = "x"
        f.end = f.start
        #expect(f.problem != nil)
    }

    @Test func aDuplicateKeepsTheDetailsAndDropsTheAnswers() {
        var e = event(guests: [sam])
        e.extras.guests = [CalendarGuest(email: "sam@example.org", name: "Sam Rivera", isOptional: true, response: .accepted)]
        let draft = form(e).duplicateDraft()
        #expect(draft.title == "Planning" && draft.start == e.start && draft.end == e.end && draft.location == "Room 4")
        #expect(draft.extras.guests.map(\.response) == [nil] && draft.extras.guests.first?.isOptional == true)
        #expect(draft.sendUpdates == .none)
    }

    @Test func aDraftRoundTripsThroughTheForm() {
        var draft = CalendarEventDraft(title: "Lunch", start: at(12, 4, 12), end: at(12, 4, 13), timeZone: la.identifier,
                                       attendees: [sam], addMeetLink: true)
        draft.extras.reminders = .custom([CalendarReminder(minutesBefore: 30)])
        var f = CalendarEventForm(draft: draft)
        f.title = "Team lunch"
        let back = f.applying(to: draft)
        #expect(back.title == "Team lunch" && back.addMeetLink && back.attendees == [sam] && back.extras.reminders == draft.extras.reminders)
    }

    @Test func theFirstGuestTurnsInvitationsOnAndALaterGuestKeepsTheChoice() {
        var draft = CalendarEventDraft(title: "Lunch", start: at(12, 4, 12), end: at(12, 4, 13), timeZone: la.identifier)
        #expect(draft.sendUpdates == .none && CalendarEventDraft.defaultSendUpdates(attendees: []) == .none)
        var f = CalendarEventForm(draft: draft)
        f.addGuest(sam)
        draft = f.applying(to: draft)
        #expect(draft.attendees == [sam] && draft.sendUpdates == .all && draft.emailsAttendees)
        draft.sendUpdates = .none
        f = CalendarEventForm(draft: draft)
        f.addGuest(robin)
        draft = f.applying(to: draft)
        #expect(draft.attendees == [sam, robin] && draft.sendUpdates == .none, "the user's choice stays")
        draft.setAttendees([])
        draft.setAttendees([robin])
        #expect(draft.sendUpdates == .all, "a first guest again turns invitations on")
    }
}


@Suite struct CalendarFieldRightsTests {
    @Test func theOrganizerChangesEverythingExceptTheCalendarWithoutThatAbility() {
        let rights = CalendarFieldRights.make(for: event(), abilities: full, refusal: nil)
        for field in CalendarFormField.allCases where field != .calendar { #expect(rights.access(field) == .editable, "\(field)") }
        #expect(rights.access(.calendar).reason != nil)
        #expect(rights.delete == .delete)
    }

    @Test func aGuestSeesEachFieldReadOnlyWithItsOwnReasonNotOneGlobalLock() {
        let e = event(organizer: false, guests: [sam], permissions: CalendarGuestPermissions(canModify: false, canInviteOthers: false),
                      response: .needsAction)
        let rights = CalendarFieldRights.make(for: e, abilities: full, refusal: nil)
        for field in [CalendarFormField.title, .time, .timeZone, .location, .notes, .meet, .repeats, .visibility] {
            #expect(rights.access(field).reason == "Someone else organizes this event: only they can change it.", "\(field)")
        }
        #expect(rights.access(.guests).reason == "The organizer didn't let guests invite others.")
        #expect(rights.access(.guestPermissions).reason == "Only the organizer changes what guests can do.")
        for field in [CalendarFormField.reminders, .busy, .color] { #expect(rights.access(field) == .editable, "your own copy: \(field)") }
        #expect(rights.hasAnyEditable)
        #expect(rights.summary == "Someone else organizes this event: only they can change it.", "said once for the form")
    }

    @Test func guestsWhoMayInviteOthersCanAddButNotRemove() {
        let e = event(organizer: false, guests: [sam], permissions: CalendarGuestPermissions(canModify: false, canInviteOthers: true),
                      response: .needsAction)
        let rights = CalendarFieldRights.make(for: e, abilities: full, refusal: nil)
        #expect(rights.access(.guests) == .addOnly)
        var f = form(e)
        f.addGuest(robin)
        #expect(rights.firstViolation(of: f.patch(from: e, defaultZone: la.identifier)) == nil)
        f.removeGuest("sam@example.org")
        #expect(rights.firstViolation(of: f.patch(from: e, defaultZone: la.identifier)) != nil)
    }

    @Test func aGuestWhoMayModifyTheEventChangesItsContentButNotWhatGuestsMayDo() {
        let e = event(organizer: false, guests: [sam], permissions: CalendarGuestPermissions(canModify: true), response: .accepted)
        let rights = CalendarFieldRights.make(for: e, abilities: full, refusal: nil)
        #expect(rights.access(.title) == .editable && rights.access(.time) == .editable && rights.access(.guests) == .editable)
        #expect(rights.access(.guestPermissions).reason != nil)
        #expect(rights.access(.calendar).reason != nil)
        #expect(rights.summary == nil, "the form must not say only the organizer can change what this guest may change")
    }

    @Test func aGuestCannotDeleteAndIsOfferedDecliningInstead() {
        let e = event(organizer: false, guests: [sam], response: .needsAction)
        if case .declineInstead = CalendarFieldRights.make(for: e, abilities: full, refusal: nil).delete {} else {
            Issue.record("a non-organizer is offered No, never a delete")
        }
    }

    @Test func aRefusalLocksEveryFieldWithTheSameVisibleReason() {
        let why = "Reconnect Google Calendar to change events."
        let rights = CalendarFieldRights.make(for: event(), abilities: full, refusal: why)
        for field in CalendarFormField.allCases { #expect(rights.access(field) == .readOnly(why)) }
        #expect(rights.delete == .unavailable(why) && rights.summary == why && !rights.hasAnyEditable)
        #expect(CalendarFieldRights.forNewEvent(refusal: why).access(.title).reason == why)
        #expect(CalendarFieldRights.forNewEvent(refusal: nil).access(.title) == .editable)
    }

    @Test func aCalendarWithoutTheFullEditKeepsTheOlderRules() {
        let rights = CalendarFieldRights.make(for: event(), abilities: [.respond, .editDetails, .remove], refusal: nil)
        #expect(rights.access(.title) == .editable && rights.access(.time) == .editable)
        #expect(rights.access(.guests).reason != nil && rights.access(.meet).reason != nil && rights.access(.reminders).reason != nil)
    }

    @Test func removingAMeetLinkIsOfferedOnlyWhenTheCalendarSaysItCan() {
        let linked = event(meet: URL(string: "https://meet.google.com/aaa-bbbb-ccc"))
        #expect(CalendarFieldRights.make(for: linked, abilities: full, refusal: nil).access(.meet).reason
                == "Mail can't remove a Meet link from this calendar yet. Remove it in your calendar.")
        #expect(CalendarFieldRights.make(for: linked, abilities: full.union(.removeMeet), refusal: nil).access(.meet) == .editable)
        #expect(CalendarFieldRights.make(for: event(), abilities: full, refusal: nil).access(.meet) == .editable, "adding one")
    }

    @Test func anInstanceWhoseRulesAreUnknownCannotChangeHowTheSeriesRepeats() {
        let rights = CalendarFieldRights.make(for: event(recurring: true), abilities: full, refusal: nil)
        #expect(rights.access(.repeats).reason == "Change how this series repeats from its first event.")
    }
}


@Suite struct CalendarSendUpdatesPolicyTests {
    @Test func guestsAreAskedAboutWheneverTheChangeConcernsThem() {
        let e = event(guests: [sam])
        var f = form(e)
        f.title = "New title"
        let patch = f.patch(from: e, defaultZone: la.identifier)
        #expect(CalendarSendUpdatesPolicy.needsChoice(hasOtherGuests: true, patch: patch))
        #expect(!CalendarSendUpdatesPolicy.needsChoice(hasOtherGuests: false, patch: patch), "nobody else is invited")
        f.busy = .free
        var personal = CalendarEventPatch()
        personal.busy = .free
        #expect(!CalendarSendUpdatesPolicy.needsChoice(hasOtherGuests: true, patch: personal), "your own copy emails nobody")
    }

    @Test func theDefaultIsGuestsOnlyWhenGuestsOrTheTimeChanged() {
        let e = event(guests: [sam])
        var title = form(e)
        title.title = "x"
        #expect(CalendarSendUpdatesPolicy.preselected(for: title.patch(from: e, defaultZone: la.identifier)) == .none)
        var moved = form(e)
        moved.setStart(at(12, 5, 9))
        #expect(CalendarSendUpdatesPolicy.preselected(for: moved.patch(from: e, defaultZone: la.identifier)) == .all)
        var invited = form(e)
        invited.addGuest(robin)
        #expect(CalendarSendUpdatesPolicy.preselected(for: invited.patch(from: e, defaultZone: la.identifier)) == .all)
        #expect(CalendarSendUpdatesPolicy.options == [.none, .all], "only none or all guests are offered")
    }

    @Test func theChoiceWinsAndNobodyIsEmailedWithoutOtherGuests() {
        var patch = CalendarEventPatch()
        patch.time = CalendarTimeChange(start: at(12, 5, 9), end: at(12, 5, 10), isAllDay: false, timeZone: la.identifier)
        #expect(CalendarSendUpdatesPolicy.effective(chosen: nil, hasOtherGuests: true, patch: patch) == .all)
        #expect(CalendarSendUpdatesPolicy.effective(chosen: CalendarSendUpdates.none, hasOtherGuests: true, patch: patch) == .none)
        #expect(CalendarSendUpdatesPolicy.effective(chosen: .all, hasOtherGuests: false, patch: patch) == .none)
    }
}


@Suite struct CalendarRecurrenceTests {
    @Test func aSeriesInstanceAsksForTheScopeAndOneOffEventsDoNot() {
        var patch = CalendarEventPatch()
        patch.title = "x"
        #expect(CalendarRecurrenceScope.options(for: event(), patch: patch).isEmpty)
        #expect(CalendarRecurrenceScope.options(for: event(recurring: true), patch: patch) == [.thisEvent, .thisAndFollowing, .allEvents])
        patch.recurrence = ["RRULE:FREQ=DAILY"]
        #expect(CalendarRecurrenceScope.options(for: event(recurring: true), patch: patch) == [.thisAndFollowing, .allEvents],
                "one instance cannot change how the series repeats")
    }

    @Test func presetsMapToRulesAndBack() {
        for preset in CalendarRepeat.Preset.allCases where preset != .custom {
            #expect(CalendarRepeat.preset(of: CalendarRepeat.rules(preset)) == preset)
        }
        #expect(CalendarRepeat.preset(of: ["RRULE:FREQ=WEEKLY;INTERVAL=2"]) == .custom)
    }

    @Test func cuttingASeriesEndsItJustBeforeTheInstant() {
        let cut = CalendarRepeat.endingBefore(["RRULE:FREQ=WEEKLY;COUNT=10", "EXDATE:20261201T170000Z"],
                                              instantStart: at(12, 4, 18), isAllDay: false, zone: la)
        #expect(cut == ["RRULE:FREQ=WEEKLY;UNTIL=20261205T015959Z", "EXDATE:20261201T170000Z"], "18:00 Los Angeles is 02:00 UTC the next day")
        let allDay = CalendarRepeat.endingBefore(["RRULE:FREQ=DAILY;UNTIL=20270101"], instantStart: at(12, 4), isAllDay: true, zone: la)
        #expect(allDay == ["RRULE:FREQ=DAILY;UNTIL=20261203"])
    }

    @Test func theFollowingSeriesKeepsItsEndAndTheLaterExceptions() {
        let split = at(12, 4, 18)
        #expect(CalendarRepeat.continuing(["RRULE:FREQ=WEEKLY;BYDAY=FR;UNTIL=20270101T000000Z"], from: split, isAllDay: false,
                                          zone: la) == ["RRULE:FREQ=WEEKLY;BYDAY=FR;UNTIL=20270101T000000Z"], "a fixed end stays")
        #expect(CalendarRepeat.continuing(["RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=4"], from: split, isAllDay: false, zone: la) == nil,
                "the number of times left is not known, so the split is refused")
        let rules = ["RRULE:FREQ=WEEKLY", "EXDATE:20261127T020000Z,20261212T020000Z",
                     "EXDATE;TZID=America/Los_Angeles:20261120T180000,20261218T180000", "RDATE:20261101T020000Z",
                     "EXDATE:garbage"]
        #expect(CalendarRepeat.continuing(rules, from: split, isAllDay: false, zone: la)
                == ["RRULE:FREQ=WEEKLY", "EXDATE:20261212T020000Z", "EXDATE;TZID=America/Los_Angeles:20261218T180000",
                    "EXDATE:garbage"], "only exceptions on or after the split move to the new series")
        let days = ["RRULE:FREQ=DAILY", "EXDATE;VALUE=DATE:20261203,20261204,20261210", "RDATE;VALUE=DATE:20261220"]
        #expect(CalendarRepeat.continuing(days, from: at(12, 4), isAllDay: true, zone: la)
                == ["RRULE:FREQ=DAILY", "EXDATE;VALUE=DATE:20261204,20261210", "RDATE;VALUE=DATE:20261220"])
        #expect(CalendarRepeat.continuing(["RRULE:FREQ=DAILY", "RDATE:nonsense"], from: split, isAllDay: false, zone: la)
                == ["RRULE:FREQ=DAILY"], "an unreadable extra date is never added")
    }
}


@Suite struct CalendarDateFieldTests {
    @Test func monthAndDayAreAlwaysTwoDigitsInTheLocalesOrder() {
        #expect(CalendarDateField.pad("M/d/y") == "MM/dd/yyyy")
        #expect(CalendarDateField.pad("d.M.y") == "dd.MM.yyyy")
        #expect(CalendarDateField.pad("y/MM/dd") == "yyyy/MM/dd")
        #expect(CalendarDateField.pad("d 'de' M 'de' y") == "dd 'de' MM 'de' yyyy", "quoted text stays")
        let december1 = at(12, 1, 18)
        #expect(CalendarDateField.text(december1, zone: la, locale: Locale(identifier: "en_US")) == "12/01/2026")
        #expect(CalendarDateField.text(december1, zone: la, locale: Locale(identifier: "de_DE")) == "01.12.2026")
        #expect(!CalendarDateField.text(december1, zone: la, locale: Locale(identifier: "en_US")).contains(" "), "no gap")
    }

    @Test func aTypedDateKeepsTheTimeOfDayAndAnInvalidOneIsRefused() {
        let us = Locale(identifier: "en_US")
        #expect(CalendarDateField.parse("12/05/2026", keepingTimeOf: at(12, 4, 18, 30), zone: la, locale: us) == at(12, 5, 18, 30))
        #expect(CalendarDateField.parse("13/45/2026", keepingTimeOf: at(12, 4, 18), zone: la, locale: us) == nil)
        #expect(CalendarDateField.parse("soon", keepingTimeOf: at(12, 4, 18), zone: la, locale: us) == nil)
    }

    @Test func steppingMovesOneDayAcrossSummerTimeKeepingTheWallClock() {
        #expect(CalendarDateField.stepped(at(10, 31, 18), byDays: 1, zone: la) == at(11, 1, 18), "the day summer time ends")
        #expect(CalendarDateField.stepped(at(12, 4, 18), byDays: -1, zone: la) == at(12, 3, 18))
    }

    @Test func theFieldShowsTheSameDayAsTheGridColumnInTheEventsZone() {
        let evening = at(12, 4, 18)
        let us = Locale(identifier: "en_US")
        #expect(CalendarDateField.text(evening, zone: la, locale: us) == "12/04/2026")
        #expect(CalendarDateField.text(evening, zone: TimeZone(identifier: "UTC")!, locale: us) == "12/05/2026",
                "what a field in the wrong zone would have shown")
        #expect(CalendarDateField.isOnDay(evening, day: at(12, 4), zone: la))
        #expect(!CalendarDateField.isOnDay(evening, day: at(12, 2), zone: la), "never two days off")
        for hour in [0, 9, 18, 23] {
            let moment = at(12, 4, hour, 15)
            let typed = CalendarDateField.text(moment, zone: la, locale: us)
            #expect(CalendarDateField.parse(typed, keepingTimeOf: moment, zone: la, locale: us) == moment)
        }
    }
}


@Suite struct CalendarPendingMoveTests {
    @Test func aDropIsAProposalNamingFromToAndLength() {
        let e = event()
        let moved = CalendarPendingMove(event: e, proposedStart: at(12, 5, 10), proposedEnd: at(12, 5, 11, 30))
        #expect(moved.kind == .moved && moved.originalLength == 5_400 && moved.proposedLength == 5_400)
        let resized = CalendarPendingMove(event: e, proposedStart: e.start, proposedEnd: at(12, 4, 21))
        #expect(resized.kind == .resized && CalendarPendingMove.lengthText(resized.proposedLength) == "3 h")
        let both = CalendarPendingMove(event: e, proposedStart: at(12, 5, 10), proposedEnd: at(12, 5, 10, 45))
        #expect(both.kind == .movedAndResized && CalendarPendingMove.lengthText(both.proposedLength) == "45 min")
        #expect(CalendarPendingMove(event: e, proposedStart: e.start, proposedEnd: e.end).kind == .unchanged)
    }

    @Test func theUserCanAdjustTheLengthBeforeAcceptingAndTheEndNeverPrecedesTheStart() {
        var move = CalendarPendingMove(event: event(), proposedStart: at(12, 5, 10), proposedEnd: at(12, 5, 11))
        move.adopt(start: at(12, 5, 10), end: at(12, 5, 12))
        #expect(move.proposedLength == 7_200)
        move.adopt(start: at(12, 5, 10), end: at(12, 5, 9))
        #expect(move.proposedEnd > move.proposedStart)
        #expect(CalendarPendingMove.lengthText(5_400) == "1 h 30 min")
    }

    @Test func guestsAreEmailedByDefaultOnlyWhenSomeoneElseIsInvitedAndSomethingMoved() {
        let e = event(guests: [sam])
        let move = CalendarPendingMove(event: e, proposedStart: at(12, 5, 10), proposedEnd: at(12, 5, 11, 30))
        #expect(move.sendUpdatesDefault(hasOtherGuests: true) == .all)
        #expect(move.sendUpdatesDefault(hasOtherGuests: false) == .none)
        #expect(CalendarPendingMove(event: e, proposedStart: e.start, proposedEnd: e.end).sendUpdatesDefault(hasOtherGuests: true) == .none)
    }
}
