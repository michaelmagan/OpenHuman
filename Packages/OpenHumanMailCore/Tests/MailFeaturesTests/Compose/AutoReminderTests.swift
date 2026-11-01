import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct AutoReminderTests {
    private let mine: Set<String> = ["me@work.example", "alias@work.example"]

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    @Test func offByDefaultWithTheFixedDefaults() {
        let rule = SentMailReminderRule()
        #expect(!rule.enabled && rule.days == 3 && rule.hour == 9 && rule.weekdaysOnly)
        #expect(rule.dueDate(sentAt: fixedNow, recipients: ["someone@else.example"], myAddresses: mine) == nil)
        #expect(SentMailReminderRule(days: 0, hour: 30).days == 1 && SentMailReminderRule(days: 0, hour: 30).hour == 23)
        #expect(SentMailReminderRule(days: 40, hour: -1).days == 14 && SentMailReminderRule(days: 40, hour: -1).hour == 0)
    }

    @Test func onlyRecipientsOutsideTheAuthorsDomainCount() {
        #expect(SentMailReminderRule.hasExternalRecipient(["someone@else.example"], myAddresses: mine))
        #expect(SentMailReminderRule.hasExternalRecipient(["colleague@work.example", "Someone@Else.example"], myAddresses: mine))
        #expect(!SentMailReminderRule.hasExternalRecipient(["colleague@work.example", "ME@work.example"], myAddresses: mine))
        #expect(!SentMailReminderRule.hasExternalRecipient([], myAddresses: mine))
        let personal: Set<String> = ["me@gmail.com"]
        #expect(SentMailReminderRule.hasExternalRecipient(["friend@gmail.com"], myAddresses: personal))
        #expect(!SentMailReminderRule.hasExternalRecipient(["me@gmail.com"], myAddresses: personal))
    }

    @Test func threeWeekdaysLaterAtNine() throws {
        let friday = try #require(utc.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 15)))
        let rule = SentMailReminderRule(enabled: true)
        let due = rule.dueDate(sentAt: friday, recipients: ["someone@else.example"], myAddresses: mine, calendar: utc)
        #expect(due == utc.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9)), "Wednesday")
        var everyDay = rule
        everyDay.weekdaysOnly = false
        #expect(everyDay.dueDate(after: friday, calendar: utc) == utc.date(from: DateComponents(year: 2026, month: 10, day: 12,
                                                                                                hour: 9)), "Monday")
        #expect(rule.dueDate(sentAt: friday, recipients: ["colleague@work.example"], myAddresses: mine, calendar: utc) == nil)
    }

    private func reminder(_ f: ComposeFixture, _ thread: ThreadKey) async -> ReminderItem? {
        do {
            for try await items in f.store.reminders(ComposeFixture.work) { return items.first { $0.thread == thread } }
        } catch {}
        return nil
    }

    private func sendReply(_ f: ComposeFixture, to address: String) async throws -> (ThreadKey, ReminderItem?) {
        await f.loaded()
        let thread = try #require(f.router.list?.cursor)
        let before = await reminder(f, thread)
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        session.to.text = "\(address),"
        session.updateBody(doc("Thanks"))
        #expect(await f.run(.send, in: session))
        #expect(await reminder(f, thread) == before, "nothing while the send can still be undone")
        f.heldGate.release()
        await soon { f.compose.outgoing.first?.state == .sending }
        f.store.completeHeldSends()
        return (thread, before)
    }

    @Test func withTheSettingOnAReplyOutsideGetsAnIfNoReplyReminder() async throws {
        let f = ComposeFixture()
        try await f.store.set(AppSettings.autoRemindExternal, true)
        let (thread, before) = try await sendReply(f, to: "someone@else.example")
        await f.posted("Sent.", "Reminder set for")
        let stored = try #require(await reminder(f, thread))
        #expect(stored.kind == .ifNoReply)
        #expect(stored.dueAt > fixedNow && stored != before)
    }

    @Test func offByDefaultNothingIsSet() async throws {
        let f = ComposeFixture()
        let (thread, before) = try await sendReply(f, to: "someone@else.example")
        await f.posted("Sent.")
        await f.compose.settle()
        #expect(await reminder(f, thread) == before)
        #expect(!f.postedToasts.contains { $0.hasPrefix("Reminder set for") })
    }

    private func relaunch(_ f: ComposeFixture) async -> AppEnvironment {
        let env = AppEnvironment(data: f.store, commands: f.store, accounts: f.store, settings: f.store, isFake: true)
        env.router.start()
        await eventually(timeout: .seconds(15)) { env.router.active != nil }
        env.compose.restoreOpenDrafts()
        return env
    }

    private func pendingReminders(_ f: ComposeFixture) async -> [PendingSendReminder] {
        (try? await f.store.get(ComposeSettings.pendingSendReminders)) ?? []
    }

    private func sendThenQuit(_ f: ComposeFixture, to address: String,
                              remindMe: Date? = nil, quit: Bool = true) async throws -> (ThreadKey, ReminderItem?, SendToken) {
        await f.loaded()
        let thread = try #require(f.router.list?.cursor)
        let before = await reminder(f, thread)
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        session.to.text = "\(address),"
        session.updateBody(doc("Thanks"))
        if let remindMe { session.pendingReminder = ComposeSession.PendingReminder(dueAt: remindMe, kind: .always) }
        #expect(await f.run(.send, in: session))
        let token = try #require(f.compose.held.values.first?.token)
        if quit {
            await f.compose.prepareForQuit()
        } else {
            f.compose.held.removeAll()
        }
        f.heldGate.release()
        await f.compose.settle()
        return (thread, before, token)
    }

    @Test func aRemindMeChosenInTheComposerSurvivesARelaunchBeforeTheSend() async throws {
        let f = ComposeFixture()
        let due = Date().addingTimeInterval(5 * 86_400)
        let (thread, before, _) = try await sendThenQuit(f, to: "someone@else.example", remindMe: due)
        #expect(await reminder(f, thread) == before, "the quitting process sets nothing")
        let kept = await pendingReminders(f)
        #expect(kept.count == 1 && kept[0].thread == thread && kept[0].dueAt == due && kept[0].kind == .always)

        let env2 = await relaunch(f)
        f.store.completeHeldSends()
        await eventuallyAsync { await reminder(f, thread)?.kind == .always }
        await eventuallyAsync { await pendingReminders(f).isEmpty }
        await env2.compose.settle()
        let set = try #require(await reminder(f, thread))
        #expect(abs(set.dueAt.timeIntervalSince(due)) < 1, "\(set.dueAt) vs \(due)")
    }

    @Test func theAutoReminderSurvivesARelaunchBeforeTheSend() async throws {
        let f = ComposeFixture()
        try await f.store.set(AppSettings.autoRemindExternal, true)
        let (thread, before, _) = try await sendThenQuit(f, to: "someone@else.example")
        #expect(await reminder(f, thread) == before)
        #expect(await pendingReminders(f).map(\.kind) == [.ifNoReply])

        let env2 = await relaunch(f)
        f.store.completeHeldSends()
        await eventuallyAsync { let now = await reminder(f, thread); return now?.kind == .ifNoReply && now != before }
        await eventuallyAsync { await pendingReminders(f).isEmpty }
        await env2.compose.settle()
    }

    @Test func aSendTheEngineGivesBackAsADraftSetsNoReminder() async throws {
        let f = ComposeFixture()
        try await f.store.set(AppSettings.autoRemindExternal, true)
        let (thread, before, token) = try await sendThenQuit(f, to: "someone@else.example", quit: false)
        #expect(await pendingReminders(f).count == 1)
        let env2 = await relaunch(f)
        #expect(try await f.store.cancelSend(token))
        await eventuallyAsync { await pendingReminders(f).isEmpty }
        await env2.compose.settle()
        #expect(await reminder(f, thread) == before)
    }

    @Test func withNoReminderNothingIsKept() async throws {
        let f = ComposeFixture()
        _ = try await sendThenQuit(f, to: "someone@else.example")
        #expect(await pendingReminders(f).isEmpty)
    }

    @Test func aSendIsReportedStartedOnlyOnceItsReminderIntentIsStored() async throws {
        let f = ComposeFixture(settings: { HeldSettingWrites($0, holding: ComposeSettings.pendingSendReminders.name) })
        let writes = try #require(f.env.settings as? HeldSettingWrites)
        try await f.store.set(AppSettings.autoRemindExternal, true)
        await f.loaded()
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        session.to.text = "someone@else.example,"
        session.updateBody(doc("Thanks"))
        let sending = Task { await f.run(.send, in: session) }
        await writes.checkpoint.arrived()
        await eventually { f.env.undo?.stack.contains { String(localized: $0.title) == "Reply sent." } == true }
        #expect(f.compose.sendsStarting.contains(session.id), "the send waits for its intent while the write is held")
        #expect(await pendingReminders(f).isEmpty)

        writes.checkpoint.release()
        #expect(await sending.value)
        #expect(await pendingReminders(f).map(\.kind) == [.ifNoReply], "stored before the send reports it started")
        #expect(!f.compose.sendsStarting.contains(session.id))
        f.compose.held.removeAll()
        f.heldGate.release()
        await f.compose.settle()
    }
}
