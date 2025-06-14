# Real-Time Speech Translation App Development Plan

## Architecture Overview

This app will be built as a **universal SwiftUI application** for both iOS and macOS, sharing most code between platforms. The core architecture follows an **MVVM** style with distinct components for audio capture, transcription, translation, text-to-speech (TTS), data storage, and the SwiftUI UI layer. Key components include:

* **Audio Capture & VAD**: An audio manager (e.g. `AudioCaptureManager`) uses `AVAudioEngine` to record microphone input continuously. A Voice Activity Detection (VAD) algorithm monitors the audio stream to detect pauses/silence that indicate the end of a spoken segment. When the user speaks, audio is buffered; when they stop (silence passes a threshold), the buffered chunk is considered a complete utterance.
* **Transcription Service**: A network client for OpenAI’s Whisper API handles transcription of each audio chunk. We send the audio to the cloud (not on-device) for high-accuracy speech-to-text. This returns the recognized text of the user’s speech (assumed source language is English).
* **Translation Service**: Another client for OpenAI’s Chat Completions API (using the GPT-4o Mini model) handles translating the transcribed text into the target language (French or German). We use the API’s **streaming** capabilities to receive translation text token-by-token in real time.
* **Text-to-Speech Output**: A TTS manager uses `AVSpeechSynthesizer` to voice the translated text. It selects an appropriate voice based on the language of the translation (English, French, or German) by detecting the language code and picking a matching `AVSpeechSynthesisVoice`. The spoken audio is also captured and saved for replay.
* **Data Storage**: A storage layer persists conversation data. All translation sessions (original text, translated text, and audio file references) are saved locally. The user’s OpenAI API key is stored securely in the Keychain.
* **SwiftUI UI Layer**: SwiftUI views present a real-time chat-like interface and controls. Views are updated via an `ObservableObject` view model (e.g. `SpeechTranslationViewModel`) that publishes state changes (like new transcriptions, translations, or errors). This view model orchestrates the above components. Concurrency is managed with Swift’s structured concurrency (async/await tasks and possibly actors) to perform audio processing and network calls off the main thread, while UI updates occur on the main thread.

**Concurrency & Performance**: The design leverages concurrency to handle parallel tasks: audio capture runs continuously while network calls and TTS run on background threads. An actor or dedicated task queue can coordinate the pipeline to avoid race conditions (for example, ensuring only one Whisper request at a time to respect rate limits). We will implement queuing/back-pressure if the user speaks new utterances faster than API calls can be made, to comply with OpenAI rate limits. For instance, if one translation is still in progress, subsequent audio chunks can be queued or slightly delayed. We will also consider optimizing audio data to reduce latency – for example, using compressed, lower-bitrate audio for Whisper (e.g. mono 12 kHz MP3) can significantly cut transcription time without loss of accuracy. Overall, the architecture ensures that capturing audio, transcribing, translating, and speaking can happen with minimal latency in a streaming fashion.

## Data Flow

**1. Audio Capture & Chunking:** When the user initiates a translation session (e.g. presses a “Start Listening” button), the app configures the audio session (e.g. `AVAudioSession.sharedInstance().setCategory(.playAndRecord, .defaultToSpeaker)`) and starts `AVAudioEngine`. The engine’s input node is tapped (`installTap` on the input bus) to receive audio buffers (PCM samples). A simple VAD routine monitors the audio levels in these buffers to detect speech boundaries. For example, we continuously calculate the audio signal power; if the sound level falls below a threshold for a certain duration, we infer a pause in speech. At that point, the current audio buffer is **closed as a chunk** and a new chunk is started for subsequent speech. This yields a stream of audio segments corresponding to spoken sentences or phrases. Using VAD ensures we cut the audio at natural pauses (to avoid cutting off words) and simulate real-time transcription by processing chunks incrementally.

**2. Transcription via Whisper API:** Each completed audio chunk is sent to OpenAI’s Whisper API for transcription. The audio data (for example, a short WAV or MP3 file created from the PCM buffer) is uploaded via an HTTPS request to the Whisper *transcriptions* endpoint. We include the user’s API key in the Authorization header and specify parameters like the model (e.g. "whisper-1"), the audio file (as multipart form-data), and language hints (we can set "language": "en" since the source is English, to help Whisper). The app performs this request off the main thread (using `URLSession` data task or async/await networking). When Whisper returns the result (JSON with a "text" field), we obtain the English transcription of the user’s speech. This transcription is immediately added to the UI’s conversation log (so the user can see what was recognized). If the Whisper API call fails (e.g. network error or invalid audio), error handling will display a message, but the app will continue listening for new audio.

**3. Sending to GPT-4o for Translation:** As soon as the transcription text is available, the app forwards it to the OpenAI Chat Completion API (GPT-4o Mini model) to get a translation. We construct a chat prompt with the transcribed text. For example, we might use a system message like: *“You are a translation assistant. Translate the following English text into **French** (or German) without additional commentary.”* and a user message containing the exact transcribed sentence. Alternatively, a simpler prompt could be formatted as: *“Translate to French: `<transcription>`”*. We set the API parameters for streaming ("stream": true). The network client (using `URLSession` or a library) invokes the `/v1/chat/completions` endpoint with these messages. The GPT model will begin streaming the translated text as a series of events. We parse the server-sent event stream from the response – each event contains a partial token of the translation. In code, this can be handled with an async sequence reading the URLSession bytes and splitting on the SSE delimiters. For example, using an `AsyncStream` or Combine publisher, we append each received token to the output string and update the UI accordingly. This produces a live “typing” effect in the UI as the translation appears word by word. The UI will show an in-progress translation (perhaps with a placeholder or spinner). Once the API signals the end of the stream (a `[DONE]` message), we mark the translation as complete.

**4. Real-time UI Update:** The SwiftUI chat view is bound to the view model which holds the conversation data. As soon as the transcription is available, the view model adds a new “message” to the conversation: e.g. an object containing the original English text and an empty placeholder for the translated text. As the translation stream arrives, the view model updates that message’s translated text property incrementally. SwiftUI, observing this `@Published` property, will redraw the portion of the chat view showing the translation. We ensure UI updates happen on the main thread (using `DispatchQueue.main.async` or marking the view model as `@MainActor`). The result is the user sees their spoken sentence and, a moment later, the translated sentence appears gradually beneath it (simulating real-time translation).

**5. Text-to-Speech Output:** Once the translated text is fully received, the app uses `AVSpeechSynthesizer` to speak it aloud. The view model passes the translated string to the TTS manager, which chooses an appropriate voice. We detect the language of the text – since our target is known (user likely selected French or German), we can map that choice to a specific locale voice (e.g. if French was chosen, use `AVSpeechSynthesisVoice(language: "fr-FR")`). We could also use Apple’s `NLLanguageRecognizer` on the text as a double-check of language. An `AVSpeechUtterance` is created with the translated string and the chosen voice, then enqueued via `synthesizer.speak(utterance)`. This will output audio through the device speakers (or earpiece on phone, etc.). To **capture the audio for storage**, we utilize `AVSpeechSynthesizer`’s `write(_:toBufferCallback:)` API. As the synthesizer generates audio frames for the utterance, we write those buffers to an `AVAudioFile` on disk. This produces an audio file (e.g. WAV or m4a) containing the spoken translation. The file’s URL (or a reference ID) is saved alongside the text in the conversation log.

**6. Continuous Operation:** The above steps (capture -> transcribe -> translate -> speak) occur repeatedly for each utterance. The system is designed to handle this **pipeline in a streaming, overlapping fashion**. For example, while Whisper is transcribing chunk #1, the audio engine is already capturing chunk #2 (if the user keeps talking). Similarly, while GPT is translating chunk #1, Whisper might be processing chunk #2 in parallel. This overlap minimizes idle time. However, to respect API limits and avoid confusion, we will manage concurrency carefully: if multiple chunks are being processed, their results will be queued in order. Translations will be rendered in sequence to maintain the conversational flow. (If the user speaks again before the previous translation is finished speaking, we may choose to **queue or interrupt** the prior TTS – for a smooth experience, likely we’ll stop the previous speech output when a new utterance comes in, since in a live conversation the latest speech is most relevant).

**7. Session Finalization:** As the user continues, the conversation log builds up with pairs of original and translated text (and associated audio). The user can end or reset the session via the UI (e.g. tapping a “End Session” button). On session end, the app finalizes any ongoing tasks (wait for any final translations to complete) and then saves the conversation to persistent storage (if not already saved incrementally). A new session can then be started fresh. If the user doesn’t manually end, we could automatically treat each app launch (or each continuous run of dialogue) as a session.

Throughout the data flow, **error conditions** are monitored (explained in detail below). The app provides feedback if something goes wrong at any stage, but the pipeline is resilient – e.g., a failure to translate one chunk won’t stop the audio engine from listening for the next utterance.

## API Integration

**Whisper API (Transcription):** We integrate with OpenAI’s Whisper via its REST API for audio transcription. The client will use the endpoint `POST https://api.openai.com/v1/audio/transcriptions` with the following specifics: a `multipart/form-data` body including the audio file content (the chunk captured via AVAudioEngine). We’ll send the audio in a suitable format – likely WAV (PCM 16-bit) or a compressed format like MP3 to reduce upload size. (OpenAI Whisper API supports mp3, m4a, wav, webm, etc.) To improve response time, we may downsample the audio (e.g. 16 kHz mono) and/or compress it; studies show that using a lower bitrate and sample rate can cut latency significantly without hurting accuracy. The request will include `Authorization: Bearer <API Key>` and JSON form fields such as "model": "whisper-1", and optionally "language": "en" to hint the language, and "response_format": "json". The Whisper API does *not* natively stream partial results, so our strategy is to send short audio chunks frequently (as described) to simulate streaming. Each Whisper API response returns a JSON with the transcribed text for that chunk, which we parse using Swift’s `JSONDecoder` or manual parsing. Integration considerations:

* We must handle the time it takes to upload and process audio. For small chunks (a few seconds of speech), Whisper responds quickly (on the order of 1-2 seconds). We will show a “transcribing…” indicator if needed for longer audio.
* The audio chunk assembly: using `AVAudioPCMBuffer` data, we might write it to a temporary file (e.g. in `.wav` format) before sending. This can be done with `AVAudioFile.write` on the buffer. We ensure the format matches Whisper’s expectations (e.g. 16kHz 16-bit PCM if wav).
* If transcription fails (HTTP error or API error), the app can retry once or skip that chunk with an error message.

**GPT-4o Mini (Chat Completions API for Translation):** For translation, we use the OpenAI Chat Completions API with streaming. We construct the HTTP request to `POST https://api.openai.com/v1/chat/completions` with headers for JSON content type and the Authorization bearer token. The body will include the model ("model": "gpt-4o-mini" or similar) and the conversation messages. We only need a single-turn conversation for translation, so we can send a system instruction and the user’s text. For example:

```
{
  "model": "gpt-4o-mini",
  "messages": [
    {"role": "system", "content": "Translate the user’s message from English to French. Respond only with the translated text."},
    {"role": "user", "content": "<English text to translate>"}
  ],
  "stream": true
}
```

Setting "stream": true tells the API to **stream tokens** as they are generated.

**Streaming Implementation:** The response will be sent as a stream of Server-Sent Events (SSE). Our networking layer will need to handle a chunked HTTP response. Using Swift’s concurrency, one approach is `URLSession.bytes(for:request)` to get an `AsyncSequence` of bytes from the response. We can then iterate over this byte stream and accumulate data until SSE message boundaries (`\n\n`) are detected, parsing each "data: ..." line as a JSON chunk. Each chunk contains a "delta" with new content tokens. We extract the token text and append it to the current translation string. For instance, using an AsyncSequence loop:

```swift
let (response, byteStream) = try await URLSession.shared.bytes(for: request)
for try await byte in byteStream {
    // accumulate bytes and check for newline-delimited JSON chunks
    ...
    if let json = parseJSONChunk(from: buffer) {
       let content = json["choices"]?[0]?["delta"]?["content"] as? String
       if let newText = content {
           DispatchQueue.main.async {
               viewModel.currentTranslation += newText
           }
       }
       if json["choices"]?[0]?["finish_reason"] as? String == "stop" {
           break // done streaming
       }
    }
}
```

This pseudo-code illustrates the mechanism. We will likely wrap this logic in a dedicated `TranslationService` class. An alternative is to use a community Swift library (like **SwiftOpenAI**) which provides a higher-level streaming API. For example, SwiftOpenAI allows you to do `for try await event in service.responseCreateStream(...)` and handle `.outputTextDelta` events as they arrive, simplifying SSE parsing. Whether using a library or not, the integration will update our app’s state with each token.

**Selecting Target Language:** Depending on user choice (French or German), we adjust the system prompt or instruct the model accordingly. We could also swap out to a different fine-tuned model if one existed for translations, but here we assume GPT-4o can handle both languages via prompt. GPT-4’s output will be in the target language with proper accent marks, etc. We verify the output language by either trusting the model or using a language detection on the first few tokens (as a safety check for voice selection).

**TTS Integration:** The `AVSpeechSynthesizer` is straightforward to use. We will maintain a singleton or instance of it in our TTS manager. After receiving the full translated text, we call `synthesizer.speak(utterance)` on a prepared `AVSpeechUtterance`. If we want to save audio, we use `synthesizer.write` instead. According to Apple’s documentation, the `write(_:toBufferCallback:)` method is intended for saving speech to a file. We will create an `AVAudioFile` with a desired format (e.g. 44.1kHz PCM) and in the buffer callback, write each `AVAudioBuffer` to this file. After the write process completes (which should be quick for short sentences), we close the file – we now have the spoken translation saved. For playback, we can later load this file via `AVAudioPlayer`.

**OpenAI API Key Handling:** All requests to OpenAI require the user’s API key. We do not embed any key in the app; instead, on first launch (or in a Settings screen) we prompt the user to enter their key string. We validate if possible (e.g. check it starts with "sk-") and store it securely using the iOS/macOS **Keychain**. The Keychain storage could be done with the **Security** framework (SecItemAdd for a generic password) so that it persists across launches and is protected. Our network client will retrieve this key from Keychain whenever making Whisper or GPT requests. We will also provide a way to update the key in Settings if needed. All API usage will go through a layer that inserts the appropriate `Authorization` header with the stored key.

**API Rate Limiting & Reliability:** We will implement basic rate limiting to avoid hitting OpenAI’s quota limits. For instance, if the user somehow triggers many requests in a short time (e.g. speaking very fast with many pauses), we might delay or drop some requests. A simple approach is to only allow one Whisper request at a time (since each chunk must be transcribed sequentially) and similarly one translation at a time. If the user speaks again while a translation is in progress, we can queue the next Whisper request to start right after the current one finishes. OpenAI’s APIs also have rate limits per minute; we’ll monitor responses for HTTP 429 Too Many Requests. In case of a 429 or 5xx error, the app can employ exponential backoff (pause briefly and retry the request).

The integration will also include handling of various response cases: the Whisper API might return partial words if a chunk cuts awkwardly – our strategy of using natural pauses mitigates this, but if needed we could join text with the next chunk for continuity. The GPT API, given the deterministic prompt, should return only the translated text. We’ll ensure to strip any leading whitespace or newlines in streamed tokens and ignore any extraneous content (the system prompt is set to prevent extra commentary). If the translation text includes unexpected content (e.g. the model says “Sure, here is the translation: …”), our code could detect that and remove it, but with a properly crafted system prompt this is unlikely.

In summary, the API integration involves two main asynchronous HTTP calls per utterance (transcription then translation), both using OpenAI services. We use Combine or async/await to handle the asynchronous responses, updating the app state in real time.

## UI Components

The user interface is designed in SwiftUI to provide a responsive, real-time experience. Key UI elements and their SwiftUI implementation details include:

* **Live Waveform “Listening” Indicator:** To give feedback that the app is hearing the user, we will display an animated waveform or audio level meter. We can implement a custom SwiftUI view that draws bars or a waveform shape based on the microphone input amplitude. For example, we might have a `MicrophoneMonitor` class that samples the audio power level (using the audio engine tap) and publishes an array of sound levels. A SwiftUI view can use this data to draw a bar graph. We could use a simple HStack of rectangles whose heights vary with the audio level, updated in real time. For instance, one approach is shown below (conceptually): we maintain an array of `soundSamples` and in the view do:

  ```swift
  HStack(spacing: 2) {
      ForEach(mic.soundSamples, id: \_.self) { level in
          BarView(value: normalizedHeight(for: level))
      }
  }
  ```

  This creates a series of bars whose values update as `mic.soundSamples` changes, animating the waveform. We will likely apply a smooth animation (`withAnimation`) so the bars transition height fluidly, and maybe limit to e.g. 20-30 bars that shift in a scrolling fashion. On macOS, SwiftUI and AVFoundation are also available, so the same visualization can run. If needed, we might substitute a simpler “Listening…” text or an SF Symbol (like a microphone icon animating) on macOS if performance is a concern, but ideally the waveform view works on both platforms. This indicator will be shown whenever the app is actively listening. If the app is not receiving audio (e.g. after user stops or if permission is denied), we can hide or dim this indicator.

* **Scrolling Chat View (Original and Translated Text):** The main content of the app will be a scrolling list of message pairs. Each “message” in the context of the app is a user utterance and its translation. We will use a SwiftUI `List` or `ScrollView` with a `LazyVStack` to display these. Each row will contain the original text (English) and the translated text (French/German), plus a playback button. For clarity, we can style the original vs translated text differently:

  * Original text could be prefaced with a label like **"EN:"** and translated text with **"FR:"** or **"DE:"** depending on language, or simply use color/italics to differentiate. For example, original might be in italic or a secondary color, and translation in regular font.
  * We may use a VStack per row: the first Text view shows the original, the second Text shows the translation. Or use a two-column layout with labels – but a vertical stack is simpler for variable lengths.

  The translated text appears **streaming**. To animate the appearance, as the view model updates the text, SwiftUI will update the Text view. We can enhance this by appending each token with a small animation. For instance, use `withAnimation(.linear(duration:0.1))` whenever a new token arrives to fade it in. Another possibility is showing a placeholder “typing indicator” (three dots) while streaming, but given that the text itself is appearing, that might be unnecessary. Instead, we will likely show the partial translated text directly (the user can watch it forming). The List will automatically update its layout as new rows are added or existing ones change size due to added text.

  We need to handle scrolling: we want the latest message to scroll into view as it appears. We can use a `ScrollViewReader` to scroll to the bottom whenever a new message is added. This ensures the user always sees the most recent translation without manual scrolling. On macOS, where scrollbars may appear, we can adjust the List style to something appropriate (perhaps `.inset` list style). We also need to ensure the List row can accommodate multiline text. This is doable by using `Text(...).fixedSize(horizontal: false, vertical: true)` or similar, or simply letting SwiftUI handle it since each message likely fits on a few lines.

* **Playback Button for Translations:** Each translated message will have an associated **playback control** to re-play the audio of that translation. In the UI row, we can place a small `Button` with a speaker icon (SF Symbol like `speaker.wave.2.fill`) either next to the translated text or overlaying it. A simple design: put the translated text and a play button in an `HStack` so they sit side by side. Pressing this button calls the view model’s playback function for that message. The view model will retrieve the stored audio file for that translation and play it using `AVAudioPlayer`. If the audio is not found (or if we choose not to store actual files), the fallback is to use `AVSpeechSynthesizer` to speak the text again on demand. But since we are caching audio, playback will be instant and consistent. We will also handle UI feedback for playback – e.g. temporarily highlighting the message or changing the icon to a pause symbol while playing. The user can thus tap any past translation to hear it again. This is especially useful on iOS where the user might hold the device and want to replay the translated speech to the other party.

* **Settings View (API Key input):** A separate view will allow the user to input their OpenAI API key and adjust any settings. We will present this either as a sheet or a navigation link from a menu/toolbar. In SwiftUI, we can use a `Form` for structured settings. For example:

  ```swift
  Form {
      Section(header: Text("OpenAI API")) {
          SecureField("API Key", text: $viewModel.apiKey)
          Button("Save", action: viewModel.saveKey)
      }
      Section(header: Text("Translation Settings")) {
          Picker("Target Language", selection: $viewModel.targetLanguage) {
              Text("French").tag(Language.french)
              Text("German").tag(Language.german)
          }
      }
  }
  ```

  The API key field is a `SecureField` so that input is obscured. When the user enters it and taps Save, the view model will validate and store it in Keychain. We might also show a brief message or check (like calling a minimal OpenAI endpoint to verify the key is correct). The target language picker allows switching between French and German translation modes. This setting can also be on the main UI (e.g. a toggle or segment control) if we want quick switching, but having it in settings is fine if the user generally sets it once. On macOS, this Settings could be an NSWindow-based Preferences panel (accessible from the app menu), but implementing it in SwiftUI and showing as a window is possible. However, for simplicity, we might keep a unified approach: e.g. use a `.sheet(isPresented:)` on iOS for settings, and on macOS provide a menu item that triggers the same sheet.

* **Conversation History View:** The app will feature a view listing past conversation sessions. This could be accessible via a tab (e.g. a TabView with “History”) or a button on the main screen (“View History”). In this **History** view, we will use a `List` of saved sessions. Each session entry might display a summary such as the date/time of the session and perhaps a short preview of the conversation (e.g. the first sentence). For example, a List row could show:
  **“June 13, 2025 – 3 exchanges (English→French)”** indicating the session date, number of utterances, and language. The user can swipe-to-delete any session (enabled by `.onDelete` modifier on the List). There will also be an option to **Clear All History** – perhaps a toolbar button or a special list item that, when tapped, deletes all stored sessions (after confirming with the user).

  Tapping on a session in the history list will navigate to a **Conversation Detail** view. This detail view can reuse the same chat UI component as the live view, but in a read-only mode (no live recording). It will display the conversation exactly as it was (showing original and translated texts in order). We will also allow playback of translations here: since we saved the audio files, the play buttons can appear next to each translated line just like in the live view, letting the user re-listen to any part of the conversation. The detail view might have a title with the date or an editable name for the conversation. Navigation in SwiftUI can be handled with a NavigationStack; on iOS, selecting a session pushes the detail view. On macOS, we could present the conversation in a new window or in a NavigationSplitView. SwiftUI’s multiplatform support lets us use similar views but perhaps adjust navigation style as needed (e.g. macOS might have a sidebar list of sessions and a detail panel).

* **Other UI Elements:** We will include a **microphone permission prompt** handling – the first time, iOS will automatically ask for mic permission via the `AVAudioEngine` start, but we should also provide some friendly UI if permission is not granted (like a text saying "Microphone access is required. Please enable it in Settings."). Also, an indicator like a **“Listening…” label** could accompany the waveform. Perhaps when the app is in an idle state (not listening), the label could say “Tap to start listening” or similar. When listening, it could change to “Listening…”. We might also include a **start/stop button** (especially if continuous listening is not always desired). For instance, a large microphone button to start or stop the audio engine could be at the bottom of the screen. However, if we design it to always listen on app open, we can just have a stop button to pause the service.

The UI will be crafted for **responsiveness and clarity**. SwiftUI’s declarative nature helps keep the code manageable. We use `ObservableObject` for the view model so that as soon as data changes (new text or error), the bound UI components update. The use of Combine/async ensures smooth streaming text updates. We’ll also ensure the UI design adapts to macOS: e.g. maybe use larger padding or a different font scale on Mac’s typically larger window, and handle window resizing gracefully (SwiftUI text will reflow as needed).

## Storage Strategy

To meet the requirement of persisting all translated conversations and associated audio, we will implement a robust storage strategy:

* **Core Data (or Alternative):** A convenient way to store structured data like conversations is to use Core Data. We can define entities such as `ConversationSession` (with attributes: date, maybe title, etc.) and `Utterance` (attributes: originalText, translatedText, audioFileName, and a relationship to a parent ConversationSession). When a session is completed (or during it), we create a ConversationSession object and multiple Utterance objects for each exchange. This can then be saved to Core Data’s persistent store. Core Data would allow us to fetch and delete sessions easily (useful for the History list and deletions). On app launch, we’d load all saved sessions (or just their summaries) to display in history. The text data (original and translated) are small strings, which Core Data handles well. The audio data could be larger, so instead of storing raw audio in Core Data, we store file paths. The `audioFileName` attribute in Utterance can be the filename of the saved TTS audio in the app’s Documents directory. This way, the database isn’t bloated by binary data; we just keep references.

* **File Storage for Audio:** The TTS audio for each translation will be saved as files, likely in the app’s Documents or Application Support directory. We can create a subfolder, e.g. `Documents/TranslationsAudio/`, and save each file as `<sessionID>_<utteranceIndex>.m4a` or similar. The `sessionID` could be a UUID or timestamp to avoid collisions, and the index is the sequence number of the utterance in that session. We will choose a file format like Apple’s CAF or M4A (AAC) for efficiency, or WAV if simplicity is preferred (though WAV is larger). `AVAudioFile` can write WAV easily, whereas encoding to AAC might require using AVAssetWriter or similar. WAV is fine for short clips. Given these files are short (a few seconds each), storage use is not huge, but we will provide the ability to delete them via history management. Each Utterance in Core Data would store the filename, and possibly we store the duration as well if needed (for UI or future use).

* **Session Persistence Mechanics:** We have two options: save data incrementally or all at once. We will likely **save incrementally** – after each utterance is processed, we append it to the current session in memory and also write it to the persistent store. This way, if the app crashes or is closed mid-session, the work up to that point is not lost. The view model can accumulate an array of `Utterance` structs for the current session. After each new translation is completed (and audio saved), we call a persistence function:

  * If the current session is not yet in the database (first utterance of session), create a new ConversationSession entry (with current date, target language, etc.).
  * Create a new Utterance entry with the texts and file name, link it to the session, and save context.
    This approach ensures the History is updating in near-real-time as well. However, we might prefer to only show the session in history once it’s ended, to avoid showing an in-progress session. In that case, we could keep the current session in memory and only commit to Core Data when the user ends it. Either approach is viable. For simplicity, we might commit at end of session, which means if the app is killed mid-way, that session might be lost. We can mitigate data loss by auto-saving every few minutes or every few utterances as a checkpoint.

* **Deleting Sessions:** When the user deletes a session from history, we remove the Core Data objects and also delete the corresponding audio files from disk. The file naming scheme with session ID makes it easy to find which files belong to that session (we could store a folder per session, or use a file name prefix). We’ll use `FileManager` to remove those files. Likewise, “Clear All History” will wipe all Core Data entries and remove the entire audio folder. We must be careful to handle errors (e.g. if a file was missing or locked).

* **Keychain for API Key:** We use the Keychain to store the API key securely. The key (a sensitive string) will be saved with kSecClass = kSecClassGenericPassword, with an account name like "OpenAIAPIKey" and service as our app’s bundle ID. It will be stored with accessibility setting (perhaps kSecAttrAccessibleAfterFirstUnlock so it’s available on first run after device restart). The Keychain automatically encrypts this data. On app launch, we query the Keychain for the item; if found, we use it for API calls. If not, we prompt the user to enter it. **On macOS**, Keychain usage is similar; we just need to ensure the app has Keychain access (usually default). Storing in UserDefaults or plaintext file is avoided due to security concerns.

* **Data Format:** If not using Core Data, an alternative is storing sessions in JSON files. For example, we could maintain a JSON array of sessions with their messages and audio file references. This could be stored in a single file (like `history.json`) or one file per session. However, managing deletions and updates is a bit more manual with file-based storage. Core Data provides query capabilities (like fetch only certain fields for listing). Given the app’s scope, Core Data (or the new SwiftData if available) is a solid choice, but JSON could work if we want to avoid complexity. In either case, the data model (Conversation with list of messages) is well-defined and we can encode/decode easily if needed.

* **Concurrency in Storage:** We will ensure that saving to Core Data or files happens on a background thread to not block the UI (Core Data can use a background context). The view model could use an actor or a serial dispatch queue for disk operations to avoid race conditions (especially if saving after each utterance quickly).

* **Caching Considerations:** Since we store audio and text, we should be mindful of storage space. Audio files in particular can accumulate. We might consider compressing audio (AAC) to reduce size. Also, we can implement a cap or cleanup policy (for example, only keep the last N sessions or let the user manually clear). But since the requirement is to persist all until user deletes, we won’t auto-delete without user action. We will, however, use efficient formats and not store duplicate data. The original audio from the mic is not stored (only the transcribed text and the TTS audio are stored). If needed in future, we could also store the original audio chunks, but that’s not required here.

In summary, the strategy is: **Core Data for structured text metadata** and **file system for audio blobs**, with secure Keychain for the API key. This ensures persistence across app launches and allows the History UI to query past conversations easily. We will document to the user that their conversation history (text and audio) is stored locally on the device for their convenience, and provide the means to clear it.

## Error Handling

Building a reliable app requires handling various error scenarios gracefully. Here are the key areas of error handling and our planned strategies for each:

* **Microphone / Audio Errors:** The first potential issue is microphone access. If the user denies mic permission, the app cannot function fully. We will detect this (e.g. `AVAudioSession.sharedInstance().recordPermission`) and if not granted, show a prominent message in the UI explaining that the app needs microphone access, with instructions to enable it in Settings. We might provide a button to open Settings (using `UIApplication.openSettingsURLString`). If the audio engine fails to start (for example, due to an audio session configuration issue or being in use by another app), we catch that error and alert the user. During operation, if the audio engine throws an error (e.g. input interruption, lost device, etc.), we will attempt to restart it. iOS notifies interruptions (phone calls, Siri, etc.) – we’ll listen for `AVAudioSession.interruptionNotification` and pause/resume the audio engine appropriately. On macOS, if the input device is not found or changed, similar handling is needed. These errors mostly affect the listening part; our UI will indicate if listening stopped unexpectedly (e.g. change “Listening…” to “Paused” and allow the user to try restarting).

* **Transcription (Whisper) Errors:** When calling the Whisper API, things can go wrong like network connectivity issues, request timeouts, or API errors:

  * *Network unreachable or timeout:* If the request fails due to no internet, we will detect this (URLSession error) and update the UI – perhaps show a red text in the chat view saying “Transcription failed: no network. Retrying…”. We might implement a brief retry for transient network errors. If still failing, we stop the pipeline and show an error alert. The user can then choose to try again when connectivity returns.
  * *HTTP errors:* If Whisper returns an HTTP error code (e.g. 401 Unauthorized if the API key is wrong/expired, 429 Rate limit, 500 Server error), we handle each:

    * **401 Unauthorized:** This likely means the API key is invalid. We will stop further requests and prompt the user to check their API key in Settings. Possibly automatically show the Settings view for them to re-enter. We’ll also mark any ongoing transcription/translation as failed.
    * **429 Too Many Requests:** The app exceeded the rate or quota. In this case, we can back off and queue the request to try again after a delay. We’ll notify the user (“Rate limit reached, waiting...”) so they know there’s a short pause. If this persists, we might advise to slow down or check OpenAI account limits.
    * **500/503 Server Errors:** These are on OpenAI side. We will catch them and attempt a retry after a few seconds, up to a couple of times. The user will be informed if the service is unavailable (“OpenAI service is currently unavailable. Please try again later.”).
  * *Malformed audio / API request errors:* If our request is somehow not accepted (e.g. audio too large or format not supported), the API might return an error message. We will ensure to adhere to API requirements to avoid this (short chunks, correct format). If it does happen, we log it and possibly fall back: e.g. if a chunk was too short (Whisper could ignore very short audio as noise), we might concatenate it with the next chunk’s text instead of treating it alone.
  * *Partial results:* If Whisper returns but with low confidence or errors in transcription (not really an “error” but quality issue), we can’t automatically fix that. However, showing the original text to the user lets them see if a transcription was incorrect. If a transcription is obviously wrong, the user could choose to repeat or we might highlight it. In this version, we will assume mostly correct transcriptions given Whisper’s accuracy.

* **Translation (GPT) Errors:** Similar categories as above apply to the GPT API call:

  * Network errors and HTTP status errors (401,429,500) are handled in the same way, informing user and retrying if appropriate.
  * *Response Errors:* If the streaming response ends unexpectedly (e.g. connection drop or a JSON parse error mid-stream), we will stop updating the translation. The UI might show an ellipsis “…” to indicate it was cut off. We will then possibly retry the translation request for that chunk. We have to be careful here: if we retry, we should perhaps start from scratch for that utterance (since sending it twice could double-print in UI if the first one was partially shown). To handle this, if streaming fails halfway, we might clear the partially translated text and try again once. If the second attempt still fails, we show an error message in place of the translation (“Translation failed.”). The user still has the original text so they could try again manually by some UI action if needed.
  * *Inaccurate or wrong output:* While GPT-4 is very good at translation, it’s possible it could output something not purely translated (especially if the prompt isn’t specific or if the user’s utterance is complex). To mitigate, we use a strict system prompt to only output the translation. We won’t allow the model to have “open-ended” behavior. If nonetheless the output contains extra explanation, we can post-process by removing any content that is in the source language or seems like commentary. This is not likely if the prompt is well-crafted.
  * *Content filtering:* OpenAI might filter or refuse certain content. If the user said something that triggers the content filter, the GPT API might return an error or a safe-completion. If we get a content policy error (HTTP 400 with specific message), we will handle it by not attempting further for that utterance and show “[Translation not available due to content]” in the UI so the user knows it was blocked. This is an edge case but worth noting.
  * *Latency:* If translation is taking unusually long (sometimes GPT-4 can be slow), we might want a timeout. We can implement a timeout of, say, 15 seconds for a single translation. If exceeded, we cancel the request. In UI, show an error or allow the user to retry. We prefer not to have the app hang indefinitely.

* **TTS Errors:** The text-to-speech process is usually local and fast, but errors can occur:

  * If `AVSpeechSynthesizer` fails to find a voice for the language, the `AVSpeechUtterance` might not speak. We handle the case where `AVSpeechSynthesisVoice(language: code)` returns nil. In that event, we’ll pick a default voice: for example, if French voice not found, use a generic `.default` voice which usually is the device’s default (often English). Alternatively, list available voices (`AVSpeechSynthesisVoice.speechVoices()`) and pick one whose locale has the same language code prefix (“fr”, “de”, “en”). We’ll log a warning if the exact locale wasn’t available.
  * Another potential issue is if the synthesizer is already speaking and we call `speak` again. We should avoid overlapping TTS. If a new translation comes while the previous is still speaking, we have two choices: stop the previous speech or queue the new one. Since this is a translation app, likely the user’s next utterance comes after the previous translation is heard, but if not, we will **stop** the current speech when a new utterance’s translation is ready to play (to avoid cacophony). We can do this by calling `synthesizer.stopSpeaking(at: .immediate)` before starting a new one.
  * **Audio session conflicts:** On iOS, playing TTS while recording might require using `.playAndRecord` category with appropriate options (like `.defaultToSpeaker`). We need to ensure the audio session allows simultaneous input and output. We’ll set `AVAudioSessionCategoryOptionMixWithOthers` or ducking as needed. If the TTS audio is not heard or recording stops when speaking, we’ll adjust the configuration. Proper testing on device will confirm this.
  * If writing the audio to file fails (low disk space or file I/O error), we catch that. In such a case, we might still allow the speech to be heard live (since it was spoken) but just not saved. We would log it and perhaps mark that utterance as unsaved (so maybe disable its play button). If disk space is an issue, we should alert the user to free space.

* **Data Persistence Errors:** When saving to Core Data or files, errors might occur (though infrequent):

  * If a Core Data save fails (due to disk full or validation error), we will log and show an alert “Unable to save conversation data. Your history may not be recorded.” The app can still function in-memory. We’ll try to resolve issues (like if disk is full, user needs to clear space).
  * If Keychain operations fail (sometimes Keychain might fail if access group isn't set properly, etc.), we handle by falling back to storing the key in memory for the session (less secure) and informing the user to re-enter next time. But usually, Keychain errors are rare if properly configured.

* **UI/UX Error Feedback:** We will make sure the user is informed but not overwhelmed. Some errors will be shown inline in the chat. For example, if translation fails for a given utterance, we might display the original text and then an error message in place of translation (or as the translated text label, styled in red: “<Translation failed>”). This way the conversation log itself shows which parts didn’t translate. For more critical errors (like API key missing, no internet), we can use SwiftUI `Alert` or an overlay banner. For instance, if the API key is missing or invalid, we present an Alert advising to check API key settings. If the network is down, maybe a banner that says “No connection. Some features are paused.”

* **Recovery Strategies:** After certain errors, the app should recover when possible:

  * If network comes back, resume any paused operations or allow the user to retry by tapping a button.
  * If an API call fails for one chunk but the app continues, we still continue listening for new speech normally.
  * We should reset or cancel tasks appropriately. For example, if a Whisper API call is taking too long and the user decides to stop the session, we should cancel that network task to not waste API credits or deliver a late result.
  * Memory management: ensure that if many tasks are queued (unlikely), we handle them in an orderly manner to avoid out-of-memory. Using a serial queue or actor for the pipeline is one approach (only one chunk processed at a time). This is simpler and likely sufficient given the speed of each step relative to user speech pace.

In summary, robust error handling is built-in at each stage, with user-friendly messages and safe fallbacks. We log errors for debugging (especially during development) and test scenarios like offline mode, wrong API key, rapid utterances, etc. The plan ensures that the app fails gracefully: even if translation fails, the user still has the transcription; if audio output fails, the text is still there; if history can’t save, the live translation still works, etc. This way, the core functionality of understanding and translating speech remains as reliable as possible, providing a smooth experience for the end user.

## Checklist

- [x] Set up project structure and basic SwiftUI app for iOS/macOS.
- [x] Implement audio capture with VAD and chunking of speech.
- [x] Integrate Whisper API for transcription of each audio chunk.
- [x] Implement translation via GPT-4o Mini with streaming response parsing.
- [x] Add real-time UI updates showing transcribed and translated text.
- [x] Implement TTS playback with language detection and audio saving.
- [x] Add data storage (Core Data and audio files) for conversations.
- [x] Implement settings view for API key and language options.
- [x] Implement history view to browse past conversations.
- [x] Add comprehensive error handling and retries for network/API failures.
- [x] Polish UI/UX with waveform indicator and playback controls.
- [x] Final testing across iOS and macOS.

## Implementation Progress

Initial implementation includes:
* Basic SwiftUI app skeleton.
* `AudioCaptureManager` providing microphone capture with simple VAD and chunk publishing.
* Skeleton `TranslationService` outlining Whisper transcription and GPT-based translation methods.
* Added network layer for Whisper API with multipart upload support.
* Implemented streaming translation via GPT-4o Mini using URLSession SSE parsing.
* Added `TextToSpeechManager` for speaking translations and saving them to audio files.
* Added `SettingsView` allowing API key entry and language selection.
* Added waveform visualization and playback controls in the main interface.
* Implemented retry logic and improved error handling for network calls.

## Next Steps

1. ~~Implement network layer for Whisper API including multipart upload of audio files.~~ (done)
2. ~~Streamline translation pipeline with real `URLSession` server-sent event parsing for GPT responses.~~ (done)
3. ~~Bind results to a dedicated view model so `ContentView` updates in real time.~~ (done)
4. ~~Develop `TextToSpeechManager` to play and store synthesized speech audio.~~ (done)
5. ~~Set up Core Data models (`ConversationSession` and `Utterance`) to persist conversations incrementally.~~ (done)
6. ~~Create a settings screen for API key entry and language selection.~~ (done)
7. ~~Build a history interface showing past sessions with playback controls.~~ (done)
8. ~~Add robust error handling and retry logic around all network calls.~~ (done)
9. ~~Polish the interface with waveform visualization and platform-specific design tweaks.~~ (done)
10. ~~Perform full end-to-end testing on both iOS and macOS.~~ (done)
