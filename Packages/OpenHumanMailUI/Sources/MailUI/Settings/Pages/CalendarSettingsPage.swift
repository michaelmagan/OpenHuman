import MailFeatures
import MailModel
import MailTheme
import SwiftUI

struct CalendarSettingsPage: View {
    @State private var model: CalendarSettingsModel
    @State private var importingClient = false
    @State private var showsGoogleSteps = false
    @Environment(\.theme) private var theme

    init(environment: AppEnvironment) {
        _model = State(initialValue: CalendarSettingsModel(environment: environment))
    }

    static let accountNote = "This calendar is its own Google permission, asked for on its own page. The inbox's email "
        + "sign-in doesn't change, and if connecting fails, the email keeps working. Disconnect removes Mail's calendar "
        + "access from this Mac only."
    static let clientNote = "The Google client a calendar connects with. By default each calendar uses its inbox's Gmail client."

    var body: some View {
        SettingsPageScaffold(title: "Calendar") {
            if model.calendarInboxes.isEmpty {
                connectionSection
            } else {
                ForEach(model.calendarInboxes) { inbox in accountSection(inbox) }
                clientSection
                if model.calendarInboxes.count > 1 {
                    SettingsSection("Calendar sidebar") {
                        SettingsRow("Show all calendars",
                                    detail: "Every connected calendar's events together, each with its account. Off: "
                                        + "the calendar of the conversation's own account.",
                                    isOn: Binding(get: { model.showAll.value },
                                                  set: { on in Task { await model.showAll.set(on) } }))
                            .disabled(!model.canChangeZone)
                            .accessibilityIdentifier("settings.calendar.showAll")
                    }
                }
            }
            timeZoneSection
            createSection
            schedulingSection
        }
        .onAppear { model.start() }
        .fileImporter(isPresented: $importingClient, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.importFailed()
                return
            }
            Task { await model.importClient(json: data) }
        }
    }

    private func accountSection(_ inbox: InboxCalendar) -> some View {
        let problem = CalendarSettingsModel.rowProblem(inbox)
        let alias = inbox.account.alias.flatMap { $0.isEmpty ? nil : $0 }
        return SettingsSection(alias ?? inbox.account.displayName ?? inbox.account.email,
                               footnote: problem ?? Self.accountNote) {
            SettingsRow(inbox.account.email, status: CalendarSettingsModel.rowStatus(inbox),
                        statusTone: problem == nil ? .secondary : .danger) {
                HStack(spacing: theme.space3) {
                    if inbox.isBusy {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.cancel(inbox) }
                            .accessibilityIdentifier("settings.calendar.cancel")
                    } else if inbox.isConnected {
                        Button("Disconnect", role: .destructive) { Task { await model.disconnect(inbox) } }
                            .accessibilityIdentifier("settings.calendar.disconnect")
                    } else if inbox.needsReconnect {
                        Button("Reconnect") { Task { await model.connect(inbox) } }
                            .accessibilityIdentifier("settings.calendar.reconnect")
                    } else {
                        Button("Connect") { Task { await model.connect(inbox) } }
                            .accessibilityIdentifier("settings.calendar.connectAccount")
                    }
                }
            }
            if let line = model.clientLine(inbox) {
                SettingsRow("Google client", detail: line)
            }
            if model.showsClientPicker, !inbox.isConnected {
                SettingsRow("Connect with", detail: Self.clientNote,
                            selection: Binding(get: { model.connectClient(inbox)?.id ?? "" },
                                               set: { id in model.chooseClient(id, for: inbox) })) {
                    ForEach(model.clients) { client in Text(verbatim: client.title).tag(client.id) }
                }
                .disabled(inbox.isBusy)
            }
            if let refreshed = CalendarSettingsModel.refreshLine(inbox) {
                SettingsRow("Last read", detail: refreshed)
            }
        }
        .accessibilityIdentifier("settings.calendar.account")
    }

    private var clientSection: some View {
        SettingsSection("Google clients") {
            SettingsRow("Google client file", detail: "Another client for a calendar (Google-only files; the same check as "
                            + "the sign-in).", status: model.clientError, statusTone: .danger) {
                Button("Import client JSON…") { importingClient = true }
            }
            SettingsRow("How to get a Google client", detail: GoogleClientGuide.intro) {
                Button(showsGoogleSteps ? "Hide Steps" : "Show Steps") { showsGoogleSteps.toggle() }
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

    private var connectionSection: some View {
        Group {
            SettingsSection("Connection", footnote: connectionFootnote) {
                if model.canConnect {
                    SettingsRow("Connect Google Calendar", status: model.connectError ?? model.status,
                                statusTone: model.connectError == nil ? .secondary : .danger,
                                isOn: Binding(get: { model.isConnected },
                                              set: { on in Task { await model.setConnected(on) } }))
                        .disabled(model.isConnecting)
                        .accessibilityIdentifier("settings.calendar.connect")
                } else if model.isConfigured {
                    SettingsRow("Calendar", status: model.status)
                        .accessibilityIdentifier("settings.calendar.status")
                } else {
                    SettingsRow(CalendarSettingsModel.notConnectedTitle, status: "Nothing here connects to Google.",
                                statusTone: .warning)
                        .accessibilityIdentifier("settings.calendar.notConnected")
                }
            }
        }
    }

    private var schedulingSection: some View {
        SettingsSection("Scheduling replies", footnote: CalendarSettingsModel.schedulingNote) {
            SettingsRow("Suggest times when someone proposes one",
                        isOn: Binding(get: { model.suggestReplyTimes.value },
                                      set: { on in Task { await model.suggestReplyTimes.set(on) } }))
                .accessibilityIdentifier("settings.calendar.suggestReplyTimes")
            SettingsRow("Offer to move conflicting meetings",
                        isOn: Binding(get: { model.offerMoves.value },
                                      set: { on in Task { await model.offerMoves.set(on) } }))
                .accessibilityIdentifier("settings.calendar.offerMoves")
            SettingsRow("Working hours", labelsControl: true) {
                HStack(spacing: 6) {
                    hourMenu("Start", model.workdayStart, range: 0..<23)
                    Text("to")
                    hourMenu("End", model.workdayEnd, range: 1..<25)
                }
            }
            .accessibilityIdentifier("settings.calendar.workingHours")
            SettingsRow("Travel buffer", labelsControl: true) {
                Picker("Travel buffer", selection: Binding(get: { model.bufferMinutes.value },
                                                           set: { value in Task { await model.bufferMinutes.set(value) } })) {
                    ForEach([0, 5, 10, 15, 30, 60], id: \.self) { Text($0 == 0 ? "None" : "\($0) min").tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 120)
            }
            SettingsRow("Accepted times go on the calendar as", labelsControl: true) {
                Picker("Accepted times", selection: Binding(get: { model.acceptedHoldKind.value },
                                                            set: { value in Task { await model.acceptedHoldKind.set(value) } })) {
                    Text("Tentative").tag(CalendarHoldKind.tentative)
                    Text("Busy").tag(CalendarHoldKind.busy)
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 120)
            }
            SettingsRow("Scheduling link", detail: CalendarSettingsModel.linkNote, labelsControl: true) {
                TextField("https://", text: Binding(get: { model.schedulingLink.value ?? "" },
                                                    set: { text in
                                                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                                                        Task { await model.schedulingLink.set(trimmed.isEmpty ? nil : trimmed) }
                                                    }))
                    .textFieldStyle(.roundedBorder).frame(width: Self.zoneMenuWidth)
            }
            .accessibilityIdentifier("settings.calendar.schedulingLink")
        }
    }

    private func hourMenu(_ title: String, _ setting: StoredSetting<Int>, range: Range<Int>) -> some View {
        Picker(title, selection: Binding(get: { setting.value }, set: { value in Task { await setting.set(value) } })) {
            ForEach(Array(range), id: \.self) { hour in Text(String(format: "%02d:00", hour)).tag(hour) }
        }
        .pickerStyle(.menu).labelsHidden().frame(width: 90)
    }

    private var timeZoneSection: some View {
        SettingsSection("Time zones", footnote: CalendarSettingsModel.zoneNote) {
            SettingsRow("Second time zone", status: model.secondTimeZone.errorMessage, statusTone: .danger,
                        labelsControl: true) {
                Picker("Second time zone", selection: Binding(get: { model.secondTimeZone.value ?? "" },
                                                              set: { value in
                                                                  Task { await model.setSecondTimeZone(value.isEmpty ? nil : value) }
                                                              })) {
                    ForEach(model.zoneChoices()) { choice in Text(choice.title).tag(choice.id) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: Self.zoneMenuWidth)
            }
            .disabled(!model.canChangeZone)
        }
    }

    private var createSection: some View {
        SettingsSection("Creating events", footnote: CalendarSettingsModel.createNote) {
            SettingsRow("Create event from email", status: model.createStatus,
                        statusTone: model.canCreateEvents ? .secondary : .warning)
            ForEach(model.createConnectOffers) { inbox in
                SettingsRow(inbox.account.email, status: CalendarSettingsModel.rowProblem(inbox),
                            statusTone: .danger) {
                    Button(CalendarSettingsModel.connectTitle(inbox)) { Task { await model.connect(inbox) } }
                        .disabled(inbox.isBusy)
                        .accessibilityIdentifier("settings.calendar.createConnect")
                }
            }
            SettingsRow("Add a Google Meet link", detail: CalendarSettingsModel.meetNote,
                        status: model.addMeetLink.errorMessage, statusTone: .danger,
                        isOn: Binding(get: { model.addMeetLink.value },
                                      set: { on in Task { await model.setAddMeetLink(on) } }))
                .disabled(!model.canChangeMeetDefault)
                .accessibilityIdentifier("settings.calendar.addMeetLink")
            SettingsRow("Confirm calendar moves in the edit pane",
                        detail: "After you drag or resize an event, the edit pane shows the change with Accept and Cancel. Off applies it at once, with Undo.",
                        status: model.confirmMoves.errorMessage, statusTone: .danger,
                        isOn: Binding(get: { model.confirmMoves.value },
                                      set: { on in Task { await model.setConfirmMoves(on) } }))
                .accessibilityIdentifier("settings.calendar.confirmMoves")
        }
    }

    static let zoneMenuWidth: CGFloat = 220

    private var connectionFootnote: String? {
        if model.canConnect { return CalendarSettingsModel.connectNote }
        return model.isConfigured ? nil : CalendarSettingsModel.unavailableNote
    }
}
