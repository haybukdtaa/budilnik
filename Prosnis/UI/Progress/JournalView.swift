import SwiftUI

enum Format {
    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM, HH:mm"
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// «6 октября 2026»
    static func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }

    /// День «гггг-мм-дд» в виде «6 октября»; без сдвига по часовым поясам.
    static func dayKey(_ key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return key }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM"
        return formatter.string(from: date)
    }

    /// «пн, 6 октября»
    static func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "EE, d MMMM"
        return formatter.string(from: date)
    }
}

/// Карточка «сколько денег удержали за месяц».
struct SavedCard: View {
    @EnvironmentObject private var journal: JournalStore

    var body: some View {
        let stats = journal.monthStats()
        VStack(alignment: .leading, spacing: 6) {
            Text("За этот месяц")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Сохранено \(stats.saved) ₽")
                .font(.title2.bold())
                .foregroundStyle(Theme.accentGradient)
            Text("Встали вовремя \(stats.successes) из \(stats.total)" + (stats.streak > 1 ? " · серия \(stats.streak)" : ""))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if stats.lost > 0 {
                Text("Списано: \(stats.lost) ₽")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Журнал утр (открывается из вкладки «Прогресс»).
struct JournalListView: View {
    @EnvironmentObject private var journal: JournalStore

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if journal.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 52))
                        .foregroundStyle(Theme.accent)
                    Text("Журнал пока пуст").font(.title3.bold())
                    Text("Здесь появится каждое утро: что произошло и почему списали или нет.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)
                }
            } else {
                List {
                    SavedCard()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    ForEach(journal.entries) { entry in
                        NavigationLink {
                            JournalDetailView(entryID: entry.id)
                        } label: {
                            JournalRow(entry: entry)
                        }
                        .listRowBackground(Theme.card)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Журнал")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Добавить тестовые записи", systemImage: "wand.and.stars") {
                        journal.addDemoEntries()
                    }
                    Button("Удалить тестовые записи", systemImage: "trash") {
                        journal.removeDemoEntries()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}

private func outcomeTitle(_ entry: JournalEntry) -> (String, Color) {
    switch entry.outcome {
    case .success: return ("Встали", .green)
    case .failed:
        if entry.dispute == .refunded { return ("Возвращено", .blue) }
        return ("Проспали", .red)
    case .technical: return ("Сбой, без списания", .gray)
    }
}

private struct JournalRow: View {
    let entry: JournalEntry

    var body: some View {
        let (title, color) = outcomeTitle(entry)
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(Format.dateTime(entry.date)).font(.headline)
                Text("\(entry.alarmTitle) · \(entry.timeText)" + (entry.isDemo == true ? " · тест" : ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                if entry.outcome == .failed && entry.stake > 0 {
                    Text(entry.dispute == .refunded ? "0 ₽" : "−\(entry.stake) ₽")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct JournalDetailView: View {
    @EnvironmentObject private var journal: JournalStore
    let entryID: UUID

    var body: some View {
        if let entry = journal.entries.first(where: { $0.id == entryID }) {
            let (title, color) = outcomeTitle(entry)
            List {
                Section {
                    HStack {
                        Text("Итог")
                        Spacer()
                        Text(title).foregroundStyle(color).bold()
                    }
                    HStack {
                        Text("Ставка")
                        Spacer()
                        Text("\(entry.stake) ₽").foregroundStyle(.secondary)
                    }
                    if entry.outcome == .failed {
                        HStack {
                            Text("Списано")
                            Spacer()
                            Text("\(entry.charged) ₽").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if entry.isTraining {
                        Text("Тренировка: деньги не списывались.")
                    }
                }

                Section("Как это было") {
                    ForEach(entry.events, id: \.self) { event in
                        HStack(alignment: .top) {
                            Text(Format.time(event.date))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .leading)
                            Text(event.text)
                        }
                    }
                }

                if entry.outcome == .failed {
                    Section {
                        switch entry.dispute {
                        case .none:
                            Button("Оспорить списание") { journal.dispute(entry) }
                        case .refunded:
                            Label("Спор принят, деньги возвращены", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .pending:
                            Label("Спор на рассмотрении", systemImage: "clock")
                                .foregroundStyle(.orange)
                        }
                    } footer: {
                        Text("Первый спор в аккаунте возвращается автоматически. Остальные рассматриваются по записям журнала.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(Format.dateTime(entry.date))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
