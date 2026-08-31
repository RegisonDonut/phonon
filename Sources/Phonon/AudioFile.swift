import AVFoundation
import Foundation

/// Writes 16 kHz mono float samples to a 16-bit PCM WAV file.
/// The MLX omni server reads this path directly (both processes are local),
/// which avoids base64-bloating the recording into the HTTP body.
enum AudioFile {
    static func writeWAV(samples: [Float], to destination: URL? = nil) throws -> URL {
        let url = destination ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("s2t-\(UUID().uuidString).wav")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)

        guard let inFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buf = AVAudioPCMBuffer(
            pcmFormat: inFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw NSError(domain: "AudioFile", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot build PCM buffer"])
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buf.floatChannelData?[0] {
            for i in 0..<samples.count { channel[i] = samples[i] }
        }
        try file.write(from: buf)
        return url
    }
}
