import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

private func la(_ m: Int, _ d: Int, _ h: Int = 0) -> Date {
    CalendarDateMentions.calendar(losAngeles).date(from: DateComponents(year: 2026, month: m, day: d, hour: h))!
}

private let sam = EmailAddress(name: "Sam Rivera", email: "sam@example.org")

private let untilCancelled: @Sendable (Duration) async throws -> Void = { _ in
    let (stream, continuation) = AsyncStream.makeStream(of: Never.self)
    for await _ in stream {}
    continuation.finish()
    throw CancellationError()
}

@MainActor
private struct QuitFixture {
    let env: AppEnvironment
    let calendar: FakeCalendar
    let thread: ThreadKey

    init(events: [CalendarEvent] = []) {
        let corpus = FakeCorpus.make(threadCount: 6, now: fixedNow)
        calendar = FakeCalendar(events: events, abilities: [.respond, .editDetails, .remove])
        env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), featureFlags: FeatureFlags(),
                                  calendar: calendar)
        thread = corpus.threads[0].row.id
    }

    func sidebar() -> CalendarSidebarModel {
        let model = env.calendarSidebar!
        model.timeZone = losAngeles
        model.now = { la(10, 12, 11) }
        model.loadText = { _ in
            CalendarThreadText(subject: "Lunch?", texts: ["Lunch?", "October 15, 2026 at 12:30 PM"], participants: [sam])
        }
        model.sleep = untilCancelled
        return model
    }

    func window() -> CalendarWindowModel {
        _ = sidebar()
        let model = env.calendarWindow!
        model.timeZone = losAngeles
        model.now = { la(10, 12, 11) }
        model.confirmsMovesOverride = false
        model.sleep = untilCancelled
        return model
    }
}

@MainActor
@Suite struct CalendarQuitTests {
    @Test func quittingInsideTheUndoWindowCreatesTheHeldEventOnce() async throws {
        let f = QuitFixture()
        let model = f.sidebar()
        await model.beginDraft(for: f.thread)
        model.draft?.sendUpdates = .all
        #expect(await model.createEvent())
        #expect(model.heldCreateCount == 1 && model.hasQuitWork && f.calendar.createCalls == 0)
        await model.prepareForQuit()
        #expect(f.calendar.createCalls == 1 && model.heldCreateCount == 0 && !model.hasQuitWork)
        await model.prepareForQuit()
        #expect(f.calendar.createCalls == 1, "a second flush finds nothing")
    }

    @Test func quittingAfterUndoCreatesNothing() async throws {
        let f = QuitFixture()
        let model = f.sidebar()
        await model.beginDraft(for: f.thread)
        model.draft?.sendUpdates = .all
        #expect(await model.createEvent())
        await f.env.undo?.undoLast()
        #expect(model.heldCreateCount == 0 && !model.hasQuitWork)
        await model.prepareForQuit()
        #expect(f.calendar.createCalls == 0 && f.calendar.created.isEmpty)
    }

    @Test func quittingInsideTheWindowSendsAHeldMoveAndNeverAnUndoneOne() async throws {
        let meeting = CalendarEvent(id: "meet", title: "Planning", start: la(10, 13, 9), end: la(10, 13, 10),
                                    attendees: [sam], organizerIsMe: true)
        let f = QuitFixture(events: [meeting])
        let model = f.window()
        await model.open()
        let shown = try #require(model.events.first)
        await model.moveEvent(shown, to: la(10, 13, 15), end: la(10, 13, 16))
        #expect(model.heldCount == 1 && model.hasQuitWork && f.calendar.moveCalls == 0)
        await f.env.undo?.undoLast()
        #expect(model.heldCount == 0 && !model.hasQuitWork)
        await model.prepareForQuit()
        #expect(f.calendar.moveCalls == 0, "an undone move is never sent")

        await model.moveEvent(shown, to: la(10, 13, 14), end: la(10, 13, 15))
        #expect(model.heldCount == 1)
        await model.prepareForQuit()
        #expect(f.calendar.moveCalls == 1 && model.heldCount == 0)
        #expect(f.calendar.calls.contains(.move(id: "meet", start: la(10, 13, 14), end: la(10, 13, 15), sendUpdates: .all)))
    }
}

private final class CheckpointCalendar: CalendarProviding, Sendable {
    let inner: FakeCalendar
    let checkpoint: Checkpoint

    init(_ inner: FakeCalendar, checkpoint: Checkpoint) {
        self.inner = inner
        self.checkpoint = checkpoint
    }

    var info: CalendarProviderInfo { inner.info }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] { try await inner.events(from: from, to: to) }
    func freeBusy(from: Date, to: Date) async throws -> CalendarFreeBusy { try await inner.freeBusy(from: from, to: to) }
    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEvent {
        await checkpoint.pass()
        return try await inner.createEvent(draft)
    }
    func deleteEvent(_ event: CalendarEvent) async throws { try await inner.deleteEvent(event) }
}

@MainActor
@Suite struct CalendarSidebarCreateRaceTests {
    @Test func switchingConversationsDuringACreateKeepsTheOtherDraft() async throws {
        let corpus = FakeCorpus.make(threadCount: 6, now: fixedNow)
        let inner = FakeCalendar()
        let checkpoint = Checkpoint()
        let env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), featureFlags: FeatureFlags(),
                                      calendar: CheckpointCalendar(inner, checkpoint: checkpoint))
        let model = env.calendarSidebar!
        model.timeZone = losAngeles
        model.now = { la(10, 12, 11) }
        model.loadText = { _ in
            CalendarThreadText(subject: "Lunch?", texts: ["Lunch?", "October 15, 2026 at 12:30 PM"], participants: [])
        }
        let a = corpus.threads[0].row.id, b = corpus.threads[1].row.id
        await model.show(thread: b)
        await model.beginDraft(for: b)
        model.draft?.title = "Plan for B"
        await model.show(thread: a)
        await model.beginDraft(for: a)
        #expect(model.draft != nil && model.draft?.title != "Plan for B")

        let creating = Task { await model.createEvent() }
        await checkpoint.arrived()
        await model.show(thread: b)
        #expect(model.draft?.title == "Plan for B")
        checkpoint.release()
        #expect(await creating.value)
        #expect(inner.createCalls == 1)
        #expect(model.draft?.title == "Plan for B", "the draft on screen is not the one that was created")
        #expect(env.pendingEvents.pending(for: .thread(b)) != nil)
        #expect(env.pendingEvents.pending(for: .thread(a)) == nil, "the created draft is not offered again")
    }
}
