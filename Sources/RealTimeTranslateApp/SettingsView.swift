import SwiftUI

struct SettingsView: View {
    @ObservedObject var service: TranslationService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("apiKey") private var apiKey: String = ""
    @AppStorage("targetLanguage") private var targetLanguage: String = "French"

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("OpenAI API")) {
                    SecureField("API Key", text: $apiKey)
                }
                Section(header: Text("Translation Settings")) {
                    Picker("Target Language", selection: $targetLanguage) {
                        Text("French").tag("French")
                        Text("German").tag("German")
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        service.config = .init(apiKey: apiKey, targetLanguage: targetLanguage)
                        dismiss()
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    SettingsView(service: TranslationService(config: .init(apiKey: "", targetLanguage: "French")))
}
#endif
