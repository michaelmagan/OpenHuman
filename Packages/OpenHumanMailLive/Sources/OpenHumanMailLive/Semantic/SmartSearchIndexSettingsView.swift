import MailUI
import OpenHumanSemanticIndex
import SwiftUI

public struct SmartSearchIndexSettingsView: View {
    let services: SemanticServices
    @State private var progress = SemanticIndexProgress(phase: .off(.disabled))
    @State private var isOn = false
    @State private var working = false

    static let detail = "Finds mail by meaning, not just matching words. Builds an index of your mail on this Mac. Nothing leaves this Mac."
    static let deleteNote = "Search keeps working without it. Rebuild it any time."

    public init(services: SemanticServices) {
        self.services = services
    }

    public var body: some View {
        SettingsSection("Smart search", footnote: Self.deleteNote) {
            SettingsRow("Smart search index", detail: Self.detail,
                        isOn: Binding(get: { isOn }, set: { on in
                            isOn = on
                            services.setIndexSwitch(on)
                        }))
            SettingsRow("Status", status: Self.status(progress), statusTone: Self.tone(progress.phase))
            SettingsRow("Index on this Mac", detail: Self.size(progress.bytesOnDisk)) {
                HStack {
                    Button("Rebuild index") { run { await services.rebuild() } }
                        .disabled(!isOn || working)
                    Button("Delete index") {
                        isOn = false
                        run { await services.deleteIndex() }
                    }
                    .disabled(working)
                }
            }
        }
        .task {
            isOn = services.indexSwitch
            for await update in services.progress.updates() { progress = update }
        }
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        working = true
        Task { @MainActor in
            await action()
            working = false
        }
    }

    static func status(_ progress: SemanticIndexProgress) -> String {
        let count = progress.embedded.formatted()
        switch progress.phase {
        case .off(.aiOff): return "Off: AI is turned off in Settings › AI"
        case .off(.noProvider): return "Off: no on-device model on this Mac"
        case .off(.needsDownload): return "Off: the model needs a download"
        case .off(.disabled): return "Off"
        case .ready: return "Ready · \(count) messages · \(size(progress.bytesOnDisk))"
        case .indexing:
            let percent = Int((progress.fraction * 100).rounded(.down))
            return "Indexing · \(percent)% (\(count) of \(progress.eligible.formatted()))"
        case .rebuilding(let fraction): return "Rebuilding · \(Int((fraction * 100).rounded(.down)))%"
        case .paused(.lowPower): return "Paused: Low Power Mode is on"
        case .paused(.hot): return "Paused: the Mac is hot"
        case .paused(.userActive): return "Paused while you search"
        case .paused(.lowDisk): return "Paused: not enough free disk space"
        case .failed: return "Couldn't open the index · Rebuild"
        }
    }

    static func tone(_ phase: SemanticIndexProgress.Phase) -> SettingsTone {
        switch phase {
        case .paused: return .warning
        case .failed: return .danger
        default: return .secondary
        }
    }

    static func size(_ bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "Not built"
    }
}
