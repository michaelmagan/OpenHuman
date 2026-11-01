import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailFeatures

private let yes = #"{"needsFollowUp":true,"reason":"Asked for the budget numbers","suggestedDays":null}"#
private let no = #"{"needsFollowUp":false,"reason":"Only says thanks","suggestedDays":null}"#

@MainActor
@Suite(.serialized) struct AIAutoReminderTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func fixture(_ provider: any AIProvider, scope: SentMailReminderRule.Scope = .needsFollowUp) async throws
        -> ComposeFixture {
        let center = AICenter.make(registry: ProviderRegistry(providers: [provider]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore(AISettings())))
        let f = ComposeFixture(ai: center)
        try await f.store.set(AppSettings.autoRemindExternal, scope != .off)
        try await f.store.set(AppSettings.autoRemindAIDetected, scope == .needsFollowUp)
        f.env.followUps.now = { fixedNow }
        f.env.followUps.calendar = utc
        await f.loaded()
        return f
    }

    @discardableResult
    private func send(_ f: ComposeFixture, to: [String], _ text: String) async throws -> ThreadKey {
        let sentBefore = f.store.sentMessages.count
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = to.joined(separator: ", ") + ","
        session.subject = "Budget"
        session.updateBody(doc(text))
        #expect(await f.run(.send, in: session))
        f.heldGate.release()
        await eventually { f.store.heldSendCount > 0 }
        f.store.completeHeldSends()
        await eventually { f.store.sentMessages.count > sentBefore }
        await eventually { f.postedToasts.filter { $0 == "Sent." }.count > sentBefore }
        await f.compose.settle()
        return try #require(f.store.sentMessages.last).thread
    }

    private func reminder(_ f: ComposeFixture, _ thread: ThreadKey) async -> ReminderItem? {
        do {
            for try await items in f.store.reminders(ComposeFixture.work) { return items.first { $0.thread == thread } }
        } catch {}
        return nil
    }

    private func myAddress(_ f: ComposeFixture) throws -> String {
        try #require(f.router.accounts.first { $0.id == ComposeFixture.work }?.account.email)
    }

    @Test func aMessageThatAsksSomethingGetsAnIfNoReplyReminderWithItsReason() async throws {
        let provider = ScriptedProvider(responses: [.text(yes)])
        let f = try await fixture(provider)
        let thread = try await send(f, to: ["someone@else.example"], "Could you send the budget numbers?")
        await f.posted("Sent.", "Reminder set for")
        let stored = try #require(await reminder(f, thread))
        #expect(stored.kind == .ifNoReply)
        let rule = SentMailReminderRule(enabled: true, aiDetected: true)
        #expect(stored.dueAt == rule.dueDate(after: fixedNow, calendar: utc), "3 weekdays later at 9:00")
        #expect(provider.requests.count == 1)
        let request = try #require(provider.requests.first)
        #expect(request.task == .followUp && request.untrusted.last?.text == "Could you send the budget numbers?")
        #expect(RequestInspector.problems(in: request).isEmpty)
        #expect(f.recorder.calls.filter { $0 == "send" }.count == 1, "nothing is sent but the message itself")
        let row = try #require(try await f.store.threadPage(.system(.reminders), account: ComposeFixture.work, after: nil,
                                                            limit: 500).rows.first { $0.id == thread })
        #expect(f.env.followUps.reason(for: row) == "Asked for the budget numbers")
    }

    @Test func aDateInTheMessageBringsTheReminderSooner() async throws {
        let soon = #"{"needsFollowUp":true,"reason":"Needs an answer by Monday","suggestedDays":1}"#
        let f = try await fixture(ScriptedProvider(responses: [.text(soon)]))
        let thread = try await send(f, to: ["someone@else.example"], "Can you confirm by Monday?")
        await f.posted("Sent.", "Reminder set for")
        let stored = try #require(await reminder(f, thread))
        let rule = SentMailReminderRule(enabled: true, aiDetected: true)
        #expect(stored.dueAt == rule.dueDate(after: fixedNow, days: 1, calendar: utc))
    }

    @Test func thanksAndFYIsGetNoReminder() async throws {
        let provider = ScriptedProvider(responses: [.text(no), .text(no)])
        let f = try await fixture(provider)
        let thanks = try await send(f, to: ["someone@else.example"], "Thanks, got it!")
        let fyi = try await send(f, to: ["someone@else.example"], "FYI: the office is closed on Monday.")
        #expect(provider.requests.count == 2)
        let onThanks = await reminder(f, thanks)
        let onFYI = await reminder(f, fyi)
        #expect(onThanks == nil && onFYI == nil)
        #expect(!f.postedToasts.contains { $0.hasPrefix("Reminder set for") })
    }

    @Test func noReplyAndOwnAddressesAreNeverAskedAbout() async throws {
        let provider = ScriptedProvider(responses: [.text(yes), .text(yes)])
        let f = try await fixture(provider)
        let toService = try await send(f, to: ["noreply@service.example", "do-not-reply@billing.example"], "Is this right?")
        let toMe = try await send(f, to: [try myAddress(f)], "Did I pack the charger?")
        #expect(provider.requests.isEmpty)
        let onService = await reminder(f, toService)
        let onMe = await reminder(f, toMe)
        #expect(onService == nil && onMe == nil)
    }

    @Test func aMalformedAnswerIsNo() async throws {
        let provider = ScriptedProvider(responses: [.text("yes please"), .text(#"{"needsFollowUp":"maybe"}"#)])
        let f = try await fixture(provider)
        let thread = try await send(f, to: ["someone@else.example"], "Could you send the budget numbers?")
        #expect(provider.requests.count == 2, "one repair attempt")
        #expect(await reminder(f, thread) == nil)
        #expect(!f.postedToasts.contains { $0.hasPrefix("Reminder set for") })
    }

    @Test func anUnavailableModelSetsNothingAndNeverFallsBack() async throws {
        let off = ScriptedProvider(availability: .unavailable(reason: .appleIntelligenceNotEnabled)) { _, _ in .text(yes) }
        let f = try await fixture(off)
        let thread = try await send(f, to: ["someone@else.example"], "Could you send the budget numbers?")
        #expect(off.requests.isEmpty)
        #expect(await reminder(f, thread) == nil, "no fallback to the external-recipient rule either")
        let status = await f.env.followUps.availability()
        #expect(!status.available && status.reason == "Turn on Apple Intelligence in System Settings")
    }

    @Test func aModelOffTheMacIsNeverUsed() async throws {
        let remote = ScriptedProvider(id: .agentClaude, capabilities: .remote(), responses: [.text(yes)])
        let center = AICenter.make(registry: ProviderRegistry(providers: [remote]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore(
                                       AISettings(consents: [.agentClaude: ProviderConsent(grantedAt: fixedNow, fingerprint: nil)]))))
        let f = ComposeFixture(ai: center)
        try await f.store.set(AppSettings.autoRemindExternal, true)
        try await f.store.set(AppSettings.autoRemindAIDetected, true)
        await f.loaded()
        let thread = try await send(f, to: ["someone@else.example"], "Could you send the budget numbers?")
        #expect(remote.requests.isEmpty)
        #expect(await reminder(f, thread) == nil)
        let status = await f.env.followUps.availability()
        #expect(!status.available)
    }

    @Test func aSlowModelTimesOutAsNo() async throws {
        let provider = ScriptedProvider(responses: [.hang])
        let f = try await fixture(provider)
        f.env.followUps.timeout = .milliseconds(100)
        let thread = try await send(f, to: ["someone@else.example"], "Could you send the budget numbers?")
        #expect(await reminder(f, thread) == nil)
        #expect(!f.postedToasts.contains { $0.hasPrefix("Reminder set for") })
    }

    @Test func aReplyCancelsTheReminder() async throws {
        let f = try await fixture(ScriptedProvider(responses: [.text(yes)]))
        let thread = try await send(f, to: ["someone@else.example"], "Could you send the budget numbers?")
        await f.posted("Sent.", "Reminder set for")
        let stored = try #require(await reminder(f, thread))
        f.store.deliverMessage(account: ComposeFixture.work, to: thread,
                               from: EmailAddress(name: "Some One", email: "someone@else.example"), unread: false,
                               at: fixedNow.addingTimeInterval(3_600))
        let report = f.store.runSchedulers(now: stored.dueAt.addingTimeInterval(60))
        #expect(report.satisfiedReminders.contains(stored.id))
        #expect(!report.firedReminders.contains(stored.id))
        #expect(await reminder(f, thread) == nil)
    }

    @Test func undoTakesTheReminderBack() async throws {
        let f = try await fixture(ScriptedProvider(responses: [.text(yes)]))
        let thread = try await send(f, to: ["someone@else.example"], "Could you send the budget numbers?")
        await f.posted("Sent.", "Reminder set for")
        #expect(await reminder(f, thread) != nil)
        #expect(await f.run(.undo))
        var gone = false
        for _ in 0..<12_000 where !gone {
            gone = await reminder(f, thread) == nil
            if !gone { try? await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(gone, "one ⌘Z takes the reminder away")
    }

    @Test func theExternalScopeStillWorksWithoutAnyModel() async throws {
        let provider = ScriptedProvider(responses: [.text(no)])
        let f = try await fixture(provider, scope: .externalRecipients)
        let thread = try await send(f, to: ["someone@else.example"], "Thanks!")
        await f.posted("Sent.", "Reminder set for")
        #expect(await reminder(f, thread) != nil)
        #expect(provider.requests.isEmpty, "the model is asked only in the AI scope")
    }

    @Test func theCatchUpRunsOnlyWhenAskedAndNeverTwiceForOneMessage() async throws {
        let provider = ScriptedProvider()
        let f = try await fixture(provider, scope: .off)
        let asks = try await send(f, to: ["someone@else.example"], "Are you free on Tuesday?")
        let thanks = try await send(f, to: ["someone@else.example"], "Thanks, all good.")
        #expect(provider.requests.isEmpty, "nothing runs on its own")
        await #expect(throws: FollowUpReminders.CatchUpError.scopeOff) { try await f.env.followUps.catchUp() }

        try await f.store.set(AppSettings.autoRemindExternal, true)
        try await f.store.set(AppSettings.autoRemindAIDetected, true)
        let first = try await f.env.followUps.catchUp()
        #expect(first.checked >= 2 && first.remindersSet >= 1)
        #expect(await reminder(f, asks) != nil)
        #expect(await reminder(f, thanks) == nil)
        let asked = provider.requests.count

        _ = try await f.store.apply(.cancelReminder(asks))
        let second = try await f.env.followUps.catchUp()
        #expect(second.checked == 0 && second.remindersSet == 0)
        #expect(provider.requests.count == asked)
    }

    @Test func theCatchUpLeavesAMessageSentInABatchWithRemindersOffAlone() async throws {
        let provider = ScriptedProvider { _, _ in .text(yes) }
        let f = try await fixture(provider, scope: .off)
        let alone = try await send(f, to: ["someone@else.example"], "Could you send the budget numbers?")
        let content = DraftFields(to: [EmailAddress(name: nil, email: "someone@else.example")], subject: "Notes",
                                  bodyHTML: "<p>Could you look over the notes?</p>", bodyText: "Could you look over the notes?")
        let (key, _) = try await f.store.createDraft(DraftInput(account: ComposeFixture.work, mode: .new, content: content))
        let draft = try #require(await f.draftRow(key))
        #expect(await f.compose.sendBatch([draft], reminders: nil).queued == [key])
        f.store.completeHeldSends()
        await f.compose.settle()
        await f.posted("Sent 1 draft.")
        let batched = try #require(f.store.sentMessages.last { $0.draft == key }).thread

        try await f.store.set(AppSettings.autoRemindExternal, true)
        try await f.store.set(AppSettings.autoRemindAIDetected, true)
        let result = try await f.env.followUps.catchUp()
        #expect(result.remindersSet >= 1)
        #expect(await reminder(f, alone) != nil, "a message sent on its own is still checked")
        #expect(await reminder(f, batched) == nil, "the batch went with reminders off, and that choice holds")
    }

    @Test func scopesNoReplyAddressesAndTheSuggestedWait() throws {
        #expect(SentMailReminderRule().scope == .off)
        #expect(SentMailReminderRule(enabled: true).scope == .externalRecipients)
        #expect(SentMailReminderRule(enabled: true, aiDetected: true).scope == .needsFollowUp)
        #expect(SentMailReminderRule(enabled: false, aiDetected: true).scope == .off)
        for address in ["noreply@a.example", "no-reply@a.example", "No_Reply@a.example", "donotreply@a.example",
                        "do-not-reply@a.example", "accounts-noreply@a.example", "mailer-daemon@a.example"] {
            #expect(SentMailReminderRule.isNoReply(address), "\(address)")
        }
        #expect(!SentMailReminderRule.isNoReply("nora@a.example") && !SentMailReminderRule.isNoReply("reply@a.example"))
        let mine: Set<String> = ["me@work.example"]
        #expect(!SentMailReminderRule.mayNeedFollowUp(["me@work.example", "noreply@a.example"], myAddresses: mine))
        #expect(!SentMailReminderRule.mayNeedFollowUp([], myAddresses: mine))
        #expect(SentMailReminderRule.mayNeedFollowUp(["colleague@work.example"], myAddresses: mine), "colleagues count too")
        let rule = SentMailReminderRule(enabled: true, days: 5, aiDetected: true)
        #expect(rule.followUpDays(suggested: nil) == 5 && rule.followUpDays(suggested: 2) == 2)
        #expect(rule.followUpDays(suggested: 9) == 5, "never later than the wait the user chose")
        #expect(rule.nextSlot(after: fixedNow, calendar: utc)
                == utc.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9)))
        var anyDay = rule
        anyDay.weekdaysOnly = false
        #expect(anyDay.nextSlot(after: fixedNow, calendar: utc)
                == utc.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9)))
    }

    @Test func settingsOfferTheAIScopeOnlyWithTheModelReady() async throws {
        let ready = try await fixture(ScriptedProvider(), scope: .off)
        let model = InboxAutomationSettingsModel(environment: ready.env)
        model.start()
        await model.refreshFollowUpModel()
        await eventually { model.autoRemind.value == false }
        #expect(model.followUpModelReady == true && model.scopeChoices == SentMailReminderRule.Scope.allCases)
        await model.setScope(.needsFollowUp)
        let enabled = try await ready.store.get(AppSettings.autoRemindExternal)
        let detected = try await ready.store.get(AppSettings.autoRemindAIDetected)
        #expect(enabled && detected)
        await eventually { model.scope == .needsFollowUp }
        #expect(model.scopeNote.contains("on this Mac") && model.scopeStatus == nil)
        await model.setScope(.externalRecipients)
        let detectedAfter = try await ready.store.get(AppSettings.autoRemindAIDetected)
        #expect(!detectedAfter)
        await model.setScope(.off)
        let enabledAfter = try await ready.store.get(AppSettings.autoRemindExternal)
        #expect(!enabledAfter)

        let off = ScriptedProvider(availability: .unavailable(reason: .appleIntelligenceNotEnabled)) { _, _ in .text(yes) }
        let notReady = try await fixture(off, scope: .off)
        let other = InboxAutomationSettingsModel(environment: notReady.env)
        other.start()
        await other.refreshFollowUpModel()
        #expect(other.followUpModelReady == false)
        #expect(other.scopeChoices == [.off, .externalRecipients])
        #expect(other.scopeStatus?.contains("Turn on Apple Intelligence in System Settings") == true)
        await other.setScope(.needsFollowUp)
        let refused = try await notReady.store.get(AppSettings.autoRemindAIDetected)
        #expect(!refused, "refused while the model is not ready")
    }
}
