import MailFeatures
import SwiftUI

public struct DevFeedbackSettingsView: View {
    @Bindable var settings: DevFeedbackSettings
    let availability: DevFeedbackAvailability
    let feedbackFolder: String
    let onRevealFolder: (() -> Void)?

    public init(settings: DevFeedbackSettings, availability: DevFeedbackAvailability, feedbackFolder: String,
                onRevealFolder: (() -> Void)? = nil) {
        self.settings = settings
        self.availability = availability
        self.feedbackFolder = feedbackFolder
        self.onRevealFolder = onRevealFolder
    }

    public var body: some View {
        if availability.isAvailable {
            SettingsSection("Developer feedback (temporary)") {
                SettingsRow("Developer feedback mode", detail: "Adds the Developer menu: Test checklist… (⌃⌥⌘T) and Give "
                            + "feedback… (⌃⌥⌘F). Temporary, for dogfooding; nothing leaves this Mac unless you send it.",
                            isOn: $settings.isEnabled)
                SettingsRow("Receiving device's Tailscale name", status: targetProblem, statusTone: .warning, labelsControl: true) {
                    TextField("Receiving device's Tailscale name", text: $settings.taildropTarget,
                              prompt: Text(verbatim: DevFeedbackCommands.targetPlaceholder))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                SettingsRow("Feedback folder", detail: feedbackFolder) {
                    if let onRevealFolder { Button("Show in Finder", action: onRevealFolder) }
                }
            }
        }
    }

    private var targetProblem: String? {
        guard !settings.taildropTarget.isEmpty, DevFeedbackCommands.resolvedTarget(settings.taildropTarget) == nil else { return nil }
        return "Use the device name only: letters, digits, dots and hyphens."
    }
}

extension View {
    func devCheckbox() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        self
        #endif
    }
}
