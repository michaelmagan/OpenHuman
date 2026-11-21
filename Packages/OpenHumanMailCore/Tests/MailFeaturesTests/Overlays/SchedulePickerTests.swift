import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.timeLimit(.minutes(2))) struct SchedulePickerTests {
    @Test func hOpensTheSnoozePickerOnTheCursorAndAChoiceSnoozesWithUndo() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        let key = try #require(f.router.list?.cursor)
        #expect(await f.run(.snooze))
        let picker = try #require(f.timePicker)
        #expect(picker.kind == .snooze && picker.targets == [key])
        #expect(picker.title == "Snooze until…" && picker.footer == "Comes back to your inbox. Syncs to your other Mac.")
        picker.chooseNumber(2)
        #expect(f.center.overlay.isNone, "a choice closes the card")
        await f.settled()
        #expect(f.hasToast("Snoozed until "))
        #expect(!f.rows.contains { $0.id == key })
        #expect(try await Self.snooze(of: key, f) != nil)
        #expect(await f.run(.undo))
        #expect(try await Self.snooze(of: key, f) == nil)
        await untilObserved { f.rows.contains { $0.id == key } }
    }

    @Test func snoozingASnoozedThreadShowsItsCurrentTimeFromTheCacheAndReschedules() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        let key = try #require(f.router.list?.cursor)
        let first = Date(timeIntervalSince1970: 1_791_000_000 + 2 * 86_400)
        f.store.simulateOtherInstallSnooze(key, until: first)
        f.center.present(.snoozePicker(targets: [key]))
        let picker = try #require(f.timePicker)
        await untilObserved { picker.currentLine != nil }
        #expect(picker.current == .snoozedUntil(ScheduleStamp.floorToMinute(first)))
        picker.chooseNumber(4)
        await f.settled()
        #expect(f.hasToast("Snoozed until "))
        let rescheduled = try await Self.snooze(of: key, f)?.wakeAt
        #expect(rescheduled != nil && rescheduled != ScheduleStamp.floorToMinute(first))
        #expect(await f.run(.undo))
        #expect(try await Self.snooze(of: key, f)?.wakeAt == ScheduleStamp.floorToMinute(first))
    }

    @Test func aMalformedSnoozeOffersWakeNowAndSnoozeAgain() async throws {
        let corpus = FakeCorpus.rich(threadCount: 120, now: fixedNow)
        let unknown = corpus.mailboxes[0].threads[10].row.id
        let f = OverlayFixture(corpus: corpus)
        await f.loaded()
        f.center.present(.snoozePicker(targets: [unknown]))
        let picker = try #require(f.timePicker)
        await untilObserved { picker.isWakeTimeUnknown }
        #expect(picker.currentLine == "Wake time unknown")
        #expect(picker.rows.map(\.title) == ["Wake now", "Snooze again…"])
        picker.confirm()
        #expect(f.center.overlay.isNone)
        await f.settled()
        #expect(f.hasToast("Moved to Inbox"))
        #expect(try await Self.snooze(of: unknown, f) == nil)
        f.center.present(.snoozePicker(targets: [unknown]))
        let again = try #require(f.timePicker)
        again.apply(snooze: .wakeTimeUnknown, reminder: nil)
        again.moveCursor(by: 1)
        again.confirm()
        #expect(again.rows.contains { $0.title == "Tomorrow morning" } && !again.isWakeTimeUnknown)
    }

    @Test func anExistingReminderOfTheCorpusIsShownByThePicker() async throws {
        let corpus = FakeCorpus.rich(threadCount: 120, now: fixedNow)
        let withReminder = corpus.mailboxes[0].threads[11].row.id
        let f = OverlayFixture(corpus: corpus)
        await f.loaded()
        f.center.present(.remindPicker(thread: withReminder))
        let picker = try #require(f.timePicker)
        await untilObserved { picker.currentLine != nil }
        #expect(picker.currentLine?.hasPrefix("Current: ") == true)
        #expect(picker.rows.last?.title == "Clear reminder")
    }

    @Test func shiftHRemindsWithTheCheckboxAndShowsAndReplacesAnExistingReminder() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        let key = try #require(f.router.list?.cursor)
        #expect(await f.run(.remind))
        var picker = try #require(f.timePicker)
        #expect(picker.kind == .remind && picker.footer == "Reminders stay on this Mac.")
        #expect(picker.rows.map(\.title) == ["Later today", "Tomorrow morning", "In 2 days", "Next week", "Pick a date…", "Someday"])
        picker.onlyIfNoReply = true
        picker.chooseNumber(2)
        await f.settled()
        #expect(f.hasToast("Reminder set for "))
        #expect(f.env.notices.toasts.contains { $0.message.hasSuffix("if no reply") })
        let placed = try await Self.reminders(f)
        #expect(placed.map(\.thread) == [key] && placed.first?.kind == .ifNoReply)
        await untilObserved { f.rows.first { $0.id == key }?.reminderAt != nil }
        let first = try #require(f.rows.first { $0.id == key }?.reminderAt)

        #expect(await f.run(.remind))
        picker = try #require(f.timePicker)
        await untilObserved { picker.currentLine?.hasPrefix("Current: ") == true }
        #expect(picker.currentLine?.hasSuffix("(if no reply)") == true)
        #expect(picker.rows.last?.title == "Clear reminder")
        picker.chooseNumber(3)
        await f.settled()
        let reminders = try await Self.reminders(f)
        #expect(reminders.count == 1, "replaced, not added")
        #expect(reminders.first?.dueAt != placed.first?.dueAt)
        await untilObserved { f.rows.first { $0.id == key }?.reminderAt.map { $0 != first } == true }

        #expect(await f.run(.remind))
        picker = try #require(f.timePicker)
        await untilObserved { picker.rows.last?.title == "Clear reminder" }
        picker.choose(picker.rows.last!)
        await f.settled()
        #expect(f.hasToast("Reminder cleared"))
        #expect(try await Self.reminders(f).isEmpty)
        await untilObserved { f.rows.first { $0.id == key }?.reminderAt == nil }
        #expect(await f.run(.undo))
        #expect(try await Self.reminders(f).map(\.thread) == [key])
        await untilObserved { f.rows.first { $0.id == key }?.reminderAt != nil }
    }

    @Test func theRemindersLocationListsSoonestFirst() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        let keys = f.rows.prefix(3).map(\.id)
        let later = fixedNow.addingTimeInterval(5 * 86_400)
        let sooner = fixedNow.addingTimeInterval(1 * 86_400)
        let middle = fixedNow.addingTimeInterval(3 * 86_400)
        for (key, date) in zip(keys, [later, sooner, middle]) {
            await f.registry.threadActions?.remind(key, at: date, kind: .always, host: f.router)?.value
        }
        f.router.go(to: .system(.reminders))
        await untilObserved { f.router.list?.rows.count == 3 }
        #expect(f.rows.map(\.id) == [keys[1], keys[2], keys[0]])
        #expect(f.rows.compactMap(\.reminderAt) == [sooner, middle, later])
    }

    @Test func withTheSnoozeFlagOffThereIsNoKeyPaletteEntryOrLocation() async throws {
        let f = OverlayFixture(flags: FeatureFlags().with(.snooze, false))
        await f.loaded(10)
        #expect(f.registry.availability(.snooze, host: f.router) == .hidden)
        #expect(await f.run(.snooze) == false, "the key passes on")
        #expect(f.center.overlay.isNone)
        #expect(!f.env.modules.locations.contains { $0.location == .system(.snoozed) })
        #expect(!f.registry.descriptors.contains { $0.id == .snooze })
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        palette.query = "snooze"
        // Searching mail for the typed word is still offered
        let offered = palette.entries.filter { $0.kind != .searchMail("snooze") }
        #expect(!offered.contains { $0.title.lowercased().contains("snooze") }, "no snooze entry: \(palette.entries.map(\.title))")
        #expect(f.registry.availability(.remind, host: f.router) == .enabled)
    }

    @Test func withTheRemindersFlagOffThereIsNoKeyPaletteEntryOrLocation() async throws {
        let f = OverlayFixture(flags: FeatureFlags().with(.reminders, false))
        await f.loaded(10)
        #expect(await f.run(.remind) == false)
        #expect(await f.run(.clearReminder) == false)
        #expect(f.center.overlay.isNone)
        #expect(!f.env.modules.locations.contains { $0.location == .system(.reminders) })
        #expect(!f.registry.descriptors.contains { $0.id == .remind || $0.id == .clearReminder })
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        palette.query = "remind"
        #expect(palette.isEmptyResult, "no remind entry, only the mail-search fallback: \(palette.entries.map(\.title))")
        let sheet = ShortcutHelpModel(descriptors: f.registry.descriptors)
        #expect(!sheet.allLines.contains { $0.action == .remind }, "its key is gone from the shortcut sheet")
        #expect(f.registry.availability(.snooze, host: f.router) == .enabled)
    }

    @Test func theSendLaterCardIsAvailableToTheComposer() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        var scheduled: Date?
        f.center.presentSendLater { scheduled = $0 }
        let picker = try #require(f.timePicker)
        #expect(picker.kind == .sendLater && picker.title == "Send later…")
        picker.chooseNumber(1)
        #expect(scheduled == fixedNow.addingTimeInterval(3_600))
    }

    static func snooze(of key: ThreadKey, _ f: OverlayFixture) async throws -> SnoozeState? {
        for try await detail in f.env.data.threadDetail(key) { return detail?.snooze }
        return nil
    }

    static func reminders(_ f: OverlayFixture) async throws -> [ReminderItem] {
        for try await items in f.env.data.reminders(nil) { return items }
        return []
    }
}

extension OverlayCenter.Overlay {
    var isNone: Bool {
        if case .none = self { true } else { false }
    }
}
