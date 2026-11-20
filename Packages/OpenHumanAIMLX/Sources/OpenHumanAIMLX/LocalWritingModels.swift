import Foundation
import OpenHumanAI
import OpenHumanAIModelStore

public enum LocalWritingModels {
    public static let contextTokens = 8_192

    public static let e4b = LocalClassifierModels.huggingFace(
        id: AIModelDefaults.gemmaE4BID, displayName: "Gemma 4 E4B (4-bit)",
        repository: "mlx-community/gemma-4-e4b-it-4bit", revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",
        context: contextTokens, license: "Google Gemma 4 · MLX Community conversion (Gemma)",
        files: [
            ("chat_template.jinja", 17_336, "2f1b4d75d067bae3fe44e676721c7f077d243bc007156cb9c2f8b5836613d082"),
            ("config.json", 6_628, "780ccb3a514a5f1ced161d383f948fc22eca9b84b752ca19494f625bd9bad7a6"),
            ("generation_config.json", 208, "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de"),
            ("model.safetensors", 5_146_800_534, "932b8271fc3fe65adcc78b96c10c6268bbfb13e8f67d1358727c0d6ee97e1eff"),
            ("model.safetensors.index.json", 240_961, "f8accac59ee7efe87e0c298c854610b262c3cadd477407503147c71209ff0093"),
            ("tokenizer.json", 32_169_626, "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
            ("tokenizer_config.json", 2_740, "080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656"),
        ])

    public static let e2b = LocalClassifierModels.huggingFace(
        id: AIModelDefaults.gemmaE2BID, displayName: "Gemma 4 E2B (4-bit)",
        repository: "mlx-community/gemma-4-e2b-it-4bit", revision: "238767527555cb75a05732a84dff5d6ba0dd6809",
        context: contextTokens, license: "Google Gemma 4 · MLX Community conversion (Gemma)",
        files: [
            ("chat_template.jinja", 17_336, "2f1b4d75d067bae3fe44e676721c7f077d243bc007156cb9c2f8b5836613d082"),
            ("config.json", 6_395, "6397cb6eca41b911d1dcab74e17941351057bd759284052a2331918ff6f9246c"),
            ("generation_config.json", 208, "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de"),
            ("model.safetensors", 3_550_670_554, "038e39a37a7667373d2c3991375446b10c96ae1d717a68674870343db376b76e"),
            ("model.safetensors.index.json", 218_323, "edb157dbf495e23f37377af4a628a9ad13c4ee7937f93ccb36ec9e9a19940f16"),
            ("tokenizer.json", 32_169_626, "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
            ("tokenizer_config.json", 2_740, "080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656"),
        ])

    public static let all = [e4b, e2b]
}
