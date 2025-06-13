import SwiftUI
import CoreData
import AVFoundation

struct HistoryView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(
        entity: ConversationSession.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \ConversationSession.timestamp, ascending: false)]
    ) private var sessions: FetchedResults<ConversationSession>

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions) { session in
                    NavigationLink(value: session) {
                        Text(session.timestamp, style: .date)
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: ConversationSession.self) { session in
                SessionDetailView(session: session)
            }
        }
    }
}

private struct SessionDetailView: View {
    @ObservedObject var session: ConversationSession
    @State private var audioPlayer: AVAudioPlayer?

    private var utterances: [Utterance] {
        Array(session.utterances).sorted { $0.original < $1.original }
    }

    var body: some View {
        List(utterances) { utt in
            VStack(alignment: .leading) {
                Text(utt.original)
                    .font(.body)
                Text(utt.translated)
                    .font(.callout)
                    .foregroundColor(.blue)
                if let path = utt.audioPath {
                    Button("Play") { play(url: URL(fileURLWithPath: path)) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle(session.timestamp, format: .dateTime)
    }

    private func play(url: URL) {
        audioPlayer?.stop()
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
        } catch {
            print("Audio playback error: \(error)")
        }
    }
}

#if DEBUG
#Preview {
    HistoryView()
        .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
}
#endif
