import SwiftUI

/// Утренние истории: серии по направлениям. Глава открывается успешным утром.
struct StoriesView: View {
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var settings: AppSettings

    /// Направления, которые включил человек. Истории о намазе — только при включённом модуле намаза.
    private var modules: [WakeModule] {
        WakeModule.allCases.filter { settings.isEnabled($0) }
    }

    var body: some View {
        List {
            Section {
                Text("Каждое успешное утро открывает следующую главу. Проспали — глава подождёт, пока снова встанете.")
                    .foregroundStyle(.secondary)
            }
            ForEach(modules) { module in
                let series = StoryLibrary.series(for: module)
                let unlocked = StoryLibrary.unlockedCount(module: module, entries: journal.realEntries)
                Section {
                    ForEach(Array(series.chapters.enumerated()), id: \.offset) { index, chapter in
                        if index < unlocked {
                            NavigationLink {
                                StoryChapterView(series: series, index: index)
                            } label: {
                                Label("\(index + 1). \(chapter.title)", systemImage: "book.fill")
                            }
                        } else {
                            Label(index == unlocked ? "\(index + 1). Откроется после следующего подъёма" : "\(index + 1). Закрыта",
                                  systemImage: "lock.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label(series.title, systemImage: module.icon)
                } footer: {
                    Text(unlocked >= series.chapters.count
                         ? "\(series.subtitle). Серия прочитана — новые истории появятся в обновлениях."
                         : "\(series.subtitle). Открыто \(unlocked) из \(series.chapters.count). Главы открываются утрами с будильником «\(module.title)».")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Утренние истории")
    }
}

/// Одна глава.
struct StoryChapterView: View {
    let series: StorySeries
    let index: Int

    var body: some View {
        let chapter = series.chapters[index]
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(series.title) · глава \(index + 1) из \(series.chapters.count)")
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                Text(chapter.title)
                    .font(.app(.title).bold())
                Text(chapter.text)
                    .font(.app(.body))
                    .lineSpacing(5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// «Часы, которые вы выиграли» за этот месяц.
struct HoursWonCard: View {
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var settings: AppSettings
    @State private var editing = false
    @State private var usual = Calendar.current.date(bySettingHour: 8, minute: 30, second: 0, of: Date()) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Часы, которые вы выиграли", systemImage: "hourglass").font(.app(.headline))
            if let baseline = settings.data.usualWakeMinutes, !editing {
                let calendar = Calendar.current
                let monthStart = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
                let minutes = HoursWon.total(entries: journal.realEntries, usualWakeMinutes: baseline,
                                             from: monthStart, to: Date().addingTimeInterval(86400))
                Text("+\(HoursWon.text(minutes: minutes)) утра в этом месяце")
                    .font(.app(.title2).bold())
                    .foregroundStyle(Theme.accentGradient)
                let equivalents = HoursWon.equivalents(minutes: minutes)
                if equivalents.isEmpty {
                    Text("Считаем по сравнению с тем, когда вы вставали раньше (\(String(format: "%02d:%02d", baseline / 60, baseline % 60))). Каждое раннее утро добавляет время.")
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Это примерно " + equivalents.joined(separator: ", или "))
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                }
                Button("Изменить прежнее время подъёма") {
                    usual = calendar.date(bySettingHour: baseline / 60, minute: baseline % 60, second: 0, of: Date()) ?? Date()
                    editing = true
                }
                .font(.app(.footnote))
            } else {
                Text("Во сколько вы обычно вставали до приложения? По этому времени посчитаем, сколько утра вы выиграли.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                DatePicker("Обычно вставал(а) в", selection: $usual, displayedComponents: .hourAndMinute)
                Button("Сохранить") {
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: usual)
                    settings.data.usualWakeMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                    editing = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Итоги недели подробно и включение воскресной сводки.
struct WeeklySummaryView: View {
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var challenges: ChallengeStore
    @State private var permissionDenied = false

    var body: some View {
        let summary = WeeklySummary.compute(entries: journal.realEntries, now: Date(), usualWakeMinutes: settings.data.usualWakeMinutes)
        let snapshot = ProgressEngine.compute(entries: journal.realEntries, challenges: challenges.challenges)
        List {
            Section {
                row("Будильников с заданием", "\(summary.mornings)")
                row("Встали", "\(summary.successes)")
                if summary.failures > 0 { row("Проспали", "\(summary.failures)") }
                if summary.successes > 0 {
                    row("С повторной проверкой", "\(summary.rechecked) из \(summary.successes)")
                }
                if settings.data.usualWakeMinutes != nil {
                    row("Выиграно утра", "+\(HoursWon.text(minutes: summary.minutesWon))")
                }
                if summary.saved > 0 { row("Сохранено ставок", "\(summary.saved) ₽") }
                row("Дерево", "\(snapshot.tree.title), +\(summary.successes) к росту")
            } header: {
                Text("Неделя с \(Format.dayKey(AppSettings.dayKey(summary.weekStart)))")
            } footer: {
                if summary.previousSuccesses > 0 || summary.successes > 0 {
                    Text(summary.isBetterThanPrevious
                         ? "Лучше прошлой недели: \(summary.successes) против \(summary.previousSuccesses). Так держать!"
                         : "На прошлой неделе: \(summary.previousSuccesses). Новая неделя — новый шанс.")
                }
            }

            Section {
                Toggle("Присылать итоги по воскресеньям", isOn: Binding(
                    get: { settings.data.weeklySummaryOn },
                    set: { isOn in
                        Task {
                            if isOn {
                                let granted = await DeadlineNotifications.requestPermission()
                                if !granted {
                                    permissionDenied = true
                                    return
                                }
                            }
                            settings.data.weeklySummaryOn = isOn
                            await WeeklyNotification.update(enabled: isOn)
                        }
                    }
                ))
            } footer: {
                Text(permissionDenied
                     ? "Нет разрешения на уведомления. Включите его в Настройках iPhone → Prosnis."
                     : "В воскресенье в 20:00 придёт напоминание посмотреть итоги недели.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Итоги недели")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
