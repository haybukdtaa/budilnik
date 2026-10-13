import SwiftUI

/// Экран после успешного подъёма: награды, чек-лист, программа модуля.
struct MorningView: View {
    @EnvironmentObject private var wake: WakeCoordinator
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var challenges: ChallengeStore
    let state: MorningState

    @State private var done: Set<String> = []

    private var checklist: [String] { settings.checklist(for: state.module) }
    private var after: ProgressSnapshot {
        ProgressEngine.compute(entries: journal.realEntries, challenges: challenges.challenges)
    }

    var body: some View {
        let snapshot = after
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text("Доброе утро!")
                            .font(.app(.largeTitle, weight: .bold))
                        Text(Format.dateTime(state.startedAt))
                            .foregroundStyle(.secondary)
                        if let reason = settings.wakeReason {
                            Text("«\(reason)»")
                                .italic()
                                .multilineTextAlignment(.center)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.top, 8)

                    rewards(snapshot)

                    if let index = state.storyChapter, StoryLibrary.series(for: state.module).chapters.indices.contains(index) {
                        let series = StoryLibrary.series(for: state.module)
                        NavigationLink {
                            StoryChapterView(series: series, index: index)
                        } label: {
                            card {
                                HStack(spacing: 12) {
                                    Image(systemName: "book.fill").font(.app(.title2)).foregroundStyle(Theme.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Открыта глава \(index + 1): «\(series.chapters[index].title)»")
                                            .font(.app(.headline))
                                            .multilineTextAlignment(.leading)
                                        Text(series.title).font(.app(.subheadline)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if settings.data.medsEnabled {
                        MorningMedsLine()
                    }

                    MorningPhotoCard(date: state.startedAt)

                    if !checklist.isEmpty {
                        card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Утренний чек-лист").font(.app(.headline))
                                ForEach(checklist, id: \.self) { item in
                                    Button {
                                        if done.contains(item) { done.remove(item) } else { done.insert(item) }
                                    } label: {
                                        HStack {
                                            Image(systemName: done.contains(item) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(done.contains(item) ? Color.green : Color.secondary)
                                            Text(item).foregroundStyle(.primary)
                                            Spacer()
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                                Text("+2 опыта за каждый пункт")
                                    .font(.app(.caption))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    ModuleProgramView(module: state.module, startedAt: state.startedAt)

                    Button {
                        let ordered = checklist.filter { done.contains($0) }
                        journal.setRoutine(entryID: state.entryID, done: ordered, total: checklist.count)
                        wake.finishMorning()
                    } label: {
                        Text("Готово")
                            .font(.app(.headline))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
        }
        .interactiveDismissDisabled()
    }

    private func rewards(_ snapshot: ProgressSnapshot) -> some View {
        let gained = max(0, snapshot.xp - state.xpBefore)
        let newBadges = snapshot.unlocked.filter { !state.badgesBefore.contains($0.id) }
        let tree = snapshot.tree
        let movedToGarden = tree.index > state.treeIndexBefore
        return card {
            HStack(alignment: .center, spacing: 16) {
                TreeView(stage: tree.stage, wilt: tree.wilt,
                         species: settings.species(forTree: tree.index) ?? .oak,
                         flowers: tree.flowers, fruits: tree.fruits)
                    .frame(width: 110, height: 130)
                VStack(alignment: .leading, spacing: 6) {
                    if gained > 0 {
                        Text("+\(gained) опыта").font(.app(.title2, weight: .bold)).foregroundStyle(Theme.accent)
                    }
                    if Titles.changed(fromLevel: state.levelBefore, toLevel: snapshot.level) {
                        Label("Новое звание: \(snapshot.title)", systemImage: "arrow.up.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text(snapshot.title)
                    }
                    Text("Серия: \(snapshot.currentStreak)")
                        .foregroundStyle(.secondary)
                    if movedToGarden {
                        Text("Дерево выросло и переехало в ваш сад! Сажаем новое.")
                            .font(.app(.subheadline, weight: .semibold))
                            .foregroundStyle(.green)
                    } else if tree.stage > state.treeStageBefore {
                        Text("Дерево выросло: \(tree.title)")
                            .font(.app(.subheadline))
                            .foregroundStyle(.green)
                    } else {
                        Text(tree.title)
                            .font(.app(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                    if tree.fruits && !state.fruitsBefore {
                        Text("Появились плоды: месяц без провалов").font(.app(.subheadline)).foregroundStyle(.green)
                    } else if tree.flowers && !state.flowersBefore {
                        Text("Дерево зацвело: неделя без провалов").font(.app(.subheadline)).foregroundStyle(.pink)
                    }
                    ForEach(newBadges) { item in
                        Label("Значок: \(item.badge.title)", systemImage: item.badge.icon)
                            .font(.app(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Утренняя программа модуля.
struct ModuleProgramView: View {
    @EnvironmentObject private var settings: AppSettings
    let module: WakeModule
    let startedAt: Date

    var body: some View {
        switch module {
        case .basic:
            EmptyView()
        case .sport:
            SportProgramView(goal: settings.data.sportStepGoal)
        case .study:
            FocusTimerView()
        case .work:
            MainTaskView()
        case .prayer:
            PrayerTodayView()
        }
    }
}

private struct ProgramCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.app(.headline))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SportProgramView: View {
    let goal: Int
    @StateObject private var counter = StepCounter()

    var body: some View {
        ProgramCard(title: "Шаги сегодня", icon: "figure.walk") {
            ProgressView(value: min(1, Double(counter.steps) / Double(max(goal, 1))))
                .tint(Theme.accent)
            Text("\(counter.steps) из \(goal)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .onAppear { counter.loadToday() }
    }
}

/// Фокус-сессия вместо прежнего таймера: от 30 до 120 минут, с учётом времени вне приложения.
struct FocusTimerView: View {
    @EnvironmentObject private var wake: WakeCoordinator
    @ObservedObject private var focus = FocusStore.shared
    @State private var showStart = false

    var body: some View {
        ProgramCard(title: "Фокус перед учёбой", icon: "timer") {
            if focus.current != nil {
                Text("Фокус-сессия уже идёт.")
                    .foregroundStyle(.secondary)
            } else {
                Text("От 30 до 120 минут без отвлечений. Суммарно вне приложения можно провести 5 минут.")
                    .foregroundStyle(.secondary)
                Button("Начать фокус-сессию") { showStart = true }
                    .buttonStyle(.burgundy)
            }
        }
        .sheet(isPresented: $showStart) {
            // Утренний экран закрывается, чтобы сессия показалась поверх приложения.
            FocusStartView { wake.finishMorning() }
        }
    }
}

struct MainTaskView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var text = ""

    var body: some View {
        ProgramCard(title: "Главная задача дня", icon: "target") {
            TextField("Что важнее всего сделать сегодня?", text: $text, axis: .vertical)
                .lineLimit(1...3)
                .onAppear { text = settings.mainTask(for: Date()) }
                .onChange(of: text) { _, value in settings.setMainTask(value, for: Date()) }
        }
    }
}

struct PrayerTodayView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let day = PrayerTimes.day(for: Date(), settings: settings.data.prayer)
        ProgramCard(title: "Сегодня, \(settings.data.prayer.city.name)", icon: "moon.stars") {
            HStack {
                Text("Фаджр")
                Spacer()
                Text(day.fajr.map(Format.time) ?? "не определяется")
            }
            HStack {
                Text("Восход")
                Spacer()
                Text(day.sunrise.map(Format.time) ?? "нет")
            }
            if day.fajrAdjusted {
                Text("Время Фаджра посчитано по правилу высоких широт.")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
