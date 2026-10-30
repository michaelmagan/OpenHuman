import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private let utc = TimeZone(identifier: "UTC")!
private let day = Date(timeIntervalSince1970: 1_791_000_000)

private func event(_ id: String, hours: Double) -> CalendarEvent {
    CalendarEvent(id: id, title: "Event \(id)", start: day.addingTimeInterval(hours * 3_600),
                  end: day.addingTimeInterval(hours * 3_600 + 1_800))
}

private final class ScriptedCalendar: CalendarProviding, Sendable {
    let info = CalendarProviderInfo(name: "Google Calendar", account: "robin@example.com")
    private let answers: Mutex<[CalendarEventWindow]>
    private let asked = Mutex(0)
    let checkpoint: Checkpoint?

    init(_ answers: [CalendarEventWindow], checkpoint: Checkpoint? = nil) {
        self.answers = Mutex(answers)
        self.checkpoint = checkpoint
    }

    var reads: Int { asked.withLock { $0 } }

    func events(from: Date, to: Date) async throws -> [CalendarEvent] { [] }
    func freeBusy(from: Date, to: Date) async throws -> CalendarFreeBusy { CalendarFreeBusy(busy: []) }
    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEvent { throw CalendarError.notConfigured }

    func eventWindow(from: Date, to: Date) async throws -> CalendarEventWindow {
        asked.withLock { $0 += 1 }
        let answer = answers.withLock { $0.isEmpty ? CalendarEventWindow(records: []) : $0.removeFirst() }
        await checkpoint?.pass()
        return answer
    }
}

@MainActor
@Suite struct CalendarEventStoreRaceTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    @Test func aReadThatFinishesAfterTheCalendarIsDisconnectedIsThrownAway() async throws {
        let checkpoint = Checkpoint()
        let provider = ScriptedCalendar([CalendarEventWindow(records: [CalendarEventRecord(event: event("secret", hours: 2))])],
                                        checkpoint: checkpoint)
        let cache = InMemoryCalendarCache()
        let store = CalendarEventStore(persistence: cache, timeZone: utc)
        let key = CalendarEventStore.key(for: provider)
        let reading = Task {
            await store.ensure(key, provider: provider, from: day, to: day.addingTimeInterval(86_400), today: day,
                               calendar: calendar, now: day)
        }
        await checkpoint.arrived()
        store.forget(account: "robin@example.com")
        checkpoint.release()
        await reading.value
        await store.flush()
        #expect(store.record(key, id: "secret") == nil && store.events(key, from: day, to: day.addingTimeInterval(86_400)) == nil)
        #expect(await cache.load().allSatisfy { $0.records.isEmpty }, "nothing is written back to disk")
    }

    @Test func aTruncatedReadKeepsTheEventsItDidNotReach() async throws {
        let first = CalendarEventWindow(records: [CalendarEventRecord(event: event("a", hours: 1)),
                                                 CalendarEventRecord(event: event("b", hours: 5))])
        let truncated = CalendarEventWindow(records: [CalendarEventRecord(event: event("a", hours: 1))], isComplete: false)
        let provider = ScriptedCalendar([first, truncated])
        let store = CalendarEventStore(persistence: InMemoryCalendarCache(), timeZone: utc)
        let key = CalendarEventStore.key(for: provider)
        let visible = DateInterval(start: day, end: day.addingTimeInterval(86_400))
        await store.ensure(key, provider: provider, from: visible.start, to: visible.end, today: day, calendar: calendar,
                           now: day)
        #expect(store.record(key, id: "b") != nil)
        await store.revalidate(key, provider: provider, visible: visible, today: day, calendar: calendar,
                               now: day.addingTimeInterval(600), force: true)
        #expect(provider.reads == 2)
        #expect(store.record(key, id: "b") != nil, "an incomplete answer is not proof that the event is gone")
    }
}
