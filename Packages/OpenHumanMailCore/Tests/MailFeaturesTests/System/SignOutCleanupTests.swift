import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized)
struct SignOutCleanupTests {
    private let sender = EmailAddress(name: "Ada Sender", email: "ada@sender.example")

    @Test func theIndexerDropsAnAccountsDomainAtOnceAndForgetsItsLedger() async throws {
        let f = SystemFixture(corpus: .rich(threadCount: 30, now: fixedNow))
        let defaults = ScopedDefaults("openhuman.test.signout")
        defer { defaults.cleanup() }
        let indexer = SpotlightIndexer(data: f.store, settings: f.store, index: f.spotlight, defaults: defaults)
        indexer.debounce = .zero
        indexer.start()
        let accounts = try #require(await first(f.store.accounts()))
        await eventually(timeout: .seconds(15)) { Set(f.spotlight.items.values.map(\.domain)).count == 2 }
        let gone = try #require(accounts.last).id
        await eventually(timeout: .seconds(15)) { defaults.stringArray(forKey: SpotlightIndexer.ledgerKey(gone)) != nil }
        await indexer.removeAccount(gone)
        #expect(!f.spotlight.items.values.contains { $0.domain == SpotlightIdentifier.domain(gone) })
        #expect(f.spotlight.items.values.contains { $0.domain == SpotlightIdentifier.domain(accounts[0].id) })
        #expect(defaults.stringArray(forKey: SpotlightIndexer.ledgerKey(gone)) == nil)
        indexer.stop()
    }

    @Test func theSystemCenterTakesTheAccountsNotificationsAndReminderCopiesOff() async throws {
        let f = SystemFixture(authorization: .authorized)
        let account = f.account
        f.env.system.startNotifications()
        let service = try #require(f.env.system.notifications)
        await eventually(timeout: .seconds(15)) { service.hasBaseline(for: account) }
        f.env.system.preferences.setNewMailEnabled(true, for: account)
        f.store.deliverMessage(account: account, from: sender, subject: "MARKER signout", important: true)
        await f.delivered(count: 1)
        let thread = try await f.firstThread().id
        _ = try await f.store.apply(.setReminder(thread, dueAt: Date().addingTimeInterval(3600), kind: .always))
        await eventually(timeout: .seconds(15)) { f.notifier.pending.contains { $0.identifier.hasPrefix("reminder.") } }
        await f.notifier.schedule(SystemNotification(identifier: "reauth.\(account.rawValue)", title: "Sign in to Mail again"))
        await f.notifier.schedule(SystemNotification(identifier: "unrelated", title: "Stays"))
        f.env.system.preferences.setNewMailEnabled(false, for: account)

        await f.env.system.removeAccount(account)

        let left = f.notifier.delivered.map(\.identifier) + f.notifier.pending.map(\.identifier)
        #expect(left == ["unrelated"], "only what is not about the account stays: \(left)")
        #expect(f.spotlight.calls.contains("deleteDomains"), "a leftover index is cleared even with Spotlight off")
        #expect(f.env.system.preferences.newMailEnabled(account), "the account's own switch is forgotten")
    }

    @Test func stopAllLetsGoOfTheMenuBarItemTheShortcutAndTheNotificationResponder() async throws {
        let f = SystemFixture(authorization: .authorized)
        f.env.system.startNotifications()
        f.env.system.setMenuBar(enabled: true)
        f.env.system.setGlobalHotkey(enabled: true)
        #expect(f.menuBar.isShown && f.hotkeys.registered != nil)
        f.env.system.stopAll()
        #expect(!f.menuBar.isShown)
        #expect(f.hotkeys.registered == nil)
        #expect(f.env.system.notifications == nil && f.env.system.menuBar == nil && f.env.system.globalHotkey == nil)
        #expect(f.env.system.preferences.menuBarEnabled && f.env.system.preferences.globalHotkeyEnabled,
                "the user's choices stay for the next window")
    }

    @Test func removingTheLastAccountThenSigningInCanOpenAMessage() async throws {
        let corpus = FakeCorpus.make(threadCount: 3, now: fixedNow)
        let store = FakeMailStore(corpus: corpus)
        let oldAccount = try #require(corpus.accounts.first?.id)
        var previous: AppEnvironment? = AppEnvironment(data: store, commands: store, accounts: store,
                                                        settings: store, isFake: true, featureFlags: FeatureFlags())
        // Readers in parallel suites must not borrow this accessory during account removal.
        let accessorySlot = ReaderHeaderAccessoryStore()
        previous?.system.startUnsubscribe(accessorySlot: accessorySlot)
        weak var removedAccessory = previous?.system.unsubscribe
        try await store.remove(oldAccount)
        previous?.system.unsubscribe?.install()
        #expect(accessorySlot.current === removedAccessory)
        previous?.system.stopAll()
        #expect(previous?.system.unsubscribe == nil)
        #expect(previous?.overlays.fallback == nil)
        previous = nil
        #expect(removedAccessory == nil)
        #expect(accessorySlot.current == nil)

        let client = Data(#"{"installed":{"client_id":"fake","client_secret":"fake"}}"#.utf8)
        try await store.importOAuthClient(json: client)
        let account = try await store.addAccount(loginHint: "reconnected@example.org")
        store.deliverMessage(account: account, from: sender, subject: "Welcome back")
        let next = AppEnvironment(data: store, commands: store, accounts: store, settings: store,
                                  isFake: true, featureFlags: FeatureFlags().with(.unsubscribe, false))
        next.router.start()
        await eventually { next.router.activeAccountID == account }
        next.router.go(to: .system(.inbox))
        await eventually { next.router.list?.rows.first != nil }
        let thread = try #require(next.router.list?.rows.first?.id)
        next.router.open(thread)
        await eventually { next.router.reader?.state == .loaded }
        #expect(next.router.reader?.messages.count == 1)
    }
}
