import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
private let utc = TimeZone(identifier: "UTC")!

private func utcDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private let messageKey = MessageKey(account: AccountID(1), rowID: 7, gmailMessageID: GmailMessageID("m7"))

let googleStyleInvite = """
BEGIN:VCALENDAR\r
PRODID:-//Example//Calendar 1.0//EN\r
VERSION:2.0\r
METHOD:REQUEST\r
BEGIN:VTIMEZONE\r
TZID:America/Los_Angeles\r
END:VTIMEZONE\r
BEGIN:VEVENT\r
DTSTART;TZID=America/Los_Angeles:20261015T140000\r
DTEND;TZID=America/Los_Angeles:20261015T150000\r
DTSTAMP:20261012T180000Z\r
ORGANIZER;CN=Dana Ruiz:mailto:dana@example.com\r
UID:7kq2example@example.com\r
ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;CN=Dana Ruiz;X-NUM-GUESTS=0:mailto:dana@example.com\r
ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=robin@example.com:mailto:robin@example.com\r
ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=OPT-PARTICIPANT;PARTSTAT=TENTATIVE;CN="Lee, Sam":mailto:sam@example.org\r
ATTENDEE;CUTYPE=RESOURCE;PARTSTAT=ACCEPTED;CN=Room 4:mailto:room4@resource.example\r
X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij\r
DESCRIPTION:Agenda: plan the launch\\, then the budget.\\nBring numbers\\; and \r
 questions.\\n\\n-::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-\\nJoin wit\r
 h the calendar's own link.\\n-::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-\r
LOCATION:500 Example Avenue\\, Suite 200\r
SEQUENCE:0\r
STATUS:CONFIRMED\r
SUMMARY:Launch planning\r
BEGIN:VALARM\r
ACTION:DISPLAY\r
DESCRIPTION:This is an event reminder\r
TRIGGER:-P0DT0H10M0S\r
END:VALARM\r
END:VEVENT\r
END:VCALENDAR\r

"""

let outlookStyleInvite = """
BEGIN:VCALENDAR
METHOD:REQUEST
VERSION:2.0
BEGIN:VTIMEZONE
TZID:Example Pacific Time
BEGIN:STANDARD
DTSTART:16010101T020000
TZOFFSETFROM:-0700
TZOFFSETTO:-0800
RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=11
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:16010101T020000
TZOFFSETFROM:-0800
TZOFFSETTO:-0700
RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=2SU;BYMONTH=3
END:DAYLIGHT
END:VTIMEZONE
BEGIN:VEVENT
ORGANIZER;CN=Kai Moreno:MAILTO:kai@example.net
ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Robin Example:mailto:robin@example.com
DESCRIPTION;LANGUAGE=en-US:Quarterly review.\\nJoin: https://teams.microsoft.com/l/meetup-join/example\\n
UID:040000008200E00074C5B7101A82E0080000000000000000000000000000
SUMMARY;LANGUAGE=en-US:Quarterly review
DTSTART;TZID=Example Pacific Time:20261110T090000
DTEND;TZID=Example Pacific Time:20261110T100000
LOCATION;LANGUAGE=en-US:https://example.zoom.us/j/123456
SEQUENCE:3
END:VEVENT
END:VCALENDAR
"""

@Suite struct InviteParserTests {
    @Test func aGoogleStyleInvitationIsReadInFull() throws {
        let invite = try #require(ICSParser.parse(googleStyleInvite, defaultZone: utc))
        #expect(invite.method == .request && invite.uid == "7kq2example@example.com" && invite.sequence == 0)
        #expect(invite.title == "Launch planning" && !invite.isCancelled && !invite.repeats && !invite.isAllDay)
        #expect(invite.start == utcDate(2026, 10, 15, 21) && invite.end == utcDate(2026, 10, 15, 22))
        #expect(invite.timeZoneID == "America/Los_Angeles")
        #expect(invite.location == "500 Example Avenue, Suite 200", "the escaped comma is unescaped")
        let notes = try #require(invite.notes)
        #expect(notes.hasPrefix("Agenda: plan the launch, then the budget.\nBring numbers; and questions."),
                "folded lines are joined and \\n, \\, and \\; unescaped")
        #expect(invite.organizer == CalendarInvite.Person(email: "dana@example.com", name: "Dana Ruiz"))
        #expect(invite.attendees.count == 4)
        #expect(invite.attendees[1].email == "robin@example.com" && invite.attendees[1].response == .needsAction)
        #expect(invite.attendees[1].name == nil, "a CN that is the address is no name")
        #expect(invite.attendees[2].name == "Lee, Sam" && invite.attendees[2].isOptional
                && invite.attendees[2].response == .tentative, "a quoted CN keeps its comma")
        #expect(invite.attendees[3].isResource)
        #expect(invite.conferenceURL?.absoluteString == "https://meet.google.com/abc-defg-hij" && invite.conferenceIsGoogle)
        #expect(invite.attendee(in: ["robin@example.com"])?.email == "robin@example.com")
    }

    @Test func anOutlookStyleZoneIsResolvedFromItsOwnDefinition() throws {
        let invite = try #require(ICSParser.parse(outlookStyleInvite, defaultZone: utc))
        #expect(invite.start == utcDate(2026, 11, 10, 17) && invite.end == utcDate(2026, 11, 10, 18))
        #expect(invite.timeZoneID == "Example Pacific Time" && invite.sequence == 3)
        #expect(invite.organizer?.email == "kai@example.net", "MAILTO: in capitals")
        #expect(invite.conferenceURL?.host() == "example.zoom.us" && !invite.conferenceIsGoogle)
        let summer = outlookStyleInvite.replacingOccurrences(of: "20261110T090000", with: "20260710T090000")
            .replacingOccurrences(of: "20261110T100000", with: "20260710T100000")
        #expect(ICSParser.parse(summer, defaultZone: utc)?.start == utcDate(2026, 7, 10, 16))
    }

    @Test func datesDurationsAndFloatingTimes() throws {
        func event(_ lines: String) -> String {
            "BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:u1@example.com\nSUMMARY:Offsite\n\(lines)\nEND:VEVENT\nEND:VCALENDAR\n"
        }
        let allDay = try #require(ICSParser.parse(event("DTSTART;VALUE=DATE:20261020"), defaultZone: losAngeles))
        #expect(allDay.isAllDay && allDay.end.timeIntervalSince(allDay.start) == 86_400)
        let timed = try #require(ICSParser.parse(event("DTSTART:20261020T160000Z\nDURATION:PT1H30M"), defaultZone: utc))
        #expect(timed.end == utcDate(2026, 10, 20, 17, 30))
        let floating = try #require(ICSParser.parse(event("DTSTART:20261020T090000\nDTEND:20261020T093000"),
                                                    defaultZone: losAngeles))
        #expect(floating.start == utcDate(2026, 10, 20, 16))
        #expect(ICSParser.seconds(duration: "P1W") == 604_800 && ICSParser.seconds(duration: "-PT15M") == -900)
        #expect(ICSParser.seconds(duration: "P") == nil && ICSParser.seconds(duration: "1H") == nil)
    }

    @Test func aSeriesAndItsExceptions() throws {
        let text = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:weekly@example.com
        SUMMARY:Weekly sync
        DTSTART:20261014T170000Z
        DTEND:20261014T173000Z
        RRULE:FREQ=WEEKLY;BYDAY=WE
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:robin@example.com
        END:VEVENT
        BEGIN:VEVENT
        UID:weekly@example.com
        RECURRENCE-ID:20261021T170000Z
        SUMMARY:Weekly sync (moved)
        DTSTART:20261021T180000Z
        DTEND:20261021T183000Z
        END:VEVENT
        END:VCALENDAR
        """
        let series = try #require(ICSParser.parse(text, defaultZone: utc))
        #expect(series.repeats && series.repeatFrequency == "WEEKLY" && series.recurrenceID == nil,
                "the series is read before its exceptions")
        #expect(series.occurrence == utcDate(2026, 10, 14, 17))
        let one = text.components(separatedBy: "END:VEVENT\n").dropFirst().joined(separator: "END:VEVENT\n")
        let exception = try #require(ICSParser.parse("BEGIN:VCALENDAR\nMETHOD:REQUEST\n" + one, defaultZone: utc))
        #expect(exception.recurrenceID == utcDate(2026, 10, 21, 17) && exception.occurrence == utcDate(2026, 10, 21, 17))
        #expect(exception.start == utcDate(2026, 10, 21, 18))
    }

    @Test func cancelReplyAndCounter() throws {
        let cancel = googleStyleInvite.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:CANCEL")
            .replacingOccurrences(of: "STATUS:CONFIRMED", with: "STATUS:CANCELLED")
        let cancelled = try #require(ICSParser.parse(cancel, defaultZone: utc))
        #expect(cancelled.method == .cancel && cancelled.isCancelled)
        let reply = """
        BEGIN:VCALENDAR
        METHOD:REPLY
        BEGIN:VEVENT
        UID:7kq2example@example.com
        DTSTART:20261015T210000Z
        DTEND:20261015T220000Z
        SUMMARY:Launch planning
        ATTENDEE;PARTSTAT=ACCEPTED;CN=Sam Lee:mailto:sam@example.org
        END:VEVENT
        END:VCALENDAR
        """
        let answered = try #require(ICSParser.parse(reply, defaultZone: utc))
        #expect(answered.method == .reply && answered.attendees.first?.response == .accepted)
        let counter = reply.replacingOccurrences(of: "METHOD:REPLY", with: "METHOD:COUNTER")
        #expect(ICSParser.parse(counter, defaultZone: utc)?.method == .counter)
        #expect(ICSParser.parse(reply.replacingOccurrences(of: "METHOD:REPLY\n", with: ""), defaultZone: utc)?.method
                == .publish, "no METHOD is an announcement")
    }

    @Test func brokenOrHostileInputGivesNoInvitation() {
        #expect(ICSParser.parse("", defaultZone: utc) == nil)
        #expect(ICSParser.parse("<html><body>Not a calendar</body></html>", defaultZone: utc) == nil)
        #expect(ICSParser.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:No UID\nDTSTART:20261015T210000Z\nEND:VEVENT\nEND:VCALENDAR",
                                defaultZone: utc) == nil, "no UID")
        #expect(ICSParser.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x@example.com\nDTSTART:2026-10-15\nEND:VEVENT\nEND:VCALENDAR",
                                defaultZone: utc) == nil, "no readable start")
        let unsafe = googleStyleInvite.replacingOccurrences(of: "https://meet.google.com/abc-defg-hij",
                                                            with: "javascript:alert(1)")
        #expect(ICSParser.parse(unsafe, defaultZone: utc)?.conferenceURL == nil)
        #expect(ICSParser.safeURL("http://meet.google.com/x") == nil && ICSParser.safeURL("https://u:p@example.com") == nil)
        let padded = googleStyleInvite + String(repeating: "X-PAD:0123456789\r\n", count: 40_000)
        #expect(ICSParser.parse(padded, defaultZone: utc)?.uid == "7kq2example@example.com")
    }

    @Test func theNthWeekdayOfAMonth() {
        #expect(ICSParser.Observance.day(year: 2026, month: 11, weekday: 1, ordinal: 1) == 1)
        #expect(ICSParser.Observance.day(year: 2026, month: 3, weekday: 1, ordinal: 2) == 8)
        #expect(ICSParser.Observance.day(year: 2026, month: 10, weekday: 1, ordinal: -1) == 25)
        #expect(ICSParser.offset("+0530") == 19_800 && ICSParser.offset("-0800") == -28_800 && ICSParser.offset("8") == nil)
        #expect(ICSParser.Observance.day(year: 2026, month: 3, weekday: 1, ordinal: 5) == 29)
        #expect(ICSParser.Observance.day(year: 2026, month: 2, weekday: 1, ordinal: 5) == 22, "a missing fifth is the last")
        for ordinal in [0, 6, -6, 1_000_000_000_000, Int.max, Int.min] {
            #expect(ICSParser.Observance.day(year: 2026, month: 3, weekday: 1, ordinal: ordinal) == nil)
        }
        #expect(ICSParser.Observance.day(year: 2026, month: 13, weekday: 1, ordinal: 1) == nil)
        #expect(ICSParser.Observance.day(year: 2026, month: 3, weekday: 8, ordinal: 1) == nil)
    }

    @Test func aHostileZoneRuleNeitherTrapsNorSpins() throws {
        let hostile = ["9223372036854775807MO", "-9223372036854775808MO", "1000000000000MO", "-1000000000000MO", "0MO",
                       "+0MO", "6SU", "-6SU", "99999999999999999999999SU"]
        for byday in hostile {
            let text = outlookStyleInvite.replacingOccurrences(of: "BYDAY=1SU", with: "BYDAY=\(byday)")
            let invite = try #require(ICSParser.parse(text, defaultZone: utc), "\(byday)")
            #expect(invite.timeZoneID == "Example Pacific Time")
        }
        let badMonth = outlookStyleInvite.replacingOccurrences(of: "BYMONTH=11", with: "BYMONTH=9223372036854775807")
        #expect(ICSParser.parse(badMonth, defaultZone: utc) != nil)
        let observance = try #require(ICSParser.Observance([
            ICSParser.Line(name: "DTSTART", params: [:], value: "16010101T020000"),
            ICSParser.Line(name: "TZOFFSETTO", params: [:], value: "-0800"),
            ICSParser.Line(name: "RRULE", params: [:], value: "FREQ=YEARLY;BYDAY=9223372036854775807MO;BYMONTH=1"),
        ]))
        #expect(observance.ordinal == nil && observance.month == nil, "an out-of-range rule is a fixed offset")
        #expect(ICSParser.seconds(duration: "P" + String(repeating: "9", count: 400) + "W") == nil)
        #expect(ICSParser.seconds(duration: "P99999999D") == nil)
        let endless = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:u@example.com\nDTSTART:20261020T160000Z\nDURATION:P"
            + String(repeating: "9", count: 400) + "W\nEND:VEVENT\nEND:VCALENDAR\n"
        let parsed = try #require(ICSParser.parse(endless, defaultZone: utc))
        #expect(parsed.end == parsed.start, "an unreadable duration is ignored")
    }
}

@Suite struct InviteCardBuilderTests {
    private let me: Set<String> = ["robin@example.com"]
    private let enUS = Locale(identifier: "en_US")

    @Test func theCardShowsWhenWhereWhoAboutAndJoin() throws {
        let invite = try #require(ICSParser.parse(googleStyleInvite, defaultZone: losAngeles))
        let card = InviteCardBuilder.card(invite, message: messageKey, myAddresses: me, timeZone: losAngeles, locale: enUS)
        #expect(card.kind == .request && card.offersRSVP && card.canRespond && card.isInvited && !card.isUpdate)
        #expect(card.title == "Launch planning")
        #expect(card.when.contains("Thursday, October 15, 2026") && card.when.contains("2:00") && card.when.contains("3:00")
                && card.when.hasSuffix("PDT"), "the whole range in the user's zone: \(card.when)")
        #expect(card.whenNote == nil, "the event's zone is the user's")
        #expect(card.locationLink?.host() == "maps.apple.com"
                && card.locationLink?.query?.contains("Example") == true, "a place opens a Maps search")
        #expect(card.guests.map(\.title) == ["Dana Ruiz", "Me", "Lee, Sam"])
        #expect(card.guests[0].isOrganizer && card.guests[0].response == .accepted)
        #expect(card.guests[1].isMe && card.guests[1].response == nil && card.guests[2].isOptional)
        #expect(card.notes == "Agenda: plan the launch, then the budget.\nBring numbers; and questions.")
        #expect(card.join == InviteCard.Join(title: "Join with Google Meet",
                                             url: URL(string: "https://meet.google.com/abc-defg-hij")!))
        #expect(card.response == nil, "NEEDS-ACTION is no answer yet")
        let newYork = TimeZone(identifier: "America/New_York")!
        let elsewhere = InviteCardBuilder.card(invite, message: messageKey, myAddresses: me, timeZone: newYork, locale: enUS)
        #expect(elsewhere.when.hasSuffix("EDT") && elsewhere.whenNote?.contains("PDT") == true)
    }

    @Test func theAnswerConflictsUpdatesAndOlderVersions() throws {
        let invite = try #require(ICSParser.parse(googleStyleInvite, defaultZone: utc))
        let busy = CalendarEvent(id: "b", title: "Design review", start: invite.start.addingTimeInterval(-1_800),
                                 end: invite.start.addingTimeInterval(1_800))
        let itself = CalendarEvent(id: "self", title: "Launch planning", start: invite.start, end: invite.end)
        let declined = CalendarEvent(id: "d", title: "Skipped", start: invite.start, end: invite.end, myResponse: .declined)
        let card = InviteCardBuilder.card(invite, message: messageKey, myAddresses: me, timeZone: utc, locale: enUS,
                                          known: .tentative, conflicts: [busy, itself, declined])
        #expect(card.response == .tentative, "the calendar's answer is highlighted")
        #expect(card.conflict == "Conflicts with Design review", "the event itself and declined ones are no conflict")
        let two = InviteCardBuilder.card(invite, message: messageKey, myAddresses: me, timeZone: utc, locale: enUS,
                                         conflicts: [busy, CalendarEvent(id: "c", title: "Lunch", start: invite.start,
                                                                         end: invite.end)])
        #expect(two.conflict == "Conflicts with Design review and 1 more")
        let updated = try #require(ICSParser.parse(googleStyleInvite.replacingOccurrences(of: "SEQUENCE:0", with: "SEQUENCE:2"),
                                                   defaultZone: utc))
        #expect(InviteCardBuilder.card(updated, message: messageKey, myAddresses: me, timeZone: utc).isUpdate)
        let older = InviteCardBuilder.card(invite, message: messageKey, myAddresses: me, timeZone: utc, newestSequence: 2)
        #expect(older.isOutdated && !older.offersRSVP && !older.canRespond)
        let stranger = InviteCardBuilder.card(invite, message: messageKey, myAddresses: ["kim@example.com"], timeZone: utc)
        #expect(stranger.offersRSVP && !stranger.isInvited && !stranger.canRespond)
    }

    @Test func cancelledRepliesAndCounters() throws {
        let cancel = googleStyleInvite.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:CANCEL")
        let cancelled = InviteCardBuilder.card(try #require(ICSParser.parse(cancel, defaultZone: utc)), message: messageKey,
                                               myAddresses: me, timeZone: utc)
        #expect(cancelled.kind == .cancelled && !cancelled.offersRSVP)
        let reply = googleStyleInvite.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:REPLY")
        let replied = InviteCardBuilder.card(try #require(ICSParser.parse(reply, defaultZone: utc)), message: messageKey,
                                             myAddresses: me, timeZone: utc)
        #expect(replied.kind == .reply && !replied.offersRSVP && replied.compactLine == "Dana Ruiz accepted")
        let counter = googleStyleInvite.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:COUNTER")
        let countered = InviteCardBuilder.card(try #require(ICSParser.parse(counter, defaultZone: utc)), message: messageKey,
                                               myAddresses: me, timeZone: utc)
        #expect(countered.kind == .counter && countered.compactLine == "Dana Ruiz proposed a new time")
        let publish = googleStyleInvite.replacingOccurrences(of: "METHOD:REQUEST\r\n", with: "")
        #expect(InviteCardBuilder.card(try #require(ICSParser.parse(publish, defaultZone: utc)), message: messageKey,
                                       myAddresses: me, timeZone: utc).kind == .notice)
    }

    @Test func allDayTimesAndJoinTitles() throws {
        let allDay = CalendarInvite(method: .request, uid: "a@example.com", title: "Offsite", start: utcDate(2026, 10, 20),
                                    end: utcDate(2026, 10, 22), isAllDay: true)
        let when = InviteCardBuilder.when(allDay, in: utc, locale: Locale(identifier: "en_US"))
        #expect(when.contains("Oct 20") && when.contains("Oct 21") && when.hasSuffix("(all day)"), "\(when)")
        func joinTitle(_ link: String) -> String? {
            InviteCardBuilder.join(CalendarInvite(method: .request, uid: "j", title: nil, start: .now, end: .now,
                                                  conferenceURL: URL(string: link)))?.title
        }
        #expect(joinTitle("https://example.zoom.us/j/1") == "Join Zoom meeting")
        #expect(joinTitle("https://teams.microsoft.com/l/x") == "Join Teams meeting")
        #expect(joinTitle("https://meet.example/x") == "Join meeting")
        #expect(InviteCardBuilder.cleanNotes("\n\n  \n") == nil)
        #expect(InviteCardBuilder.locationLink("https://example.zoom.us/j/1")?.host() == "example.zoom.us",
                "a place that is a link opens that link")
    }
}
