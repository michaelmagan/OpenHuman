import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let utc = TimeZone(identifier: "UTC")!

@Sendable private func holdUntilCancelled(_: Duration) async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    await withTaskCancellationHandler {
        for await _ in stream {}
    } onCancel: {
        continuation.finish()
    }
    try Task.checkCancellation()
}

@MainActor
private struct InviteFixture {
    let env: AppEnvironment
    let calendar: FakeCalendar?
    let home: FakeCalendar
    let corpus: FakeCorpus

    init(events: [CalendarEvent]? = [], calendarRefusal: String? = nil) {
        corpus = .rich(threadCount: 12, now: fixedNow)
        let accounts = corpus.accounts
        home = FakeCalendar(info: CalendarProviderInfo(name: "Google Calendar", account: accounts[1].email))
        if let events {
            let made = FakeCalendar(events: events, info: CalendarProviderInfo(name: "Google Calendar", account: accounts[0].email,
                                                                               createRefusal: calendarRefusal))
            calendar = made
            let connections = FakeCalendarConnections(providers: [accounts[0].email: made, accounts[1].email: home],
                                                      windowAccount: accounts[0].email)
            env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate),
                                      featureFlags: FeatureFlags(), calendar: made, calendarConnections: connections)
        } else {
            calendar = nil
            env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate),
                                      featureFlags: FeatureFlags())
        }
        env.invites.timeZone = utc
        env.invites.locale = Locale(identifier: "en_US")
        env.invites.now = { fixedNow }
    }

    var center: InviteCenter { env.invites }
    var account: AccountID { corpus.accounts[0].id }

    func invitation(account: AccountID? = nil) async throws -> (ThreadKey, MessageSummary) {
        let rows = try await env.data.threadPage(.system(.inbox), account: account ?? self.account, after: nil, limit: 500).rows
        for row in rows {
            for try await detail in env.data.threadDetail(row.id) {
                if let message = detail?.messages.first(where: \.hasCalendarInvite) { return (row.id, message) }
                break
            }
        }
        Issue.record("no invitation in the corpus")
        throw CancellationError()
    }

    func load(_ thread: ThreadKey, _ message: MessageSummary) async {
        center.load(message, in: thread, force: true)
        await center.pendingLoad(message.id)?.value
    }

    func card(_ thread: ThreadKey, _ message: MessageSummary) async throws -> InviteCard {
        await load(thread, message)
        return try #require(center.card(for: message.id))
    }

    func original(_ message: MessageSummary) async throws -> String {
        let part = try #require(InviteCenter.calendarPart(of: message.attachments))
        return try InviteCenter.readText(try await env.data.attachmentData(message.id, attachment: part))
    }

    func inInbox(_ thread: ThreadKey) async throws -> Bool {
        try await env.data.threadPage(.system(.inbox), account: account, after: nil, limit: 500).rows.contains { $0.id == thread }
    }

    func addInvitedEvent(_ card: InviteCard, id: String = "ev", start: Date? = nil, series: String? = nil,
                         response: CalendarResponse = .needsAction, withUID: Bool = true) {
        let begins = start ?? card.invite.start
        let event = CalendarEvent(id: id, title: card.title, start: begins,
                                  end: begins.addingTimeInterval(card.invite.end.timeIntervalSince(card.invite.start)),
                                  attendees: [FakeCorpus.me], organizerIsMe: false, myResponse: response,
                                  recurringEventID: series)
        calendar?.add(event)
        if withUID { calendar?.setICalUID(card.invite.uid, for: id) }
    }

    func endWindows(_ gate: TestGate) async {
        let tasks = center.heldTasks
        gate.release()
        for task in tasks { await task.value }
    }

    func answered() -> [FakeCalendar.Call] {
        calendar?.calls.filter { if case .respond = $0 { true } else { false } } ?? []
    }

    func lookedUp() -> Bool {
        !(calendar?.lookups.isEmpty ?? true)
    }
}

@MainActor
@Suite(.serialized) struct InviteCenterTests {
    @Test func rememberedAnswersUseTheInboxAccountAsPartOfTheirKey() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        let card = try await f.card(thread, message)
        let work = InviteCenter.answerKey(card.invite, account: f.corpus.accounts[0].id)
        let personal = InviteCenter.answerKey(card.invite, account: f.corpus.accounts[1].id)
        #expect(work != personal)
    }

    @Test func theCardIsReadFromTheCalendarPartThroughTheAttachmentPath() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        #expect(InviteCenter.mayHaveCard(message))
        let card = try await f.card(thread, message)
        #expect(card.kind == .request && card.offersRSVP && card.canRespond && card.response == nil)
        #expect(card.title.hasSuffix("review") && card.when.contains("October 13, 2026"))
        #expect(card.guests.contains { $0.isOrganizer } && card.guests.contains { $0.isMe && $0.title == "Me" })
        #expect(card.join?.title == "Join with Google Meet" && card.location == "Room 4, Example Building")
        #expect(card.notes?.contains("agree on next steps.") == true, "the folded line is joined")
        #expect(f.center.showsCard(message.id))
        #expect(f.center.answerBlock(for: message.id) == nil, "invited, a calendar that answers: answers on")
        f.center.toggleOriginal(message.id)
        #expect(!f.center.showsCard(message.id), "Show original: the sender's HTML")
        f.center.toggleOriginal(message.id)
        #expect(f.center.showsCard(message.id))
        let plain = MessageSummary(id: MessageKey(account: f.account, rowID: 999_999, gmailMessageID: GmailMessageID("x")),
                                   from: nil, to: [], cc: [], bcc: [], date: fixedNow, snippet: "", isUnread: false,
                                   attachments: [])
        #expect(!InviteCenter.mayHaveCard(plain))
        f.center.readFile = { _ in "<html>not a calendar</html>" }
        await f.load(thread, message)
        #expect(f.center.entries[message.id] == .unavailable)
        #expect(!f.center.showsCard(message.id))
    }

    @Test func yesMarksDoneAtOnceHoldsTheAnswerAndOneUndoTakesBothBack() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        let card = try await f.card(thread, message)
        f.addInvitedEvent(card)
        f.center.sleep = holdUntilCancelled
        let readsBeforeAnswer = f.calendar?.lookups.count
        #expect(try await f.inInbox(thread))
        await f.center.respond(.accepted, to: message.id)
        #expect(f.center.card(for: message.id)?.response == .accepted, "the answer shows at once")
        #expect(f.center.heldCount == 1)
        #expect(f.answered().isEmpty, "nothing reaches the calendar inside the window")
        #expect(try await !f.inInbox(thread), "marked done at once, like e")
        #expect(f.env.undo?.nextUndo.map { String(localized: $0.title) } == "Accepted — Done", "one entry for both")
        #expect(f.env.undo?.stack.count == 1)

        let held = f.center.heldTasks
        await f.env.undo?.undoLast()
        for task in held { await task.value }
        #expect(f.center.heldCount == 0 && f.center.card(for: message.id)?.response == nil)
        #expect(try await f.inInbox(thread), "back in the Inbox")
        #expect(f.answered().isEmpty && f.calendar?.lookups.count == readsBeforeAnswer,
                "undone inside the window: no new calendar request")
    }

    @Test func aHeldAnswerIsSentOnQuitAndASecondFlushSendsNothing() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        let card = try await f.card(thread, message)
        f.addInvitedEvent(card)
        f.center.sleep = holdUntilCancelled
        await f.center.respond(.accepted, to: message.id)
        #expect(f.answered().isEmpty && f.center.hasQuitWork)
        let held = f.center.heldTasks
        await f.center.prepareForQuit()
        for task in held { await task.value }
        #expect(f.answered() == [.respond(id: "ev", response: .accepted, sendUpdates: .all)])
        #expect(!f.center.hasQuitWork)
        await f.center.prepareForQuit()
        #expect(f.answered() == [.respond(id: "ev", response: .accepted, sendUpdates: .all)])
    }

    @Test func anUndoneAnswerIsNotSentOnQuit() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        let card = try await f.card(thread, message)
        f.addInvitedEvent(card)
        f.center.sleep = holdUntilCancelled
        await f.center.respond(.accepted, to: message.id)
        let held = f.center.heldTasks
        await f.env.undo?.undoLast()
        for task in held { await task.value }
        await f.center.prepareForQuit()
        #expect(f.answered().isEmpty && !f.center.hasQuitWork)
    }

    @Test func twoHeldAnswersAreBothSentOnQuit() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        let card = try await f.card(thread, message)
        f.addInvitedEvent(card)
        let (homeThread, homeMessage) = try await f.invitation(account: f.corpus.accounts[1].id)
        #expect(homeMessage.id != message.id)
        let homeCard = try await f.card(homeThread, homeMessage)
        f.home.add(CalendarEvent(id: "home-ev", title: homeCard.title, start: homeCard.invite.start,
                                 end: homeCard.invite.end, attendees: [FakeCorpus.personalMe],
                                 organizerIsMe: false, myResponse: .needsAction))
        f.home.setICalUID(homeCard.invite.uid, for: "home-ev")
        f.center.sleep = holdUntilCancelled
        await f.center.respond(.accepted, to: message.id)
        await f.center.respond(.declined, to: homeMessage.id)
        #expect(f.center.heldCount == 2 && f.center.hasQuitWork)
        #expect(f.answered().isEmpty && !f.home.calls.contains { if case .respond = $0 { true } else { false } })
        let held = f.center.heldTasks
        await f.center.prepareForQuit()
        for task in held { await task.value }
        #expect(f.answered() == [.respond(id: "ev", response: .accepted, sendUpdates: .all)])
        let homeAnswers = f.home.calls.filter { if case .respond = $0 { true } else { false } }
        #expect(homeAnswers == [.respond(id: "home-ev", response: .declined, sendUpdates: .all)])
        #expect(!f.center.hasQuitWork)
    }

    @Test func quittingWithNoHeldAnswersDoesNothingAndPostsNoNotice() async {
        let f = InviteFixture()
        #expect(!f.center.hasQuitWork)
        #expect(f.env.notices.toasts.isEmpty)
        await f.center.prepareForQuit()
        #expect(!f.center.hasQuitWork && f.answered().isEmpty)
        #expect(f.env.notices.toasts.isEmpty)
    }

    @Test func afterTheWindowTheEventIsFoundByUIDAndAnsweredWithTheOrganizerTold() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        let card = try await f.card(thread, message)
        f.addInvitedEvent(card)
        let gate = TestGate()
        f.center.sleep = { _ in await gate.wait() }
        await f.center.respond(.declined, to: message.id)
        await f.endWindows(gate)
        #expect(f.answered() == [.respond(id: "ev", response: .declined, sendUpdates: .all)])
        #expect(f.calendar?.lookups == Array(repeating: FakeCalendar.Lookup(iCalUID: card.invite.uid, wholeSeries: false), count: 2))
        #expect(f.calendar?.allEvents.first { $0.id == "ev" }?.myResponse == .declined)
        #expect(try await !f.inInbox(thread))
        await f.env.undo?.undoLast()
        #expect(try await f.inInbox(thread))
        #expect(f.answered().count == 1)
        #expect(f.center.notes[message.id]?.contains("already sent") == true)
    }

    @Test func undoAfterTheWindowSendsThePreviousAnswerBack() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        let first = try await f.card(thread, message)
        f.addInvitedEvent(first, response: .tentative)
        await f.env.calendarEvents.revalidate(CalendarEventStore.key(for: f.calendar!), provider: f.calendar!,
                                               visible: DateInterval(start: first.invite.start, end: first.invite.end),
                                               today: fixedNow, calendar: Calendar(identifier: .gregorian), now: fixedNow,
                                               force: true)
        let card = try await f.card(thread, message)
        #expect(card.response == .tentative)
        let gate = TestGate()
        f.center.sleep = { _ in await gate.wait() }
        await f.center.respond(.accepted, to: message.id)
        await f.endWindows(gate)
        #expect(f.answered() == [.respond(id: "ev", response: .accepted, sendUpdates: .all)])
        await f.env.undo?.undoLast()
        #expect(f.calendar?.calls.contains(.respond(id: "ev", response: .tentative, sendUpdates: .all)) == true,
                "the previous answer goes back (the organizer is told again)")
        #expect(f.center.card(for: message.id)?.response == .tentative)
        #expect(try await f.inInbox(thread))
    }

    @Test func withoutACalendarTheCardAsksToConnectAndNothingIsDone() async throws {
        let f = InviteFixture(events: nil)
        let (thread, message) = try await f.invitation()
        let card = try await f.card(thread, message)
        #expect(card.offersRSVP, "the buttons show")
        #expect(f.center.answerBlock(for: message.id) == nil, "on: a click offers to connect a calendar")
        await f.center.respond(.accepted, to: message.id)
        #expect(f.center.connectPrompt == message.id)
        #expect(f.center.card(for: message.id)?.response == nil && f.center.heldCount == 0)
        #expect(try await f.inInbox(thread), "not marked done")
        #expect(f.env.undo?.stack.isEmpty == true)
        f.center.dismissConnectPrompt()
        #expect(f.center.connectPrompt == nil)
    }

    @Test func aCalendarThatCannotCreateAndANotInvitedCardShowWhyUpFront() async throws {
        let refusal = "Mail can't create events with this calendar connection."
        let f = InviteFixture(calendarRefusal: refusal)
        let (thread, message) = try await f.invitation()
        let card = try await f.card(thread, message)
        f.addInvitedEvent(card)
        #expect(f.center.answerBlock(for: message.id) == refusal)
        await f.center.respond(.accepted, to: message.id)
        #expect(f.center.heldCount == 0 && !f.lookedUp())
        #expect(try await f.inInbox(thread))

        let open = InviteFixture()
        let (otherThread, otherMessage) = try await open.invitation()
        let text = try await open.original(otherMessage)
        let mine = open.corpus.accounts[0].email
        open.center.readFile = { _ in text.replacingOccurrences(of: "mailto:\(mine)", with: "mailto:lee@example.org") }
        let notMine = try await open.card(otherThread, otherMessage)
        #expect(!notMine.isInvited && notMine.offersRSVP)
        #expect(open.center.answerBlock(for: otherMessage.id)?.contains("guest list") == true)
        await open.center.respond(.accepted, to: otherMessage.id)
        #expect(open.center.heldCount == 0 && !open.lookedUp())
    }

    @Test func aFailedAnswerSaysWhyAndShowsThePreviousAnswer() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        _ = try await f.card(thread, message)
        let gate = TestGate()
        f.center.sleep = { _ in await gate.wait() }
        await f.center.respond(.accepted, to: message.id)
        await f.endWindows(gate)
        #expect(f.env.notices.toasts.contains { $0.message.hasPrefix("Couldn't answer") })
        #expect(f.center.card(for: message.id)?.response == nil)
        #expect(f.answered().isEmpty)
    }

    @Test func anAnswerForOneEventOfASeriesNeverLandsOnTheWholeSeries() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        let text = try await f.original(message)
        f.center.readFile = { _ in text.replacingOccurrences(of: "SEQUENCE:0", with: "SEQUENCE:0\r\nRRULE:FREQ=WEEKLY") }
        let card = try await f.card(thread, message)
        #expect(card.invite.repeats)
        f.addInvitedEvent(card, id: "series1")
        let gate = TestGate()
        f.center.sleep = { _ in await gate.wait() }
        await f.center.respond(.accepted, to: message.id)
        await f.endWindows(gate)
        #expect(f.answered().isEmpty, "the whole series was never answered for one event")
        #expect(f.env.notices.toasts.contains { $0.message.contains("this one event of the series") })
        #expect(f.center.card(for: message.id)?.response == nil)
    }

    @Test func withoutTheUIDTheTitleAndStartFindItAndTwoLookAlikesRefuse() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        let card = try await f.card(thread, message)
        f.addInvitedEvent(card, id: "copy", withUID: false)
        f.addInvitedEvent(card, id: "elsewhere", start: card.invite.start.addingTimeInterval(3_600), withUID: false)
        let gate = TestGate()
        f.center.sleep = { _ in await gate.wait() }
        await f.center.respond(.accepted, to: message.id)
        await f.endWindows(gate)
        #expect(f.answered() == [.respond(id: "copy", response: .accepted, sendUpdates: .all)])

        let twice = InviteFixture()
        let (otherThread, otherMessage) = try await twice.invitation()
        let same = try await twice.card(otherThread, otherMessage)
        twice.addInvitedEvent(same, id: "copy1", withUID: false)
        twice.addInvitedEvent(same, id: "copy2", withUID: false)
        let gate2 = TestGate()
        twice.center.sleep = { _ in await gate2.wait() }
        await twice.center.respond(.accepted, to: otherMessage.id)
        await twice.endWindows(gate2)
        #expect(twice.answered().isEmpty, "never a guess between two events")
        #expect(twice.env.notices.toasts.contains { $0.message.contains("more than one event") })
    }

    @Test func aMovedOccurrenceIsAnsweredAtItsNewTime() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        let text = try await f.original(message)
        f.center.readFile = { _ in
            text.replacingOccurrences(of: "DTSTART:20261013T100000Z",
                                      with: "RECURRENCE-ID:20261013T100000Z\r\nDTSTART:20261013T110000Z")
                .replacingOccurrences(of: "DTEND:20261013T103000Z", with: "DTEND:20261013T113000Z")
        }
        let card = try await f.card(thread, message)
        #expect(card.invite.recurrenceID != nil && card.invite.start != card.invite.occurrence)
        f.addInvitedEvent(card, id: "series1_moved", start: card.invite.start, series: "series1")
        f.addInvitedEvent(card, id: "series1_next", start: card.invite.occurrence.addingTimeInterval(7 * 86_400),
                          series: "series1")
        let gate = TestGate()
        f.center.sleep = { _ in await gate.wait() }
        await f.center.respond(.tentative, to: message.id)
        await f.endWindows(gate)
        #expect(f.answered() == [.respond(id: "series1_moved", response: .tentative, sendUpdates: .all)])
    }

    @Test func cancellationsRepliesAndSeries() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        let base = try await f.card(thread, message)
        let original = try await f.original(message)
        f.center.readFile = { _ in original.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:CANCEL") }
        let cancelled = try await f.card(thread, message)
        #expect(cancelled.kind == .cancelled && !cancelled.offersRSVP)
        #expect(f.center.answerBlock(for: message.id) == nil, "no answers, so no reason either")
        await f.center.respond(.accepted, to: message.id)
        #expect(f.center.heldCount == 0 && f.env.undo?.stack.isEmpty == true, "a cancellation offers no answer")

        f.center.readFile = { _ in original.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:REPLY") }
        let reply = try await f.card(thread, message)
        #expect(reply.kind == .reply && reply.compactLine?.hasSuffix("accepted") == true)

        f.center.readFile = { _ in original.replacingOccurrences(of: "SEQUENCE:0", with: "SEQUENCE:0\r\nRRULE:FREQ=WEEKLY") }
        let series = try await f.card(thread, message)
        #expect(series.repeats == "Repeats weekly" && series.offersRSVP)
        f.addInvitedEvent(base)
        let gate = TestGate()
        f.center.sleep = { _ in await gate.wait() }
        await f.center.respond(.accepted, to: message.id, wholeSeries: true)
        #expect(f.env.undo?.nextUndo.map { String(localized: $0.title) } == "Accepted all events — Done")
        await f.endWindows(gate)
        #expect(f.calendar?.lookups == [FakeCalendar.Lookup(iCalUID: base.invite.uid, wholeSeries: false),
                                        FakeCalendar.Lookup(iCalUID: base.invite.uid, wholeSeries: false),
                                        FakeCalendar.Lookup(iCalUID: base.invite.uid, wholeSeries: true)])
        #expect(f.answered() == [.respond(id: "ev", response: .accepted, sendUpdates: .all)])
    }

    @Test func theKeysAnswerTheOpenInvitationAndAreRefusedWithoutOne() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        _ = try await f.card(thread, message)
        let other = MessageKey(account: f.account, rowID: 999_998, gmailMessageID: GmailMessageID("other"))
        #expect(f.center.target(focused: nil, in: thread, shown: [other]) == nil, "no card: the keys are hidden")
        #expect(f.center.target(focused: other, in: thread, shown: [message.id, other]) == message.id)
        #expect(f.center.target(focused: message.id, in: thread, shown: [message.id]) == message.id)
        f.center.toggleOriginal(message.id)
        #expect(f.center.target(focused: message.id, in: thread, shown: [message.id]) == nil,
                "Show original: the keys do not answer an invitation that is not on screen")
        f.center.toggleOriginal(message.id)
        #expect(InviteActionHandler.ids == [.inviteYes, .inviteMaybe, .inviteNo, .inviteShowOriginal])
        for id in [ActionID.inviteYes, .inviteMaybe, .inviteNo] {
            let descriptor = try #require(ActionCatalog.descriptor(id))
            #expect(descriptor.scopes == [.reader] && descriptor.effect == .external && descriptor.defaultBindings.count == 1)
        }
    }

    @Test func anEventMovedAfterTheInvitationIsFoundByItsUIDAndAnswered() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        let card = try await f.card(thread, message)
        let later = 2 * 86_400.0
        f.calendar?.add(CalendarEvent(id: "ev", title: "Moved and renamed", start: card.invite.start.addingTimeInterval(later),
                                      end: card.invite.end.addingTimeInterval(later), attendees: [FakeCorpus.me],
                                      organizerIsMe: false, myResponse: .needsAction))
        f.calendar?.setICalUID(card.invite.uid, for: "ev")
        let gate = TestGate()
        f.center.sleep = { _ in await gate.wait() }
        await f.center.respond(.accepted, to: message.id)
        await f.endWindows(gate)
        #expect(f.answered() == [.respond(id: "ev", response: .accepted, sendUpdates: .all)],
                "two days later and under a new title, its UID still names it")
        #expect(f.env.notices.toasts.contains { $0.message.hasPrefix("Answered Yes") })
    }

    @Test func anEventFoundNowhereSaysWhereMailLookedAndOffersCalendar() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        _ = try await f.card(thread, message)
        let gate = TestGate()
        f.center.sleep = { _ in await gate.wait() }
        await f.center.respond(.accepted, to: message.id)
        await f.endWindows(gate)
        let toast = try #require(f.env.notices.toasts.first { $0.message.hasPrefix("Couldn't answer") })
        #expect(toast.message.contains("couldn't find it on the calendar of \(f.corpus.accounts[0].email)"))
        #expect(toast.message.contains("it may have moved") && !toast.message.contains("yet"))
        #expect(toast.actionTitle == "Open in Calendar")
        #expect(f.answered().isEmpty && f.center.card(for: message.id)?.response == nil)
    }

    @Test func aMissingInboxCopyNeverAnswersFromAnotherConnectedCalendar() async throws {
        let homeAddress = FakeCorpus.personalMe.email
        for withUID in [true, false] {
            let f = InviteFixture()
            let (thread, message) = try await f.invitation()
            let text = try await f.original(message)
            f.center.readFile = { _ in
                text.replacingOccurrences(of: "ATTENDEE;CN=Sam Lee",
                                          with: "ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:\(homeAddress)\r\nATTENDEE;CN=Sam Lee")
            }
            let card = try await f.card(thread, message)
            #expect(card.isInvited && card.invite.attendees.contains { $0.email == homeAddress })
            f.home.add(CalendarEvent(id: "home-ev", title: card.title, start: card.invite.start, end: card.invite.end,
                                     attendees: [FakeCorpus.personalMe], organizerIsMe: false, myResponse: .needsAction))
            if withUID { f.home.setICalUID(card.invite.uid, for: "home-ev") }
            let gate = TestGate()
            f.center.sleep = { _ in await gate.wait() }
            await f.center.respond(.accepted, to: message.id)
            await f.endWindows(gate)
            #expect(f.answered().isEmpty, "nothing on the inbox's own calendar")
            let answeredHome = f.home.calls.contains(.respond(id: "home-ev", response: .accepted, sendUpdates: .all))
            #expect(!answeredHome, "the other account is never answered from this inbox")
            #expect(f.env.notices.toasts.contains {
                $0.message.contains("couldn't find it on the calendar of \(f.corpus.accounts[0].email)")
            })
        }
    }

    @Test func anAnswerToTheWholeSeriesShowsOnTheStoredOccurrencesAtOnce() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        let text = try await f.original(message)
        f.center.readFile = { _ in text.replacingOccurrences(of: "SEQUENCE:0", with: "SEQUENCE:0\r\nRRULE:FREQ=WEEKLY") }
        let card = try await f.card(thread, message)
        let calendar = try #require(f.calendar)
        let length = card.invite.end.timeIntervalSince(card.invite.start)
        var master = CalendarEvent(id: "s", title: card.title, start: card.invite.start, end: card.invite.end,
                                   attendees: [FakeCorpus.me], organizerIsMe: false, myResponse: .needsAction)
        master.extras.recurrence = ["RRULE:FREQ=WEEKLY"]
        calendar.add(master)
        for week in 0..<2 {
            let start = card.invite.start.addingTimeInterval(Double(week) * 7 * 86_400)
            calendar.add(CalendarEvent(id: "s_\(week)", title: card.title, start: start, end: start.addingTimeInterval(length),
                                       attendees: [FakeCorpus.me], organizerIsMe: false, myResponse: .needsAction,
                                       recurringEventID: "s"))
        }
        calendar.setICalUID(card.invite.uid, for: "s_0")
        let key = CalendarEventStore.key(for: calendar)
        let span = DateInterval(start: card.invite.start, end: card.invite.start.addingTimeInterval(8 * 86_400))
        await f.env.calendarEvents.revalidate(key, provider: calendar, visible: span, today: fixedNow,
                                               calendar: Calendar(identifier: .gregorian), now: fixedNow, force: true)
        let gate = TestGate()
        f.center.sleep = { _ in await gate.wait() }
        await f.center.respond(.accepted, to: message.id, wholeSeries: true)
        await f.endWindows(gate)
        #expect(f.answered() == [.respond(id: "s", response: .accepted, sendUpdates: .all)])
        let occurrences = (f.env.calendarEvents.events(key, from: span.start, to: span.end, includeDeclined: true) ?? [])
            .filter { $0.recurringEventID == "s" }
        #expect(occurrences.map(\.id) == ["s_0", "s_1"])
        #expect(occurrences.allSatisfy { $0.myResponse == .accepted }, "shown before the next sync")
    }

    @Test func anInvitationSentToAnAliasIsAnsweredAsThatAddress() async throws {
        let f = InviteFixture()
        let (thread, message) = try await f.invitation()
        let text = try await f.original(message)
        let alias = "robin@team.example"
        let mine = f.corpus.accounts[0].email
        f.center.readFile = { _ in text.replacingOccurrences(of: "RSVP=TRUE:mailto:\(mine)", with: "RSVP=TRUE:mailto:\(alias)") }
        let card = try await f.card(thread, message)
        #expect(card.isInvited, "the alias is one of the account's send-as addresses")
        var event = CalendarEvent(id: "ev", title: card.title, start: card.invite.start, end: card.invite.end,
                                  attendees: [EmailAddress(name: nil, email: alias)])
        event.extras.guests = [CalendarGuest(email: alias, response: .needsAction)]
        f.calendar?.add(event)
        f.calendar?.setICalUID(card.invite.uid, for: "ev")
        let gate = TestGate()
        f.center.sleep = { _ in await gate.wait() }
        await f.center.respond(.tentative, to: message.id)
        await f.endWindows(gate)
        #expect(f.answered() == [.respond(id: "ev", response: .tentative, sendUpdates: .all)])
        let stored = f.calendar?.allEvents.first { $0.id == "ev" }
        #expect(stored?.myResponse == nil && stored?.extras.guests.first?.response == .tentative, "on the alias's own entry")
        let key = CalendarEventStore.key(for: try #require(f.calendar))
        let shown = f.env.calendarEvents.events(key, from: card.invite.start, to: card.invite.end, includeDeclined: true)?
            .first { $0.id == "ev" }
        #expect(shown?.myResponse == .tentative && shown?.respondsAs == alias)
    }
}
