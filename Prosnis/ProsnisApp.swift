import SwiftUI

@main
struct ProsnisApp: App {
    @StateObject private var store = AlarmStore.shared
    @StateObject private var journal = JournalStore.shared
    @StateObject private var wake = WakeCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

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
            .environmentObject(wake)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .overlay(alignment: .top) {
                if let session = wake.session, session.phase == .waiting {
                    RecheckBanner(session: session)
                        .environmentObject(wake)
                }
            }
            .fullScreenCover(
                isPresented: Binding(
                    get: { wake.session?.phase == .task },
                    set: { _ in }
                )
            ) {
                if let session = wake.session {
                    WakeTaskView(session: session)
                        .environmentObject(wake)
                        .preferredColorScheme(.dark)
                }
            }
            .task { wake.reconcile() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { wake.reconcile() }
            }
        }
    }
}
