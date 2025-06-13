import SwiftUI

@main
struct RealTimeTranslateApp: App {
    let persistence = PersistenceController.shared
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistence.container.viewContext)
        }
    }
}
