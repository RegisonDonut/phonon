import Foundation

/// Where Phonon keeps its models + where the bundled server binary lives.
enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Phonon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// ~/Library/Application Support/Phonon/models/<folder>
    static func modelDir(_ spec: ModelSpec) -> URL {
        support.appendingPathComponent("models/\(spec.folder)", isDirectory: true)
    }
    static var activeModelDir: URL { modelDir(Models.active) }

    /// The frozen server binary bundled in the .app, or nil (dev runs).
    static var bundledServer: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let bin = res.appendingPathComponent("server/phonon-server")
        return FileManager.default.isExecutableFile(atPath: bin.path) ? bin : nil
    }

    /// A model is "ready" once its weight shards are present and roughly the
    /// expected total size (works for any shard layout / model).
    static func modelReady(_ spec: ModelSpec) -> Bool {
        let dir = modelDir(spec)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        var total = 0
        for f in items where f.hasSuffix(".safetensors") {
            if let s = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(f).path))?[.size] as? Int {
                total += s
            }
        }
        return Double(total) > spec.approxGB * 0.85 * 1_000_000_000
    }
}
