import AVFoundation
import Combine
import Accelerate

/// Manages microphone input using `AVAudioEngine` and detects pauses in speech to form audio chunks.
/// This simplified implementation publishes audio buffers whenever a period of silence is detected.
final class AudioCaptureManager: ObservableObject {
    /// Publisher emitting captured audio chunks ready for transcription.
    let chunkPublisher = PassthroughSubject<AVAudioPCMBuffer, Never>()
    /// Current input power level in dB, published for a waveform view.
    @Published var powerLevel: Float = -100

    private let engine = AVAudioEngine()
    private let inputNode: AVAudioInputNode
    private var recognitionFormat: AVAudioFormat
    private var buffer: AVAudioPCMBuffer?

    /// Simple VAD thresholds
    private let silenceThreshold: Float = -40.0 // dB
    private let silenceDuration: TimeInterval = 0.5
    private var lastSpeechTime: TimeInterval = 0

    init() {
        self.inputNode = engine.inputNode
        self.recognitionFormat = inputNode.outputFormat(forBus: 0)
    }

    /// Starts capturing audio from the microphone.
    func start() throws {
        buffer = nil
        lastSpeechTime = CACurrentMediaTime()

        // Start engine first so the input node's format matches the hardware
        try engine.start()
        recognitionFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recognitionFormat) { [weak self] pcmBuffer, _ in
            self?.process(buffer: pcmBuffer)
        }
    }

    /// Stops the audio engine and clears state.
    func stop() {
        inputNode.removeTap(onBus: 0)
        engine.stop()
        buffer = nil
    }

    /// Process each incoming buffer, appending to the current chunk and emitting when silence is detected.
    private func process(buffer pcmBuffer: AVAudioPCMBuffer) {
        let power = pcmBuffer.averagePower
        DispatchQueue.main.async { [weak self] in
            self?.powerLevel = power
        }
        let now = CACurrentMediaTime()

        if buffer == nil {
            buffer = AVAudioPCMBuffer(pcmFormat: recognitionFormat, frameCapacity: 8192)
            buffer?.frameLength = 0
        }

        buffer?.append(pcmBuffer)

        if power > silenceThreshold {
            lastSpeechTime = now
        }

        if now - lastSpeechTime > silenceDuration {
            if let chunk = buffer {
                chunkPublisher.send(chunk)
            }
            self.buffer = nil
            lastSpeechTime = now
        }
    }
}

private extension AVAudioPCMBuffer {
    /// Append another buffer of the same format to this buffer.
    func append(_ other: AVAudioPCMBuffer) {
        guard let channelData = floatChannelData, let otherData = other.floatChannelData else { return }
        let writePos = Int(frameLength)
        let otherFrames = Int(other.frameLength)
        for channel in 0..<Int(format.channelCount) {
            let dest = channelData[channel] + writePos
            let src = otherData[channel]
            dest.assign(from: src, count: otherFrames)
        }
        frameLength += other.frameLength
    }

    /// Compute the average power (in dB) of this buffer.
    var averagePower: Float {
        guard let data = floatChannelData else { return -100 }
        let frames = Int(frameLength)
        var rms: Float = 0
        vDSP_measqv(data[0], 1, &rms, vDSP_Length(frames))
        var db: Float = 0
        var zero: Float = 1.0
        vDSP_vdbcon(&rms, 1, &zero, &db, 1, 1, 1)
        return db
    }
}
