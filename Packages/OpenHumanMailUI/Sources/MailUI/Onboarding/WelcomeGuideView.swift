import MailFeatures
import MailModel
import MailTheme
import SwiftUI
import UniformTypeIdentifiers

public struct WelcomeGuideView: View {
    @Bindable var model: OnboardingModel
    let onClose: () -> Void
    @Environment(\.theme) private var theme

    public init(model: OnboardingModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space5) {
                    VStack(alignment: .leading, spacing: theme.space2) {
                        Text(model.stepCountText).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                            .accessibilityHidden(true)
                        Text(model.title)
                            .themeFont(model.step == .welcome ? theme.typeDisplayLG : theme.typeTitle)
                            .foregroundStyle(theme.textPrimary.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                    stepContent
                }
                .frame(maxWidth: 440, alignment: .leading)
                .padding(theme.space8)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 520)
        .background(theme.bgWindow.color)
        .task { await model.enter() }
        .onChange(of: model.isFinished) { _, done in if done { onClose() } }
    }

    private var footer: some View {
        HStack(spacing: theme.space4) {
            Button("Close") { model.close() }.keyboardShortcut(.cancelAction).ohLinkButtonStyle()
                .help("Close the guide. Help › Show Welcome Guide opens it again where you left off.")
            dots
            Spacer()
            if !model.isFirst { Button("Back") { Task { await model.back() } }.ohLinkButtonStyle() }
            actions
        }
        .padding(theme.space5)
    }

    @ViewBuilder
    private var skipLink: some View {
        if model.canSkip {
            let note = model.step.laterNote ?? ""
            Button("Skip for now") { Task { await model.skip() } }
                .ohLinkButtonStyle()
                .help(note)
                .accessibilityHint(note)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.step {
        case .ready:
            Button("Start reading") { model.finish() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .help("Everything here can be changed in Settings (⌘,). Help › Show Welcome Guide shows this guide "
                    + "again.")
        case .ai:
            skipLink
            Button(model.ai.saved == nil ? "Save choice" : "Continue") {
                Task { if model.ai.saved == nil { await model.confirmAI() } else { await model.next() } }
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            .disabled(model.ai.isSaving || (model.ai.saved == nil && model.ai.selected == nil))
            .help(AIStepModel.footnote)
        case .calendar:
            if let calendar = model.setupCalendar, calendar.canConnect, !calendar.isConnected {
                Button("Skip for now") { Task { await model.skipCalendar() } }
                    .ohLinkButtonStyle()
                    .help("Skip this inbox's calendar. Connect it later in Settings › Calendar.")
                Button(calendar.needsReconnect ? "Connect again" : "Connect calendar") {
                    Task { await model.connectCalendar() }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(calendar.isBusy)
            } else {
                Button("Continue") { Task { await model.next() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        case .connectEmail:
            EmptyView()
        default:
            skipLink
            Button("Continue") { Task { await model.next() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(model.steps, id: \.self) { step in
                Circle().fill(step == model.step ? theme.accentRing.color : theme.borderControl.color).frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.stepCountText)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .welcome: welcome
        case .calendar: CalendarStep(model: model)
        case .inboxes: inboxesStep
        case .connectEmail:
            if let signIn = model.emailSignIn { ConnectEmailStep(signIn: signIn) }
        case .permissions: PermissionsStep(model: model.permissions)
        case .look: LookStep()
        case .keys: KeysStep(tutorial: model.keys)
        case .ai: AIStep(model: model.ai)
        case .ready: ready
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            Text("First your inboxes, then a few choices you can skip.")
                .themeFont(theme.typeReader).foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inboxesStep: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            Text("Work and personal side by side, with ⌃1 and ⌃2 to switch.")
                .themeFont(theme.typeReader).foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.inboxRows) { row in
                InboxRowView(row: row, showsSync: false, model: model)
            }
            Button("Add another inbox") { Task { await model.addAnotherInbox() } }
                .ohLinkButtonStyle()
                .disabled(!model.canAddAccount)
                .help("Each inbox gets its email first, then its calendar. Add inboxes any time in Settings › "
                    + "Accounts.")
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            Text(model.summaryLine).themeFont(theme.typeReader).foregroundStyle(theme.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.inboxRows) { row in
                InboxRowView(row: row, showsSync: true, model: model)
            }
            if let error = model.fixError {
                Text(error).themeFont(theme.typeBody).foregroundStyle(theme.textDanger.color)
            }
            Label(model.readingLine, systemImage: model.firstMailArrived ? "checkmark.circle.fill" : "tray.and.arrow.down")
                .themeFont(theme.typeBody)
                .foregroundStyle((model.firstMailArrived ? theme.textSuccess : theme.textSecondary).color)
        }
    }
}

private struct InboxRowView: View {
    let row: InboxRow
    let showsSync: Bool
    let model: OnboardingModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            Text(verbatim: row.account.email).themeFont(theme.typeBodyStrong).foregroundStyle(theme.textPrimary.color)
            Label(row.emailText, systemImage: row.email == .connected ? "checkmark.circle.fill" : "exclamationmark.circle")
                .themeFont(theme.typeMeta)
                .foregroundStyle((row.email == .connected ? theme.textSuccess : theme.textWarning).color)
            Label(row.calendarText, systemImage: calendarIcon)
                .themeFont(theme.typeMeta)
                .foregroundStyle(calendarTone.color)
            if showsSync, let line = row.syncLine {
                Label(line, systemImage: "arrow.triangle.2.circlepath").themeFont(theme.typeMeta)
                    .foregroundStyle(theme.textSecondary.color)
            }
            if row.email == .needsSignIn || row.calendarCanBeFixed {
                HStack(spacing: theme.space3) {
                    if row.email == .needsSignIn {
                        Button("Sign in again") { Task { await model.signInAgain(row.id) } }
                    }
                    if row.calendarCanBeFixed {
                        Button("Connect calendar") { Task { await model.fixCalendar(row.id) } }
                            .accessibilityLabel("Connect calendar for \(row.account.email)")
                    }
                }
            }
        }
        .padding(theme.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgSunken.color))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private var calendarIcon: String {
        switch row.calendar {
        case .connected: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .notConnected: "circle"
        case .needsReconnect: "exclamationmark.circle"
        case .unavailable: "calendar"
        }
    }

    private var calendarTone: ThemeColor {
        switch row.calendar {
        case .connected: theme.textSuccess
        case .needsReconnect: theme.textWarning
        case .skipped, .notConnected, .unavailable: theme.textSecondary
        }
    }
}

private struct CalendarStep: View {
    @Bindable var model: OnboardingModel
    @Environment(\.theme) private var theme
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            if let calendar = model.setupCalendar, calendar.canConnect {
                Text(OnboardingModel.calendarWhat).themeFont(theme.typeReader).foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showsDetails.toggle() } label: {
                    HStack(spacing: theme.space2) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(showsDetails ? 90 : 0))
                            .accessibilityHidden(true)
                        Text("What Mail does with it").themeFont(theme.typeBody)
                    }
                    .foregroundStyle(theme.textSecondary.color)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsDetails ? "Expanded" : "Collapsed")
                if showsDetails {
                    point(OnboardingModel.calendarCreate, icon: "hand.raised")
                    point(OnboardingModel.calendarScope, icon: "video")
                    point(OnboardingModel.calendarSeparate, icon: "lock")
                }
                if model.showsCalendarClientChoice {
                    Picker("Connect with", selection: Binding(get: { model.calendarClientChoice ?? "" },
                                                              set: { model.calendarClientChoice = $0.isEmpty ? nil : $0 })) {
                        ForEach(model.calendarClientChoices) { choice in Text(verbatim: choice.title).tag(choice.id) }
                    }
                    .fixedSize()
                    .disabled(calendar.isBusy)
                }
                if calendar.isBusy {
                    HStack(spacing: theme.space2) {
                        ProgressView().controlSize(.small)
                        Text("Finish in your browser; Google asks about the calendar only.")
                            .themeFont(theme.typeBody).foregroundStyle(theme.textSecondary.color)
                    }
                } else if calendar.isConnected {
                    Label("Calendar connected", systemImage: "checkmark.circle.fill").themeFont(theme.typeBody)
                        .foregroundStyle(theme.textSuccess.color)
                }
                if let error = calendar.errorMessage {
                    Text(error).themeFont(theme.typeBody).foregroundStyle(theme.textDanger.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(OnboardingModel.calendarUnavailable).themeFont(theme.typeReader)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func point(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).themeFont(theme.typeBody).foregroundStyle(theme.textSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ConnectEmailStep: View {
    @Bindable var signIn: SignInModel
    @State private var importing = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            Text(Self.intro).themeFont(theme.typeReader).foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            clientRow
            if signIn.phase == .needsClient {
                Text(Self.noClient).themeFont(theme.typeBody).foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Import client file…") { importing = true }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else if signIn.phase == .signingIn {
                HStack(spacing: theme.space2) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in with Google in your browser.").themeFont(theme.typeBody)
                        .foregroundStyle(theme.textSecondary.color)
                    Spacer()
                    Button("Cancel") { signIn.cancel() }
                }
            } else {
                Button { signIn.signIn() } label: {
                    Text("Sign in with Google").themeFont(theme.typeBodyStrong).frame(minHeight: 24)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled(!signIn.canSignIn)
            }
            if signIn.showsKeychainNote {
                Text(signIn.keychainNote).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = signIn.clientWarning {
                Text(warning).themeFont(theme.typeBody).foregroundStyle(theme.textWarning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = signIn.errorMessage {
                let parts = SignInView.splitDetails(error)
                Text(parts.message).themeFont(theme.typeBody).foregroundStyle(theme.textDanger.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let details = parts.details {
                    Text(verbatim: "Details: \(details)").themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
                        .textSelection(.enabled)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                signIn.importFailed()
                return
            }
            Task { await signIn.importClient(json: data) }
        }
    }

    private var clientRow: some View {
        HStack(spacing: theme.space3) {
            if signIn.showsClientPicker {
                Picker("Google client for this inbox", selection: Binding(get: { signIn.selectedClient?.id ?? "" },
                                                                          set: { id in Task { await signIn.selectClient(id) } })) {
                    ForEach(signIn.clients) { client in Text(verbatim: client.title).tag(client.id) }
                }
                .fixedSize()
                .disabled(signIn.phase != .ready)
            } else if let label = signIn.clientLabel {
                Text(verbatim: label).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
            }
            Spacer(minLength: 0)
            if signIn.canImportAnotherClient {
                Button("Import another client file…") { importing = true }.ohLinkButtonStyle()
            }
        }
    }

    static let intro = "Sign in with your next Google account; Mail asks Google for your email only, and the calendar "
        + "comes next."
    static let noClient = "Import a Google client file to add this inbox; Settings › Accounts shows how to get one."
}

private struct PermissionsStep: View {
    let model: PermissionsModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space4) {
            Text("Nothing is asked until you press a button, and saying no switches off only that one thing.")
                .themeFont(theme.typeReader).foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.guideRows) { row in
                VStack(alignment: .leading, spacing: theme.space2) {
                    HStack {
                        Text(row.info.title).themeFont(theme.typeBodyStrong).foregroundStyle(theme.textPrimary.color)
                        Spacer()
                        Text(row.state.text).themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
                    }
                    Text(row.info.why).themeFont(theme.typeBody).foregroundStyle(theme.textSecondary.color)
                    if row.showsWhatBreaks {
                        Text(row.whatBreaks).themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
                    }
                    action(row)
                }
                .padding(theme.space4)
                .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgSunken.color))
                .accessibilityElement(children: .contain)
            }
        }
    }

    @ViewBuilder
    private func action(_ row: PermissionsModel.Row) -> some View {
        switch row.id {
        case .gmail: EmptyView()
        case .notifications:
            if row.state == .notAsked { Button(row.info.actionTitle) { Task { await model.requestNotifications() } } }
        case .openAtLogin:
            Toggle("Open at login", isOn: Binding(get: { row.state == .granted || row.state == .needsApproval },
                                                  set: { model.setOpenAtLogin($0) }))
                .toggleStyle(.switch)
        case .onDeviceAI: EmptyView()
        }
    }
}

private struct LookStep: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var store = themes
        VStack(alignment: .leading, spacing: theme.space4) {
            Picker("Appearance", selection: $store.preferences.mode) {
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
                Text("System").tag(AppearanceMode.system)
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack(spacing: theme.space3) {
                ForEach(store.library.accentIDs, id: \.self) { id in
                    let accent = store.resolve(ThemePreferences(lightThemeID: store.resolved.themeID,
                                                                darkThemeID: store.resolved.themeID, accentID: id),
                                               appearance: store.resolved.appearance)
                    let isSelected = store.resolved.accentID == id
                    Button { store.preferences.accentID = id } label: {
                        VStack(spacing: 4) {
                            Circle().fill(accent.accentFill.color).frame(width: 24, height: 24)
                                .overlay(Circle().stroke(isSelected ? theme.accentRing.color : .clear, lineWidth: 2).padding(-3))
                            Text(id.prefix(1).uppercased() + id.dropFirst()).themeFont(theme.typeMeta)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(id) accent\(isSelected ? ", selected" : "")")
                }
            }
        }
    }
}

private struct KeysStep: View {
    let tutorial: KeysTutorial
    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space4) {
            Text(KeysTutorial.layoutNote).themeFont(theme.typeBody).foregroundStyle(theme.textSecondary.color)
            HStack(spacing: theme.space5) {
                ForEach(Array(KeysTutorial.sampleSplits.enumerated()), id: \.offset) { index, name in
                    Text(name).themeFont(index == tutorial.split ? theme.typeBodyStrong : theme.typeBody)
                        .foregroundStyle((index == tutorial.split ? theme.textPrimary : theme.textTertiary).color)
                        .accessibilityAddTraits(index == tutorial.split ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tutorial.rows.enumerated()), id: \.offset) { index, row in
                    Text(row).themeFont(theme.typeBody).foregroundStyle(theme.textPrimary.color)
                        .padding(.horizontal, theme.space3).frame(height: 32, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == tutorial.cursor ? theme.accentFill.color.opacity(0.14) : .clear)
                }
            }
            .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgSunken.color))
            ForEach(KeysTutorial.prompts) { prompt in
                let done = tutorial.completed.contains(prompt.id)
                Label(prompt.text, systemImage: done ? "checkmark.circle.fill" : "circle")
                    .themeFont(theme.typeBody)
                    .foregroundStyle(done ? theme.textSuccess.color : (tutorial.current == prompt ? theme.textPrimary.color : theme.textTertiary.color))
            }
            Button("") { tutorial.press("cmd-k") }.keyboardShortcut("k", modifiers: .command).opacity(0).frame(width: 0, height: 0)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(characters: CharacterSet(charactersIn: "jez/")) { press in
            tutorial.press(press.characters.lowercased())
            return .handled
        }
        .onKeyPress(.tab) {
            guard tutorial.current?.key == "tab" else { return .ignored }
            tutorial.press("tab")
            return .handled
        }
        .onAppear { focused = true }
    }
}

private struct AIStep: View {
    @Bindable var model: AIStepModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space4) {
            Text(AIStepModel.explanation).themeFont(theme.typeReader).foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = model.unavailableReason {
                fallbacks(reason: reason)
            }
            ForEach(model.options) { option in
                Button { model.selected = option.choice } label: {
                    HStack(alignment: .top, spacing: theme.space3) {
                        Image(systemName: model.selected == option.choice ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(option.isEnabled ? theme.accentFill.color : theme.textTertiary.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title).themeFont(theme.typeBodyStrong)
                                .foregroundStyle(option.isEnabled ? theme.textPrimary.color : theme.textTertiary.color)
                            Text(option.detail).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                            if let reason = option.disabledReason, model.unavailableReason == nil {
                                Text(reason).themeFont(theme.typeMeta).foregroundStyle(theme.textWarning.color)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(theme.space3)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgSunken.color))
                }
                .buttonStyle(.plain)
                .disabled(!option.isEnabled || model.saved != nil)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(model.selected == option.choice ? .isSelected : [])
            }
            if let sample = model.sample {
                VStack(alignment: .leading, spacing: theme.space2) {
                    Text(sample.text).themeFont(theme.typeReader).foregroundStyle(theme.textPrimary.color)
                    Label(sample.badge, systemImage: "desktopcomputer").themeFont(theme.typeCaption)
                        .foregroundStyle(theme.textTertiary.color)
                }
                .padding(theme.space3)
                .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgSunken.color))
            } else if let note = model.sampleNote {
                Text(note).themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
            }
            if let error = model.errorMessage {
                Text(error).themeFont(theme.typeBody).foregroundStyle(theme.textDanger.color)
            }
        }
    }

    private func fallbacks(reason: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AIStepModel.unavailableTitle).themeFont(theme.typeBodyStrong).foregroundStyle(theme.textPrimary.color)
                Text(reason).themeFont(theme.typeMeta).foregroundStyle(theme.textWarning.color)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.fallbacks) { option in
                    if option.id != model.fallbacks.first?.id {
                        Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
                            .accessibilityHidden(true)
                    }
                    fallbackRow(option)
                }
            }
            .padding(.horizontal, theme.space3)
            .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgSunken.color))
        }
    }

    private func fallbackRow(_ option: AIFallbackOption) -> some View {
        HStack(spacing: theme.space3) {
            Image(systemName: option.choice == .localModel ? "arrow.down.circle" : "arrow.up.right")
                .foregroundStyle((option.isEnabled ? theme.textSecondary : theme.textTertiary).color)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title).themeFont(theme.typeBodyStrong)
                    .foregroundStyle((option.isEnabled ? theme.textPrimary : theme.textTertiary).color)
                Text(option.detail).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if option.isEnabled {
                Button(option.actionTitle) { model.choose(option.choice) }
                    .accessibilityLabel(option.title)
            }
        }
        .padding(.vertical, theme.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
