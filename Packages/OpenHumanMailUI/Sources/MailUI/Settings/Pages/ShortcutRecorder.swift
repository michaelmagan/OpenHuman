import MailActions
import MailTheme
import Observation
import SwiftUI
#if os(macOS)
#if canImport(AppKit)
import AppKit
#endif
#endif

struct ShortcutRecorder: View {
    let keys: String
    let label: String
    let record: @MainActor (_ key: String, _ modifiers: KeyBinding.Modifiers) -> Void
    @State private var catcher = KeyCatcher()
    @Environment(\.theme) private var theme

    var body: some View {
        Button { catcher.start(record) } label: {
            Group {
                if catcher.isRecording {
                    Text("Press the keys…").font(.system(size: NativeMetrics.Text.secondary)).foregroundStyle(.secondary)
                } else {
                    NativeKeycap(keys)
                }
            }
            .padding(.horizontal, theme.space2)
            .frame(minWidth: ShortcutRecorderMetrics.minWidth, minHeight: ShortcutRecorderMetrics.height)
            .background(.background, in: RoundedRectangle(cornerRadius: theme.radiusMD))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusMD)
                .strokeBorder(catcher.isRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                              lineWidth: catcher.isRecording ? ShortcutRecorderMetrics.recordingBorder : theme.borderWidthControl))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Click, then press the new keys")
        .accessibilityLabel(label)
        .accessibilityValue(catcher.isRecording ? "Waiting for the new keys" : keys)
        .accessibilityHint("Press, then press the new keys. Escape cancels.")
        .onDisappear { catcher.stop() }
    }
}

enum ShortcutRecorderMetrics {
    static let minWidth: CGFloat = 120
    static let height: CGFloat = 24
    static let recordingBorder: CGFloat = 2
}

@MainActor @Observable
final class KeyCatcher {
    private(set) var isRecording = false
    @ObservationIgnored private var monitor: Any?

    func start(_ caught: @escaping @MainActor (String, KeyBinding.Modifiers) -> Void) {
        stop()
        #if os(macOS)
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event, caught) ?? false }
            return consumed ? nil : event
        }
        #endif
    }

    func stop() {
        #if os(macOS)
        if let monitor { NSEvent.removeMonitor(monitor) }
        #endif
        monitor = nil
        isRecording = false
    }

    isolated deinit {
        #if os(macOS)
        if let monitor { NSEvent.removeMonitor(monitor) }
        #endif
    }

    #if os(macOS)
    static let escapeKeyCode: UInt16 = 53

    private func handle(_ event: NSEvent, _ caught: @MainActor (String, KeyBinding.Modifiers) -> Void) -> Bool {
        stop()
        guard event.type == .keyDown else { return false }
        let modifiers = Self.modifiers(event.modifierFlags)
        if event.keyCode == Self.escapeKeyCode, modifiers.isEmpty { return true }
        caught(event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "", modifiers)
        return true
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyBinding.Modifiers {
        var modifiers: KeyBinding.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
    #endif
}
