import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized)
struct SystemModulesTests {
    @Test func everyFlagOffRemovesItsPartAndTheAppStillLaunches() async throws {
        let flags = FeatureFlags([.notifications: false, .dockBadge: false, .launchAtLogin: false, .unsubscribe: false,
                                  .diagnostics: false])
        let f = SystemFixture(flags: flags)
        f.env.runLaunchTasks()
        try await Task.sleep(for: .milliseconds(100))
        let system = f.env.system
        #expect(system.notifications == nil && system.dockBadge == nil && system.launchAtLogin == nil)
        #expect(system.unsubscribe == nil && system.diagnostics == nil && system.reminderMirror == nil)
        #expect(!f.env.modules.settingsPages.contains { ["notifications", "general.dockBadge", "general.loginItem"].contains($0.id) })
        #expect(f.notifier.scheduleLog.isEmpty && f.dock.history.isEmpty && f.login.registerCalls == 0)
    }

    @Test func everyFlagOnRegistersThePagesAndStartsEachPartOnce() async throws {
        let f = SystemFixture()
        f.env.runLaunchTasks()
        f.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { f.env.system.diagnostics != nil && f.env.system.unsubscribe != nil }
        let system = f.env.system
        #expect(system.notifications != nil && system.dockBadge != nil && system.launchAtLogin != nil)
        #expect(system.reminderMirror != nil, "the mirror runs with the reminders module")
        let ids = f.env.modules.settingsPages.map(\.id)
        #expect(ids.contains("notifications") && ids.contains("general.dockBadge") && ids.contains("general.loginItem"))
        #expect(f.env.overlays.fallback === system.unsubscribe)
    }

    @Test func theMirrorNeedsBothTheNotificationsAndRemindersModules() async throws {
        let off = SystemFixture(flags: FeatureFlags().with(.reminders, false))
        off.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { off.env.system.notifications != nil }
        #expect(off.env.system.reminderMirror == nil)
    }

    @Test func nothingSystemRelatedStartsUntilLaunchTasksRun() {
        let f = SystemFixture()
        #expect(f.env.system.notifications == nil && f.env.system.dockBadge == nil)
        #expect(f.notifier.authorizationRequests == 0)
    }

    @Test func theInertPlatformIsTheDefaultSoTestsNeverTouchTheRealOS() async throws {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow), featureFlags: FeatureFlags())
        env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { env.system.notifications != nil }
        #expect(env.system.platform.notifier is FakeSystemNotifier)
        #expect(env.system.platform.dock is FakeDockBadge)
        #expect(env.system.platform.loginItem is FakeLoginItem)
        #expect(env.system.platform.urlOpener is FakeURLOpener)
    }

    @Test func installingThePlatformAfterTheSystemStartedIsIgnored() async throws {
        let f = SystemFixture()
        f.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { f.env.system.notifications != nil }
        let late = FakeSystemNotifier()
        f.env.installPlatform(SystemPlatform(notifier: late, dock: FakeDockBadge(), loginItem: FakeLoginItem(),
                                             urlOpener: FakeURLOpener(), isAppActive: { false }))
        #expect((f.env.system.platform.notifier as? FakeSystemNotifier) === f.notifier)
    }
}

@MainActor
@Suite(.serialized)
struct NotificationResponseTests {
    private func ready(options: FakeMailStore.Options = .init(remoteAck: .immediate)) async -> SystemFixture {
        let f = SystemFixture(options: options)
        f.env.router.start()
        f.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { f.env.system.notifications != nil && f.env.router.active?.list?.state == .loaded }
        return f
    }

    @Test func clickingANotificationOpensItsThread() async throws {
        let f = await ready()
        let row = try await f.firstThread()
        f.notifier.respond(NotificationResponse(identifier: "x", action: .open, userInfo: NotificationRouting.userInfo(for: row.id)))
        await eventually(timeout: .seconds(15)) { f.env.router.active?.mode == .reader }
    }

    @Test func clickingAReviewNotificationOpensTheReviewQueue() async throws {
        let f = await ready()
        f.notifier.respond(NotificationResponse(identifier: "x", action: .open, userInfo: NotificationRouting.reviewRoute))
        await eventually(timeout: .seconds(15)) { f.env.router.location == .reviewQueue(nil) }
    }

    @Test func markDoneFromANotificationIsTheNormalUndoableAction() async throws {
        let f = await ready()
        let row = try await f.firstThread()
        f.notifier.respond(NotificationResponse(identifier: "n1", action: .markDone, userInfo: NotificationRouting.userInfo(for: row.id)))
        await eventually(timeout: .seconds(15)) { f.env.undo?.nextUndo != nil }
        // The undo entry is posted optimistically, before its command finishes.
        let action = try #require(f.env.actions.lastTask)
        await action.value
        let rows = try #require(await first(f.store.threadWindow(.system(.inbox), account: f.account, limit: 200))).rows
        #expect(!rows.contains { $0.id == row.id })
        #expect(f.env.notices.toasts.contains { $0.actionTitle == "Undo" || $0.style == .undo })
    }

    @Test func markReadFromANotificationMarksTheThreadRead() async throws {
        let f = await ready()
        let rows = try #require(await first(f.store.threadWindow(.system(.inbox), account: f.account, limit: 200))).rows
        let unread = try #require(rows.first { $0.isUnread })
        f.notifier.respond(NotificationResponse(identifier: "n2", action: .markRead, userInfo: NotificationRouting.userInfo(for: unread.id)))
        await eventually(timeout: .seconds(15)) {
            f.env.undo?.nextUndo != nil
        }
        let action = try #require(f.env.actions.lastTask)
        await action.value
        let after = try #require(await first(f.store.threadWindow(.system(.inbox), account: f.account, limit: 200))).rows
        #expect(after.first { $0.id == unread.id }?.isUnread == false)
    }

    @Test func snoozeFromANotificationUsesTheLaterTodayPresetAndCanBeUndone() async throws {
        let f = await ready()
        let row = try await f.firstThread()
        f.notifier.respond(NotificationResponse(identifier: "n4", action: .snooze, userInfo: NotificationRouting.userInfo(for: row.id)))
        await eventually(timeout: .seconds(15)) { f.env.undo?.nextUndo != nil }
        let action = try #require(f.env.actions.threadActions?.lastTask)
        await action.value
        let inbox = try #require(await first(f.store.threadWindow(.system(.inbox), account: f.account, limit: 200))).rows
        #expect(!inbox.contains { $0.id == row.id })
        let snoozed = try #require(await first(f.store.threadWindow(.system(.snoozed), account: f.account, limit: 200))).rows
        let until = try #require(snoozed.first { $0.id == row.id }?.snoozedUntil)
        #expect(until > Date(), "later today, or the next preset when the day is nearly over")
        #expect(f.env.notices.toasts.contains { $0.style == .undo || $0.actionTitle == "Undo" })
    }

    @Test func remindIfNoReplySetsAnIfNoReplyReminder() async throws {
        let f = await ready()
        let row = try await f.firstThread()
        f.notifier.respond(NotificationResponse(identifier: "n5", action: .remindIfNoReply, userInfo: NotificationRouting.userInfo(for: row.id)))
        await eventually(timeout: .seconds(15)) { f.env.undo?.nextUndo != nil }
        let action = try #require(f.env.actions.threadActions?.lastTask)
        await action.value
        let reminders = try #require(await first(f.store.reminders(nil)))
        let reminder = try #require(reminders.first { $0.thread == row.id })
        #expect(reminder.kind == .ifNoReply)
        #expect(reminder.dueAt > Date())
    }

    @Test func buttonsDoNotBringMailToTheFrontButAClickDoes() async throws {
        let f = await ready()
        let row = try await f.firstThread()
        f.notifier.respond(NotificationResponse(identifier: "n6", action: .markDone, userInfo: NotificationRouting.userInfo(for: row.id)))
        await eventually(timeout: .seconds(15)) { f.env.undo?.nextUndo != nil }
        let action = try #require(f.env.actions.lastTask)
        await action.value
        #expect(f.active.activations == 0)
        f.notifier.respond(NotificationResponse(identifier: "n7", action: .open, userInfo: NotificationRouting.userInfo(for: row.id)))
        #expect(f.active.activations == 1)
    }

    @Test func theSnoozeAndRemindTimesComeFromTheWP09Presets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let morning = Date(timeIntervalSince1970: 1_791_000_000)
        let snooze = NotificationService.snoozeTime(now: morning, calendar: calendar)
        let remind = NotificationService.remindTime(now: morning, calendar: calendar)
        #expect(snooze.map { $0 > morning } == true)
        #expect(remind.map { $0 > morning } == true)
        let presets = TimePresets(timeZone: calendar.timeZone)
        #expect(snooze == presets.presets(for: .snooze, now: morning).first?.date)
        #expect(remind == presets.presets(for: .remind, now: morning).first?.date)
    }
}

@MainActor
@Suite(.serialized)
struct NotificationsSettingsModelTests {
    @Test func switchesPersistAndTurningOneOnAsksPermission() async throws {
        let f = SystemFixture(authorization: .notDetermined)
        f.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { f.env.system.notifications != nil }
        let model = NotificationsSettingsModel(environment: f.env)
        model.start()
        await eventually(timeout: .seconds(15)) { !model.accounts.isEmpty }
        #expect(model.accounts.allSatisfy { $0.isOn }, "on by default")
        await model.setNewMail(false, for: f.account)
        #expect(!f.env.system.preferences.newMailEnabled(f.account))
        #expect(f.notifier.authorizationRequests == 0, "turning one off asks nothing")
        await model.setNewMail(true, for: f.account)
        #expect(f.notifier.authorizationRequests == 1)
        await model.setReminders(false)
        await eventually(timeout: .seconds(15)) { !model.remindersOn }
        #expect(try await f.store.get(AppSettings.schedulerReminders) == false)
        model.setShowPreviews(false)
        #expect(f.env.system.preferences.hidePreviews)
    }

    @Test func theTestNotificationUsesTheSamePathAndWarnsWhenOff() async throws {
        let f = SystemFixture(authorization: .denied)
        let model = NotificationsSettingsModel(environment: f.env)
        await model.refreshAuthorization()
        #expect(model.showsPermissionWarning)
        await model.sendTest()
        #expect(f.notifier.delivered.isEmpty && !model.testSent)
        let ok = SystemFixture(authorization: .authorized)
        let okModel = NotificationsSettingsModel(environment: ok.env)
        await okModel.sendTest()
        #expect(ok.notifier.delivered.first?.title == "Test notification" && okModel.testSent)
    }

    @Test func preferencesPersistInTheirDefaultsSuite() {
        let defaults = ScopedDefaults("openhuman.test.system")
        defer { defaults.cleanup() }
        let a = SystemPreferences(defaults: defaults)
        a.hidePreviews = true
        a.dockBadge = .inbox
        a.setNewMailEnabled(false, for: AccountID(3))
        let b = SystemPreferences(defaults: defaults)
        #expect(b.hidePreviews && b.dockBadge == .inbox && !b.newMailEnabled(AccountID(3)) && b.newMailEnabled(AccountID(4)))
        #expect(b.snoozeReturned && b.agentDrafts)
    }
}
