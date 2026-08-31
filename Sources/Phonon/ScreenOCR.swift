import Foundation
import Vision
import AppKit

/// Extracts candidate keywords from a screenshot using the native Vision OCR
/// (VNRecognizeTextRequest) — fast (~100-300 ms) and on-device, so we never
/// pay a vision-model pass on the server. We send these words as text; the
/// model only uses them to disambiguate similar-sounding speech.
enum ScreenOCR {
    static func keywords(from imageURL: URL) -> [String] {
        guard let nsImage = NSImage(contentsOf: imageURL),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return [] }

        var lines: [String] = []
        for obs in request.results ?? [] {
            if let top = obs.topCandidates(1).first { lines.append(top.string) }
        }
        return distill(lines)
    }

    /// Turn raw OCR lines into a compact keyword list worth disambiguating
    /// against: latin words / product names / codes, plus short CJK terms.
    private static func distill(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        // split on whitespace and punctuation, keep meaningful tokens
        let separators = CharacterSet(charactersIn: " \t\n\r　，。、；：！？（）()[]{}<>“”\"'`/\\|=+*…—-_~@#")
        for line in lines {
            for rawTok in line.components(separatedBy: separators) {
                let tok = rawTok.trimmingCharacters(in: .whitespaces)
                guard tok.count >= 2, tok.count <= 30, !seen.contains(tok) else { continue }
                if isInteresting(tok) {
                    seen.insert(tok)
                    out.append(tok)
                }
                if out.count >= 60 { return out }
            }
        }
        return out
    }

    private static func isInteresting(_ s: String) -> Bool {
        let hasLatinOrDigit = s.unicodeScalars.contains {
            ("a"..."z").contains(Character($0)) || ("A"..."Z").contains(Character($0)) || ("0"..."9").contains(Character($0))
        }
        let hasCJK = s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        // Latin/alnum tokens (product names, codes, English words) are the
        // prime disambiguation targets; also keep short CJK terms (2-8 chars).
        if hasLatinOrDigit { return true }
        if hasCJK && s.count <= 8 { return true }
        return false
    }
}
