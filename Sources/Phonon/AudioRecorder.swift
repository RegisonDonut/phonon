import AVFoundation
import Foundation

/// Captures mic audio, resamples to 16 kHz mono float, and publishes a live
/// RMS level for waveform visualization. `stop()` returns the full buffer.
@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var level: Float = 0  // 0...1
    @Published private(set) var isRecording = false

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let targetSampleRate: Double = 16_000
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    func start() throws {
        guard !isRecording else { return }
        samples.removeAll(keepingCapacity: true)

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot build target format"])
        }
        self.targetFormat = target
        self.converter = AVAudioConverter(from: inputFormat, to: target)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() -> [Float] {
        guard isRecording else { return samples }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        level = 0
        return samples
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }

        // Estimate output capacity with room to spare.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var error: NSError?
        var delivered = false
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil { return }

        guard let channelData = outBuffer.floatChannelData?[0] else { return }
        let count = Int(outBuffer.frameLength)

        // RMS over this chunk for live level
        var sumSquares: Float = 0
        for i in 0..<count {
            let s = channelData[i]
            sumSquares += s * s
        }
        let rms = count > 0 ? sqrtf(sumSquares / Float(count)) : 0
        // Compress dynamic range: -52dB...-10dB → 0...1, then a perceptual curve
        // (gamma < 1) lifts the low end so *quiet* speech still drives the orb
        // clearly instead of barely registering.
        let db = 20 * log10f(max(rms, 1e-6))
        let lin = max(0, min(1, (db + 52) / 42))
        let normalized = powf(lin, 0.55)

        let chunk = Array(UnsafeBufferPointer(start: channelData, count: count))
        Task { @MainActor [normalized, chunk] in
            self.samples.append(contentsOf: chunk)
            // Snappy EMA so the orb pulses with each syllable (visible "wave").
            self.level = self.level * 0.25 + normalized * 0.75
        }
    }
}
