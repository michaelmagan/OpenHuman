import MailFeatures
import MailModel
import MailTheme
import SwiftUI

struct SidebarSettingsPage: View {
    @State private var model: SidebarSettingsModel
    let router: AppRouter

    init(environment: AppEnvironment) {
        self.init(model: SidebarSettingsModel(environment: environment), router: environment.router)
    }

    init(model: SidebarSettingsModel, router: AppRouter) {
        _model = State(initialValue: model)
        self.router = router
    }

    var body: some View {
        SettingsPageScaffold(title: SettingsPageID.sidebar.title) {
            SettingsSection(SidebarSettingsModel.accountsTitle) {
                SettingsRow(SidebarSettingsModel.allInboxesTitle, detail: SidebarSettingsModel.allInboxesNote,
                            status: SidebarSettingsModel.allInboxesStatus(accountCount: router.accounts.count),
                            isOn: Binding(get: { model.allInboxes.value },
                                          set: { on in Task { await model.allInboxes.set(on) } }))
                    .disabled(!model.canEdit)
            }
            SettingsSection(SidebarSettingsModel.foldersTitle, footnote: SidebarSettingsModel.foldersNote, compact: true) {
                ForEach(model.rows) { row in
                    SidebarFolderRow(row: row, isOn: Binding(get: { model.isShown(row.folder) },
                                                             set: { on in Task { await model.setShown(row.folder, on) } }))
                        .disabled(!model.canEdit)
                }
            }
            SettingsErrorLine(text: model.errorMessage)
        }
        .task { model.start() }
    }
}

private struct SidebarFolderRow: View {
    let row: SidebarSettingsModel.FolderRow
    @Binding var isOn: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: theme.space4) {
            Image(systemName: row.folder.symbol)
                .font(.system(size: SettingsMetrics.sidebarIconSize))
                .foregroundStyle(isOn ? HierarchicalShapeStyle.secondary : .tertiary)
                .frame(width: theme.space6)
                .accessibilityHidden(true)
            Text(row.folder.title)
                .foregroundStyle(isEnabled ? HierarchicalShapeStyle.primary : .tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            if !row.keycaps.isEmpty {
                KeycapRow(keycaps: row.keycaps)
            } else if let route = row.route {
                Text(route)
                    .font(.system(size: NativeMetrics.Text.secondary).monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            SettingsSwitch(title: row.folder.title, isOn: $isOn)
                .padding(.leading, theme.space3)
                .accessibilityLabel(Text(row.folder.title))
                .accessibilityHint(Text(row.spokenHint))
                .accessibilityIdentifier("settings.sidebar.\(row.id)")
        }
        .frame(minHeight: SettingsMetrics.compactRowMinHeight)
    }
}
