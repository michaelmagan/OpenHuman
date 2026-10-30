import MailFeatures
import MailTheme
import SwiftUI

struct UpdateCheckSettingsSection: View {
    let center: UpdateCheckCenter
    @Environment(\.theme) private var theme

    var body: some View {
        if let updater = center.updater {
            updaterSection(updater)
        } else {
            feedSection
        }
    }

    private func updaterSection(_ updater: any SoftwareUpdater) -> some View {
        SettingsSection("Updates", footnote: UpdateCheck.updaterPrivacyNote) {
            SettingsRow(UpdateCheckCenter.settingsTitle, detail: center.versionLine, status: center.lastCheckedLine) {
                Button("Check Now") { center.begin() }
                    .accessibilityLabel(Text(verbatim: UpdateCheckCenter.settingsTitle))
            }
            SettingsRow(UpdateCheckCenter.automaticTitle, detail: UpdateCheck.automaticNote,
                        isOn: Binding(get: { updater.automaticallyChecksForUpdates },
                                      set: { updater.automaticallyChecksForUpdates = $0 }))
        }
    }

    private var feedSection: some View {
        SettingsSection("Updates", footnote: UpdateCheck.privacyNote) {
            SettingsRow(UpdateCheckCenter.settingsTitle, detail: detail, status: center.summary, statusTone: tone) {
                HStack(spacing: theme.space3) {
                    if center.isChecking {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(UpdateCheck.checking.headline)
                    }
                    if let release = center.available {
                        Button("Download") { center.download() }
                            .help("Opens the release page in your browser")
                            .accessibilityLabel(Text(verbatim: "Download version \(release.version.displayName)"))
                            .accessibilityHint(Text(verbatim: "Opens the release page in your browser"))
                    }
                    Button(checkTitle) { center.start() }
                        .disabled(center.isChecking)
                        .accessibilityLabel(Text(verbatim: UpdateCheckCenter.settingsTitle))
                }
            }
            if let reason = center.updatesUnavailable {
                SettingsRow(UpdaterPolicy.unavailableTitle, detail: reason.explanation)
            }
        }
    }

    var checkTitle: String { center.result == nil ? "Check Now" : "Check Again" }

    private var detail: String {
        [center.versionLine, center.earlyDevelopmentLine].compactMap { $0 }.joined(separator: " ")
    }

    private var tone: SettingsTone {
        switch center.message?.tone {
        case .good?, .news?: .success
        case .attention?: .warning
        case .neutral?, nil: .secondary
        }
    }
}
