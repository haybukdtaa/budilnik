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
        // Фоновая проверка шагов обещаний (по возможности): обработчик нужно зарегистрировать до конца запуска.
        PromiseBackground.register()
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
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                // Переключатели — бордовые, как кнопки логотипа.
                .toggleStyle(SwitchToggleStyle(tint: Theme.toggle))
                .task { await becameActive() }
                .onChange(of: scenePhase) { _, phase in
                    // Время вне приложения (в том числе с заблокированным экраном) считает фокус-сессия.
                    FocusStore.shared.scenePhaseChanged(phase)
                    if phase == .active { Task { await becameActive() } }
                }
                // Сменился часовой пояс (поездка): будильники на конкретные даты переставляются сразу.
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                    // Календарь и пояс кешируются: без сброса расчёт пошёл бы по старому поясу.
                    NSTimeZone.resetSystemTimeZone()
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
        FocusStore.shared.reloadIfNeeded()
        FocusStore.shared.scenePhaseChanged(.active)
        // Чтение шагов может занять время: остальное при открытии его не ждёт.
        Task {
            await PromiseStore.shared.reconcile(force: true)
            await PromiseStore.shared.restoreNotifications()
            PromiseBackground.schedule()
        }
        store.refreshExpected()
        store.refreshDatedAlarms()
        // Лекарства читаем до чистки: иначе их напоминания могли бы показаться «лишними».
        MedStore.shared.reloadIfNeeded()
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
        await HealthCheck.shared.refresh()
        await ConsentSync.flush()
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
    @ObservedObject private var focus = FocusStore.shared
    @ObservedObject private var health = HealthCheck.shared
    @State private var tab = 0
    /// Человек закрыл условия, не согласившись: до следующего запуска не спрашиваем.
    @State private var consentPostponed = false
    /// Окно документов и согласий закрыли («Позже»): до следующего запуска не спрашиваем.
    @State private var legalPostponed = false
    @State private var showLegalSheet = false

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
        guard wake.session == nil, wake.morning == nil, wake.note == nil, !focus.showsCover, reconsentAmount == nil,
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

    /// Условия обязательства изменились: ставки не действуют, пока человек не согласится заново.
    private var reconsentAmount: Int? {
        guard !consentPostponed, wake.session == nil, wake.morning == nil, wake.note == nil, !focus.showsCover,
              RootView.screenshotTab == nil else { return nil }
        return alarmStore.alarmsNeedingConsent.map(\.stakeAmount).max()
    }

    /// Нужно ли показать окно документов и согласий (не поверх задания, утра, фокус-сессии).
    private var legalSheetVisible: Bool { showLegalSheet && legalToShow && chargeToShow == nil && reconsentAmount == nil }

    private var legalToShow: Bool {
        guard !legalPostponed, settings.data.onboardingDone, wake.session == nil, wake.morning == nil, wake.note == nil,
              !focus.showsCover, RootView.screenshotTab == nil, RootView.screenshotScreen == nil else { return false }
        return ConsentRules.needsPrompt(settings.data.consents)
    }

    var body: some View {
        if let screen = RootView.screenshotScreen {
            if screen == "charge" {
                ChargeCardView(entry: RootView.sampleCharge, onDismiss: {}, onDispute: {})
            } else if screen == "promise" {
                PromiseEditView()
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
            VStack(spacing: 0) {
            // Плашка повторной проверки сдвигает вкладки вниз, а не лежит поверх них: кнопка «+» остаётся доступной.
            if let session = wake.session, session.phase == .waiting {
                RecheckBanner(session: session)
            }
            if legalToShow {
                // Не окно поверх экрана, а плашка: человека не перебивают, пока он занят.
                HStack(spacing: 10) {
                    Image(systemName: "doc.text")
                    Text("Нужно ваше решение по документам и согласиям")
                        .font(.app(.footnote))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Открыть") { showLegalSheet = true }
                        .font(.app(.footnote).weight(.semibold))
                    Button { legalPostponed = true } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Скрыть до следующего запуска")
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Theme.mint.opacity(0.18))
            }
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
                MedsView()
                    .tabItem { Label("Лекарства", systemImage: "pills") }
                    .tag(4)
                ProfileView()
                    .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
                    .badge(health.issueCount)
                    .tag(3)
            }
            }
            .fullScreenCover(
                isPresented: Binding(
                    get: { wake.session?.phase == .task || focus.showsCover },
                    set: { _ in }
                ),
                onDismiss: {
                    wake.presentPendingNote()
                    wake.presentPendingMorning()
                }
            ) {
                if let session = wake.session, session.phase == .task {
                    WakeTaskView(session: session)
                        .preferredColorScheme(.dark)
                        .foregroundStyle(.primary)
                } else {
                    // Фокус-сессия: идёт или показывает итог. Задание будильника важнее и перекрывает её.
                    FocusCoverView()
                        .preferredColorScheme(.dark)
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
            .sheet(isPresented: Binding(
                get: { legalSheetVisible },
                set: { if !$0 { showLegalSheet = false; legalPostponed = true } }
            )) {
                ConsentGateSheet { showLegalSheet = false; legalPostponed = true }
                    .preferredColorScheme(.dark)
            }
            .onChange(of: legalSheetVisible) { _, visible in
                // Окно скрылось само (утро, списание): не показывать его снова, когда те экраны закроются.
                if !visible { showLegalSheet = false }
            }
            .sheet(item: $wake.note) { state in
                NoteView(state: state)
                    .preferredColorScheme(.dark)
            }
            .sheet(item: $wake.morning) { state in
                MorningView(state: state)
                    .preferredColorScheme(.dark)
            }
            .onAppear {
                guard let screenshot = RootView.screenshotTab else { return }
                tab = screenshot
                // Тестовые данные, чтобы на скриншоте было что показать (только в отладочной сборке).
                if JournalStore.shared.entries.isEmpty { JournalStore.shared.addDemoEntries() }
                if !settings.data.useDemoSocial { settings.data.useDemoSocial = true }
                var work = AlarmItem()
                work.hour = 6; work.minute = 30; work.weekdays = [1, 2, 3, 4, 5]; work.label = "Работа"
                work.stakeEnabled = true; work.stakeAmount = 500; work.taskEnabled = true; work.taskKind = .steps
                var fajr = AlarmItem()
                fajr.fajrOffset = 0; fajr.module = .prayer
                var weekend = AlarmItem()
                weekend.hour = 8; weekend.minute = 30; weekend.weekdays = [6, 7]; weekend.label = "Выходные"; weekend.isEnabled = false
                AlarmStore.shared.seedDemo([work, fajr, weekend])
                if PromiseStore.shared.promises.isEmpty {
                    let begin = PromiseEditView.defaultStart()
                    _ = PromiseStore.shared.add(StepPromise(title: "Пробежка", start: begin, end: begin.addingTimeInterval(90 * 60),
                                                            minSteps: 5000, stake: 500))
                }
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
                    tab = 4
                    router.showMeds = false
                }
            }
            .task {
                // Пока приложение открыто, сверка идёт каждые 30 секунд: звонок мог прийти, пока экран был включён.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    wake.reconcile()
                    FocusStore.shared.evaluate()
                    Task { await PromiseStore.shared.reconcile() }
                }
            }
        }
    }
}
