import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = SpeechTranslationViewModel(
        service: TranslationService(config: .load())
    )
    @State private var showingSettings = false
    @State private var showingHistory = false

    var body: some View {
        VStack {
            List(viewModel.messages) { message in
                VStack(alignment: .leading) {
                    Text(message.original)
                        .font(.body)
                    Text(message.translated)
                        .font(.callout)
                        .foregroundColor(.blue)
                }
            }
            .frame(minHeight: 200)

            HStack {
                Button("Start") { viewModel.start() }
                Button("Stop") { viewModel.stop() }
            }
            .padding()
        }
        .padding()
        .toolbar {
            Button("History") { showingHistory = true }
            Button("Settings") { showingSettings = true }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(service: viewModel.service)
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView()
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
        }
    }
}

#if DEBUG
#Preview {
    ContentView()
}
#endif
