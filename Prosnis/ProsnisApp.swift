import SwiftUI

@main
struct ProsnisApp: App {
    @StateObject private var store = AlarmStore()
    @StateObject private var journal = JournalStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                AlarmListView()
                    .tabItem { Label("Будильники", systemImage: "alarm") }
                JournalView()
                    .tabItem { Label("Журнал", systemImage: "list.bullet.rectangle") }
            }
            .environmentObject(store)
            .environmentObject(journal)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
        }
    }
}
