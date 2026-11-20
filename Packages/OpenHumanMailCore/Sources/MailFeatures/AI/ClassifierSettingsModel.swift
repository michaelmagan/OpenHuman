import Foundation
import Observation
import OpenHumanAI

public enum LocalModelStatus: Sendable, Hashable {
    case notDownloaded(partialBytes: Int64)
    case downloading(bytesDone: Int64, bytesTotal: Int64)
    case verifying
    case ready
    case failed(String)
}

public struct LeftoverLocalModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let bytes: Int64

    public init(id: String, name: String, bytes: Int64) {
        self.id = id
        self.name = name
        self.bytes = bytes
    }
}

public protocol LocalClassifierModelPort: AnyObject, Sendable {
    var writingModels: [any LocalClassifierModelPort] { get }
    var isWritingDownload: Bool { get }
    var modelName: String { get }
    var classifierID: AIProviderID { get }
    var sizeBytes: Int64 { get }
    var memoryBytes: Int64 { get }
    var licence: String { get }
    var unsupportedReason: String? { get }
    func directoryPath() async -> String
    func status() async -> LocalModelStatus
    func download(confirmedSizeBytes: Int64) async -> AsyncStream<LocalModelStatus>
    func cancel() async
    func delete() async throws
    func useDirectory(_ path: String?) async throws
    func leftoverModels() async -> [LeftoverLocalModel]
    func deleteLeftover(id: String) async throws
}

extension LocalClassifierModelPort {
    public var writingModels: [any LocalClassifierModelPort] { [] }
    public var isWritingDownload: Bool { false }
}

@MainActor @Observable
public final class ClassifierSettingsModel {
    public let center: AICenter
    public let port: (any LocalClassifierModelPort)?
    public private(set) var status: LocalModelStatus?
    public private(set) var directory: String?
    public private(set) var leftovers: [LeftoverLocalModel] = []
    public private(set) var error: String?
    @ObservationIgnored public var onChange: (@MainActor () async -> Void)?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    public static let title = "High-accuracy model (optional)"
    public static let footnote = "Triage and auto labels use Apple's on-device model and Mail's rules unless you choose "
        + "this larger model. It sorts mail more accurately but is slower and needs much more memory. It runs on this "
        + "Mac; email text never leaves it. Download it here, then choose it under Model for each feature."
    public static let lowPowerTitle = "Also in Low Power Mode"
    public static let lowPowerDetail = "Off: the downloaded model pauses in Low Power Mode and while the Mac is hot."

    public init(center: AICenter, port: (any LocalClassifierModelPort)?) {
        self.center = center
        self.port = port
        if port?.isWritingDownload == true {
            onChange = { [weak center] in
                await center?.refreshProviders()
                center?.preparation.settingsChanged()
            }
        }
    }

    isolated deinit { downloadTask?.cancel() }

    public var preference: ClassifierPreference {
        get { center.settings.classifier }
        set {
            guard newValue == .appleModel || port != nil else { return }
            let id = newValue == .localModel ? port?.classifierID : nil
            change { $0.useClassifier(id ?? .appleSystemClassifier) }
            Task { await onChange?() }
        }
    }

    public var allowLowPower: Bool {
        get { center.settings.localClassifierInLowPowerMode }
        set { change { $0.localClassifierInLowPowerMode = newValue } }
    }

    public var downloadTitle: String {
        guard let port else { return "Download classifier model" }
        if port.isWritingDownload { return "Download (\(Self.sizeText(port.sizeBytes)))" }
        return "Download classifier model (\(Self.sizeText(port.sizeBytes)))"
    }

    public var requirementsText: String? {
        guard let port else { return nil }
        if port.isWritingDownload {
            let memory = String(format: "%.1f GiB", Double(port.memoryBytes) / 1_073_741_824)
            return "\(Self.sizeText(port.sizeBytes)) of disk space and about \(memory) of memory during use."
        }
        return "Needs \(Self.sizeText(port.sizeBytes)) of disk space and \(Self.memoryText(port.memoryBytes)) of "
            + "memory while it works, so other apps can slow down. It takes over a minute to load, then a few "
            + "seconds for each email."
    }

    public var unsupportedText: String? {
        port?.unsupportedReason.map { "This Mac can't run it. " + $0 }
    }

    public var isDownloading: Bool {
        switch status {
        case .downloading, .verifying: true
        default: false
        }
    }

    public var canDownload: Bool {
        guard let port, port.unsupportedReason == nil else { return false }
        switch status {
        case .notDownloaded, .failed: return true
        default: return false
        }
    }

    public var isReady: Bool { status == .ready }

    public var statusText: String {
        guard let port else { return "The downloaded model isn't part of this copy of Mail." }
        switch status {
        case nil: return "Checking…"
        case .notDownloaded(let partial) where partial > 0:
            return "Stopped at \(Self.sizeText(partial)) of \(Self.sizeText(port.sizeBytes)). Download again to resume."
        case .notDownloaded: return unsupportedText ?? "Not downloaded. Nothing is downloaded until you click."
        case .downloading(let done, let total):
            let percent = total > 0 ? Int((Double(done) / Double(total) * 100).rounded(.down)) : 0
            return "Downloading… \(percent)%"
        case .verifying: return "Checking the download…"
        case .ready where port.isWritingDownload: return "Downloaded. Available for summaries and quick replies."
        case .ready: return preference == .localModel ? "Downloaded. Used for triage and auto labels."
            : "Downloaded. Not used until you choose it for Triage and auto labels."
        case .failed(let why): return why
        }
    }

    public var progress: Double? {
        if case .downloading(let done, let total) = status, total > 0 { return min(1, Double(done) / Double(total)) }
        return nil
    }

    public func refresh() async {
        guard let port else { return }
        status = await port.status()
        directory = await port.directoryPath()
        leftovers = await port.leftoverModels()
    }

    public func download() {
        guard let port, canDownload, downloadTask == nil else { return }
        error = nil
        status = .downloading(bytesDone: 0, bytesTotal: port.sizeBytes)
        downloadTask = Task { [weak self] in
            let stream = await port.download(confirmedSizeBytes: port.sizeBytes)
            for await next in stream {
                guard let self else { return }
                self.status = next
            }
            guard let self else { return }
            self.downloadTask = nil
            self.status = await port.status()
            await self.onChange?()
        }
    }

    public func cancel() async {
        await port?.cancel()
        downloadTask?.cancel()
        downloadTask = nil
        await refresh()
    }

    public func delete() async {
        guard let port else { return }
        do {
            try await port.delete()
        } catch {
            self.error = "The model couldn't be deleted."
        }
        await refresh()
        await onChange?()
    }

    public func deleteLeftover(_ id: String) async {
        guard let port, leftovers.contains(where: { $0.id == id }) else { return }
        do {
            try await port.deleteLeftover(id: id)
            error = nil
        } catch {
            self.error = "The old model couldn't be deleted."
        }
        await refresh()
    }

    public func useDirectory(_ path: String?) async {
        guard let port, !isDownloading else { return }
        do {
            try await port.useDirectory(path)
            change { $0.modelsDirectory = path }
            await center.refreshProviders()
            center.preparation.settingsChanged()
        } catch {
            self.error = "That folder can't be used."
        }
        await refresh()
        await onChange?()
    }

    public static func leftoverText(_ leftover: LeftoverLocalModel) -> String {
        "Mail no longer uses this model. Its files still take \(sizeText(leftover.bytes)) on this Mac until you "
            + "delete them."
    }

    public static func sizeText(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 0.95 && gigabytes < 1.05 { return "about 1 GB" }
        if gigabytes >= 1 { return String(format: "about %.1f GB", gigabytes) }
        return String(format: "about %.0f MB", Double(bytes) / 1_000_000)
    }

    public static func memoryText(_ bytes: Int64) -> String {
        String(format: "about %.0f GB", max(1, (Double(bytes) / 1_000_000_000).rounded()))
    }

    private func change(_ mutate: (inout AISettings) -> Void) {
        do {
            try center.update(mutate)
            error = nil
        } catch {
            self.error = "The setting couldn't be saved."
        }
    }
}
