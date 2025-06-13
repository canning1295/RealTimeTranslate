import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = SpeechTranslationViewModel(
        service: TranslationService(config: .load())
    )
    @State private var showingSettings = false

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
            Button("Settings") { showingSettings = true }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(service: viewModel.service)
        }
    }
}

#if DEBUG
#Preview {
    ContentView()
}
#endif
