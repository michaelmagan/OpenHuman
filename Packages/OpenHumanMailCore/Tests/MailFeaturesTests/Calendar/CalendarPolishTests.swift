import Foundation
import MailFakes
import MailModel
import MailTheme
import OpenHumanCore
import Testing
@testable import MailFeatures

private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
private let laCalendar = CalendarDateMentions.calendar(losAngeles)

private func la(_ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    laCalendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: min))!
}

private func timed(_ id: String, _ start: Date, _ end: Date, response: CalendarResponse? = nil) -> CalendarEvent {
    CalendarEvent(id: id, title: id, start: start, end: end, myResponse: response)
}

private func grid(_ events: [CalendarEvent], now: Date, days: [Date]? = nil) -> CalendarTimeGrid {
    let week = CalendarPeriod.containing(la(12), kind: .week, calendar: laCalendar)
    return CalendarTimeGrid(days: days ?? week.days, events: events, timeZone: losAngeles, now: now)
}

@Suite struct CalendarOpeningHourTests {
    @Test func theGridOpensAnHourAboveNow() {
        #expect(grid([], now: la(14, 11)).openingHour == 10)
    }

    @Test func aBlockUnderTheTopEdgeLiftsTheOpeningHour() {
        let standups = (12...16).map { timed("s\($0)", la($0, 9, 30), la($0, 9, 45)) }
        #expect(grid(standups, now: la(14, 11)).openingHour == 9, "short stand-ups at 9:30 are not cut")
        let morning = timed("m", la(13, 8, 30), la(13, 10, 30))
        #expect(grid([morning], now: la(14, 11)).openingHour == 8)
    }

    @Test func theLiftStopsAfterThreeHours() {
        let long = timed("l", la(13, 5), la(13, 11))
        #expect(grid([long], now: la(14, 11, 30)).openingHour == 7)
    }

    @Test func anotherWeekOpensOnItsFirstEventsHour() {
        let next = CalendarPeriod.containing(la(20), kind: .week, calendar: laCalendar)
        #expect(grid([timed("x", la(20, 13, 30), la(20, 14))], now: la(14, 11), days: next.days).openingHour == 13)
        #expect(grid([], now: la(14, 11), days: next.days).openingHour == 8)
    }

    @Test func earlyMorningClampsAtMidnightAndEarlierDaysAreIgnored() {
        #expect(grid([], now: la(14, 0, 20)).openingHour == 0)
        let overnight = timed("o", la(13, 22), la(14, 10))
        #expect(grid([overnight], now: la(14, 11)).openingHour == 10, "a block that began the day before keeps its cut")
    }

    @Test func theOldScrollTargetIsUnchanged() {
        #expect(abs(grid([], now: la(12, 11)).scrollTarget - 10.0 / 24) < 0.0001)
    }

    @Test func pastIsWhatEndedBeforeNow() {
        let events = [timed("ended", la(14, 8), la(14, 9)), timed("running", la(14, 10, 30), la(14, 11, 30)),
                      timed("later", la(14, 15), la(14, 16))]
        let blocks = grid(events, now: la(14, 11)).blocks
        #expect(blocks.map(\.isPast) == [true, false, false])
    }
}

@Suite struct CalendarPaletteTests {
    static let darkThemes = [BuiltinThemeID.dark, BuiltinThemeID.midnight, BuiltinThemeID.systemDark]
    static let themes = [BuiltinThemeID.light, BuiltinThemeID.paper, BuiltinThemeID.systemLight] + darkThemes

    static func everyTheme() -> [(String, ThemeTokens)] {
        var result: [(String, ThemeTokens)] = []
        for themeID in themes {
            for accent in BuiltinThemeID.accents {
                for increase in [false, true] {
                    let appearance: ThemeAppearance = darkThemes.contains(themeID) ? .dark : .light
                    let tokens = ThemeLibrary.builtIn.resolve(themeID: themeID, appearance: appearance,
                                                              preferences: ThemePreferences(accentID: accent),
                                                              increaseContrast: increase).tokens
                    result.append(("\(themeID) \(accent) increaseContrast=\(increase)", tokens))
                }
            }
        }
        return result
    }

    static let states: [CalendarPalette.BlockState] = [.normal, .past, .selected, .outlined, .invited, .declined]

    @Test func everyBlockTitleReadsOnItsFillInEveryTheme() {
        for (label, tokens) in Self.everyTheme() {
            for index in 0..<CalendarPalette.hues.count {
                for state in Self.states {
                    let colors = CalendarPalette.block(index, state: state, tokens: tokens)
                    #expect(colors.fill.alpha == 1, "\(state) fill is opaque: \(label)")
                    #expect(colors.text.contrastRatio(on: colors.fill) >= 4.5, "\(index) \(state): \(label)")
                }
            }
        }
    }

    @Test func calendarsKeepDistinctColoursAndTheIndexWraps() {
        let tokens = ThemeTokens.light
        let inks = (0..<CalendarPalette.hues.count).map { CalendarPalette.ink($0, tokens: tokens) }
        #expect(Set(inks).count == CalendarPalette.hues.count)
        #expect(CalendarPalette.hue(0) == .sky && CalendarPalette.hue(6) == .sky && CalendarPalette.hue(-1) == .rose)
    }

    @Test func selectedFlipsTheFillAndPastIsPaler() {
        let tokens = ThemeTokens.light
        let normal = CalendarPalette.block(0, state: .normal, tokens: tokens)
        let selected = CalendarPalette.block(0, state: .selected, tokens: tokens)
        let past = CalendarPalette.block(0, state: .past, tokens: tokens)
        #expect(selected.fill == normal.text && selected.text == normal.fill)
        #expect(past.fill.contrastRatio(on: tokens.bgWindow) < normal.fill.contrastRatio(on: tokens.bgWindow))
        #expect(CalendarPalette.block(0, state: .invited, tokens: tokens).dashedBorder)
        #expect(CalendarPalette.block(0, state: .outlined, tokens: tokens).border != nil)
    }

    @Test func theStateFollowsSelectionThenAnswerThenMaybe() {
        func state(selected: Bool = false, declined: Bool = false, needsAnswer: Bool = false, tentative: Bool = false,
                   past: Bool = false) -> CalendarPalette.BlockState {
            CalendarPalette.state(isSelected: selected, isDeclined: declined, needsAnswer: needsAnswer,
                                  isTentative: tentative, isPast: past)
        }
        #expect(state(selected: true, declined: true, needsAnswer: true, tentative: true, past: true) == .selected)
        #expect(state(declined: true, tentative: true) == .declined)
        #expect(state(needsAnswer: true, tentative: true) == .invited)
        #expect(state(tentative: true, past: true) == .outlined)
        #expect(state(past: true) == .past)
        #expect(state() == .normal, "an accepted event is filled")
        let tokens = ThemeTokens.light
        #expect(CalendarPalette.block(0, state: .normal, tokens: tokens).border == nil)
        #expect(CalendarPalette.block(0, state: .outlined, tokens: tokens).dashedBorder == false)
        #expect(CalendarPalette.block(0, state: .invited, tokens: tokens).dashedBorder)
        #expect(CalendarPalette.block(0, state: .declined, tokens: tokens).dashedBorder)
    }

    @Test func contentFollowsTheBlocksHeight() {
        #expect([29, 30, 55, 56, 71, 72].map { CalendarPalette.content(height: $0) }
            == [.oneLine, .titleAndTime, .titleAndTime, .withPlace, .withPlace, .withAccount])
    }
}

@Suite struct CalendarCardModeTests {
    static let base = CalendarEvent(id: "e", title: "Review", start: la(14, 14), end: la(14, 15))

    static func card(_ event: CalendarEvent = base, form: Bool, rights: CalendarFieldRights = .all,
                     canMove: Bool = false, canEdit: Bool = false) -> CalendarEventCard {
        var card = CalendarEventCard(event: event, calendarKey: "robin@example.com", title: event.title, location: "",
                                     notes: "", start: event.start, end: event.end, response: event.myResponse,
                                     canMove: canMove, canEditDetails: canEdit, canRemove: false, canRespond: false,
                                     reason: nil, note: nil)
        if form {
            card.form = CalendarEventForm(event: event, calendarKey: "robin@example.com", defaultZone: losAngeles.identifier)
            card.rights = rights
        }
        return card
    }

    @Test func ownEventsOpenTheFormAndInvitationsTheDetails() {
        #expect(CalendarCardMode.make(Self.card(form: true), userAskedToEdit: false) == .form)
        let invitation = CalendarEvent(id: "i", title: "Partner review", start: la(14, 14), end: la(14, 15),
                                       attendees: [EmailAddress(name: nil, email: "sam@example.org")], organizerIsMe: false,
                                       myResponse: .needsAction)
        let rights = CalendarFieldRights.make(for: invitation, abilities: [.respond, .editFull], refusal: nil)
        let card = Self.card(invitation, form: true, rights: rights)
        #expect(CalendarCardMode.make(card, userAskedToEdit: false) == .detail)
        #expect(CalendarCardMode.offersEdit(card, mode: .detail), "personal fields stay reachable")
        #expect(CalendarCardMode.make(card, userAskedToEdit: true) == .form)
    }

    @Test func aLockedEventOffersNoEdit() {
        let card = Self.card(form: true, rights: .locked("Not connected."))
        #expect(CalendarCardMode.make(card, userAskedToEdit: false) == .detail)
        #expect(!CalendarCardMode.offersEdit(card, mode: .detail))
    }

    @Test func aPendingMoveAlwaysShowsItsForm() {
        var card = Self.card(form: true, rights: .locked("Not connected."))
        card.pendingMove = CalendarPendingMove(event: Self.base, proposedStart: la(15, 14), proposedEnd: la(15, 15))
        #expect(CalendarCardMode.make(card, userAskedToEdit: false) == .form)
    }

    @Test func connectionsWithoutFullEditKeepTheirInlineEditor() {
        #expect(CalendarCardMode.make(Self.card(form: false, canMove: true), userAskedToEdit: false) == .legacyEdit)
        #expect(CalendarCardMode.make(Self.card(form: false), userAskedToEdit: false) == .detail)
    }

    @Test func theCardWidthClampsAndRSVPReadsYesMaybeNo() {
        #expect(CalendarCardMode.width(available: 1_000) == 440)
        #expect(CalendarCardMode.width(available: 200) == 320)
        #expect(CalendarCardMode.rsvpOrder.map(\.title) == ["Yes", "Maybe", "No"])
    }
}

@MainActor
@Suite struct CalendarDraftCalendarTests {
    @Test func aNewEventFromMailCanGoToAnotherConnectedCalendar() async throws {
        let corpus = FakeCorpus.rich(threadCount: 12, now: fixedNow)
        let accounts = corpus.accounts
        let work = FakeCalendar(info: CalendarProviderInfo(name: "Google Calendar", account: accounts[0].email))
        let home = FakeCalendar(info: CalendarProviderInfo(name: "Google Calendar", account: accounts[1].email))
        let connections = FakeCalendarConnections(providers: [accounts[0].email: work, accounts[1].email: home])
        let env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), featureFlags: FeatureFlags(),
                                      calendar: work, calendarConnections: connections)
        let sidebar = try #require(env.calendarSidebar)
        sidebar.timeZone = losAngeles
        sidebar.now = { la(14, 9) }
        sidebar.loadText = { _ in CalendarThreadText(subject: "Planning", texts: ["Planning"], participants: []) }
        let thread = try #require(corpus.threads.first { $0.row.id.account == accounts[0].id }).row.id

        await sidebar.beginDraft(for: thread)
        #expect(sidebar.draftCalendarAccount?.lowercased() == accounts[0].email.lowercased())
        let choices = await sidebar.draftCalendarChoices()
        #expect(choices.map(\.id) == accounts.prefix(2).map { $0.email.lowercased() })

        #expect(await sidebar.chooseDraftCalendar(account: accounts[1].id))
        #expect(sidebar.draftCalendarAccount?.lowercased() == accounts[1].email.lowercased())
        #expect(await sidebar.createEvent())
        #expect(home.createCalls == 1 && work.createCalls == 0, "the event goes to the chosen calendar")
    }

    @Test func guestSuggestionsComeFromTheConversationsAccount() async throws {
        let corpus = FakeCorpus.rich(threadCount: 12, now: fixedNow)
        let calendar = FakeCalendar(info: CalendarProviderInfo(name: "Google Calendar", account: corpus.accounts[0].email))
        let env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), featureFlags: FeatureFlags(),
                                      calendar: calendar)
        let sidebar = try #require(env.calendarSidebar)
        let thread = try #require(corpus.threads.first { $0.row.id.account == corpus.accounts[0].id })
        let someone = try #require(thread.detail.messages.compactMap(\.from).first {
            $0.email.lowercased() != corpus.accounts[0].email.lowercased()
        })
        sidebar.loadText = { _ in CalendarThreadText(subject: "Planning", texts: ["Planning"], participants: []) }
        await sidebar.beginDraft(for: thread.row.id)
        let prefix = someone.email
        let found = await sidebar.guestSuggestions(prefix)
        #expect(found.contains { $0.email.lowercased() == someone.email.lowercased() })
        #expect(found.count <= RecipientFieldModel.maxSuggestions)
    }
}
