import SwiftUI
import UserNotifications

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

    init() {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        MedStore.registerCategory()
        Theme.applyAppearance()
    }

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
                .preferredColorScheme(.light)
                .foregroundStyle(Theme.ink)
                .tint(Theme.accent)
                .task { await becameActive() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await becameActive() } }
                }
                // Сменился часовой пояс (поездка): будильники на конкретные даты переставляются сразу.
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                    store.refreshDatedAlarms(force: true)
                    // Ожидания по старому поясу остаются: утро не теряется, а одно утро не списывается дважды.
                    store.refreshExpected()
                }
        }
    }

    /// Всё, что нужно сделать при открытии приложения.
    @MainActor
    private func becameActive() async {
        // Если приложение запустилось из звонка до разблокировки, файлы могли быть закрыты.
        journal.reloadIfNeeded()
        settings.reloadIfNeeded()
        AlarmService.shared.reloadIfNeeded()
        store.reloadIfNeeded()
        VoiceLibrary.shared.reloadIfNeeded()
        challenges.reloadIfNeeded()
        payments.reloadIfNeeded()
        wake.reconcile()
        store.refreshExpected()
        store.refreshDatedAlarms()
        store.resyncFailed()
        store.cleanupOrphans()
        await DeadlineNotifications.refresh()
        challenges.evaluateAll()
        await payments.retryPending()
        await payments.checkIfNeeded()
        social.sendPendingWitnessNotice()
        social.sendPendingGardenWater()
        MedStore.shared.reloadIfNeeded()
        MedStore.shared.refresh()
        await WeeklyNotification.update(enabled: settings.data.weeklySummaryOn)
        AccountStore.shared.ensureIdentity()
        await AccountStore.shared.ensureSignedIn()
        await AccountStore.shared.mergeRestoredData()
        let backend = BackendRegistry.current
        if backend.isOnline && !backend.isDemo {
            // Время сервера — самое надёжное для блокировки ставки.
            if let serverNow = try? await backend.serverTime() { TrustedClock.anchorToServer(serverNow) }
            await sync.sync(using: backend)
        }
        if backend.isOnline {
            social.publishStatus()
        }
    }
}

/// Вкладки, задания и утро поверх всего.
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var wake: WakeCoordinator
    @ObservedObject private var alarmStore = AlarmStore.shared
    @ObservedObject private var router = NotificationRouter.shared
    @ObservedObject private var journal = JournalStore.shared
    @State private var tab = 0
    /// Человек закрыл условия, не согласившись: до следующего запуска не спрашиваем.
    @State private var consentPostponed = false

    /// Запуск с «-screenshotTab N» (для скриншотов в автотестах): сразу вкладка N с тестовыми данными.
    /// Работает только в отладочной сборке.
    static var screenshotTab: Int? {
        #if DEBUG
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-screenshotTab"), index + 1 < args.count else { return nil }
        return Int(args[index + 1])
        #else
        return nil
        #endif
    }

    /// Запуск с «-screenshotScreen имя» (для скриншотов в автотестах): сразу нужный экран. Только в отладочной сборке.
    static var screenshotScreen: String? {
        #if DEBUG
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-screenshotScreen"), index + 1 < args.count else { return nil }
        return args[index + 1]
        #else
        return nil
        #endif
    }

    /// Пример списания для скриншота карточки.
    private static var sampleCharge: JournalEntry {
        JournalEntry(
            date: Calendar.current.date(bySettingHour: 6, minute: 30, second: 0, of: Date()) ?? Date(),
            alarmTitle: "Работа", timeText: "06:30", stake: 500, outcome: .failed,
            events: [JournalEvent(date: Date(), text: "Время на задание истекло")]
        )
    }

    /// Списание, которое пора показать карточкой (не поверх задания, утра или согласия).
    private var chargeToShow: JournalEntry? {
        guard wake.session == nil, wake.morning == nil, reconsentAmount == nil,
              RootView.screenshotTab == nil else { return nil }
        return JournalStore.firstUnseenCharge(in: journal.entries)
    }

    /// Запуск с «-gardenPreview» (для снимка 3D-сада) работает только в отладочной сборке.
    static var gardenPreviewRequested: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("-gardenPreview")
        #else
        return false
        #endif
    }

    /// Условия ставки изменились: ставки не действуют, пока человек не согласится заново.
    private var reconsentAmount: Int? {
        guard !consentPostponed, wake.session == nil, wake.morning == nil else { return nil }
        return alarmStore.alarmsNeedingConsent.map(\.stakeAmount).max()
    }

    var body: some View {
        if let screen = RootView.screenshotScreen {
            if screen == "charge" {
                ChargeCardView(entry: RootView.sampleCharge, onDismiss: {}, onDispute: {})
            } else {
                NavigationStack { PrayerSettingsView() }
                    .onAppear {
                        settings.setModule(.prayer, enabled: true)
                        settings.data.prayer.cityID = "makhachkala"
                    }
            }
        } else if RootView.gardenPreviewRequested {
            // Для снимка 3D-сада в автотестах: сразу сад, без приветствия.
            NavigationStack { GardenView(forcePreview: true) }
        } else if !settings.data.onboardingDone && RootView.screenshotTab == nil {
            OnboardingView()
        } else {
            TabView(selection: $tab) {
                AlarmListView()
                    .tag(0)
                    .tabItem { Label("Будильники", systemImage: "alarm") }
                    .sheet(isPresented: Binding(
                        get: { reconsentAmount != nil },
                        set: { if !$0 { consentPostponed = true } }
                    )) {
                        StakeTermsView(amount: reconsentAmount ?? 0) {
                            settings.acceptStakeTerms(amount: reconsentAmount ?? 0)
                            consentPostponed = true
                        }
                    }
                ProgressTabView()
                    .tabItem { Label("Прогресс", systemImage: "chart.line.uptrend.xyaxis") }
                    .tag(1)
                    .sheet(isPresented: Binding(
                        get: { router.showWeekly && wake.morning == nil && wake.session == nil },
                        set: { router.showWeekly = $0 }
                    )) {
                        NavigationStack {
                            WeeklySummaryView()
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Закрыть") { router.showWeekly = false }
                                    }
                                }
                        }
                    }
                CommunityView()
                    .tabItem { Label("Сообщество", systemImage: "person.3") }
                    .tag(2)
                if settings.data.medsEnabled {
                    MedsView()
                        .tabItem { Label("Лекарства", systemImage: "pills") }
                        .tag(4)
                }
                ProfileView()
                    .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
                    .tag(3)
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
                        .foregroundStyle(.primary)
                }
            }
            .sheet(item: Binding(get: { chargeToShow }, set: { _ in })) { entry in
                ChargeCardView(
                    entry: entry,
                    onDismiss: { journal.markChargeSeen(entry.id) },
                    onDispute: {
                        journal.dispute(entry)
                        journal.markChargeSeen(entry.id)
                    }
                )
                .interactiveDismissDisabled()
            }
            .sheet(item: $wake.morning) { state in
                MorningView(state: state)
                    .preferredColorScheme(.light)
            }
            .onAppear {
                guard let screenshot = RootView.screenshotTab else { return }
                tab = screenshot
                // Тестовые данные, чтобы на скриншоте было что показать (только в отладочной сборке).
                if JournalStore.shared.entries.isEmpty { JournalStore.shared.addDemoEntries() }
                if !settings.data.useDemoSocial { settings.data.useDemoSocial = true }
                if !settings.data.medsEnabled { settings.data.medsEnabled = true }
                if MedStore.shared.meds.isEmpty {
                    var vitamin = Medication(name: "Витамин D", dose: "1 капсула", form: .capsule, times: [8 * 60 + 30], meal: .after)
                    vitamin.startDate = Calendar.current.startOfDay(for: Date())
                    MedStore.shared.save(vitamin)
                    var antibiotic = Medication(name: "Амоксициллин", dose: "500 мг", form: .tablet, times: [9 * 60, 21 * 60], meal: .during)
                    antibiotic.startDate = Calendar.current.startOfDay(for: Date())
                    antibiotic.endDate = Date().addingTimeInterval(6 * 86400)
                    antibiotic.stock = 8
                    MedStore.shared.save(antibiotic)
                }
            }
            .onChange(of: router.showWeekly) { _, show in
                if show { tab = 1 }
            }
            .onChange(of: router.showMeds) { _, show in
                if show {
                    if settings.data.medsEnabled { tab = 4 }
                    router.showMeds = false
                }
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
