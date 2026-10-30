import MailActions
import MailFeatures
import MailModel
import MailTheme
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
#if canImport(AppKit)
import AppKit
#endif
#endif

struct ShortcutsSettingsPage: View {
    @State private var model: ShortcutsSettingsModel
    @State private var exporting: SettingsFileDocument?
    @State private var importing = false
    @State private var preview: KeymapImportPreview?
    @State private var fileNote: String?
    let printText: (String) -> Void
    @Environment(\.theme) private var theme

    init(environment: AppEnvironment, printText: @escaping (String) -> Void) {
        _model = State(initialValue: ShortcutsSettingsModel(environment: environment))
        self.printText = printText
    }

    var body: some View {
        SettingsPageScaffold(title: "Shortcuts") {
            Section {
                HStack(spacing: theme.space4) {
                    TextField("Search shortcuts", text: $model.searchText, prompt: Text("Search shortcuts").settingsPrompt(theme))
                        .settingsTextField().frame(maxWidth: 320)
                    Spacer(minLength: 0)
                    Button("Print cheat sheet") { printText(model.cheatSheetText) }
                }
                if model.sections.allSatisfy(\.lines.isEmpty) {
                    SettingsFootnote("No shortcut matches “\(model.searchText)”.")
                }
            } footer: {
                if let editor = model.editor {
                    VStack(alignment: .leading, spacing: theme.space2) {
                        SettingsFootnote(KeymapEditorModel.footnote)
                        if let message = editor.message {
                            SettingsFootnote(message, tone: editor.messageIsRefusal ? .danger : .success)
                        }
                    }
                } else {
                    SettingsFootnote("Shortcuts can't be changed.")
                }
            }
            ForEach(model.sections) { section in
                SettingsSection(section.title, compact: true) {
                    ForEach(section.lines) { line in shortcutRow(line) }
                }
            }
            let unassigned = model.unassignedLines
            if !unassigned.isEmpty {
                SettingsSection(ShortcutsSettingsModel.unassignedTitle, compact: true) {
                    ForEach(unassigned) { line in shortcutRow(line) }
                }
            }
            if let editor = model.editor {
                SettingsSection("Your shortcuts", footnote: fileNote) {
                    SettingsRow("Keymap file", detail: "One file with the shortcuts you changed, to keep or move to another "
                                + "Mac. Importing replaces your changes with the file's.") {
                        HStack(spacing: theme.space3) {
                            Button("Export…") {
                                do { exporting = SettingsFileDocument(data: try editor.exportData()) } catch {
                                    fileNote = "The shortcuts couldn't be written."
                                }
                            }
                            Button("Import…") { importing = true }
                            Button("Reset All") { editor.resetAll() }
                                .disabled(editor.overrides.isEmpty)
                        }
                    }
                    if let preview {
                        VStack(alignment: .leading, spacing: theme.space2) {
                            Text(preview.summary).fixedSize(horizontal: false, vertical: true)
                            ForEach(preview.refused, id: \.self) { SettingsFootnote($0, tone: .warning) }
                            HStack(spacing: theme.space3) {
                                Button("Cancel") { self.preview = nil }
                                Button("Import") {
                                    editor.applyImport(preview)
                                    self.preview = nil
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .settingsRowPadding()
                    }
                }
            }
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting, contentType: .json, defaultFilename: "Mail shortcuts") { result in
            if case .failure = result { fileNote = "The file couldn't be saved." } else { fileNote = "Shortcuts exported." }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result, let editor = model.editor else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                fileNote = "That file couldn't be read."
                return
            }
            do {
                preview = try editor.importPreview(data)
                fileNote = nil
            } catch {
                fileNote = (error as? KeymapFileError)?.description ?? "That file couldn't be read."
            }
        }
    }
    @ViewBuilder
    private func shortcutRow(_ line: ShortcutLine) -> some View {
        SettingsRow(line.title) {
            HStack(spacing: theme.space2) {
                if let editor = model.editor, editor.recording == line.action {
                    KeyRecorderView(editor: editor)
                } else {
                    ForEach(line.keys, id: \.self) { NativeKeycap($0) }
                }
                if let editor = model.editor, editor.canChange(line.action) {
                    let keyless = line.keys.isEmpty
                    Button(editor.recording == line.action ? "Cancel" : keyless ? "Set…" : "Change…") {
                        if editor.recording == line.action { editor.cancelRecording() }
                        else { editor.startRecording(line.action) }
                    }
                    .ohLinkButtonStyle()
                    .accessibilityLabel(keyless ? "Set a shortcut for \(line.title)" : "Change the shortcut for \(line.title)")
                    if editor.isCustomized(line.action), editor.recording != line.action {
                        Button("Reset") { editor.reset(line.action) }
                            .ohLinkButtonStyle()
                            .accessibilityLabel("Reset the shortcut for \(line.title)")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(line.title)
        .accessibilityValue(line.keys.isEmpty ? "No shortcut" : line.keys.joined(separator: ", "))
    }
}

struct KeyRecorderView: View {
    let editor: KeymapEditorModel
    @State private var session: KeyRecorderSession?
    @Environment(\.theme) private var theme

    var body: some View {
        Text(editor.pendingText ?? KeymapEditorModel.recordingHint)
            .font(.system(size: NativeMetrics.Text.secondary))
            .foregroundStyle(.tint)
            .accessibilityLabel(KeymapEditorModel.recordingHint)
            .onAppear {
                let made = session ?? KeyRecorderSession(editor: editor)
                session = made
                made.start()
            }
            .onDisappear { session?.stop() }
    }
}

@MainActor
final class KeyRecorderSession {
    private let editor: KeymapEditorModel
    private var monitor: Any?
    private var waiter: Task<Void, Never>?
    #if os(macOS)
    // The window the shortcut is recorded in, the key window when recording starts. Keys typed in any other window,
    // and keys that compose text there, are left to it, and recording ends when the window stops being key.
    private weak var window: NSWindow?
    private var resignObserver: NSObjectProtocol?
    #endif

    init(editor: KeymapEditorModel) {
        self.editor = editor
    }

    #if os(macOS)
    func start(in window: NSWindow? = NSApp.keyWindow) {
        guard monitor == nil else { return }
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode, characters = event.charactersIgnoringModifiers
            let flags = event.modifierFlags
            let command = flags.contains(.command), option = flags.contains(.option)
            let control = flags.contains(.control), shift = flags.contains(.shift)
            let windowNumber = event.windowNumber
            let taken = MainActor.assumeIsolated {
                guard let self, self.takes(windowNumber: windowNumber) else { return false }
                self.heard(keyCode: keyCode, characters: characters, command: command, option: option,
                           control: control, shift: shift)
                return true
            }
            return taken ? nil : event
        }
        if let window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                    object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowResignedKey() }
            }
        }
    }

    // Whether a key typed in the window with this number is the shortcut being recorded
    func takes(windowNumber: Int) -> Bool {
        guard let window, windowNumber == window.windowNumber, windowNumber > 0 else { return false }
        return (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
    }

    func windowResignedKey() {
        guard window != nil else { return }
        if editor.recording != nil { editor.cancelRecording() }
        stop()
    }
    #else
    func start() {}
    #endif

    func stop() {
        waiter?.cancel()
        waiter = nil
        #if os(macOS)
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        window = nil
        #endif
        monitor = nil
    }

    private func heard(keyCode: UInt16, characters: String?, command: Bool, option: Bool, control: Bool, shift: Bool) {
        guard let chord = KeyRecorder.chord(keyCode: keyCode, characters: characters, command: command, option: option,
                                            control: control, shift: shift) else { return }
        waiter?.cancel()
        if editor.record(chord) == .waitingForSecondKey {
            let editor = self.editor
            waiter = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                editor.finishPending()
            }
        }
        if editor.recording == nil { stop() }
    }
}

struct PrivacySettingsPage: View {
    @State private var model: PrivacySettingsModel
    @Environment(\.theme) private var theme

    init(environment: AppEnvironment) {
        self.init(model: PrivacySettingsModel(environment: environment))
    }

    init(model: PrivacySettingsModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        SettingsPageScaffold(title: "Privacy") {
            if model.accounts.count > 1 {
                SettingsSection {
                    SettingsRow("Account", detail: "Remote images are set for each account.", selection: $model.account) {
                        ForEach(model.accounts) { Text($0.alias ?? $0.email).tag(Optional($0.id)) }
                    }
                }
            }
            if let policy = model.policy, let senders = model.senders {
                SettingsSection("Remote images", footnote: PrivacySettingsModel.blockNote) {
                    Picker("Remote images", selection: Binding(get: { policy.value },
                                                               set: { value in Task { await model.setPolicy(value) } })) {
                        ForEach(RemoteImagePolicy.allCases, id: \.self) { Text(PrivacySettingsModel.title($0)).tag($0) }
                    }
                    .ohRadioGroupPickerStyle().labelsHidden()
                    .settingsRowPadding()
                }
                SettingsSection("Always load images from", footnote: RemoteContentPolicy.unverifiedSenderNote) {
                    ForEach(senders.value, id: \.self) { sender in
                        SettingsRow(sender) {
                            Button("Remove") { Task { await model.removeSender(sender) } }
                                .ohLinkButtonStyle()
                                .accessibilityLabel("Remove \(sender)")
                        }
                    }
                    HStack(spacing: theme.space3) {
                        TextField("Address or domain to allow", text: $model.newSender,
                                  prompt: Text(verbatim: "name@example.com or @example.com").settingsPrompt(theme))
                            .labelsHidden()
                            .settingsTextField()
                            .onSubmit { Task { await model.addSender() } }
                        Button("Add") { Task { await model.addSender() } }
                    }
                    .settingsRowPadding()
                }
                SettingsErrorLine(text: model.errorMessage)
            } else {
                SettingsFootnote("Sign in to choose how remote images load.")
            }
        }
        .task { model.start() }
    }
}

struct AISettingsPage: View {
    let environment: AppEnvironment
    let providers: (() -> AnyView)?

    var body: some View {
        SettingsPageScaffold(title: "AI") {
            if !environment.modules.modules.contains(.ai) {
                SettingsFootnote("AI features are off in Advanced › Features. Turn them on there and restart Mail; until then "
                                 + "nothing on this page is used.", tone: .warning)
            }
            if let providers {
                providers()
            } else {
                SettingsFootnote("AI isn't available in this mode.")
            }
        }
    }
}

struct SettingsFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct AdvancedSettingsPage: View {
    @State private var features: FeaturesSettingsModel
    @State private var transfer: SettingsTransferModel
    @State private var exporting: SettingsFileDocument?
    @State private var importing = false
    @State private var note: String?
    @State private var superhuman: SuperhumanImportModel
    let modules: [FeatureModuleID]
    let extras: () -> AnyView
    let sendFeedback: SendFeedbackCenter
    let preferences: SystemPreferences
    let showsDeveloperItems: Bool
    @Environment(\.theme) private var theme

    static let featuresTitle = "Features (restart required)"
    static let featuresNote = "Each switch adds or removes a whole feature the next time Mail starts. Day-to-day options "
        + "for each feature are on its own page: General, Notifications, AI and Platform features."

    init(environment: AppEnvironment, extras: @escaping () -> AnyView, showsDeveloperItems: Bool = true) {
        _features = State(initialValue: FeaturesSettingsModel(environment: environment))
        _transfer = State(initialValue: SettingsTransferModel(environment: environment))
        _superhuman = State(initialValue: SuperhumanImportModel(environment: environment))
        modules = environment.modules.modules
        sendFeedback = environment.system.sendFeedback
        preferences = environment.system.preferences
        self.extras = extras
        self.showsDeveloperItems = showsDeveloperItems
    }

    static func restartRows(_ rows: [FeaturesSettingsModel.Row]) -> [FeaturesSettingsModel.Row] {
        rows.filter { !FeatureModuleID.startsAtOnce.contains($0.id) }
    }

    static func featureRows(_ rows: [FeaturesSettingsModel.Row], developer: Bool) -> [FeaturesSettingsModel.Row] {
        FeaturesSettingsModel.visibleRows(restartRows(rows), developer: developer)
    }

    var body: some View {
        SettingsPageScaffold(title: "Advanced") {
            SettingsSection(Self.featuresTitle, detail: Self.featuresNote) {
                ForEach(Self.featureRows(features.rows, developer: showsDeveloperItems)) { row in
                    SettingsRow(row.title, detail: row.detail, status: row.needsRestart ? "Restart Mail to apply." : nil,
                                statusTone: .warning,
                                isOn: Binding(get: { row.isOn }, set: { features.set(row.id, enabled: $0) }))
                }
            }
            SettingsSection("Unsubscribing") {
                SettingsRow("Offer to clean up after unsubscribing",
                            detail: "After an unsubscribe is sent, offers to archive or move to Trash the other mail from "
                            + "that sender on this Mac. One undo brings it all back.",
                            isOn: Binding(get: { preferences.unsubscribeCleanupOffer },
                                          set: { preferences.unsubscribeCleanupOffer = $0 }))
            }
            SettingsSection("Move to another Mac", footnote: note) {
                SettingsRow("Settings file", detail: "One file with your splits, snippets and settings. It holds no mail and no "
                            + "sign-in. Importing adds or replaces by name and never deletes.") {
                    HStack(spacing: theme.space3) {
                        Button("Export settings…") { Task { await export() } }
                        Button("Import settings…") { importing = true }
                    }
                }
                if let preview = transfer.preview { previewRow(preview) }
            }
            if modules.contains(.mute) {
                superhumanSection
            }
            if modules.contains(.diagnostics) {
                SettingsSection("Diagnostics") {
                    SettingsRow("Export diagnostics", detail: "In the Help menu. Contains no email content: no subjects, "
                                + "addresses or message text.")
                }
            }
            if sendFeedback.canBegin {
                SettingsSection("Feedback") {
                    SettingsRow(SendFeedbackCenter.settingsTitle, detail: SendFeedbackCenter.settingsDetail) {
                        Button("Send…") { sendFeedback.begin() }
                    }
                }
            }
            extras()
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting, contentType: .json, defaultFilename: "Mail settings") { result in
            if case .failure = result { note = "The file couldn't be saved." } else { note = "Settings exported." }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            Task { await prepare(url) }
        }
    }

    @ViewBuilder private var superhumanSection: some View {
        SettingsSection("Import from Superhuman labels", footnote: SuperhumanImportModel.note) {
            switch superhuman.phase {
            case .idle, .counting:
                SettingsRow("Superhuman's Muted and Is Snoozed labels",
                            detail: "Counts the conversations with each label on the account you're viewing.") {
                    Button(superhuman.phase == .counting ? "Counting…" : "Count…") { Task { await superhuman.count() } }
                        .disabled(superhuman.phase == .counting)
                }
            case .failed(let text):
                SettingsFootnote(text, tone: .danger)
                Button("Count again") { Task { await superhuman.count() } }.settingsRowPadding()
            case .counted, .importing, .done:
                SettingsRow("Muted in Superhuman", detail: superhuman.mutedSummary) {
                    Button(superhuman.muteTitle) { Task { await superhuman.importMuted() } }
                        .disabled(superhuman.toMute.isEmpty || superhuman.phase == .importing)
                }
                if case .done(let text) = superhuman.phase { SettingsFootnote(text, tone: .success) }
                SettingsRow("Snoozed in Superhuman", detail: superhuman.snoozedSummary) {
                    Button("Show in Mail") { superhuman.showSnoozedInMail() }
                        .disabled(superhuman.snoozed.isEmpty)
                }
                ForEach(superhuman.snoozed.prefix(20)) { item in
                    HStack(spacing: theme.space3) {
                        Text(item.subject.isEmpty ? "(no subject)" : item.subject).lineLimit(1)
                        Spacer(minLength: theme.space3)
                        Text(item.lastMessageAt, format: .dateTime.month(.abbreviated).day())
                            .font(.system(size: NativeMetrics.Text.secondary)).foregroundStyle(.secondary)
                    }
                    .settingsRowPadding()
                }
            }
        }
    }

    private func previewRow(_ preview: SettingsImportPreview) -> some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            Text("This file would add \(preview.splitsToAdd) splits and \(preview.snippetsToAdd) snippets, replace "
                + "\(preview.splitsToReplace) splits and \(preview.snippetsToReplace) snippets with the same name, and set "
                + "\(preview.settingsToApply) settings.")
                .fixedSize(horizontal: false, vertical: true)
            if preview.accountsSkipped > 0 {
                SettingsFootnote("\(preview.accountsSkipped) account(s) in the file aren't signed in here and are skipped.")
            }
            if preview.settingsSkipped > 0 {
                SettingsFootnote("\(preview.settingsSkipped) setting(s) in the file have values Mail doesn't accept and are skipped.")
            }
            if let note = preview.storedItemsNote { SettingsFootnote(note + " Splits and snippets are skipped.") }
            HStack(spacing: theme.space3) {
                Button("Cancel") { transfer.cancelImport() }
                Button("Import") { Task { note = await transfer.applyImport() } }
                    .buttonStyle(.borderedProminent).disabled(preview.isEmpty)
            }
        }
        .settingsRowPadding()
    }

    private func export() async {
        do { exporting = SettingsFileDocument(data: try await transfer.export()) } catch { note = "The settings couldn't be read." }
    }

    private func prepare(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            note = "That file couldn't be read."
            return
        }
        do {
            _ = try await transfer.prepareImport(data)
            note = nil
        } catch {
            note = (error as? SettingsTransferError)?.description ?? "That file couldn't be read."
        }
    }
}

struct PlatformFeaturesPage: View {
    @State private var model: PlatformFeaturesModel
    let showsDeveloperItems: Bool

    static let intro = "Extras that work with the rest of your Mac. Spotlight, the global shortcut, and Shortcuts and Siri "
        + "are off until you turn them on; the Services menu is on, and Focus filters are on but do nothing until you add "
        + "Mail's filter to a Focus. The menu bar item is in General."

    init(environment: AppEnvironment, showsDeveloperItems: Bool = true) {
        _model = State(initialValue: PlatformFeaturesModel(environment: environment))
        self.showsDeveloperItems = showsDeveloperItems
    }

    private static let withControls: Set<String> = ["spotlight", "globalHotkey", "menuBarExtra", "services", "appIntents", "focusFilters"]

    var body: some View {
        SettingsPageScaffold(title: "Platform features") {
            SettingsFootnote(Self.intro)
            if let spotlight = model.spotlight, let feature = feature("spotlight") {
                SpotlightSection(feature: feature, model: spotlight,
                                 note: showsDeveloperItems ? SpotlightSettingsModel.unconfirmedNote : nil)
            }
            if let hotkey = model.hotkey, let feature = feature("globalHotkey") {
                GlobalHotkeySection(feature: feature, model: hotkey)
            }
            if let services = model.services, let feature = feature("services") {
                ServicesSection(feature: feature, model: services,
                                note: showsDeveloperItems ? ServicesSettingsModel.unconfirmedNote : nil)
            }
            if let intents = model.intents, let feature = feature("appIntents") {
                AppIntentsSection(feature: feature, model: intents,
                                  note: showsDeveloperItems ? AppIntentsSettingsModel.unconfirmedNote : nil)
            }
            if let focus = model.focus, let feature = feature("focusFilters") {
                FocusFilterSection(feature: feature, model: focus,
                                   note: showsDeveloperItems ? FocusFilterSettingsModel.unconfirmedNote : nil)
            }
            let others = model.rows.filter { $0.isAvailable && !Self.withControls.contains($0.id) }
            if !others.isEmpty {
                SettingsSection("Also available") {
                    ForEach(others) { row in
                        SettingsRow(row.feature.title, detail: row.feature.detail, status: row.status)
                    }
                }
            }
            if showsDeveloperItems {
                ForEach(Self.notYet(model.rows)) { group in
                    SettingsFootnote("Not in this build yet: \(group.titles.joined(separator: ", ")). Needs: \(group.id).")
                }
            }
        }
    }

    private func feature(_ id: String) -> PlatformFeature? {
        model.rows.first { $0.id == id }?.feature
    }

    struct MissingGroup: Identifiable, Equatable {
        let id: String
        var titles: [String]
    }

    static func notYet(_ rows: [PlatformFeaturesModel.Row]) -> [MissingGroup] {
        var groups: [MissingGroup] = []
        for row in rows where !row.isAvailable {
            if let index = groups.firstIndex(where: { $0.id == row.feature.requirement }) {
                groups[index].titles.append(row.feature.title)
            } else {
                groups.append(MissingGroup(id: row.feature.requirement, titles: [row.feature.title]))
            }
        }
        return groups
    }
}

private struct GlobalHotkeySection: View {
    let feature: PlatformFeature
    let model: GlobalHotkeySettingsModel

    var body: some View {
        SettingsSection(feature.title, footnote: GlobalHotkeySettingsModel.note) {
            SettingsRow("Open a new message with a global shortcut", detail: feature.detail, status: model.status,
                        isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
            SettingsRow("Keys", status: model.problem, statusTone: .danger) {
                ShortcutRecorder(keys: model.current, label: "Global shortcut keys") { key, modifiers in
                    model.record(key: key, modifiers: modifiers)
                }
            }
        }
    }
}

private struct ServicesSection: View {
    let feature: PlatformFeature
    @Bindable var model: ServicesSettingsModel
    let note: String?

    var body: some View {
        SettingsSection(feature.title, footnote: note) {
            SettingsRow("Answer the Services menu", detail: feature.detail, status: model.status,
                        isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
            SettingsRow("Hide an item or give it a key", detail: ServicesSettingsModel.note)
        }
    }
}

private struct AppIntentsSection: View {
    let feature: PlatformFeature
    @Bindable var model: AppIntentsSettingsModel
    let note: String?

    var body: some View {
        SettingsSection(feature.title, footnote: note) {
            SettingsRow("Let Shortcuts, Siri and Spotlight use Mail", detail: feature.detail, status: model.status,
                        isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
            SettingsRow("Include subjects in results", detail: AppIntentsSettingsModel.subjectsNote,
                        isOn: Binding(get: { model.shareSubjects }, set: { model.setShareSubjects($0) }))
                .disabled(!model.isOn)
            SettingsRow("Let Shortcuts change mail", detail: AppIntentsSettingsModel.changesNote,
                        isOn: Binding(get: { model.allowMailChanges }, set: { model.setAllowMailChanges($0) }))
                .disabled(!model.isOn)
            SettingsRow("Ask before each change",
                        isOn: Binding(get: { model.askBeforeChanges }, set: { model.setAskBeforeChanges($0) }))
                .disabled(!model.isOn || !model.allowMailChanges)
        }
    }
}

private struct FocusFilterSection: View {
    let feature: PlatformFeature
    @Bindable var model: FocusFilterSettingsModel
    let note: String?

    var body: some View {
        SettingsSection(feature.title, footnote: note) {
            SettingsRow("Let Focus filters change what Mail shows", detail: FocusFilterSettingsModel.note,
                        status: model.status,
                        isOn: Binding(get: { model.isOn }, set: { on in Task { await model.setOn(on) } }))
            SettingsRow("This Focus") {
                Button("Ignore this Focus until it changes") { Task { await model.ignoreThisFocus() } }
                    .disabled(!model.canIgnore)
            }
        }
    }
}

private struct SpotlightSection: View {
    let feature: PlatformFeature
    @Bindable var model: SpotlightSettingsModel
    let note: String?
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsSection(feature.title, footnote: note) {
            SettingsRow("Index conversations in Spotlight", detail: feature.detail, status: model.status,
                        isOn: Binding(get: { model.isOn }, set: { on in Task { await model.setOn(on) } }))
                .disabled(model.busy)
            SettingsRow("Include subjects and previews", detail: SpotlightSettingsModel.subjectsNote,
                        status: model.subjects.errorMessage, statusTone: .danger,
                        isOn: Binding(get: { model.subjects.value }, set: { on in Task { await model.setSubjects(on) } }))
                .disabled(!model.canChangeSubjects || !model.isOn)
            SettingsRow("Spotlight index", detail: SpotlightSettingsModel.removeNote,
                        status: model.isOn ? nil : "Turn on indexing to rebuild.") {
                HStack(spacing: theme.space3) {
                    Button("Rebuild") { Task { await model.rebuild() } }
                        .disabled(model.busy || !model.isOn)
                        .help("Rebuild the Spotlight index")
                    Button("Remove all") { Task { await model.removeAll() } }
                        .disabled(model.busy)
                }
            }
        }
        .onAppear { model.start() }
    }
}
