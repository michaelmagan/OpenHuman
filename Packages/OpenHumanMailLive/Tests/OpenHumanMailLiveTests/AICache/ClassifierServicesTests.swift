import Foundation
import MailFeatures
import OpenHumanAI
import OpenHumanAIMLX
import Testing
@testable import OpenHumanMailLive

@Suite struct ClassifierServicesTests {
    @Test func offersTheLargeModelAndFindsTheOldDownloadWithoutDeletingIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-models-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = LocalClassifierModels.qwen3_1_7b_4bit
        let folder = root.appendingPathComponent(old.id, isDirectory: true)
            .appendingPathComponent(old.revision, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = try #require(old.files.first { $0.path == "config.json" })
        try Data(repeating: 0, count: Int(config.sizeBytes)).write(to: folder.appendingPathComponent(config.path))

        let settings = AISettingsBox(store: InMemoryAISettingsStore(AISettings(modelsDirectory: root.path)))
        let registry = ProviderRegistry()
        let services = ClassifierServices(registry: registry, settings: settings)
        #expect(registry.providers.map(\.id) == AIModelDefaults.writingModels)
        #expect(services.writingModels.map(\.modelName) == ["Gemma 4 E4B (4-bit)", "Gemma 4 E2B (4-bit)"])
        #expect(services.modelName == "Qwen3.5 9B OptiQ (4-bit)")
        #expect(services.sizeBytes == 7_120_910_361 && services.memoryBytes == 7_973_397_524)
        #expect(services.classifierID == "local.qwen3.5-9b-optiq-4bit.classifier")
        #expect(registry.classifiers.map(\.id) == [services.classifierID])
        #expect(await services.status() == .notDownloaded(partialBytes: 0))
        #expect(await services.leftoverModels()
            == [LeftoverLocalModel(id: old.id, name: "Qwen3 1.7B (4-bit)", bytes: config.sizeBytes)])
        #expect(FileManager.default.fileExists(atPath: folder.path), "finding it deletes nothing")
        try await services.deleteLeftover(id: LocalClassifierModels.offered.id)
        #expect(FileManager.default.fileExists(atPath: folder.path), "only a retired model is deleted this way")
        try await services.deleteLeftover(id: old.id)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(old.id).path))
        #expect(await services.leftoverModels().isEmpty)
    }
}
