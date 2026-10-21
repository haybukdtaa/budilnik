import SwiftUI

/// «Здоровье будильников»: что может помешать звонку, и возврат данных из копии.
struct HealthView: View {
    @ObservedObject private var health = HealthCheck.shared
    @State private var pending: AppFiles.BackupFile?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                ForEach(health.items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.isOK ? Theme.mint : Color.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.app(.body))
                            Text(item.detail).font(.app(.caption)).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(item.isOK ? "в порядке" : "требует внимания")
                }
            } footer: {
                Text("Проверка обновляется при каждом открытии приложения. Оранжевое значит: из-за этого будильник может не зазвонить.")
            }

            if !health.backups.isEmpty {
                Section {
                    ForEach(health.backups) { backup in
                        Button {
                            pending = backup
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Вернуть: \(backup.title)")
                                Text("Копия от \(Format.dateTime(backup.date))")
                                    .font(.app(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Сохранённые копии")
                } footer: {
                    Text("Если файл с данными однажды не прочитался, приложение оставило его копию. Её можно вернуть: то, что записано сейчас, сохранится рядом.")
                }
            }

            if let message {
                Section { Text(message).font(.app(.footnote)).foregroundStyle(.secondary) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Здоровье будильников")
        .navigationBarTitleDisplayMode(.inline)
        .task { await health.refresh() }
        .confirmationDialog(
            "Вернуть данные из копии?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("Вернуть", role: .destructive) {
                guard let backup = pending else { return }
                let ok = AppFiles.restore(backup)
                health.reloadStores()
                message = ok ? "Готово: «\(backup.title)» возвращены из копии." : "Не получилось. Разблокируйте телефон и повторите."
                pending = nil
                Task { await health.refresh() }
            }
            Button("Отмена", role: .cancel) { pending = nil }
        } message: {
            Text("Записанное сейчас заменится данными из копии. Текущая версия останется в файле рядом.")
        }
    }
}
