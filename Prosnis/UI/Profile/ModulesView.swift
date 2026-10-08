import SwiftUI

/// Модули: включение, чек-листы и программы.
struct ModulesView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List {
            Section {
                ForEach(WakeModule.allCases) { module in
                    Toggle(isOn: Binding(
                        get: { settings.isEnabled(module) },
                        set: { settings.setModule(module, enabled: $0) }
                    )) {
                        Label {
                            VStack(alignment: .leading) {
                                Text(module.title)
                                Text(module.subtitle).font(.app(.caption)).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: module.icon)
                        }
                    }
                }
            } footer: {
                Text("Модули определяют шаблоны будильников, утренний чек-лист и программу после подъёма. Модуль «Утренний намаз» и всё, что с ним связано, хранится только на телефоне, пока вы сами не разрешите иное в Приватности.")
            }

            Section {
                Toggle(isOn: $settings.data.medsEnabled) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Лекарства")
                            Text("Напоминания о таблетках, курс и запас").font(.app(.caption)).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "pills")
                    }
                }
            } footer: {
                Text("Отдельная вкладка. Без ставок и заданий: лекарства — это забота, а не испытание. Сведения о лекарствах не уходят на сервер и друзьям.")
            }

            Section("Настройки модулей") {
                ForEach(settings.data.modules) { module in
                    NavigationLink {
                        ModuleSettingsView(module: module)
                    } label: {
                        Label(module.title, systemImage: module.icon)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Модули")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ModuleSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    let module: WakeModule
    @State private var items: [String] = []
    @State private var newItem = ""

    var body: some View {
        Form {
            Section {
                ForEach(items, id: \.self) { item in
                    Text(item)
                }
                .onDelete { items.remove(atOffsets: $0) }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    TextField("Новый пункт", text: $newItem)
                    Button("Добавить") {
                        let value = newItem.trimmingCharacters(in: .whitespaces)
                        guard !value.isEmpty, !items.contains(value) else { return }
                        items.append(value)
                        newItem = ""
                    }
                    .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Вернуть по умолчанию") { items = module.defaultChecklist }
            } header: {
                Text("Утренний чек-лист")
            } footer: {
                Text("Показывается после подъёма. Каждый отмеченный пункт даёт 2 опыта.")
            }

            switch module {
            case .sport:
                Section("Шаги за день") {
                    Stepper("Цель: \(settings.data.sportStepGoal)", value: $settings.data.sportStepGoal, in: 500...20000, step: 500)
                }
            case .study:
                Section("Фокус-таймер") {
                    Stepper("\(settings.data.focusMinutes) минут", value: $settings.data.focusMinutes, in: 5...90, step: 5)
                }
            case .prayer:
                Section {
                    NavigationLink("Город и способ расчёта") { PrayerSettingsView() }
                }
            case .basic, .work:
                EmptyView()
            }
        }
        .navigationTitle(module.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onAppear { items = settings.checklist(for: module) }
        .onChange(of: items) { _, value in
            // Первое заполнение списка не должно сохранять чек-лист по умолчанию как свой.
            guard value != settings.checklist(for: module) else { return }
            settings.setChecklist(value, for: module)
        }
    }
}

/// Настройки Фаджра: город и одно действие — подогнать время под свой источник.
struct PrayerSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: AlarmStore
    @State private var entered = Date()
    @State private var message: String?
    @State private var messageIsError = false
    /// Человек сам поменял время в поле. До этого поле показывает расчёт для выбранного города.
    @State private var edited = false

    /// Будильник на Фаджр со ставкой закрыт: менять расчёт нельзя, иначе звонок можно сдвинуть или убрать.
    private var lockedByStake: Bool {
        store.alarms.contains { $0.isFajr && $0.stakeEnabled && store.isLocked($0) }
    }

    var body: some View {
        let prayer = settings.data.prayer
        Form {
            if lockedByStake {
                Section {
                    Label("Настройки закрыты: будильник на Фаджр со ставкой зазвонит меньше чем через 2 часа или идёт проверка.", systemImage: "lock.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            Group {
                Section("Город") {
                    Picker("Город", selection: $settings.data.prayer.cityID) {
                        ForEach(City.all) { Text($0.name).tag($0.id) }
                    }
                }

                Section {
                    Text("Время Фаджра зависит от того, как его считает ваша мечеть или муфтият: у одних солнце должно опуститься на 16° под горизонт, у других — на 18° и больше. Поэтому в разных приложениях время отличается на несколько минут, а иногда и на полчаса.")
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)
                    Text("Введите один раз время Фаджра на сегодня из источника, которому вы доверяете. Мы подберём угол и дальше будем считать по нему каждый день — и зимой, и летом.")
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)
                    DatePicker("Фаджр сегодня у вас", selection: Binding(
                        get: { edited ? entered : wallClock(PrayerTimes.day(for: Date(), settings: prayer).fajr, zone: prayer.city.timeZone) },
                        set: { value in
                            entered = value
                            edited = true
                        }
                    ), displayedComponents: .hourAndMinute)
                    Button("Подобрать") { calibrate() }
                    if let message {
                        Label(message, systemImage: messageIsError ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.app(.footnote))
                            .foregroundStyle(messageIsError ? Theme.accent : Theme.leaf)
                    }
                } header: {
                    Text("Подогнать под ваш источник")
                } footer: {
                    if prayer.method == .custom, let minutes = prayer.calibratedMinutes, let on = prayer.calibratedOn {
                        Text("Сейчас: угол \(PrayerCalibration.angleText(prayer.customAngle))°, подобран по вашему времени \(String(format: "%02d:%02d", minutes / 60, minutes % 60)) от \(Format.dayKey(AppSettings.dayKey(on))).")
                    }
                }

                Section("Ближайшие 7 дней") {
                    ForEach(0..<7, id: \.self) { offset in
                        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
                        let day = PrayerTimes.day(for: date, settings: prayer)
                        HStack {
                            Text(Format.weekday(date))
                            Spacer()
                            Text(day.fajr.map { cityTime($0, prayer) } ?? "—").monospacedDigit()
                            if day.fajrAdjusted {
                                Image(systemName: "moon.haze").foregroundStyle(.secondary)
                            }
                            Text("восход \(day.sunrise.map { cityTime($0, prayer) } ?? "—")")
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    DisclosureGroup("Дополнительно") {
                        Picker("Способ", selection: Binding(
                            get: { settings.data.prayer.method },
                            set: { value in
                                settings.data.prayer.method = value
                                clearCalibration()
                            }
                        )) {
                            ForEach(PrayerMethod.allCases) { Text($0.title).tag($0) }
                        }
                        if prayer.method == .custom {
                            Stepper(String(format: "Угол: %.1f°", prayer.customAngle), value: Binding(
                                get: { settings.data.prayer.customAngle },
                                set: { value in
                                    settings.data.prayer.customAngle = value
                                    clearCalibration()
                                }
                            ), in: 10...20, step: 0.5)
                        }
                        Picker("Высокие широты", selection: $settings.data.prayer.highLatitude) {
                            ForEach(HighLatitudeRule.allCases) { Text($0.title).tag($0) }
                        }
                        Stepper("Поправка: \(prayer.adjustmentMinutes) мин", value: $settings.data.prayer.adjustmentMinutes, in: -30...30)
                    }
                } footer: {
                    Text("Обычно здесь ничего менять не нужно: достаточно подогнать время выше.")
                }
            }
            .disabled(lockedByStake)
        }
        .navigationTitle("Фаджр")
        .navigationBarTitleDisplayMode(.inline)
        // Сменили город — поле снова показывает расчёт уже для него.
        .onChange(of: settings.data.prayer.cityID) { _, _ in
            edited = false
            message = nil
        }
    }

    /// Время по часам выбранного города, а не по часам телефона.
    private func cityTime(_ date: Date, _ prayer: PrayerSettings) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = prayer.city.timeZone
        return formatter.string(from: date)
    }

    /// Показывает время города в выборе времени (выбор работает в поясе телефона).
    private func wallClock(_ date: Date?, zone: TimeZone) -> Date {
        guard let date else { return Calendar.current.date(bySettingHour: 5, minute: 0, second: 0, of: Date()) ?? Date() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Calendar.current.date(bySettingHour: parts.hour ?? 5, minute: parts.minute ?? 0, second: 0, of: Date()) ?? Date()
    }

    private func calibrate() {
        let prayerNow = settings.data.prayer
        let chosen = edited ? entered : wallClock(PrayerTimes.day(for: Date(), settings: prayerNow).fajr, zone: prayerNow.city.timeZone)
        let parts = Calendar.current.dateComponents([.hour, .minute], from: chosen)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let now = Date()
        let prayer = settings.data.prayer
        guard let target = PrayerCalibration.fajrDate(minutes: minutes, on: now, settings: prayer),
              let angle = PrayerCalibration.angle(forFajr: target, on: now, settings: prayer) else {
            messageIsError = true
            message = "Такое время не похоже на Фаджр для города «\(prayer.city.name)» на сегодня. Проверьте город и время."
            return
        }
        var updated = prayer
        updated.method = .custom
        updated.customAngle = angle
        updated.adjustmentMinutes = 0
        updated.calibratedMinutes = minutes
        updated.calibratedOn = now
        settings.data.prayer = updated
        messageIsError = false
        message = "Готово: угол \(PrayerCalibration.angleText(angle))°. Дальше Фаджр считается по нему."
    }

    private func clearCalibration() {
        settings.data.prayer.calibratedMinutes = nil
        settings.data.prayer.calibratedOn = nil
    }
}
