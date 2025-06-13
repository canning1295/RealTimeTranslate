import Foundation
import AVFoundation
import Combine
import SwiftUI

/// View model coordinating audio capture and translation.
@MainActor
final class SpeechTranslationViewModel: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        let original: String
        var translated: String = ""
    }

    @Published var messages: [Message] = []

    private let audioManager = AudioCaptureManager()
    private let service: TranslationService
    private var cancellables: Set<AnyCancellable> = []

    init(service: TranslationService) {
        self.service = service

        audioManager.chunkPublisher
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .sink { [weak self] buffer in
                Task { await self?.handleChunk(buffer) }
            }
            .store(in: &cancellables)
    }

    func start() {
        try? audioManager.start()
    }

    func stop() {
        audioManager.stop()
    }

    private func handleChunk(_ buffer: AVAudioPCMBuffer) async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        do {
            try buffer.writeWAV(to: url)
            let text = try await service.transcribe(audioURL: url)
            var message = Message(original: text)
            messages.append(message)
            guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }

            for await token in service.translate(text: text) {
                messages[index].translated += token
            }
        } catch {
            // In a real app, handle error appropriately.
        }
        try? FileManager.default.removeItem(at: url)
    }
}

private extension AVAudioPCMBuffer {
    /// Write the buffer to a WAV file at the provided URL.
    func writeWAV(to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: self)
    }
}
