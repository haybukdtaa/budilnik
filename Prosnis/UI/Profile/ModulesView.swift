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
                                Text(module.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: module.icon)
                        }
                    }
                }
            } footer: {
                Text("Модули определяют шаблоны будильников, утренний чек-лист и программу после подъёма. Модуль «Утренний намаз» и всё, что с ним связано, хранится только на телефоне, пока вы сами не разрешите иное в Приватности.")
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
        .onChange(of: items) { _, value in settings.setChecklist(value, for: module) }
    }
}

/// Настройки расчёта Фаджра.
struct PrayerSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let prayer = settings.data.prayer
        Form {
            Section("Город") {
                Picker("Город", selection: $settings.data.prayer.cityID) {
                    ForEach(City.all) { Text($0.name).tag($0.id) }
                }
            }
            Section {
                Picker("Способ", selection: $settings.data.prayer.method) {
                    ForEach(PrayerMethod.allCases) { Text($0.title).tag($0) }
                }
                if prayer.method == .custom {
                    Stepper(String(format: "Угол: %.1f°", prayer.customAngle),
                            value: $settings.data.prayer.customAngle, in: 10...20, step: 0.5)
                }
                Picker("Высокие широты", selection: $settings.data.prayer.highLatitude) {
                    ForEach(HighLatitudeRule.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Поправка: \(prayer.adjustmentMinutes) мин", value: $settings.data.prayer.adjustmentMinutes, in: -30...30)
            } header: {
                Text("Расчёт Фаджра")
            } footer: {
                Text("ДУМ РФ считает Фаджр по углу 16°, ДУМ Татарстана — по 18°. Летом в средней полосе солнце не опускается на нужный угол, тогда время считается по правилу высоких широт. Если ваша мечеть публикует другое время, задайте поправку.")
            }
            Section("Ближайшие 7 дней") {
                ForEach(0..<7, id: \.self) { offset in
                    let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
                    let day = PrayerTimes.day(for: date, settings: prayer)
                    HStack {
                        Text(Format.weekday(date))
                        Spacer()
                        Text(day.fajr.map(Format.time) ?? "—").monospacedDigit()
                        if day.fajrAdjusted {
                            Image(systemName: "moon.haze").foregroundStyle(.secondary)
                        }
                        Text("восход \(day.sunrise.map(Format.time) ?? "—")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Значок луны: время по правилу высоких широт.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Фаджр")
        .navigationBarTitleDisplayMode(.inline)
    }
}
