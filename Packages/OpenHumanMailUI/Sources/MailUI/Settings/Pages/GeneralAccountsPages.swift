import MailActions
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettingsPage: View {
    @State private var model: GeneralSettingsModel
    @State private var menuBar: MenuBarSettingsModel
    @State private var savedSearches: SavedSearchesModel
    @State private var writing: ComposeTextSettings
    let modules: [FeatureModuleID]
    let extras: () -> AnyView
    let ai: AICenter?
    let savedSearchAccount: AccountID?
    let environment: AppEnvironment

    static let schedulingNote = "These switches apply to this Mac only."
    static let sentencesNote = "When you type a search as a sentence, Mail offers the matching filters to use with ⇥. "
        + "It runs only on this Mac and sends nothing anywhere."
    static let welcomeTourNote = "The short guide from your first sign-in: look, keys and AI replies. It opens over the "
        + "mail window and changes no mail."

    init(environment: AppEnvironment, extras: @escaping () -> AnyView) {
        _model = State(initialValue: GeneralSettingsModel(environment: environment))
        _menuBar = State(initialValue: MenuBarSettingsModel(system: environment.system))
        _savedSearches = State(initialValue: SavedSearchesModel(settings: environment.settings))
        _writing = State(initialValue: environment.composeText)
        modules = environment.modules.modules
        self.extras = extras
        ai = environment.ai
        savedSearchAccount = environment.router.active?.id
        self.environment = environment
    }

    var body: some View {
        SettingsPageScaffold(title: "General") {
            SettingsSection("Sending") {
                SettingsRow("Undo send", detail: "How long a sent message can still be taken back.",
                            selection: binding(model.undoSend)) {
                    ForEach(GeneralSettingsModel.undoSendChoices, id: \.self) { Text(GeneralSettingsModel.undoSendTitle($0)).tag($0) }
                }
                .disabled(!model.availability.canEditSettings)
                switchRow("Archive and go back after sending a reply", model.sendAndMarkDone,
                          detail: "A sent reply, reply all or forward marks its conversation done and takes you back to the list; Undo puts it back.")
                switchRow("Include signature on replies and forwards", model.signatureOnReplies,
                          detail: GeneralSettingsModel.signatureOnRepliesNote)
                if model.showsConfirmBeforeSending {
                    switchRow(GeneralSettingsModel.confirmBeforeSendingTitle, model.confirmEverySend,
                              detail: GeneralSettingsModel.confirmEverySendNote)
                }
            }
            SettingsSection("Writing", footnote: ComposeTextSettings.protectedNote) {
                SettingsRow("Correct spelling automatically", detail: writing.autocorrectNote, selection: $writing.autocorrect) {
                    ForEach(AutocorrectChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SettingsRow("Check spelling while typing", isOn: $writing.continuousSpelling)
                SettingsRow("Check grammar with spelling", isOn: $writing.grammar)
                SettingsRow("Text replacements", detail: ComposeTextSettings.replacementsNote,
                            selection: $writing.textReplacement) {
                    ForEach(FollowSystemChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SettingsRow("Smart quotes and dashes", selection: $writing.smartPunctuation) {
                    ForEach(FollowSystemChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SettingsRow("Automatic lists", detail: ComposeTextSettings.autoListsNote, isOn: $writing.autoLists)
                SettingsRow("Pasted image size", detail: ComposeTextSettings.pastedImageSizeNote,
                            selection: $writing.pastedImageSize) {
                    ForEach(InlineImageSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            SettingsSection("Window") {
                switchRow("Show shortcut hints", model.showShortcutHints,
                          detail: "A strip along the bottom with the keys that matter where you are.")
                switchRow("Show sync progress in the footer", model.showPendingSync,
                          detail: "Says how many of your changes are still on their way to Gmail.")
                SettingsRow("Tab counts", detail: GeneralSettingsModel.tabCountsNote, selection: binding(model.tabCounts)) {
                    ForEach(TabCountMode.allCases, id: \.self) { Text(GeneralSettingsModel.tabCountTitle($0)).tag($0) }
                }
                .disabled(!model.availability.canEditSettings)
                SettingsRow("Account counts", detail: GeneralSettingsModel.accountCountsNote,
                            selection: binding(model.accountCounts)) {
                    ForEach(AccountCountMode.allCases, id: \.self) {
                        Text(GeneralSettingsModel.accountCountTitle($0)).tag($0)
                    }
                }
                .disabled(!model.availability.canEditSettings)
                SettingsRow("Zoom", detail: GeneralSettingsModel.zoomNote,
                            selection: Binding(get: { ReaderPreferences.shared.textZoom },
                                               set: { ReaderPreferences.shared.setZoom($0) })) {
                    ForEach(ReaderPreferences.zoomSteps, id: \.self) { Text(ReaderPreferences.percent($0)).tag($0) }
                }
            }
            SettingsSection("Learning the keys") {
                switchRow(GeneralSettingsModel.hintOnClickTitle, model.hintOnClick, detail: GeneralSettingsModel.hintOnClickNote)
                SettingsRow(GeneralSettingsModel.resetHintsTitle, detail: GeneralSettingsModel.resetHintsNote) {
                    Button("Reset") { Task { await model.resetShortcutHints() } }
                        .disabled(!model.canResetShortcutHints)
                        .accessibilityLabel("Reset shortcut hints")
                }
            }
            SettingsSection("Move to") {
                switchRow("Show splits and places in Move to", model.moveToSuperset,
                          detail: GeneralSettingsModel.moveToSupersetNote)
            }
            SettingsSection("Welcome tour") {
                SettingsRow("Run welcome tour again", detail: Self.welcomeTourNote) {
                    Button("Run Again") { environment.welcomeGuide.presentFromStart() }
                        .accessibilityLabel("Run welcome tour again")
                }
            }
            if let updates = environment.system.updates {
                UpdateCheckSettingsSection(center: updates)
            }
            InboxAutomationSection(environment: environment)
            SettingsSection("Scheduling on this Mac", footnote: Self.schedulingNote) {
                if modules.contains(.snooze) {
                    switchRow("Snoozing", model.snooze, detail: GeneralSettingsModel.snoozeNote)
                    switchRow("Mark snoozed threads unread when they wake", model.snoozeMarkUnread)
                }
                if modules.contains(.sendLater) {
                    switchRow("Send later", model.sendLater, detail: GeneralSettingsModel.sendLaterNote)
                }
                if modules.contains(.reminders) {
                    switchRow("Reminders", model.reminders, detail: GeneralSettingsModel.remindersNote)
                }
            }
            if modules.contains(.snooze) || modules.contains(.reminders) {
                SettingsSection("Reminders and snooze") {
                    SettingsRow("Default time", detail: GeneralSettingsModel.defaultReminderTimeNote,
                                selection: binding(model.defaultReminderTime)) {
                        ForEach(model.defaultReminderTimeChoices, id: \.self) {
                            Text(GeneralSettingsModel.defaultReminderTimeTitle($0)).tag($0)
                        }
                    }
                    .disabled(!model.availability.canEditSettings)
                    switchRow("Weekdays only", model.reminderWeekdaysOnly, detail: GeneralSettingsModel.reminderWeekdaysOnlyNote)
                }
            }
            SettingsSection("Search") {
                switchRow("Download message bodies for search", model.downloadBodies, detail: GeneralSettingsModel.downloadBodiesNote)
                SettingsRow("Keep at most", detail: model.bodyDiskNote, selection: binding(model.bodyMax)) {
                    ForEach(GeneralSettingsModel.bodyCapChoices, id: \.self) { Text(GeneralSettingsModel.bodyCapTitle($0)).tag($0) }
                }
                .disabled(!model.availability.canEditSettings || !model.downloadBodies.value)
                if modules.contains(.smartSearch) {
                    if let ai {
                        SettingsRow("Understand searches written as sentences", detail: Self.sentencesNote,
                                    isOn: Binding(get: { ai.understandsSearchSentences },
                                                  set: { ai.setUnderstandsSearchSentences($0) }))
                    }
                    if savedSearches.canSave {
                        SavedSearchSettingsRows(model: savedSearches)
                    }
                }
            }
            SettingsSection("Login, Dock and menu bar") {
                extras()
                SettingsRow("Show Mail in the menu bar", detail: MenuBarSettingsModel.note,
                            status: menuBar.isOn ? menuBar.status : nil,
                            isOn: Binding(get: { menuBar.isOn }, set: { menuBar.setOn($0) }))
                SettingsRow("Number next to the menu bar icon", selection: $menuBar.count) {
                    ForEach(DockBadgeSource.allCases, id: \.self) { Text(MenuBarSettingsModel.countTitle($0)).tag($0) }
                }
                .disabled(!menuBar.isOn)
            }
            SettingsErrorLine(text: model.errorMessage)
        }
        .task {
            model.start()
            savedSearches.follow(savedSearchAccount)
        }
    }

    private func binding<Value>(_ setting: StoredSetting<Value>) -> Binding<Value> {
        Binding(get: { setting.value }, set: { value in Task { await setting.set(value) } })
    }

    private func switchRow(_ title: String, _ setting: StoredSetting<Bool>, detail: String? = nil) -> some View {
        SettingsRow(title, detail: detail, isOn: binding(setting))
            .disabled(!model.availability.canEditSettings)
    }
}

struct AccountsSettingsPage: View {
    @State private var model: AccountsSettingsModel
    @State private var aliasDrafts: [AccountID: String] = [:]
    @State private var importingClient = false
    @State private var replacingClient: OAuthClientSummary.ID?
    @State private var showsGoogleSteps = false
    @State private var copiedSteps = false
    private let navigator: SettingsNavigator
    @Environment(\.theme) private var theme

    init(environment: AppEnvironment) {
        _model = State(initialValue: AccountsSettingsModel(environment: environment))
        navigator = environment.settingsNavigator
    }

    static let clientNote = "The Google client a new account signs in with. Signing in again always uses the account's own."

    static let addressNote = "Sent from and replies from only decide which address the composer starts with. They stay on "
        + "this Mac."

    var body: some View {
        SettingsPageScaffold(title: "Accounts") {
            if model.rows.isEmpty {
                SettingsFootnote("No account is signed in.")
            }
            ForEach(model.rows) { row in accountSection(row) }
            SettingsSection(footnote: model.keychainNote) {
                SettingsRow("Add another account", detail: addAccountNote) {
                    HStack(spacing: theme.space3) {
                        if model.isAdding { ProgressView().controlSize(.small) }
                        Button("Add account…") { Task { await model.addAccount() } }
                            .disabled(!model.canAddAccount)
                    }
                }
                if model.showsClientPicker {
                    SettingsRow("Sign in with", detail: Self.clientNote,
                                selection: Binding(get: { model.selectedClient?.id ?? "" },
                                                   set: { id in Task { await model.selectClient(id) } })) {
                        ForEach(model.clients) { client in Text(verbatim: client.title).tag(client.id) }
                    }
                    .disabled(!model.canAddAccount)
                }
                if model.canAddAccount || model.isAdding {
                    SettingsRow("Google client file",
                                detail: model.selectedClient.map { "New accounts sign in with \($0.title)." }) {
                        Button("Import client JSON…") {
                            replacingClient = nil
                            importingClient = true
                        }
                        .disabled(!model.canAddAccount)
                    }
                }
            }
            SettingsErrorLine(text: model.errorMessage)
            googleClientsListSection
            googleClientSection
        }
        .task {
            model.start()
            model.addAccountIfRequested(by: navigator)
        }
        .onChange(of: navigator.addAccountRequested) { _, requested in
            if requested { model.addAccountIfRequested(by: navigator) }
        }
        .fileImporter(isPresented: $importingClient, allowedContentTypes: [.json]) { result in
            let target = replacingClient
            replacingClient = nil
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.importFailed()
                return
            }
            if let target {
                Task { await model.replaceClient(target, json: data) }
            } else {
                Task { await model.importClient(json: data) }
            }
        }
        .alert(model.pendingMove.map { model.moveTitle($0) } ?? "",
               isPresented: Binding(get: { model.pendingMove != nil }, set: { if !$0 { model.cancelMove() } })) {
            Button("Cancel", role: .cancel) { model.cancelMove() }
            Button(model.pendingMove.map { model.moveButton($0) } ?? "OK") { Task { await model.confirmMove() } }
        } message: {
            Text(model.pendingMove.map { model.moveMessage($0) } ?? "")
        }
        .alert(AccountsSettingsModel.removalConfirmationTitle,
               isPresented: Binding(get: { model.confirmingRemoval != nil }, set: { if !$0 { model.cancelRemoval() } })) {
            Button("Cancel", role: .cancel) { model.cancelRemoval() }
            Button(AccountsSettingsModel.removalConfirmationButton, role: .destructive) { model.confirmRemoval() }
            if model.removalOffersSharedSignIn {
                Button(AccountsSettingsModel.removalSharedSignInButton, role: .destructive) {
                    model.confirmRemoval(includingSharedSignIn: true)
                }
            }
        } message: {
            Text(model.removalMessage)
        }
    }

    @ViewBuilder private var googleClientsListSection: some View {
        if !model.clientRows.isEmpty {
            SettingsSection("Google clients", footnote: Self.clientsNote) {
                ForEach(model.clientRows) { client in
                    SettingsRow(client.title,
                                detail: [client.usedBy, client.calendars, client.imported].compactMap { $0 }
                                    .joined(separator: " · ")) {
                        if client.isImported {
                            HStack(spacing: theme.space3) {
                                Button("Replace…") {
                                    replacingClient = client.id
                                    importingClient = true
                                }
                                Button("Remove…", role: .destructive) { Task { await model.removeClient(client.id) } }
                            }
                            .disabled(!model.canChangeClients)
                        }
                    }
                    if let note = client.syncNote {
                        SettingsRow("Don't sync \(client.title)", detail: note,
                                    isOn: Binding(get: { client.dontSync },
                                                  set: { on in Task { await model.setDontSync(client.id, on) } }))
                            .disabled(!model.canChangeClients)
                    }
                }
                if model.isMoving {
                    SettingsRow("Signing in again with the new client") { ProgressView().controlSize(.small) }
                }
                if let notice = model.clientNotice { SettingsFootnote(notice) }
            }
        }
    }

    static let clientsNote = "Google sign-in clients are kept in your Keychain, not in files. By default a client syncs "
        + "through iCloud Keychain to your other Macs, so you set it up once. Turn on "
        + "Don't sync to keep a client on this Mac only. Removing a client deletes it from the Keychain, and from "
        + "iCloud Keychain if it synced, never anything at Google. A client an account or calendar still uses can't "
        + "be removed."

    private var googleClientSection: some View {
        SettingsSection("Google sign-in") {
            SettingsRow("How to get a Google client", detail: GoogleClientGuide.intro,
                        status: copiedSteps ? "Copied" : nil) {
                HStack(spacing: theme.space3) {
                    Button(showsGoogleSteps ? "Hide Steps" : "Show Steps") { showsGoogleSteps.toggle() }
                    Button("Copy Steps") {
                        TextClipboard.copy(GoogleClientGuide.plainText)
                        copiedSteps = true
                    }
                }
            }
            if showsGoogleSteps {
                Text(GoogleClientGuide.plainText)
                    .font(.system(size: NativeMetrics.Text.secondary))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var addAccountNote: String {
        model.availability.hasAccounts ? "A new account is asked for the same access as the first one."
            : "Adding another account isn't available yet."
    }

    private func accountSection(_ row: AccountsSettingsModel.Row) -> some View {
        SettingsSection(row.alias.isEmpty ? row.name : row.alias, footnote: Self.addressNote) {
            SettingsRow(row.email, status: row.status, statusTone: row.needsSignIn ? .danger : .secondary) {
                HStack(spacing: theme.space3) {
                    if row.needsSignIn { Button("Sign in again") { Task { await model.reauthorize(row.id) } } }
                    Button("Sign out…", role: .destructive) { Task { await model.askToRemove(row.id) } }
                }
            }
            if let short = row.clientShortID {
                SettingsRow("Google client", detail: "Signed in with the client ending …\(short)")
            }
            if let note = row.signInSyncNote {
                SettingsRow("Don't sync this sign-in", detail: note,
                            isOn: Binding(get: { row.dontSyncSignIn },
                                          set: { on in Task { await model.setDontSyncSignIn(row.id, on) } }))
                    .disabled(!model.canChangeClients || !row.canChangeSignInSync)
            }
            SettingsRow("Short name", detail: "Press Return to save it.") {
                TextField("Short name", text: Binding(get: { aliasDrafts[row.id] ?? row.alias },
                                                      set: { aliasDrafts[row.id] = $0 }),
                          prompt: Text("Work").settingsPrompt(theme))
                    .labelsHidden()
                    .settingsTextField()
                    .frame(width: 180)
                    .onSubmit { Task { await model.setAlias(aliasDrafts[row.id] ?? row.alias, for: row.id) } }
            }
            SettingsRow("New mail is sent from",
                        selection: Binding(get: { row.defaultFrom ?? "" },
                                           set: { value in Task { await model.setDefaultFrom(value.isEmpty ? nil : value, for: row.id) } })) {
                Text("Gmail's default address").tag("")
                ForEach(row.fromChoices, id: \.self) { Text($0).tag($0) }
            }
            .disabled(!model.availability.canEditSettings)
            SettingsRow("Replies come from",
                        selection: Binding(get: { row.replyFrom },
                                           set: { value in Task { await model.setReplyFrom(value, for: row.id) } })) {
                ForEach(ReplyFromPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!model.availability.canEditSettings)
        }
    }
}
