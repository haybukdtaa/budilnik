import SwiftUI

@main
struct ProsnisApp: App {
    @StateObject private var store = AlarmStore()

    var body: some Scene {
        WindowGroup {
            AlarmListView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
