import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct NotificationsSettingsView: View {
    let model: NotificationsSettingsModel
    @Environment(\.theme) private var theme

    public init(model: NotificationsSettingsModel) {
        self.model = model
    }

    public var body: some View {
        SettingsPageScaffold(title: "Notifications") {
            if model.showsPermissionWarning {
                Section {
                    HStack(spacing: theme.space4) {
                        Image(systemName: "bell.slash")
                            .foregroundStyle(theme.textWarning.color)
                            .accessibilityHidden(true)
                        Text("Notifications are off for Mail in System Settings")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Open System Settings") { model.openSystemSettings() }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            SettingsSection("New mail", footnote: NotificationsSettingsModel.newMailNote) {
                ForEach(model.accounts) { row in
                    SettingsRow(row.title, selection: Binding(get: { row.mode },
                                                              set: { mode in Task { await model.setNewMailMode(mode, for: row.id) } })) {
                        ForEach(NewMailNotifications.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            SettingsSection("Also notify me") {
                SettingsRow("Snoozed conversations come back", isOn: Binding(get: { model.preferences.snoozeReturned },
                                                                             set: { on in Task { await model.setSnoozeReturned(on) } }))
                SettingsRow("Drafts ready to review", isOn: Binding(get: { model.preferences.agentDrafts },
                                                                    set: { on in Task { await model.setAgentDrafts(on) } }))
            }
            SettingsSection("Previews") {
                SettingsRow("Show previews (sender and subject)", detail: "Off shows the sender only.",
                            isOn: Binding(get: { !model.preferences.hidePreviews }, set: { model.setShowPreviews($0) }))
            }
            SettingsSection {
                SettingsRow("Test notification", detail: "Shows one now, the way new mail would look.",
                            status: model.testSent ? "Sent" : nil) {
                    Button("Send test notification") { Task { await model.sendTest() } }
                }
            }
        }
        .task { model.start() }
    }
}

public struct SystemGeneralSettingsView: View {
    let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        let system = environment.system
        if let login = system.launchAtLogin {
            SettingsRow("Open at login", detail: login.detail, status: login.errorMessage, statusTone: .danger, labelsControl: false) {
                LoginItemControls(login: login)
            }
            .onAppear { login.refresh() }
        }
        if system.dockBadge != nil {
            let preferences = system.preferences
            SettingsRow("Dock badge", selection: Binding(get: { preferences.dockBadge }, set: { preferences.dockBadge = $0 })) {
                ForEach(DockBadgeSource.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }
}

private struct LoginItemControls: View {
    let login: LaunchAtLoginModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space3) {
            if login.showsSettingsButton {
                Button("Open System Settings") { login.openSystemSettings() }
            }
            Toggle("Open at login", isOn: Binding(get: { login.isOn }, set: { login.setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}
