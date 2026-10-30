import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let pacific = TimeZone(identifier: "America/Los_Angeles")!

private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    CalendarDateMentions.calendar(pacific).date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

@MainActor
@Suite(.serialized) struct SchedulingAccountTests {
    @Test func eachConversationIsCheckedAgainstItsOwnAccountsCalendar() async throws {
        let corpus = FakeCorpus.rich(threadCount: 12, now: fixedNow)
        let accounts = corpus.accounts
        try #require(accounts.count >= 2 && corpus.mailboxes[1].threads.count > 0)
        let busyAtOne = CalendarEvent(id: "work-focus", title: "Work focus", start: at(13, 13), end: at(13, 14),
                                      organizerIsMe: true)
        let work = FakeCalendar(events: [busyAtOne], info: CalendarProviderInfo(name: "Google Calendar", account: accounts[0].email))
        let home = FakeCalendar(events: [], info: CalendarProviderInfo(name: "Google Calendar", account: accounts[1].email))
        let connections = FakeCalendarConnections(providers: [accounts[0].email: work, accounts[1].email: home])
        let env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), featureFlags: FeatureFlags(),
                                      calendar: work, calendarConnections: connections)
        let assistant = try #require(env.scheduling)
        assistant.timeZone = pacific
        assistant.now = { at(12, 9) }
        assistant.language = nil
        let homeThread = corpus.mailboxes[1].threads[0].row.id
        let message = try #require(corpus.mailboxes[1].threads[0].detail.messages.last?.id)
        assistant.loadMessage = { _ in
            SchedulingMessage(key: message, subject: "Re: Lunch", senderName: "Dana Ruiz <dana@example.org>",
                              sentAt: at(12, 9), text: "How about 1pm tomorrow?", isFromMe: false)
        }

        await assistant.analyze(homeThread)
        let analysis = try #require(assistant.analyses[homeThread])
        #expect(analysis.calendarRead && analysis.conflicts.isEmpty, "the work meeting is not on this account's calendar")
        #expect(home.readCalls > 0 && work.readCalls == 0)
        #expect(assistant.calendar(for: homeThread) as AnyObject === home, "holds and moves go to the same calendar")

        let workThread = corpus.mailboxes[0].threads[0].row.id
        await assistant.analyze(workThread)
        #expect(assistant.analyses[workThread]?.conflicts.map(\.id) == ["work-focus"])
        #expect(assistant.calendar(for: workThread) as AnyObject === work)
    }
}
