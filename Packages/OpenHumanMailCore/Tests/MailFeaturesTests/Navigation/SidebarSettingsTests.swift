import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct SidebarSettingsTests {
    private static let account = Account(id: AccountID(1), email: "me@work.example", displayName: nil, alias: nil,
                                         health: .active)
    private static let everyFolder: [MailLocation] = [.system(.inbox), .system(.starred), .system(.snoozed),
                                                      .system(.reminders), .system(.waiting), .system(.scheduled),
                                                      .system(.drafts), .system(.sent), .system(.done),
                                                      .system(.allMail), .system(.spam), .system(.trash)]

    private func folder(_ token: String) throws -> SidebarFolder {
        try #require(SidebarFolder.named(token))
    }

    private func state(_ f: SettingsFixture) -> AccountState {
        AccountState(account: Self.account, environment: f.env, start: nil, place: nil)
    }

    @Test func theKeysAreGlobalUISettingsThatShowEverythingByDefault() {
        #expect(AppSettings.allInboxesShown.name == "ui.all_inboxes")
        #expect(AppSettings.allInboxesShown.defaultValue == true)
        #expect(AppSettings.allInboxesShown.scope == .global && !AppSettings.allInboxesShown.isSafetyKey)
        #expect(AppSettings.sidebarHidden.name == "ui.sidebar.hidden")
        #expect(AppSettings.sidebarHidden.defaultValue == [])
        #expect(AppSettings.sidebarHidden.scope == .global && !AppSettings.sidebarHidden.isSafetyKey)
    }

    @Test func unreadableStoredValuesFallBackToShowingEverything() async throws {
        let f = SettingsFixture()
        try await f.store.set(AppSettingKey(name: "ui.sidebar.hidden", defaultValue: 0), 7)
        try await f.store.set(AppSettingKey(name: "ui.all_inboxes", defaultValue: ""), "nope")
        #expect(try await f.store.get(AppSettings.sidebarHidden) == [])
        #expect(try await f.store.get(AppSettings.allInboxesShown) == true)
    }

    @Test func hidingAllMailRemovesOnlyItsRow() {
        let state = state(SettingsFixture())
        #expect(state.sidebarItems.map(\.location) == Self.everyFolder)
        state.applySidebarHidden(["allMail"])
        #expect(state.sidebarItems.map(\.location) == Self.everyFolder.filter { $0 != .system(.allMail) })
        #expect(state.sidebarItems.first?.title == "Inbox")
        #expect(SidebarFolder.visibleFolders(hidden: ["allMail"], current: nil).map(\.token)
            == ["starred", "snoozed", "reminders", "waiting", "scheduled", "muted", "drafts", "sent", "done", "spam", "trash"])
    }

    @Test func aHiddenFolderStaysWhileItIsTheCurrentPlace() {
        #expect(SidebarFolder.visibleFolders(hidden: ["allMail"], current: .system(.allMail)).contains { $0.token == "allMail" })
        #expect(!SidebarFolder.visibleFolders(hidden: ["allMail"], current: .system(.inbox)).contains { $0.token == "allMail" })
        let muted = GmailLabelID("Label_9")
        #expect(SidebarFolder.visibleFolders(hidden: ["muted"], current: .label(muted), mutedLabel: muted)
            .contains { $0.token == "muted" })
        #expect(!SidebarFolder.visibleFolders(hidden: ["muted"], current: .label(GmailLabelID("Label_3")), mutedLabel: muted)
            .contains { $0.token == "muted" })

        let state = state(SettingsFixture())
        state.applySidebarHidden(["allMail"])
        state.go(to: .system(.allMail))
        #expect(state.sidebarItems.contains { $0.location == .system(.allMail) }, "the open place keeps its row")
        state.go(to: .system(.inbox))
        #expect(!state.sidebarItems.contains { $0.location == .system(.allMail) }, "gone once you leave")
    }

    @Test func unknownHiddenTokensAreIgnored() {
        #expect(SidebarFolder.hiddenTokens(["allMail", "inbox", "important", "fromANewerBuild", ""]) == ["allMail"])
        #expect(SidebarFolder.visibleFolders(hidden: SidebarFolder.hiddenTokens(["fromANewerBuild"]), current: nil)
            == SidebarFolder.all)
        let state = state(SettingsFixture())
        state.applySidebarHidden(["inbox", "fromANewerBuild"])
        #expect(state.sidebarItems.map(\.location) == Self.everyFolder, "Inbox can't be hidden")
        #expect(SidebarFolder.hiddenList(["fromANewerBuild"], setting: "spam", hidden: true) == ["fromANewerBuild", "spam"],
                "a newer build's choices survive")
        #expect(SidebarFolder.hiddenList(["spam", "trash"], setting: "spam", hidden: false) == ["trash"])
        #expect(SidebarFolder.hiddenList(["spam"], setting: "spam", hidden: true) == ["spam"])
    }

    @Test func onlyTheSystemFoldersCanBeHidden() {
        for location: MailLocation in [.system(.inbox), .split(SplitKey("s1")), .splitOther, .reviewQueue(nil),
                                       .label(GmailLabelID("Label_3")), .search("in:all")] {
            #expect(SidebarFolder.folder(for: location, mutedLabel: GmailLabelID("Label_9")) == nil, "\(location)")
        }
        #expect(SidebarFolder.folder(for: .label(GmailLabelID("Label_9")), mutedLabel: GmailLabelID("Label_9"))?.token == "muted")
        #expect(!SidebarFolder.tokens.contains("inbox"))
    }

    @Test func goAllMailStillWorksWhenItsRowIsHidden() async throws {
        let f = SettingsFixture()
        let accounts = try await f.accounts()
        let router = f.env.router
        router.apply(accounts)
        let active = try #require(router.active)
        active.applySidebarHidden(["allMail", "spam", "trash"])
        #expect(!active.sidebarItems.contains { $0.location == .system(.allMail) })
        #expect(AppRouter.goLocation(.goAllMail) == .system(.allMail))
        #expect(router.shellIsEnabled(.goAllMail))
        #expect(router.performShellAction(.goAllMail))
        #expect(router.location == .system(.allMail))
        #expect(active.sidebarItems.contains { $0.location == .system(.allMail) })
        for row in SidebarSettingsModel.folderRows(descriptor: ActionCatalog.descriptor) {
            guard let action = row.folder.goAction, action != .goMuted else { continue }
            #expect(router.shellIsEnabled(action), "\(action)")
            #expect(AppRouter.goLocation(action).flatMap { SidebarFolder.folder(for: $0, mutedLabel: nil) } == row.folder,
                    "\(action) opens \(row.folder.title)")
        }
    }

    @Test func allInboxesOffHidesItsActionAndClosesIt() async throws {
        #expect(AllInboxesActionHandler.availability(accountCount: 2, enabled: true) == .enabled)
        #expect(AllInboxesActionHandler.availability(accountCount: 2, enabled: false) == .hidden)
        #expect(AllInboxesActionHandler.availability(accountCount: 1, enabled: true) == .hidden)

        let f = SettingsFixture()
        let accounts = try await f.accounts()
        #expect(accounts.count == 2)
        _ = f.env.overlays
        let router = f.env.router
        router.apply(accounts)
        #expect(router.showsAllInboxes)
        #expect(f.env.actions.availability(.goAllInboxes, host: router).isEnabled)
        #expect(router.goToAllInboxes())
        let model = try #require(router.unifiedInbox)

        router.applyAllInboxesSetting(false)
        #expect(router.unifiedInbox == nil && model.isClosed, "an open All Inboxes closes")
        #expect(!router.showsAllInboxes && router.showsAccountSwitcher, "the account pictures stay")
        #expect(f.env.actions.availability(.goAllInboxes, host: router) == .hidden, "⌃0, G U and ⌘K")
        #expect(!router.goToAllInboxes())
        #expect(router.unifiedInbox == nil)

        router.applyAllInboxesSetting(true)
        #expect(f.env.actions.availability(.goAllInboxes, host: router).isEnabled)
        #expect(router.goToAllInboxes())
        router.leaveAllInboxes()
    }

    @Test func theSwitchesWriteTheSettingsStore() async throws {
        let f = SettingsFixture()
        let router = f.env.router
        let allMail = try folder("allMail")
        #expect(await router.setFolder(allMail, shown: false))
        #expect(try await f.store.get(AppSettings.sidebarHidden) == ["allMail"])
        #expect(await router.setFolder(allMail, shown: true))
        #expect(try await f.store.get(AppSettings.sidebarHidden) == [])
        #expect(await router.setAllInboxesShown(false))
        #expect(try await f.store.get(AppSettings.allInboxesShown) == false)
        #expect(await router.setAllInboxesShown(true))
        #expect(try await f.store.get(AppSettings.allInboxesShown) == true)
    }

    @Test func thePageSwitchesHideAndShowAFolder() async throws {
        let f = SettingsFixture()
        try await f.store.set(AppSettings.sidebarHidden, ["fromANewerBuild"])
        let model = SidebarSettingsModel(settings: f.store, availability: f.availability)
        let spam = try folder("spam")
        let trash = try folder("trash")
        #expect(model.canEdit && model.isShown(spam))
        await model.setShown(spam, false)
        #expect(!model.isShown(spam) && model.isShown(trash))
        #expect(try await f.store.get(AppSettings.sidebarHidden) == ["fromANewerBuild", "spam"])
        await model.setShown(spam, true)
        #expect(model.isShown(spam))
        #expect(try await f.store.get(AppSettings.sidebarHidden) == ["fromANewerBuild"])
        await model.allInboxes.set(false)
        #expect(try await f.store.get(AppSettings.allInboxesShown) == false)
        #expect(model.errorMessage == nil)
    }

    @Test func theSidebarPageListsEveryHideableFolderInSidebarOrder() {
        let rows = SidebarSettingsModel.folderRows(descriptor: ActionCatalog.descriptor)
        #expect(rows.map(\.folder) == SidebarFolder.all)
        #expect(rows.map(\.id) == ["starred", "snoozed", "reminders", "waiting", "scheduled", "muted", "drafts", "sent",
                                   "done", "allMail", "spam", "trash"])
        #expect(rows.map(\.folder.title) == ["Starred", "Snoozed", "Reminders", "Waiting", "Scheduled", "Muted", "Drafts",
                                             "Sent", "Done", "All mail", "Spam", "Trash"])
        #expect(rows.map(\.route) == ["G S", "G Z", "G H", "G W", "G Y", "G M", "G D", "G T", "G E", "G A", "G !",
                                      "G #"])
        let allMail = rows[9]
        #expect(allMail.keycaps == ["G", "A"] && rows[10].keycaps == ["G", "!"] && rows[11].keycaps == ["G", "#"])
        #expect(allMail.spokenHint == "Off hides All mail from the sidebar. G A still opens it.")
        #expect(rows[10].spokenHint == "Off hides Spam from the sidebar. G ! still opens it.")
        let page = SettingsShellModel(environment: SettingsFixture().env).pages.first { $0.id == "sidebar" }
        #expect(page?.title == "Sidebar" && page?.symbol == "sidebar.left" && page?.builtIn == .sidebar)
    }

    @Test func theNoticesAndNotesSayHowToReachAHiddenFolder() throws {
        let allMail = try folder("allMail"), trash = try folder("trash"), sent = try folder("sent")
        #expect(SidebarFolder.hiddenNotice(allMail, route: "G A") == "All mail is hidden from the sidebar. G A still opens it.")
        #expect(SidebarFolder.hiddenNotice(trash, route: "in:trash")
            == "Trash is hidden from the sidebar. Searching in:trash still finds it.")
        #expect(SidebarFolder.hiddenNotice(sent, route: nil) == "Sent is hidden from the sidebar. Settings › Sidebar shows it again.")
        #expect(SidebarSettingsModel.allInboxesStatus(accountCount: 1) == "Appears once a second account is signed in.")
        #expect(SidebarSettingsModel.allInboxesStatus(accountCount: 2) == nil)
        #expect(AppRouter.allInboxesOffNotice == "All Inboxes is off. Settings › Sidebar turns it back on.")
    }
}
