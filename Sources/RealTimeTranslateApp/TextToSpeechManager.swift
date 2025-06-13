import AVFoundation
import Foundation

/// Synthesizes speech from text, plays it aloud, and saves the audio to a file.
final class TextToSpeechManager {
    private let speakSynthesizer = AVSpeechSynthesizer()
    private let writeSynthesizer = AVSpeechSynthesizer()
    private var outputFile: AVAudioFile?

    /// Speak the given text in the specified language and save the spoken audio.
    /// - Parameter text: The text to speak.
    /// - Parameter language: A locale code like "en-US" or "fr-FR".
    /// - Returns: The file URL of the saved WAV audio.
    @MainActor
    func speak(text: String, language: String) async throws -> URL {
        let voice = AVSpeechSynthesisVoice(language: language) ??
            AVSpeechSynthesisVoice(language: "en-US")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice

        let voiceLanguage = voice?.language ?? "unknown"
        print("[TTS] speaking with voice \(voiceLanguage)")

        // Speak the utterance aloud immediately
        speakSynthesizer.stopSpeaking(at: .immediate)
        speakSynthesizer.speak(utterance)

        // Prepare to write the same utterance to a WAV file
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        outputFile = try AVAudioFile(forWriting: url, settings: format.settings)

        print("[TTS] writing speech to \(url)")

        return try await withCheckedThrowingContinuation { continuation in
            writeSynthesizer.write(utterance) { [weak self] buffer in
                guard let self else { return }
                if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                    do {
                        try self.outputFile?.write(from: pcm)
                    } catch {
                        print("[TTS] write error: \(error)")
                        continuation.resume(throwing: error)
                        self.outputFile = nil
                    }
                } else {
                    // zero-length buffer indicates completion
                    self.outputFile = nil
                    print("[TTS] finished writing to \(url)")
                    continuation.resume(returning: url)
                }
            }
        }
    }
}
