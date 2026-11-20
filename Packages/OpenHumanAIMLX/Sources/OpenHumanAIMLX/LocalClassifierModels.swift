import Foundation
import OpenHumanAIModelStore

public enum LocalClassifierModels {
    public struct Requirements: Sendable, Hashable {
        public let memoryBytes: Int64
        public let machineMemoryBytes: UInt64

        public init(memoryBytes: Int64, machineMemoryBytes: UInt64) {
            self.memoryBytes = memoryBytes
            self.machineMemoryBytes = machineMemoryBytes
        }
    }

    public static let qwen3_5_9b_optiq_4bit = huggingFace(
        id: "qwen3.5-9b-optiq-4bit", displayName: "Qwen3.5 9B OptiQ (4-bit)",
        repository: "mlx-community/Qwen3.5-9B-OptiQ-4bit", revision: "890b4c43f99ff392819d83605f7b1e59fa9688aa",
        files: [
            ("chat_template.jinja", 7_756, "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
            ("config.json", 55_670, "8c6e8569075c8c0cc7e35ebdc4ec63aa465d701e57cc8a4a201480cac077cfbf"),
            ("generation_config.json", 148, "f2130efdf66df1834aa4f7a6e48752e88a8dff41965739c6ffb2bb26c841615e"),
            ("kv_config.json", 528, "88b7f80fd9b3a202088f71889a7b43f818d63c4f836a60f26d5babe08093a10c"),
            ("model-00001-of-00002.safetensors", 5_349_382_977,
             "ac85c6ecdcd12ab778d44a9d6f90f1080498173c7fa6da2f335f3c42b716d85c"),
            ("model-00002-of-00002.safetensors", 1_751_328_661,
             "9d3a23b2307c705af2e86bbf2af791f0d63eae8c24042c5f362ad7586caa0062"),
            ("model.safetensors.index.json", 117_910, "27171409f0659bf76b2671a4fe99b0681650839fcf61f821c60f0406394b7c34"),
            ("optiq_metadata.json", 26_233, "ee34e7aec78859db7f3473e1b3c75170de0985b71aabd971aa6344c9f792dec8"),
            ("tokenizer.json", 19_989_343, "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
            ("tokenizer_config.json", 1_135, "b2bed5e033438f09f22b0ce9522115b4807d9bbcc3b82bf23372cb74d93ed081"),
        ])

    // No longer offered; kept so its old download can be found and offered for deletion.
    public static let qwen3_1_7b_4bit = huggingFace(
        id: "qwen3-1.7b-4bit", displayName: "Qwen3 1.7B (4-bit)",
        repository: "mlx-community/Qwen3-1.7B-4bit", revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e",
        files: [
            ("config.json", 937, "507a6701220524eb8b283425bf0856a9ae4f21f4052e563896ddd668994b1dc7"),
            ("tokenizer.json", 11_422_654, "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            ("model.safetensors", 968_080_210, "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f"),
        ])

    public static let offered = qwen3_5_9b_optiq_4bit

    public static let all: [ModelManifest] = [qwen3_5_9b_optiq_4bit]

    public static let retired: [ModelManifest] = [qwen3_1_7b_4bit]

    public static func requirements(for manifest: ModelManifest) -> Requirements {
        switch manifest.id {
        case LocalWritingModels.e4b.id:
            Requirements(memoryBytes: 5_368_709_120, machineMemoryBytes: 16 * 1_073_741_824)
        case LocalWritingModels.e2b.id:
            Requirements(memoryBytes: 3_865_470_566, machineMemoryBytes: 8 * 1_073_741_824)
        case qwen3_5_9b_optiq_4bit.id:
            Requirements(memoryBytes: 7_973_397_524, machineMemoryBytes: 16 * 1_073_741_824)
        default:
            Requirements(memoryBytes: manifest.totalBytes, machineMemoryBytes: LocalClassifierGate.minimumMemoryBytes)
        }
    }

    public static func classifierID(for manifest: ModelManifest) -> String { "local.\(manifest.id).classifier" }

    public static func sizeText(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 0.95 && gigabytes < 1.05 { return "about 1 GB" }
        if gigabytes >= 1 { return String(format: "about %.1f GB", gigabytes) }
        return String(format: "about %.0f MB", Double(bytes) / 1_000_000)
    }

    static func huggingFace(id: String, displayName: String, repository: String, revision: String,
                                    context: Int = 40_960, license: String = "Apache-2.0",
                                    files: [(path: String, size: Int64, sha256: String)]) -> ModelManifest {
        ModelManifest(
            id: id, displayName: displayName, sourceURL: URL(string: "https://huggingface.co/\(repository)")!,
            revision: revision,
            files: files.map { file in
                ModelManifest.File(
                    path: file.path,
                    url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")!,
                    sizeBytes: file.size, sha256: file.sha256)
            },
            license: license, format: .mlx, declaredContextTokens: context)
    }
}
