import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct GeneralSettingsTests {
    @Test func undoSendAndSchedulingPersistThroughTheSettingsPortAndShowTheNewValue() async throws {
        let f = SettingsFixture()
        let model = GeneralSettingsModel(environment: f.env)
        model.start()
        #expect(model.undoSend.value == 10, "default")
        await model.undoSend.set(20)
        await model.sendLater.set(false)
        await model.snoozeMarkUnread.set(false)
        #expect(try await f.store.get(AppSettings.undoSendSeconds) == 20)
        #expect(try await f.store.get(AppSettings.schedulerSendLater) == false)
        #expect(try await f.store.get(AppSettings.snoozeMarkUnread) == false)
        try await f.store.set(AppSettings.undoSendSeconds, 5)
        await eventually { model.undoSend.value == 5 }
        #expect(GeneralSettingsModel.undoSendChoices == [0, 5, 10, 20, 30])
        #expect(GeneralSettingsModel.snoozeNote.contains("other Mac"))
        #expect(GeneralSettingsModel.remindersNote.contains("stay on this Mac"))
    }

    @Test func theBodyDownloadSwitchAndCapPersistAndTheDiskNoteFollowsTheCap() async throws {
        let f = SettingsFixture()
        let model = GeneralSettingsModel(environment: f.env)
        model.start()
        #expect(model.downloadBodies.value && model.bodyMax.value == nil, "on, no cap by default")
        #expect(model.bodyDiskNote.hasPrefix("No limit"))
        await model.bodyMax.set(5_000)
        await model.downloadBodies.set(false)
        #expect(try await f.store.get(AppSettings.bodyMaxMessages) == 5_000)
        #expect(try await f.store.get(AppSettings.downloadBodies) == false)
        #expect(model.bodyDiskNote.hasPrefix("Up to about") && model.bodyDiskNote.contains(5_000.formatted(.number)),
                "the count follows the Mac's number format")
        #expect(AppSettings.downloadBodies.name == "sync.download_bodies" && AppSettings.bodyMaxMessages.name == "sync.body_max_messages")
        #expect(GeneralSettingsModel.bodyCapChoices == [nil, 5_000, 10_000, 20_000, 50_000])
        #expect(BodyDownloadEstimate.bytes(messages: 10_000) == 10_000 * BodyDownloadEstimate.bytesPerMessage)
    }

    @Test func localSettingsNeedNoWritePort() async throws {
        let f = SettingsFixture(writePort: false)
        let model = GeneralSettingsModel(environment: f.env)
        #expect(model.availability.canEditSettings)
        await model.undoSend.set(0)
        #expect(try await f.store.get(AppSettings.undoSendSeconds) == 0)
        #expect(model.errorMessage == nil)
    }

    @Test func confirmBeforeSendingIsOfferedOnALiveAccountOnly() async throws {
        #expect(!GeneralSettingsModel(environment: SettingsFixture().env).showsConfirmBeforeSending, "fake data")
        let store = FakeMailStore(corpus: .small)
        let live = AppEnvironment(data: store, commands: store, accounts: store, settings: store, isFake: true,
                                  isLiveAccount: true)
        let model = GeneralSettingsModel(environment: live)
        #expect(model.showsConfirmBeforeSending)
        #expect(model.confirmEverySend.value == false, "off by default")
        await model.confirmEverySend.set(true)
        #expect(try await store.get(SendSettings.confirmEverySend) == true)
        let noPort = AppEnvironment(data: store, settings: store, isFake: true, isLiveAccount: true)
        #expect(!GeneralSettingsModel(environment: noPort).showsConfirmBeforeSending, "nothing can be sent")
    }

    @Test func confirmEverySendKeepsItsStoredKey() {
        #expect(SendSettings.confirmEverySend.name == "write_mode.confirm_every_send")
        #expect(SendSettings.confirmEverySend.scope == .global && SendSettings.confirmEverySend.defaultValue == false)
        #expect(!SendSettings.confirmEverySend.isSafetyKey)
    }

    @Test func aRefusedWriteRestoresTheOldValueAndSaysWhy() async throws {
        let f = SettingsFixture()
        let setting = StoredSetting(AppSettings.undoSendSeconds, port: RefusingSettings())
        await setting.set(30)
        #expect(setting.value == 10)
        #expect(setting.errorMessage == "Not available right now: settings")
    }
}

private struct RefusingSettings: SettingsPort {
    func observe<V>(_ key: AppSettingKey<V>) -> AsyncStream<V> { AsyncStream { $0.yield(key.defaultValue); $0.finish() } }
    func get<V>(_ key: AppSettingKey<V>) async throws -> V { key.defaultValue }
    func set<V>(_ key: AppSettingKey<V>, _ value: V) async throws { throw MailPortError.unavailable("settings") }
}

@MainActor
struct AccountsSettingsTests {
    @Test func theListShowsEveryAccountWithItsFromChoicesAndPolicies() async throws {
        let f = SettingsFixture()
        let model = AccountsSettingsModel(environment: f.env)
        model.start()
        await eventually { model.rows.count == 2 }
        let work = try #require(model.rows.first { $0.id == f.work })
        #expect(work.fromChoices.count >= 2, "the rich corpus gives the work account a second send-as address")
        #expect(work.defaultFrom == nil && work.replyFrom == .addressSentTo)
        #expect(!work.status.isEmpty && !work.needsSignIn)
    }

    @Test func theComposerPoliciesAreStoredUnderTheComposersKeys() async throws {
        let f = SettingsFixture()
        let model = AccountsSettingsModel(environment: f.env)
        model.start()
        await eventually { model.rows.count == 2 }
        let alias = try #require(model.rows.first { $0.id == f.work }?.fromChoices.last)
        await model.setDefaultFrom(alias, for: f.work)
        await model.setReplyFrom(.accountDefault, for: f.work)
        #expect(try await f.store.get(ComposeSettings.defaultFrom(f.work)) == alias.lowercased())
        #expect(try await f.store.get(ComposeSettings.replyFrom(f.work)) == .accountDefault)
        #expect(try await f.store.get(ComposeSettings.replyFrom(f.personal)) == .addressSentTo, "per account")
        await eventually { model.rows.first { $0.id == f.work }?.defaultFrom == alias.lowercased() }
        await model.setDefaultFrom(nil, for: f.work)
        #expect(try await f.store.get(ComposeSettings.defaultFrom(f.work)) == nil)
        let account = try #require(try await f.accounts().first { $0.id == f.work })
        await model.setDefaultFrom(alias, for: f.work)
        let setting = try await f.store.get(ComposeSettings.defaultFrom(f.work))
        let (identity, _) = FromResolver.forNew(account: account, defaultSetting: setting)
        #expect(identity.email == alias.lowercased())
    }

    @Test func aliasAndSignOutWorkAndSignOutAsksFirst() async throws {
        let f = SettingsFixture()
        let model = AccountsSettingsModel(environment: f.env)
        model.start()
        await eventually { model.rows.count == 2 }
        await model.setAlias("  Office  ", for: f.work)
        #expect(try await f.accounts().first { $0.id == f.work }?.alias == "Office")
        await model.setAlias("", for: f.work)
        #expect(try await f.accounts().first { $0.id == f.work }?.alias == nil)
        await model.askToRemove(f.personal)
        #expect(model.confirmingRemoval == f.personal)
        model.cancelRemoval()
        #expect(try await f.accounts().count == 2, "nothing removed without the confirmation")
        await model.askToRemove(f.personal)
        await model.confirmRemoval()?.value
        await eventually { model.rows.count == 1 }
        #expect(model.rows.first?.id == f.work)
    }

    @Test func theSignOutConfirmationSaysLocalOnlyGmailUntouchedAndNoUndo() {
        let message = AccountsSettingsModel.removalConfirmationMessage
        #expect(message.contains("this Mac only"))
        #expect(message.contains("Nothing changes in Gmail"))
        #expect(message.contains("can't be undone with ⌘Z"))
        #expect(message.contains("this Mac's Keychain"), "the same words as where the sign-in is made")
        for part in ["mail", "attachments", "drafts", "AI results", "Spotlight", "sign-in"] {
            #expect(message.contains(part), "names what goes: \(part)")
        }
        #expect(AccountsSettingsModel.removalConfirmationTitle == "Sign out of this account?")
        #expect(AccountsSettingsModel.removalConfirmationButton == "Sign out of this Mac")
    }

    @Test func removingTheSharedSignInIsASeparatelyWordedChoice() {
        let note = AccountsSettingsModel.removalSharedSignInNote
        #expect(note.contains("other devices") && note.contains("iCloud Keychain"))
        #expect(note.contains("sign in again"), "says what the second choice does to the other devices")
        #expect(note.contains(AccountsSettingsModel.removalSharedSignInButton))
        #expect(AccountsSettingsModel.removalSharedSignInButton != AccountsSettingsModel.removalConfirmationButton)
    }

    @Test func addingAnAccountGoesThroughTheSignInPortAndFailuresReadInWords() async throws {
        let f = SettingsFixture()
        let model = AccountsSettingsModel(environment: f.env)
        f.store.enqueueSignIn(.succeed(email: "new.person@example.org", displayName: "New Person"))
        await model.addAccount()
        #expect(model.errorMessage == nil)
        #expect(try await f.accounts().contains { $0.email == "new.person@example.org" })
        f.store.enqueueSignIn(.fail)
        await model.addAccount()
        #expect(model.errorMessage?.isEmpty == false)
        f.store.enqueueSignIn(.cancel)
        await model.addAccount()
        #expect(model.errorMessage == nil, "a cancel is not an error")
    }
}
