import Foundation
import Combine

/// Handles communication with OpenAI's APIs for transcription and translation.
/// This example focuses on function signatures and streaming parsing rather than real network calls.
final class TranslationService {
    struct Config {
        var apiKey: String
        var targetLanguage: String
    }

    @Published var config: Config

    init(config: Config) {
        self.config = config
    }

    // MARK: - Whisper

    /// Uploads audio data to Whisper for transcription and returns the recognized text.
    func transcribe(audioURL: URL) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        // Build multipart form body
        let boundary = "Boundary-\(UUID().uuidString)"
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: audioURL)
        var body = Data()

        // model field
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendString("whisper-1\r\n")

        // file field
        body.appendString("--\(boundary)\r\n")
        let filename = audioURL.lastPathComponent
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")

        body.appendString("--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        struct WhisperResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
        return decoded.text
    }

    // MARK: - Translation

    /// Sends text to ChatGPT for translation using streaming SSE.
    /// Returns an `AsyncStream` of translation tokens as they arrive.
    func translate(text: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let url = URL(string: "https://api.openai.com/v1/chat/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "model": "gpt-4o",
                "stream": true,
                "temperature": 0,
                "messages": [
                    ["role": "system", "content": "You are a translation assistant. Translate everything to \(config.targetLanguage)."],
                    ["role": "user", "content": text]
                ]
            ]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                continuation.finish()
                return
            }

            let task = Task {
                do {
                    let (stream, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }

                    for try await line in stream.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let dataLine = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if dataLine == "[DONE]" {
                            break
                        }
                        if let data = dataLine.data(using: .utf8),
                           let chunk = try? JSONDecoder().decode(ChatStreamChunk.self, from: data),
                           let token = chunk.choices.first?.delta.content {
                            continuation.yield(token)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Minimal model for decoding streaming chat completion events.
    private struct ChatStreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta
        }
        let choices: [Choice]
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
