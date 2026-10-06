import SwiftUI

@main
struct ProsnisApp: App {
    @StateObject private var store = AlarmStore.shared
    @StateObject private var journal = JournalStore.shared
    @StateObject private var wake = WakeCoordinator.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var challenges = ChallengeStore.shared
    @StateObject private var social = SocialStore.shared
    @StateObject private var payments = PaymentsStore.shared
    @StateObject private var sync = SyncEngine.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(journal)
                .environmentObject(wake)
                .environmentObject(settings)
                .environmentObject(challenges)
                .environmentObject(social)
                .environmentObject(payments)
                .environmentObject(sync)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await becameActive() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await becameActive() } }
                }
        }
    }

    /// Всё, что нужно сделать при открытии приложения.
    @MainActor
    private func becameActive() async {
        // Если приложение запустилось из звонка до разблокировки, файлы могли быть закрыты.
        settings.reloadIfNeeded()
        AlarmService.shared.reloadIfNeeded()
        store.reloadIfNeeded()
        challenges.reloadIfNeeded()
        payments.reloadIfNeeded()
        wake.reconcile()
        store.refreshDatedAlarms()
        challenges.evaluateAll()
        await payments.retryPending()
        await payments.checkIfNeeded()
        let backend = BackendRegistry.current
        if backend.isOnline {
            await sync.sync(using: backend)
            social.publishStatus()
        }
    }
}

/// Вкладки, задания и утро поверх всего.
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var wake: WakeCoordinator

    var body: some View {
        if !settings.data.onboardingDone {
            OnboardingView()
        } else {
            TabView {
                AlarmListView()
                    .tabItem { Label("Будильники", systemImage: "alarm") }
                ProgressTabView()
                    .tabItem { Label("Прогресс", systemImage: "chart.line.uptrend.xyaxis") }
                CommunityView()
                    .tabItem { Label("Сообщество", systemImage: "person.3") }
                ProfileView()
                    .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
            }
            .overlay(alignment: .top) {
                if let session = wake.session, session.phase == .waiting {
                    RecheckBanner(session: session)
                }
            }
            .fullScreenCover(
                isPresented: Binding(
                    get: { wake.session?.phase == .task },
                    set: { _ in }
                ),
                onDismiss: { wake.presentPendingMorning() }
            ) {
                if let session = wake.session {
                    WakeTaskView(session: session)
                        .preferredColorScheme(.dark)
                }
            }
            .sheet(item: $wake.morning) { state in
                MorningView(state: state)
                    .preferredColorScheme(.dark)
            }
            .task {
                // Пока приложение открыто, сверка идёт каждые 30 секунд: звонок мог прийти, пока экран был включён.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    wake.reconcile()
                }
            }
        }
    }
}
