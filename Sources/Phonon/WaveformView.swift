import SwiftUI

/// Animated bar-style waveform. Each bar has a fixed base height plus a
/// contribution driven by the current RMS level, with a phase offset so
/// they don't all pulse in lockstep.
struct WaveformView: View {
    let level: Float
    private let barCount = 28
    @State private var phase: Double = 0

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        .frame(width: 3, height: barHeight(i, max: geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }

    private func barHeight(_ i: Int, max: CGFloat) -> CGFloat {
        let t = phase + Double(i) * 0.3
        let wobble = (sin(t) + 1) / 2  // 0...1
        let amplitude = Double(level) * 0.9 + 0.08
        let norm = wobble * amplitude
        return max * CGFloat(norm) + 4
    }
}
