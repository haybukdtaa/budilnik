import SwiftUI

/// Что на самом деле стоит в системе от приложения. Нужен, чтобы увидеть «лишний» звонок:
/// будильник, который выключен или удалён у нас, но остался в системе.
struct SystemAlarmsView: View {
    @EnvironmentObject private var store: AlarmStore
    @State private var rows: [AlarmService.SystemAlarmInfo] = []
    @State private var message: String?

    var body: some View {
        List {
            Section {
                if rows.isEmpty {
                    Text("В системе нет ни одного будильника приложения.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(for: row))
                            .font(.app(.body))
                            .foregroundStyle(row.isExtra ? Color.red : Color.primary)
                        Text("\(row.when) · \(row.state)")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Красным отмечены лишние будильники: у нас они выключены или удалены, но в системе остались. Приложение снимает их при каждом открытии; кнопка ниже делает это сразу.")
            }
            Section {
                Button("Снять лишние будильники") {
                    store.cleanupOrphans()
                    reload()
                    message = "Готово."
                }
                Button("Обновить") { reload() }
                if let message {
                    Text(message).font(.app(.footnote)).foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Системные будильники")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private func title(for row: AlarmService.SystemAlarmInfo) -> String {
        if let alarm = store.alarms.first(where: { $0.id.uuidString == row.ownerKey || $0.id == row.id }) {
            let base = "\(alarm.timeText) «\(alarm.displayTitle)»"
            return row.isExtra ? base + " (выключен, но стоит в системе)" : base
        }
        return row.isExtra ? "Лишний будильник" : "Проверка, повторный звонок или лекарство"
    }

    private func reload() {
        let wanted = store.wantedSystemIDs()
        rows = AlarmService.shared.systemAlarms(known: wanted.known, enabledKeys: wanted.enabledKeys)
            .sorted { $0.isExtra && !$1.isExtra }
    }
}
