import MailFeatures
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public struct SendFeedbackSheet: View {
    @Bindable var model: SendFeedbackModel
    let onClose: () -> Void

    public init(model: SendFeedbackModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: SendFeedbackCenter.sheetTitle).font(.title2.weight(.semibold))
            note
            options
            destination
            result
            buttons
        }
        .padding(20)
        .frame(width: 480)
    }

    private var note: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.note)
                .font(.body)
                .frame(height: 84)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Note (optional)")
            if model.note.isEmpty {
                Text(verbatim: "Add a note (optional)")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Include diagnostics (scrubbed)", isOn: $model.includeDiagnostics)
            Toggle(isOn: $model.includeScreenshot) {
                label("Include a screenshot of this window", warning: "may show email", unavailable: model.canIncludeScreenshot ? nil : "not available")
            }
            .disabled(!model.canIncludeScreenshot)
            if model.includeScreenshot, model.canIncludeScreenshot { thumbnail }
            Toggle(isOn: $model.includeThread) {
                label("Include the subject and sender name", warning: "contains email content",
                      unavailable: model.canIncludeThread ? nil : "no conversation open")
            }
            .disabled(!model.canIncludeThread)
            ForEach(model.contributors, id: \.id) { contributor in
                Toggle(isOn: Binding(get: { model.extraSelection[contributor.id] ?? false },
                                     set: { model.extraSelection[contributor.id] = $0 })) {
                    label(contributor.title, warning: contributor.containsEmailContent ? "contains email content" : nil,
                          unavailable: nil)
                }
            }
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder private var thumbnail: some View {
        #if canImport(AppKit)
        if let data = model.screenshotPNG, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .padding(.leading, 20)
                .accessibilityLabel("Screenshot that will be sent")
        }
        #endif
    }

    private func label(_ title: String, warning: String?, unavailable: String?) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
            if let warning { Text(verbatim: warning).font(.caption.weight(.semibold)).foregroundStyle(.orange) }
            if let unavailable { Text(verbatim: "(\(unavailable))").font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var destination: some View {
        switch model.deviceState {
        case .noCLI:
            Text(verbatim: "Tailscale isn't installed on this Mac. Save or share the file instead.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(verbatim: "Looking for your devices…").foregroundStyle(.secondary) }
        case .unavailable(let reason):
            Text(verbatim: reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .ready:
            Picker("Send to", selection: $model.selectedDevice) {
                if model.selectedDevice == nil { Text(verbatim: "Choose a device").tag(String?.none) }
                ForEach(model.devices) { device in Text(verbatim: device.displayName).tag(String?.some(device.target)) }
            }
            .disabled(model.isBusy)
        }
    }

    @ViewBuilder private var result: some View {
        switch model.phase {
        case .sending:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(verbatim: "Sending…").foregroundStyle(.secondary) }
        case .sent(let device):
            Label { Text(verbatim: "Sent to \(device)") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        case .saved(let name):
            Label { Text(verbatim: "Saved \(name)") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        case .failed(let message):
            Text(verbatim: message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case .editing:
            EmptyView()
        }
    }

    private var buttons: some View {
        HStack {
            if model.showsFallbacks {
                Button("Save instead…") { Task { await model.saveInstead() } }
                Button("Share…") { Task { await model.share() } }
            }
            Spacer()
            switch model.phase {
            case .sent, .saved:
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            default:
                Button("Cancel", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                if model.deviceState != .noCLI {
                    Button("Send") { Task { await model.send() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSend)
                }
            }
        }
    }
}
