import Foundation
import MailFeatures
import OpenHumanAI
import OpenHumanAIMLX
import OpenHumanAIMLXRuntime
import OpenHumanAIModelStore
import Synchronization

public final class ClassifierServices: LocalClassifierModelPort, Sendable {
    @MainActor public static var current: ClassifierServices?

    private let registry: ProviderRegistry
    private let settings: AISettingsBox
    private let service: Mutex<LocalClassifierService>

    private let manifest: ModelManifest
    private let isWritingModel: Bool
    private let writingServices: [ClassifierServices]
    public var writingModels: [any LocalClassifierModelPort] { writingServices }

    @MainActor @discardableResult
    static func install(registry: ProviderRegistry, settings: AISettingsBox) -> ClassifierServices {
        let services = ClassifierServices(registry: registry, settings: settings)
        current = services
        return services
    }

    init(registry: ProviderRegistry, settings: AISettingsBox, manifest: ModelManifest = LocalClassifierModels.offered) {
        self.registry = registry
        self.settings = settings
        self.manifest = manifest
        isWritingModel = LocalWritingModels.all.contains { $0.id == manifest.id }
        writingServices = isWritingModel ? [] : LocalWritingModels.all.map {
            ClassifierServices(registry: registry, settings: settings, manifest: $0)
        }
        let made = Self.makeService(settings: settings, manifest: manifest, writing: isWritingModel)
        service = Mutex(made)
        register(made)
    }

    private func register(_ made: LocalClassifierService) {
        if isWritingModel {
            registry.register(made.provider)
        } else {
            registry.register(classifier: made.classifier)
        }
        made.provider.startMonitoringMemoryPressure()
    }

    private static func makeService(settings: AISettingsBox, manifest: ModelManifest, writing: Bool) -> LocalClassifierService {
        let root = settings.current.modelsDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? ModelStore.defaultRoot
        let gate = LocalClassifierGate(
            requiredMemoryBytes: LocalClassifierModels.requirements(for: manifest).machineMemoryBytes,
            allowsLowPowerMode: { settings.current.localClassifierInLowPowerMode })
        return LocalClassifierService(
            manifest: manifest, rootDirectory: root, runtime: MLXLocalModelRuntime(),
            allowsLoading: {
                settings.current.enabled && (writing ? gate.memoryShortfall == nil : settings.current.classifier != .appleModel)
            }, gate: gate)
    }

    private var currentService: LocalClassifierService { service.withLock { $0 } }

    public var modelName: String { manifest.displayName }
    public var isWritingDownload: Bool { isWritingModel }
    public var classifierID: AIProviderID { currentService.classifier.id }
    public var sizeBytes: Int64 { manifest.totalBytes }
    public var memoryBytes: Int64 { LocalClassifierModels.requirements(for: manifest).memoryBytes }
    public var licence: String { manifest.license }
    public var unsupportedReason: String? { currentService.gate.memoryShortfall }

    public func directoryPath() async -> String { currentService.rootDirectory.path }

    public func status() async -> LocalModelStatus { Self.status(await currentService.state()) }

    public func download(confirmedSizeBytes: Int64) async -> AsyncStream<LocalModelStatus> {
        let service = currentService
        let states = await service.download(confirmedSizeBytes: confirmedSizeBytes)
        return AsyncStream { continuation in
            let task = Task {
                for await state in states {
                    let partial = await service.partialBytes()
                    continuation.yield(Self.status(LocalClassifierService.state(state, partial: partial)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel() async { await currentService.cancel() }

    public func delete() async throws { try await currentService.delete() }

    public func leftoverModels() async -> [LeftoverLocalModel] {
        guard !isWritingModel else { return [] }
        return await currentService.leftovers().map {
            LeftoverLocalModel(id: $0.manifest.id, name: $0.manifest.displayName, bytes: $0.bytesOnDisk)
        }
    }

    public func deleteLeftover(id: String) async throws {
        guard let old = LocalClassifierModels.retired.first(where: { $0.id == id }) else { return }
        try await currentService.deleteLeftover(old)
    }

    public func useDirectory(_ path: String?) async throws {
        if let path {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.isWritableFile(atPath: path) else {
                throw ModelStoreError.transport("folder")
            }
        }
        for model in writingServices {
            switch await model.status() {
            case .downloading, .verifying: throw ModelStoreError.alreadyDownloading
            default: break
            }
        }
        try settings.update { $0.modelsDirectory = path }
        await reloadDirectory()
        for model in writingServices { await model.reloadDirectory() }
    }

    private func reloadDirectory() async {
        let old = currentService
        await old.provider.unload()
        let made = Self.makeService(settings: settings, manifest: manifest, writing: isWritingModel)
        service.withLock { $0 = made }
        register(made)
    }

    static func status(_ state: LocalClassifierService.State) -> LocalModelStatus {
        switch state {
        case .notDownloaded(let partial): .notDownloaded(partialBytes: partial)
        case .downloading(let progress): .downloading(bytesDone: progress.bytesDone, bytesTotal: progress.bytesTotal)
        case .verifying: .verifying
        case .ready: .ready
        case .failed(let why): .failed(why)
        }
    }
}
