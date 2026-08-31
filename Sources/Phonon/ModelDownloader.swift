import Foundation

/// Downloads the MiniCPM-o model from Hugging Face into AppPaths.modelDir with
/// live progress (reported into SetupState). Resumable-ish: already-complete
/// files are skipped, so a re-run continues where it left off.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    private let state: SetupState
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 7200
        // System proxy + system trust store — works through a TLS-MITM proxy
        // and directly on machines without one.
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    init(state: SetupState) { self.state = state }

    private struct Entry: Decodable {
        let type: String
        let path: String
        let size: Int?
        let lfs: LFS?
        struct LFS: Decodable { let size: Int? }
        var bytes: Int { lfs?.size ?? size ?? 0 }
    }

    private var total = 0
    private var baseDone = 0           // bytes from files finished so far
    private let started = Date()
    private var currentDest: URL?
    private var continuation: CheckedContinuation<Void, Error>?

    func run(_ spec: ModelSpec) async -> Bool {
        do {
            let repo = spec.repo
            let modelDir = AppPaths.modelDir(spec)
            guard let treeURL = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true") else {
                throw err("bad url")
            }
            let (data, _) = try await session.data(from: treeURL)
            let files = try JSONDecoder().decode([Entry].self, from: data).filter { $0.type == "file" }
            total = files.reduce(0) { $0 + $1.bytes }
            try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

            for f in files {
                let dest = modelDir.appendingPathComponent(f.path)
                if let a = try? FileManager.default.attributesOfItem(atPath: dest.path),
                   let s = a[.size] as? Int, s == f.bytes, f.bytes > 0 {
                    baseDone += f.bytes
                    report(extra: 0)
                    continue
                }
                guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(f.path)") else { continue }
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await downloadOne(url, to: dest)
                baseDone += f.bytes
            }
            await MainActor.run { self.state.fraction = 1 }
            return true
        } catch {
            await MainActor.run { self.state.phase = .error("模型下载失败：\(error.localizedDescription)") }
            return false
        }
    }

    private func downloadOne(_ url: URL, to dest: URL) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.continuation = c
            self.currentDest = dest
            session.downloadTask(with: url).resume()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        report(extra: Int(totalBytesWritten))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let dest = currentDest else { return }
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: location, to: dest)
        } catch {
            continuation?.resume(throwing: error); continuation = nil; return
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: ()) }
        continuation = nil
    }

    // MARK: progress

    private func report(extra: Int) {
        let done = baseDone + extra
        let secs = max(0.3, Date().timeIntervalSince(started))
        let speed = Double(done) / secs
        let frac = total > 0 ? min(1.0, Double(done) / Double(total)) : 0
        let detail = String(format: "%.1f / %.1f GB · %.0f MB/s",
                            Double(done) / 1e9, Double(total) / 1e9, speed / 1e6)
        Task { @MainActor in
            self.state.fraction = frac
            self.state.detail = detail
        }
    }

    private func err(_ m: String) -> NSError {
        NSError(domain: "ModelDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}
