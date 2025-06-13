import Foundation
import AVFoundation
import Combine
import SwiftUI
import CoreData

/// View model coordinating audio capture and translation.
@MainActor
final class SpeechTranslationViewModel: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        let original: String
        var translated: String = ""
        var audioURL: URL?
    }

    @Published var messages: [Message] = []
    @Published var inputPower: Float = -100

    private let audioManager = AudioCaptureManager()
    let service: TranslationService
    private let tts = TextToSpeechManager()
    private var cancellables: Set<AnyCancellable> = []
    private var audioPlayer: AVAudioPlayer?

    private let context: NSManagedObjectContext = PersistenceController.shared.container.viewContext
    private var session: ConversationSession?

    init(service: TranslationService) {
        self.service = service

        audioManager.chunkPublisher
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .sink { [weak self] buffer in
                Task { await self?.handleChunk(buffer) }
            }
            .store(in: &cancellables)

        audioManager.$powerLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$inputPower)
    }

    func start() {
        if session == nil {
            let newSession = ConversationSession(context: context)
            newSession.id = UUID()
            newSession.timestamp = Date()
            session = newSession
        }
        try? audioManager.start()
    }

    func stop() {
        audioManager.stop()
        saveContext()
    }

    func play(message: Message) {
        guard let url = message.audioURL else { return }
        audioPlayer?.stop()
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
        } catch {
            print("Audio playback error: \(error)")
        }
    }

    private func saveContext() {
        do {
            try context.save()
        } catch {
            print("Core Data save error: \(error)")
        }
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

            let ttsURL = try await tts.speak(text: messages[index].translated, language: service.config.targetLanguage)
            messages[index].audioURL = ttsURL

            if let session {
                let utt = Utterance(context: context)
                utt.id = message.id
                utt.original = message.original
                utt.translated = messages[index].translated
                utt.audioPath = ttsURL.path
                utt.session = session
                saveContext()
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
