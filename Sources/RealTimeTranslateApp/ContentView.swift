import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = SpeechTranslationViewModel(
        service: TranslationService(
            config: .init(apiKey: "YOUR_API_KEY", targetLanguage: "French")
        )
    )

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
    }
}

#if DEBUG
#Preview {
    ContentView()
}
#endif
