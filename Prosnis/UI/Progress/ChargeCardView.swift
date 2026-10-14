import SwiftUI

/// Карточка при открытии приложения после списания: что случилось и сколько списано.
/// Спокойный тон, одна главная кнопка; «Оспорить» — маленькой ссылкой.
struct ChargeCardView: View {
    let entry: JournalEntry
    let onDismiss: () -> Void
    let onDispute: () -> Void

    static func heading(_ entry: JournalEntry) -> String {
        switch entry.kind {
        case .challenge?: return "Челлендж сорван"
        case .focus?: return "Фокус-сессия не засчитана"
        case .promise?: return "Обещание не выполнено"
        case nil: return entry.isPromise == true ? "Обещание не выполнено" : "Вы проспали"
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "moon.zzz")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 6) {
                Text(ChargeCardView.heading(entry)).font(.app(.title))
                Text(Format.dateTime(entry.date))
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                Text("Списано").font(.app(.subheadline)).foregroundStyle(.secondary)
                Text("\(entry.stake) ₽").font(.app(.largeTitle))
                if entry.isTraining {
                    Text("Тренировка: деньги не тронуты")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            if let reason = entry.events.last?.text {
                Text(reason)
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button(action: onDismiss) {
                Text("Понятно")
                    .font(.app(.headline))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.burgundy)
            if entry.dispute == .none {
                Button("Оспорить списание", action: onDispute)
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .background { Theme.background.ignoresSafeArea() }
    }
}
