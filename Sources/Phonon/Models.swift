import Foundation

/// A selectable speech model.
struct ModelSpec: Identifiable, Equatable {
    let id: String          // stable id stored in config
    let name: String        // display name
    let repo: String        // Hugging Face repo
    let folder: String      // local folder under .../Phonon/models/
    let approxGB: Double
    let recRAMGB: Int
    let blurb: String       // one-line description / recommendation

    static func == (l: ModelSpec, r: ModelSpec) -> Bool { l.id == r.id }
}

enum Models {
    static let minicpm = ModelSpec(
        id: "minicpm", name: "MiniCPM-o 4.5 · 轻量",
        repo: "mlx-community/MiniCPM-o-4_5-4bit", folder: "MiniCPM-o-4_5-4bit",
        approxGB: 5.7, recRAMGB: 16,
        blurb: "快、占用小，中文好。推荐 16GB 内存。")

    /// Two-layer pipeline: Qwen3-ASR-1.7B (transcribe) → Qwen3.5-4B (cleanup).
    /// `folder` points at the ASR model for the app's readiness check; the
    /// cleanup model (Qwen3.5-4B-MLX-4bit) is loaded server-side too.
    static let qwenPipeline = ModelSpec(
        id: "qwen-pipeline", name: "Qwen3-ASR + 3.5 清洗 · 两层",
        repo: "mlx-community/Qwen3-ASR-1.7B-4bit", folder: "Qwen3-ASR-1.7B-4bit",
        approxGB: 4.0, recRAMGB: 16,
        blurb: "转写(Qwen3-ASR)+清洗(Qwen3.5-4B)两层，中文转写更准、可对比。")

    static let all: [ModelSpec] = [minicpm, qwenPipeline]

    static func spec(id: String) -> ModelSpec { all.first { $0.id == id } ?? minicpm }

    private static var configFile: URL { AppPaths.support.appendingPathComponent("model") }

    /// Whether the user has already picked a model (config exists).
    static var hasChosen: Bool { FileManager.default.fileExists(atPath: configFile.path) }

    /// The model the app is currently set to use (default: MiniCPM-o).
    static var active: ModelSpec {
        guard let raw = try? String(contentsOf: configFile, encoding: .utf8) else { return minicpm }
        return spec(id: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func setActive(_ s: ModelSpec) {
        try? s.id.write(to: configFile, atomically: true, encoding: .utf8)
    }
}
