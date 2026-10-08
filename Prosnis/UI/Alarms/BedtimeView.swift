import SwiftUI
import UIKit

/// Вечерняя проверка: всё ли готово, чтобы утром будильник сработал.
struct BedtimeView: View {
    @EnvironmentObject private var store: AlarmStore
    @Environment(\.dismiss) private var dismiss

    @State private var batteryLevel: Float = -1
    @State private var batteryState: UIDevice.BatteryState = .unknown

    @EnvironmentObject private var payments: PaymentsStore
    @EnvironmentObject private var settings: AppSettings

    private var nextStaked: (AlarmItem, Date)? {
        let now = Date()
        return store.alarms
            .filter { $0.isEnabled && $0.stakeEnabled }
            .compactMap { alarm in store.nextOccurrence(of: alarm, after: now).map { (alarm, $0) } }
            .min { $0.1 < $1.1 }
    }

    var body: some View {
        NavigationStack {
            List {
                if let reason = settings.wakeReason {
                    Section("Зачем я встаю") {
                        Text("«\(reason)»").italic()
                    }
                }
                Section("Проверка перед сном") {
                    row(
                        ok: store.isAuthorized,
                        good: "Разрешение на будильники выдано",
                        bad: "Нет разрешения на будильники. Включите его в Настройках iPhone"
                    )
                    batteryRow
                    nextAlarmRow
                    if let status = payments.lastStatus {
                        row(ok: status.isOK, good: "Оплата: \(status.message)", bad: "Оплата: \(status.message)")
                    }
                }

                Section("Не забудьте") {
                    Label("Положите телефон на зарядку", systemImage: "bolt.fill")
                    Label("Проверьте громкость: звонок должен быть слышен", systemImage: "speaker.wave.2.fill")
                    Label("Не закрывайте приложение: оно нужно утром для задания", systemImage: "app.badge")
                }
                .foregroundStyle(.secondary)

                Section {
                    Button {
                        Bedtime.recordCheck()
                        dismiss()
                    } label: {
                        Text("Спокойной ночи")
                            .font(.app(.headline))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Ложусь спать")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .onAppear {
                UIDevice.current.isBatteryMonitoringEnabled = true
                batteryLevel = UIDevice.current.batteryLevel
                batteryState = UIDevice.current.batteryState
            }
        }
    }

    @ViewBuilder
    private var batteryRow: some View {
        let charging = batteryState == .charging || batteryState == .full
        if batteryLevel < 0 {
            row(ok: true, good: "Заряд определить не удалось, проверьте сами", bad: "")
        } else if charging {
            row(ok: true, good: "Телефон на зарядке (\(Int(batteryLevel * 100))%)", bad: "")
        } else if batteryLevel >= 0.3 {
            row(ok: true, good: "Заряд \(Int(batteryLevel * 100))%, хватит до утра", bad: "")
        } else {
            row(ok: false, good: "", bad: "Заряд \(Int(batteryLevel * 100))%. Поставьте телефон на зарядку")
        }
    }

    @ViewBuilder
    private var nextAlarmRow: some View {
        if let (alarm, date) = nextStaked {
            let minutes = Int(date.timeIntervalSinceNow / 60)
            row(
                ok: true,
                good: "Ближайший со ставкой: \(alarm.timeText) «\(alarm.displayTitle)», через \(minutes / 60) ч \(minutes % 60) мин, ставка \(alarm.stakeAmount) ₽",
                bad: ""
            )
        } else {
            row(ok: false, good: "", bad: "Нет включённого будильника со ставкой")
        }
    }

    private func row(ok: Bool, good: String, bad: String) -> some View {
        Label {
            Text(ok ? good : bad)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
        }
    }
}
