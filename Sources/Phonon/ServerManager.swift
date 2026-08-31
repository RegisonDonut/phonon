import Foundation

/// Owns the local model server. If one is already listening (e.g. a dev
/// launchd instance) we reuse it; otherwise we spawn the bundled frozen
/// `phonon-server` as a child process and stop it when the app quits.
@MainActor
final class ServerManager {
    let base = URL(string: "http://127.0.0.1:8799")!
    private var process: Process?

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]            // loopback: bypass system proxy
        c.timeoutIntervalForRequest = 3
        return URLSession(configuration: c)
    }()

    /// Returns true once /health reports the model loaded. Reuses an existing
    /// server, else spawns the bundled one and waits for it to warm up.
    func ensureRunning() async -> Bool {
        if await healthLoaded() { return true }

        guard let bin = AppPaths.bundledServer else {
            // No bundled server (dev build) and nothing already running.
            return await waitLoaded(seconds: 5)
        }
        let p = Process()
        p.executableURL = bin
        var env = ProcessInfo.processInfo.environment
        env["S2T_MODEL"] = AppPaths.activeModelDir.path
        env["S2T_PORT"] = "8799"
        env["S2T_HOST"] = "127.0.0.1"
        for k in ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
            env.removeValue(forKey: k)
        }
        p.environment = env
        do { try p.run() } catch { return false }
        self.process = p
        return await waitLoaded(seconds: 120)
    }

    /// Restart the server so it loads the (now-changed) active model. Handles
    /// both the app-spawned child and an external launchd server.
    func restart() async -> Bool {
        if let p = process {                       // we own it → kill + respawn
            p.terminate(); process = nil
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return await ensureRunning()
        }
        // external (launchd) server → kickstart it; it re-reads the model config
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "gui/\(getuid())/com.phonon.omni"]
        try? task.run(); task.waitUntilExit()
        return await waitLoaded(seconds: 120)
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func waitLoaded(seconds: Int) async -> Bool {
        for _ in 0..<seconds {
            if await healthLoaded() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    private func healthLoaded() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 3
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (obj["loaded"] as? Bool) == true
    }

    /// The model folder the live server reports it actually loaded, e.g.
    /// "models/MiniCPM-o-4_5-4bit". nil if server is unreachable.
    /// Lets the menu show the truth instead of trusting the on-disk config.
    func reportedModel() async -> String? {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 3
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["model"] as? String
    }
}
