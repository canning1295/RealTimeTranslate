import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct RealTimeTranslateApp: App {
    let persistence = PersistenceController.shared
    init() {
#if os(macOS)
        // Ensure the app shows a dock icon and its windows become visible when
        // running as a command-line executable on macOS.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
#endif
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistence.container.viewContext)
        }
    }
}
