import Foundation

/// Talks to the local MLX omni server (scripts/omni_server.py), which runs
/// MiniCPM-o 4.5 and turns recorded audio (+ context) into ready-to-paste text.
///
/// This single client replaces the old two-model pipeline (whisper.cpp ASR +
/// Ollama cleanup): the omni model transcribes AND cleans in one pass.
struct OmniClient {
    let base: URL
    private let session: URLSession

    init(base: URL = URL(string: "http://127.0.0.1:8799")!) {
        self.base = base
        // Bypass the system HTTP proxy (Shadowrocket/Clash) for loopback.
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        // Local inference duration scales with recording length and available
        // CPU/GPU capacity. Never fail a valid recording merely because the
        // machine is busy; the owning Task remains explicitly cancellable.
        config.timeoutIntervalForRequest = .greatestFiniteMagnitude
        config.timeoutIntervalForResource = .greatestFiniteMagnitude
        self.session = URLSession(configuration: config)
    }

    struct Result {
        let text: String
        let elapsed: Double
        let genTokens: Int?
        let genTPS: Double?
    }

    /// Dictation: audio (+ optional on-screen keywords) → cleaned text.
    /// Keywords are OCR'd natively in the app (no server vision pass).
    func dictate(wav: URL, screenKeywords: [String], context: DictationContext) async throws -> Result {
        var body: [String: Any] = [
            "audio_path": wav.path,
            "app_context": context.appBundleID as Any,
            "vocabulary": context.vocabulary,
            "language": context.language
        ]
        if !screenKeywords.isEmpty { body["screen_keywords"] = screenKeywords }
        return try await post(path: "/dictate", body: body)
    }

    /// Voice editing: spoken command applied to selected text.
    func edit(wav: URL, selectedText: String, context: DictationContext) async throws -> Result {
        try await post(path: "/edit", body: [
            "audio_path": wav.path,
            "selected_text": selectedText,
            "app_context": context.appBundleID as Any,
            "vocabulary": context.vocabulary
        ])
    }

    private func post(path: String, body: [String: Any]) async throws -> Result {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw err("No HTTP response from omni server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw err("Omni server \(http.statusCode): \(msg ?? "is the server running? scripts/start_server.sh"))")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            throw err("Malformed omni server response.")
        }
        return Result(
            text: text,
            elapsed: obj["elapsed_s"] as? Double ?? 0,
            genTokens: obj["generation_tokens"] as? Int,
            genTPS: obj["generation_tps"] as? Double
        )
    }

    private func err(_ m: String) -> NSError {
        NSError(domain: "OmniClient", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}

/// Everything the model needs to adapt the output beyond the raw audio:
/// the frontmost app (for tone) and the user's custom vocabulary.
struct DictationContext {
    var appBundleID: String?
    var vocabulary: [String]
    var language: String  // "auto" | "zh" | "en" | ...
}
