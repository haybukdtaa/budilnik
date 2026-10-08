import AVFoundation
import CoreMotion
import SwiftUI

/// Создание и редактирование будильника.
struct AlarmEditView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var draft: AlarmItem
    @State private var showScanner = false
    @State private var scanError: String?
    @State private var permissionMessage: String?
    @State private var showTerms = false
    private let isNew: Bool

    init(alarm: AlarmItem, isNew: Bool) {
        _draft = State(initialValue: alarm)
        self.isNew = isNew
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: draft.hour, minute: draft.minute)) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.hour = parts.hour ?? 7
                draft.minute = parts.minute ?? 0
            }
        )
    }

    private var fajrBinding: Binding<Bool> {
        Binding(
            get: { draft.fajrOffset != nil },
            set: { draft.fajrOffset = $0 ? (draft.fajrOffset ?? 0) : nil }
        )
    }

    private var offsetBinding: Binding<Int> {
        Binding(get: { draft.fajrOffset ?? 0 }, set: { draft.fajrOffset = $0 })
    }

    private var taskBinding: Binding<Bool> {
        Binding(get: { draft.hasTask }, set: { draft.taskEnabled = $0 })
    }

    /// Будильник со ставкой закрыт за 2 часа до звонка и пока идёт проверка.
    private var isLocked: Bool {
        guard !isNew, let stored = store.alarms.first(where: { $0.id == draft.id }) else { return false }
        return store.isLocked(stored)
    }

    private var enabledModules: [WakeModule] {
        var list = settings.data.modules
        if !list.contains(draft.effectiveModule) { list.append(draft.effectiveModule) }
        return list
    }

    private var canSave: Bool {
        if draft.hasTask && draft.effectiveTask == .qr && (draft.qrCode ?? "").isEmpty { return false }
        // Ставка без суммы бессмысленна: будильник закрывается для изменений, а на кону ничего нет.
        if draft.stakeEnabled && draft.stakeAmount <= 0 { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            List {
                if isLocked {
                    Section {
                        Label("Изменения закрыты за 2 часа до звонка и пока идёт проверка", systemImage: "lock.fill")
                            .foregroundStyle(Theme.accent)
                    }
                }

                if enabledModules.count > 1 {
                    Section {
                        Picker("Модуль", selection: Binding(
                            get: { draft.effectiveModule },
                            set: { value in
                                draft.module = value
                                if value != .prayer { draft.fajrOffset = nil }
                            }
                        )) {
                            ForEach(enabledModules) { Label($0.title, systemImage: $0.icon).tag($0) }
                        }
                    }
                }

                timeSection
                repeatSection

                Section {
                    TextField("Название", text: $draft.label)
                    NavigationLink {
                        SoundPickerView(selection: $draft.soundID)
                    } label: {
                        HStack {
                            Text("Звук")
                            Spacer()
                            Text(SoundLibrary.option(draft.soundID).title).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Фон") {
                    preview
                    NavigationLink {
                        WallpaperPickerView(selection: $draft.wallpaper)
                    } label: {
                        Label("Выбрать фон", systemImage: "photo")
                    }
                }

                taskSection
                stakeSection

                if !isNew {
                    Section {
                        Button("Удалить будильник", role: .destructive) {
                            store.delete(draft)
                            dismiss()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .disabled(isLocked)
            .navigationTitle(isNew ? "Новый будильник" : "Будильник")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isLocked ? "Закрыть" : "Отмена") { dismiss() }
                }
                if !isLocked {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") { save() }
                            .bold()
                            .disabled(!canSave)
                    }
                }
            }
            .sheet(isPresented: $showScanner) { scannerSheet }
            .sheet(isPresented: $showTerms) {
                StakeTermsView(amount: draft.stakeAmount) {
                    settings.acceptStakeTerms(amount: draft.stakeAmount)
                    showTerms = false
                    Task {
                        _ = await DeadlineNotifications.requestPermission()
                        saveStake()
                    }
                }
            }
            // Сообщения хранилища (например, «будильник закрыт») видны прямо здесь, а не после закрытия редактора.
            .alert(
                "Внимание",
                isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })
            ) {
                Button("Понятно", role: .cancel) {}
            } message: {
                Text(store.message ?? "")
            }
        }
    }

    private func save() {
        draft.isEnabled = true
        guard draft.stakeEnabled && settings.data.isAdult else {
            if store.upsert(draft) { dismiss() }
            return
        }
        // Сначала согласие с условиями ставки: без него будильник со ставкой не сохраняется.
        if StakeTerms.needsConsent(settings.data.stakeConsent, amount: draft.stakeAmount) {
            showTerms = true
            return
        }
        saveStake()
    }

    private func saveStake() {
        // Ставка имеет смысл, только если будильник точно поставлен: без разрешения сохранить её нельзя.
        Task {
            if await AlarmService.shared.requestAuthorization() {
                if store.upsert(draft) { dismiss() }
            } else {
                store.message = "Чтобы поставить будильник со ставкой, разрешите будильники в Настройках iPhone."
            }
        }
    }

    // MARK: - Время

    @ViewBuilder
    private var timeSection: some View {
        if draft.effectiveModule == .prayer {
            Section {
                Toggle("По времени Фаджра", isOn: fajrBinding)
                if draft.isFajr {
                    Stepper(value: offsetBinding, in: -60...60, step: 5) {
                        Text(offsetText)
                    }
                    let today = settings.scheduleContext
                    if let next = ScheduleCalculator.nextOccurrence(for: draft, after: Date(), context: today) {
                        Text("Ближайший звонок: \(Format.weekday(next)), \(Format.time(next))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("В ближайшие дни время не определяется. Проверьте город в настройках модуля.")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            } footer: {
                if draft.isFajr {
                    Text("Время Фаджра меняется каждый день. Приложение ставит будильники на \(AlarmService.datedHorizonDays) дней вперёд и обновляет их при каждом открытии. Открывайте приложение хотя бы раз в неделю: если будильник не зазвонит из-за этого, утро считается провалом.")
                }
            }
        }
        if !draft.isFajr {
            Section {
                DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "ru_RU"))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var offsetText: String {
        let offset = draft.fajrOffset ?? 0
        if offset == 0 { return "Ровно в начало Фаджра" }
        return offset < 0 ? "За \(-offset) мин до Фаджра" : "Через \(offset) мин после начала"
    }

    @ViewBuilder
    private var repeatSection: some View {
        Section {
            Picker("Выходные и праздники", selection: Binding(
                get: { draft.effectiveHolidayMode },
                set: { draft.holidayMode = $0 }
            )) {
                ForEach(HolidayMode.allCases) { Text($0.title).tag($0) }
            }
            if draft.effectiveHolidayMode != .workCalendar {
                weekdayChips
            }
        } header: {
            Text("Повтор")
        } footer: {
            switch draft.effectiveHolidayMode {
            case .off:
                Text(draft.weekdays.isEmpty ? "Без выбранных дней будильник сработает один раз." : "")
            case .skipHolidays:
                Text("В праздники и перенесённые выходные будильник молчит. Календарь РФ заложен на 2026–2027 годы. Такие будильники ставятся на \(AlarmService.datedHorizonDays) дней вперёд: открывайте приложение хотя бы раз в неделю, иначе утро без звонка — провал.")
            case .workCalendar:
                Text("Звонит во все рабочие дни по производственному календарю РФ, включая рабочие субботы, и молчит в праздники. Будильники ставятся на \(AlarmService.datedHorizonDays) дней вперёд: открывайте приложение хотя бы раз в неделю, иначе утро без звонка — провал.")
            }
        }
    }

    private var weekdayChips: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { day in
                let isOn = draft.weekdays.contains(day)
                Button {
                    if isOn { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
                } label: {
                    Text(Weekdays.short[day - 1])
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(isOn ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.card), in: Circle())
                        .foregroundStyle(isOn ? Color.black : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    // MARK: - Задание и ставка

    @ViewBuilder
    private var taskSection: some View {
        Section {
            Toggle("Задание для выключения", isOn: taskBinding)
                .disabled(draft.stakeEnabled)
            if draft.hasTask {
                Picker("Задание", selection: Binding(
                    get: { draft.effectiveTask },
                    set: { kind in
                        draft.taskKind = kind
                        permissionMessage = nil
                        if kind == .qr || kind == .steps {
                            Task { await checkPermission(for: kind) }
                        }
                    }
                )) {
                    ForEach(TaskKind.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                if let permissionMessage {
                    Text(permissionMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if draft.effectiveTask == .qr {
                    if let code = draft.qrCode, !code.isEmpty {
                        Label("Код зарегистрирован", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Button("Зарегистрировать другой код") { showScanner = true }
                    } else {
                        Button("Зарегистрировать код") { showScanner = true }
                        Text("Наклейте QR-код или возьмите штрихкод с упаковки в другой комнате (ванная, кухня) и отсканируйте его сейчас. Утром нужно будет дойти до него.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if draft.stakeEnabled {
                    Label("Повторная проверка: обязательна со ставкой", systemImage: "checkmark.shield")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Повторная проверка через 10 минут", isOn: Binding(
                        get: { draft.recheckEnabled == true },
                        set: { draft.recheckEnabled = $0 }
                    ))
                }
                if draft.stakeEnabled && !draft.effectiveTask.requiresGettingUp {
                    Text("Для будильника со ставкой лучше «Сканировать код» или «Пройти шаги»: их нельзя выполнить, лёжа в кровати.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        } footer: {
            Text("Чтобы выключить будильник, нужно выполнить задание. Повторная проверка через 10 минут ловит «выполнил и лёг обратно»: со ставкой она обязательна, без ставки — по желанию. В парных челленджах с друзьями засчитываются только утра с повторной проверкой.")
        }
    }

    @ViewBuilder
    private var stakeSection: some View {
        Section {
            if settings.data.isAdult {
                Toggle("Со ставкой", isOn: $draft.stakeEnabled)
                if draft.stakeEnabled {
                    HStack {
                        Text("Сумма")
                        Spacer()
                        TextField("500", value: $draft.stakeAmount, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                        Text("₽").foregroundStyle(.secondary)
                    }
                    if draft.stakeAmount <= 0 {
                        Label("Укажите сумму больше нуля", systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else if draft.stakeAmount >= 3000 {
                        Label("Крупная сумма. Убедитесь, что это осознанно.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let hint = StakeAdvisor.hint(entries: journal.realEntries, current: draft.stakeAmount) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(hint.text, systemImage: "lightbulb")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let suggested = hint.suggested {
                                Button("Поставить \(suggested) ₽") { draft.stakeAmount = suggested }
                            }
                        }
                    }
                }
            } else {
                Label("Ставки доступны с \(AppConfig.adultAge) лет. Подтвердить возраст можно в Профиле.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Ставка")
        } footer: {
            Text(PaymentsStore.shared.isTraining
                 ? "Сейчас ставка тренировочная: деньги не списываются. Ставку видите только вы."
                 : "Если не встанете, сумма спишется. Ставку видите только вы.")
        }
        .onChange(of: draft.stakeEnabled) { _, isOn in
            if isOn { draft.taskEnabled = true }
        }
    }

    /// Задания «код» и «шаги» требуют разрешений. Без них задание выполнить нельзя, поэтому выбор отменяется сразу.
    private func checkPermission(for kind: TaskKind) async {
        let granted: Bool
        switch kind {
        case .qr:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
            default: granted = false
            }
        case .steps:
            granted = await Self.motionAccess()
        default:
            granted = true
        }
        if !granted && draft.effectiveTask == kind {
            draft.taskKind = .typing
            permissionMessage = kind == .qr
                ? "Нет доступа к камере. Разрешите его в Настройках iPhone, чтобы выбрать это задание."
                : "Нет доступа к движению или счётчик шагов недоступен. Разрешите его в Настройках iPhone, чтобы выбрать это задание."
        }
    }

    /// Запрашивает доступ к движению пробным запросом шагов.
    private static func motionAccess() async -> Bool {
        guard CMPedometer.isStepCountingAvailable() else { return false }
        switch CMPedometer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default: break
        }
        let pedometer = CMPedometer()
        return await withCheckedContinuation { continuation in
            let now = Date()
            pedometer.queryPedometerData(from: now.addingTimeInterval(-60), to: now) { _, error in
                // Держим счётчик живым до ответа системы.
                withExtendedLifetime(pedometer) {
                    continuation.resume(returning: error == nil)
                }
            }
        }
    }

    private var scannerSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                CodeScannerView { code in
                    draft.qrCode = code
                    showScanner = false
                } onError: {
                    scanError = "Нет доступа к камере. Разрешите его в Настройках iPhone."
                }
                .frame(height: 380)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                Text(scanError ?? "Наведите камеру на QR-код или штрихкод")
                    .foregroundStyle(scanError == nil ? Color.secondary : Color.orange)
                Spacer()
            }
            .padding(16)
            .navigationTitle("Регистрация кода")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { showScanner = false } } }
        }
    }

    private var preview: some View {
        ZStack {
            WallpaperView(wallpaper: draft.wallpaper)
            Color.black.opacity(0.25)
            VStack(spacing: 4) {
                Text(draft.timeText)
                    .font(.system(size: draft.isFajr ? 40 : 54, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(draft.displayTitle)
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .shadow(radius: 6)
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }
}
