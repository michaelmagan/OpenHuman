import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailFeatures

private let newYork = TimeZone(identifier: "America/New_York")!

private func on(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ tz: TimeZone = newYork) -> Date {
    CalendarDateMentions.calendar(tz).date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
}

@MainActor
private struct GapsFixture {
    let env: AppEnvironment
    let calendar: FakeCalendar
    let corpus: FakeCorpus
    let thread: ThreadKey

    init(events: [CalendarEvent] = [], ai: AICenter? = nil) {
        corpus = .make(threadCount: 6, now: fixedNow)
        calendar = FakeCalendar(events: events)
        env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate),
                                  featureFlags: FeatureFlags(), ai: ai, calendar: calendar)
        thread = corpus.threads[0].row.id
    }

    func sidebar(_ text: CalendarThreadText? = nil) -> CalendarSidebarModel {
        let model = env.calendarSidebar!
        model.timeZone = newYork
        model.now = { on(10, 10, 9) }
        let shown = text
        model.loadText = { _ in shown }
        return model
    }

    func text(_ bodies: [String], subject: String = "Planning") -> CalendarThreadText {
        CalendarThreadText(subject: subject, texts: [subject] + bodies, participants: [])
    }

    func run(_ id: ActionID, context: ActionContext) async -> Bool {
        await env.actions.run(id, source: .palette, host: nil, context: context)
    }
}

@MainActor
@Suite struct CalendarDayNavigationTests {
    @Test func minusEqualsAndTodayMoveOneDayAndTheNextConversationShowsItsOwnDays() async throws {
        let f = GapsFixture(events: [CalendarEvent(id: "e15", title: "Review", start: on(10, 15, 10), end: on(10, 15, 11))])
        let model = f.sidebar(f.text(["Can we meet on October 14, 2026 at 3:00 PM?"]))
        await model.show(thread: f.thread)
        #expect(model.days.map(\.start) == [on(10, 14)] && !model.isBrowsing)
        await model.moveDay(by: 1)
        #expect(model.days.map(\.start) == [on(10, 15)] && model.isBrowsing)
        #expect(model.days.first?.events.map(\.id) == ["e15"] && model.days.first?.isMentioned == false)
        await model.moveDay(by: -1)
        #expect(model.days.first?.isMentioned == true, "the conversation's day keeps its mark")
        await model.moveDay(by: -1)
        #expect(model.days.map(\.start) == [on(10, 13)])
        await model.goToToday()
        #expect(model.days.map(\.start) == [on(10, 10)])
        let reads = f.calendar.readCalls
        await model.refresh()
        #expect(model.days.map(\.start) == [on(10, 10)] && f.calendar.readCalls == reads + 1, "refresh reads the day shown")
        await model.show(thread: f.thread)
        #expect(model.days.map(\.start) == [on(10, 14)] && !model.isBrowsing, "a conversation shows its own days again")
        #expect(f.calendar.createCalls == 0)
    }

    @Test func thePaletteEntriesMoveTheDay() async throws {
        let f = GapsFixture()
        let model = f.sidebar()
        let context = ActionContext(scope: .list)
        for id in [ActionID.calendarPreviousDay, .calendarNextDay, .calendarToday] {
            #expect(f.env.actions.availability(id, host: nil, context: context) == .enabled, "\(id)")
        }
        #expect(await f.run(.calendarNextDay, context: context))
        await eventually { model.days.map(\.start) == [on(10, 11)] }
        #expect(model.isVisible, "the sidebar shows to move its day")
        #expect(await f.run(.calendarToday, context: context))
        await eventually { model.days.map(\.start) == [on(10, 10)] }
        #expect(await f.run(.calendarPreviousDay, context: context))
        await eventually { model.days.map(\.start) == [on(10, 9)] }
    }
}

@MainActor
@Suite struct CalendarSummaryTitleTests {
    @Test func theTitleComesFromTheSummaryShownThisSessionElseTheSubject() async throws {
        let provider = ScriptedProvider { _, _ in .text("Budget review moves to Thursday. Dana wants the numbers first.") }
        let center = AICenter.make(registry: ProviderRegistry(providers: [provider]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore(AISettings())))
        let f = GapsFixture(ai: center)
        let model = f.sidebar(f.text(["October 15, 2026 at 12:30 PM"], subject: "Re: Q4"))
        await model.beginDraft(for: f.thread)
        #expect(model.draft?.title == "Q4", "no summary yet: the subject; nothing is summarized for the title")
        #expect(!provider.requests.contains { $0.task == .summarize })

        let summary = center.summary(for: f.thread)
        summary.summarize(trigger: .user)
        await eventually { summary.phase == .done }
        model.cancelDraft()
        await model.beginDraft(for: f.thread)
        #expect(model.draft?.title == "Budget review moves to Thursday")
        #expect(f.calendar.createCalls == 0)
    }

    @Test func aSummaryTitleIsItsFirstSentenceCutAtAWord() {
        #expect(CalendarEventDraftBuilder.title(fromSummary: "\n  Lunch with Sam on Friday!  More text.") == "Lunch with Sam on Friday")
        #expect(CalendarEventDraftBuilder.title(fromSummary: "   \n ") == nil)
        let long = String(repeating: "word ", count: 40)
        let cut = CalendarEventDraftBuilder.title(fromSummary: long)
        #expect((cut?.count ?? 0) <= CalendarEventDraftBuilder.summaryTitleLimit && cut?.hasSuffix("…") == true)
        #expect(cut?.hasSuffix(" …") == false, "cut at a word, no space before the ellipsis")
    }
}

@MainActor
@Suite struct CalendarFollowsTheDraftTests {
    @Test func theSidebarShowsTheDaysADraftMentionsAndNothingElseChanges() async throws {
        let f = GapsFixture()
        let model = f.sidebar(f.text(["Can we meet on October 14, 2026 at 3:00 PM?"]))
        await model.show(thread: f.thread)
        let reads = f.calendar.readCalls
        await model.follow(typed: "Thanks! No dates in here.")
        #expect(model.days.map(\.start) == [on(10, 14)] && !model.followsDraft && f.calendar.readCalls == reads)
        await model.follow(typed: "How about October 20, 2026 at 2pm, or October 21, 2026?")
        #expect(model.followsDraft && model.days.map(\.start) == [on(10, 20), on(10, 21)])
        #expect(model.days.allSatisfy { $0.isMentioned })
        let after = f.calendar.readCalls
        await model.follow(typed: "How about October 20, 2026 at 2pm, or October 21, 2026? Thanks")
        #expect(f.calendar.readCalls == after, "the same days: nothing is read again")
        await model.show(thread: f.thread)
        #expect(!model.followsDraft && model.days.map(\.start) == [on(10, 14)])
        #expect(f.calendar.createCalls == 0)
    }
}

@MainActor
@Suite struct CalendarFreeTimesTests {
    private let mondayMorning = CalendarEvent(id: "busy", title: "Standup", start: on(10, 12, 9), end: on(10, 12, 12))

    @Test func threeFreeHalfHoursSpreadOverTheNextWorkingDaysFromOneFreeBusyRead() async throws {
        let f = GapsFixture(events: [mondayMorning])
        let model = f.sidebar()
        let found = try #require(await model.suggestTimes())
        #expect(found.slots.map(\.start) == [on(10, 12, 12), on(10, 13, 9), on(10, 14, 9)], "Monday after the busy block")
        #expect(found.slots.allSatisfy { $0.end.timeIntervalSince($0.start) == CalendarAvailability.slotLength })
        #expect(f.calendar.calls == [.freeBusy(from: on(10, 12), to: on(10, 17))], "one read, Monday to Friday")
        #expect(f.calendar.createCalls == 0, "never an event or a hold")
        let text = try #require(model.suggestionText(found))
        #expect(text.hasPrefix("Here are a few times that work for me (New York time, free as of "))
        #expect(text.split(separator: "\n").filter { $0.hasPrefix("• ") }.count == 3)
        #expect(text.contains(CalendarSidebarModel.range(on(10, 12, 12), on(10, 12, 12, 30), newYork)))
    }

    @Test func ignoreConflictsOffersTheWindowWithoutReadingTheCalendar() async throws {
        let f = GapsFixture(events: [mondayMorning])
        let model = f.sidebar()
        try await f.env.settings!.set(AppSettings.calendarAvailabilityIgnoresConflicts, true)
        #expect(AppSettings.calendarAvailabilityIgnoresConflicts.name == "calendar.availability_ignore_conflicts")
        let found = try #require(await model.suggestTimes())
        #expect(found.ignoresConflicts && found.slots.map(\.start) == [on(10, 12, 9), on(10, 13, 9), on(10, 14, 9)])
        #expect(f.calendar.readCalls == 0)
        #expect(model.suggestionText(found)?.contains("free as of") == false)
    }

    @Test func theSecondZoneFollowsEachTimeAndAFullWeekSaysSo() async throws {
        let f = GapsFixture(events: (12...16).map { CalendarEvent(id: "d\($0)", title: "Offsite", start: on(10, $0, 8),
                                                                         end: on(10, $0, 19)) })
        let model = f.sidebar()
        #expect(await model.suggestTimes() == nil)
        #expect(model.suggestionNote == CalendarSidebarModel.noFreeTimes && model.suggestion == nil)

        let slots = [CalendarAvailability.Slot(start: on(10, 12, 9), end: on(10, 12, 9, 30))]
        let london = try #require(TimeZone(identifier: "Europe/London"))
        let text = try #require(CalendarAvailability(slots: slots, asOf: on(10, 10, 9), ignoresConflicts: false)
            .text(timeZone: newYork, secondTimeZone: london))
        #expect(text.contains("(" + CalendarSidebarModel.range(on(10, 12, 9), on(10, 12, 9, 30), london) + " London)"))
    }

    @Test func workingDaysSkipTheWeekendAndAFinishedToday() {
        let calendar = CalendarDateMentions.calendar(newYork)
        #expect(CalendarAvailability.days(from: on(10, 10, 9), calendar: calendar)
                == [on(10, 12), on(10, 13), on(10, 14), on(10, 15), on(10, 16)])
        #expect(CalendarAvailability.days(from: on(10, 12, 17, 45), calendar: calendar).first == on(10, 13),
                "after 17:30 today has no half hour left")
        #expect(CalendarAvailability.days(from: on(10, 12, 11), calendar: calendar).first == on(10, 12))
        let slots = CalendarAvailability.slots(days: [on(10, 12)], busy: [], now: on(10, 12, 11, 10), calendar: calendar,
                                               ignoreConflicts: false)
        #expect(slots.first?.start == on(10, 12, 11, 30), "only times still ahead")
    }

    @Test func shiftCommandAPutsTheTimesAtTheCaretAndCreatesNothing() async throws {
        let f = GapsFixture(events: [mondayMorning])
        _ = f.sidebar()
        f.env.router.start()
        await eventually { f.env.router.active != nil }
        #expect(f.env.actions.availability(.calendarInsertAvailability, host: nil) == .hidden, "no composer: hidden")
        let session = try #require(f.env.compose.openNew(placement: .modal))
        let editor = FakeEditor(session: session, text: "Hi Sam,\n\n", selection: nil)
        #expect(f.env.actions.availability(.calendarInsertAvailability, host: session) == .enabled)
        #expect(await f.env.actions.run(.calendarInsertAvailability, source: .keyboard, host: session))
        await eventually { editor.text.contains("Here are a few times that work for me") }
        #expect(editor.text.hasPrefix("Hi Sam,\n\nHere are a few times"))
        #expect(editor.replacements.count == 1, "one undoable edit")
        #expect(f.calendar.createCalls == 0 && f.calendar.calls == [.freeBusy(from: on(10, 12), to: on(10, 17))])
    }
}

@MainActor
@Suite struct CalendarPickedTimeTests {
    @Test func aClickedTimeOpensTheCalendarOnItsDayAsABlockAndDraftsNothing() async throws {
        let f = GapsFixture(events: [CalendarEvent(id: "e14", title: "Standup", start: on(10, 14, 15),
                                                   end: on(10, 14, 15, 30))])
        let model = f.sidebar(f.text(["Can we meet on October 14, 2026 at 3:00 PM?"]))
        let mention = CalendarDateMention(date: on(10, 14, 15), hasTime: true, duration: 3_600)
        await model.reveal(mention, in: f.thread)
        #expect(model.isVisible && model.draft == nil && model.thread == f.thread)
        #expect(model.pickedTime?.start == on(10, 14, 15) && model.pickedTime?.end == on(10, 14, 16))
        #expect(model.showsPickedTime && model.days.map(\.start) == [on(10, 14)])
        let day = try #require(model.dayViewDay)
        #expect(model.timeline(for: day).conflicts.map(\.id) == ["e14"], "the block shows what it overlaps")
        await model.moveDay(by: 1)
        #expect(model.days.map(\.start) == [on(10, 15)] && !model.showsPickedTime, "the block stays on its own day")
        await model.moveDay(by: -1)
        #expect(model.showsPickedTime)
        await model.show(thread: f.thread)
        #expect(model.days.map(\.start) == [on(10, 14)] && model.showsPickedTime, "the same conversation keeps it")

        await model.createEventAtPickedTime()
        let draft = try #require(model.draft)
        #expect(draft.start == on(10, 14, 15) && draft.end == on(10, 14, 16))
        #expect(!model.showsPickedTime, "the form takes over from the block")
        model.cancelDraft()
        #expect(model.draft == nil && model.showsPickedTime, "cancelling goes back to the block")
        #expect(f.calendar.createCalls == 0)
    }

    @Test func anotherConversationOrHidingTheCalendarDropsTheBlockAndAnOpenFormMovesInstead() async throws {
        let f = GapsFixture()
        let model = f.sidebar(f.text(["Lunch on October 13, 2026?"]))
        let lunch = CalendarDateMention(date: on(10, 13, 12), hasTime: true)
        await model.reveal(lunch, in: f.thread)
        #expect(model.pickedTime != nil)
        await model.show(thread: f.corpus.threads[1].row.id)
        #expect(model.pickedTime == nil && !model.showsPickedTime)

        await model.reveal(lunch, in: f.thread)
        model.setVisible(false)
        #expect(model.pickedTime == nil)

        await model.beginDraft(for: f.thread)
        await model.reveal(CalendarDateMention(date: on(10, 16, 14), hasTime: true), in: f.thread)
        #expect(model.pickedTime == nil && model.draft?.start == on(10, 16, 14), "an open form follows the click")
        model.cancelDraft()
        #expect(f.calendar.createCalls == 0)
    }

    @Test func aTimeInADraftShowsAsABlockFirstAndItsEventBelongsToTheDraft() async throws {
        let f = GapsFixture(events: [CalendarEvent(id: "e15", title: "Review", start: on(10, 15, 10), end: on(10, 15, 11))])
        let model = f.sidebar()
        f.env.router.start()
        await eventually { f.env.router.active != nil }
        let session = try #require(f.env.compose.openNew(placement: .modal))
        let mention = CalendarDateMention(date: on(10, 15, 11), hasTime: true, duration: 1_800)
        f.env.compose.openEvent(at: mention, from: session)
        await eventually { model.showsPickedTime }
        #expect(model.isVisible && model.draft == nil, "the calendar opens on the day; no form yet")
        #expect(model.pickedTime?.key == .draft(session.id) && model.pickedTime?.thread == nil)
        #expect(model.days.map(\.start) == [on(10, 15)])

        await model.createEventAtPickedTime()
        let draft = try #require(model.draft)
        #expect(draft.start == on(10, 15, 11) && draft.end == on(10, 15, 11, 30))
        #expect(model.draftKey == .draft(session.id), "the event is the draft's, not the conversation's")
        await model.reveal(CalendarDateMention(date: on(10, 16, 9), hasTime: true), in: nil, key: .draft(session.id))
        #expect(model.draft?.start == on(10, 16, 9), "with the draft's form open, a click moves the form")
        model.cancelDraft()
        #expect(f.calendar.createCalls == 0)
    }
}

@MainActor
@Suite struct CalendarSuggestedTimesFollowTheDraftTests {
    private let mondayMorning = CalendarEvent(id: "busy", title: "Standup", start: on(10, 12, 9), end: on(10, 12, 12))

    private func composer(_ f: GapsFixture) async throws -> (ComposeSession, FakeEditor) {
        f.env.router.start()
        await eventually { f.env.router.active != nil }
        let session = try #require(f.env.compose.openNew(placement: .modal))
        return (session, FakeEditor(session: session, text: "Hi Sam,\n\n", selection: nil))
    }

    @Test func insertedTimesAreReplacedInPlaceAndRemovedAsOneEditEach() async throws {
        let f = GapsFixture(events: [mondayMorning])
        let model = f.sidebar()
        let (session, editor) = try await composer(f)
        #expect(await model.insertAvailability(into: session))
        let block = try #require(model.insertedAvailability?.text)
        #expect(editor.text == "Hi Sam,\n\n" + block && model.hasInsertedAvailability(in: session))
        let reads = f.calendar.calls.count
        #expect(await model.insertAvailability(into: session))
        #expect(f.calendar.calls.count == reads, "the times shown are still fresh, so they go in as they are")
        #expect(editor.text == "Hi Sam,\n\n" + block, "a second insert replaces the first block")
        #expect(model.removeInsertedAvailability(from: session))
        #expect(editor.text == "Hi Sam,\n\n" && !model.hasInsertedAvailability(in: session))
        #expect(editor.replacements.count == 3, "insert, replace and remove are one edit each")
        #expect(!model.removeInsertedAvailability(from: session), "nothing left to remove")
        #expect(f.calendar.createCalls == 0)
    }

    @Test func editedTimesAreLeftAloneWithANote() async throws {
        let f = GapsFixture(events: [mondayMorning])
        let model = f.sidebar()
        let (session, editor) = try await composer(f)
        #expect(await model.insertAvailability(into: session))
        editor.text = "Hi Sam,\n\nHow about Monday?"
        #expect(!model.removeInsertedAvailability(from: session))
        #expect(editor.text == "Hi Sam,\n\nHow about Monday?")
        #expect(session.notice?.text == CalendarSidebarModel.timesWereEdited)
    }

    @Test func newRecipientsAnotherDraftOrANewDayMakeTheTimesStale() async throws {
        let f = GapsFixture(events: [mondayMorning])
        let model = f.sidebar()
        let (session, _) = try await composer(f)
        let before = model.availabilityContext(for: session)
        #expect(await model.suggestTimes(for: before) != nil)
        #expect(model.staleReason(for: before) == nil)
        session.to.setTokens([EmailAddress(name: "Sam Lee", email: "sam@example.org")])
        let after = model.availabilityContext(for: session)
        #expect(model.staleReason(for: after) == .recipients)
        #expect(model.staleReason(for: model.availabilityContext(for: nil)) != nil, "no draft open: another state")
        model.now = { on(10, 13, 9) }
        #expect(model.availabilityContext(for: session).firstDay == on(10, 13))
        #expect(model.staleReason(for: model.availabilityContext(for: session)) == .recipients)
        #expect(await model.suggestTimes(for: model.availabilityContext(for: session)) != nil)
        #expect(model.staleReason(for: model.availabilityContext(for: session)) == nil, "found again for the new state")
        model.clearSuggestion()
        #expect(model.suggestion == nil && model.staleReason(for: after) == nil)
    }

    @Test func anotherConversationClearsTheTimesAndTheSameOneKeepsThem() async throws {
        let f = GapsFixture(events: [mondayMorning])
        let model = f.sidebar(f.text(["Lunch on October 13, 2026?"]))
        await model.show(thread: f.thread)
        let here = model.availabilityContext(for: nil)
        #expect(await model.suggestTimes(for: here) != nil)
        await model.show(thread: f.thread)
        #expect(model.suggestion != nil, "the same conversation keeps its times")

        let other = f.corpus.threads[1].row.id
        let there = CalendarSidebarModel.AvailabilityContext(account: other.account, thread: other, draft: nil,
                                                              recipients: [], firstDay: here.firstDay)
        #expect(model.isForAnotherConversation(there) && model.staleReason(for: there) == nil, "not dimmed: cleared")
        await model.show(thread: other)
        #expect(model.suggestion == nil && model.suggestionNote == nil && model.suggestionContext == nil)

        await model.show(thread: f.thread)
        #expect(model.suggestion == nil, "coming back does not bring them back")
        #expect(await model.suggestTimes(for: model.availabilityContext(for: nil)) != nil)
        await model.followAvailability(there)
        #expect(model.suggestion == nil, "a composer for another conversation clears them too")
        #expect(f.calendar.createCalls == 0)
    }

    @Test func otherTimesSkipTheOnesShown() async throws {
        let f = GapsFixture(events: [mondayMorning])
        let model = f.sidebar()
        let context = model.availabilityContext(for: nil)
        let first = try #require(await model.suggestTimes(for: context))
        let second = try #require(await model.suggestTimes(for: context, others: true))
        #expect(Set(first.slots).isDisjoint(with: second.slots))
        #expect(second.slots.map(\.start) == [on(10, 12, 12, 30), on(10, 13, 9, 30), on(10, 14, 9, 30)])
        let again = try #require(await model.suggestTimes(for: context))
        #expect(again.slots == first.slots, "a plain request starts over")
    }
}

@MainActor
@Suite struct AskCalendarEventsTests {
    @Test func aQuestionAboutMeetingsReadsTheCalendarAsExcerptsInsideEmailData() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 32_000))
        let clock = TestClock()
        let now = clock.now
        let events = [CalendarEvent(id: "a", title: "Offsite planning", start: now.addingTimeInterval(86_400),
                                    end: now.addingTimeInterval(86_400 + 3_600),
                                    attendees: [EmailAddress(name: "Alice", email: "alice@example.com")]),
                      CalendarEvent(id: "far", title: "Far away", start: now.addingTimeInterval(40 * 86_400),
                                    end: now.addingTimeInterval(40 * 86_400 + 3_600))]
        let calendar = FakeCalendar(events: events)
        let f = AskFixture(providers: [provider], calendar: calendar)
        await f.loaded()
        await f.ask("what meetings do I have about the offsite")
        let request = try #require(provider.requests.last { $0.task == .askInbox })
        let rendered = request.renderedInput()
        let blocks = try #require(RequestInspector.blocks(in: rendered, nonce: request.nonce))
        #expect(blocks.contains { $0.id.hasPrefix(AskCalendarEvents.keyPrefix) && $0.text.contains("Calendar event: Offsite planning") })
        #expect(RequestInspector.leaks(in: request).isEmpty, "event text stays inside email_data blocks")
        #expect(!rendered.contains("Far away"), "only 7 days back and 14 ahead")
        #expect(f.model.planLine?.contains("calendar event") == true)
        #expect(calendar.createCalls == 0)
    }

    @Test func otherQuestionsNeverReadTheCalendar() async throws {
        let calendar = FakeCalendar(events: [])
        let f = AskFixture(calendar: calendar)
        await f.loaded()
        await f.ask("zebra quokka")
        #expect(calendar.readCalls == 0)
        #expect(!AskCalendarEvents.isAbout("zebra quokka") && AskCalendarEvents.isAbout("Am I free on Thursday?"))
    }

    @Test func mailKeepsTheFirstPlacesAndEventsAtMostTen() {
        let mail = (0..<20).map { AIMessageInput(messageKey: "m\($0)", from: "x", date: fixedNow, bodyText: "b") }
        let events = (0..<20).map { AIMessageInput(messageKey: AskCalendarEvents.keyPrefix + "\($0)", from: "c", date: fixedNow,
                                                   bodyText: "e") }
        let retrieval = AskRetrieval(candidates: mail, keys: [:], sources: [:], otherThreads: [], queryText: nil,
                                     queryAccount: nil, gmailQuery: nil, searched: "x", planLine: "Searched", completeness: nil)
        let merged = AskCalendarEvents.merge(retrieval, events: events)
        #expect(merged.candidates.count == AIPolicy.askInboxMaxCandidates)
        #expect(merged.candidates.filter { $0.messageKey.hasPrefix(AskCalendarEvents.keyPrefix) }.count == 10)
        #expect(merged.planLine == "Searched · 10 calendar events")
        let few = AskCalendarEvents.merge(AskRetrieval(candidates: Array(mail.prefix(3)), keys: [:], sources: [:],
                                                       otherThreads: [], queryText: nil, queryAccount: nil, gmailQuery: nil,
                                                       searched: "x", planLine: "", completeness: nil), events: events)
        #expect(few.candidates.count == 20 && few.candidates.prefix(3).map(\.messageKey) == ["m0", "m1", "m2"])
    }
}
