import SwiftUI

/// Simple linear waveform bar representing the microphone input level.
struct WaveformView: View {
    var power: Float

    private var normalized: CGFloat {
        let minDb: Float = -60
        let clamped = max(minDb, power)
        return CGFloat((clamped - minDb) / -minDb)
    }

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.green)
                .frame(width: geo.size.width * normalized)
                .animation(.linear(duration: 0.1), value: normalized)
        }
        .frame(height: 4)
        .cornerRadius(2)
    }
}

#if DEBUG
#Preview {
    WaveformView(power: -20)
        .frame(height: 4)
}
#endif
