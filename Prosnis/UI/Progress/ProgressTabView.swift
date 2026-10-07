import SwiftUI

/// Вкладка «Прогресс»: дерево, уровень, неделя, челленджи, летопись, журнал.
struct ProgressTabView: View {
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var challenges: ChallengeStore
    @EnvironmentObject private var settings: AppSettings
    @State private var showNewChallenge = false
    @State private var showTreePreview = false
    @State private var showSpeciesPicker = false

    var body: some View {
        let snapshot = ProgressEngine.compute(entries: journal.realEntries, challenges: challenges.challenges)
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    treeCard(snapshot)
                    levelCard(snapshot)
                    weekCard(snapshot)
                    if journal.realEntries.contains(where: { $0.stake > 0 }) {
                        SavedCard()
                    }
                    challengesCard
                    NavigationLink {
                        JournalListView()
                    } label: {
                        row(icon: "list.bullet.rectangle", title: "Журнал утр", detail: "Каждое утро по минутам")
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Прогресс")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Как растёт дерево", systemImage: "leaf") { showTreePreview = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showNewChallenge) { ChallengeEditView() }
            .sheet(isPresented: $showTreePreview) { TreePreviewView() }
            .sheet(isPresented: $showSpeciesPicker) { SpeciesPickerView(treeIndex: snapshot.tree.index) }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        card {
            HStack {
                Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 28)
                VStack(alignment: .leading) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
        }
    }

    private func treeCard(_ snapshot: ProgressSnapshot) -> some View {
        let tree = snapshot.tree
        let species = settings.species(forTree: tree.index)
        return card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    TreeView(stage: tree.stage, wilt: tree.wilt, species: species ?? .oak,
                             flowers: tree.flowers, fruits: tree.fruits)
                        .frame(width: 120, height: 140)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(species.map { "\($0.title) · дерево №\(tree.index + 1)" } ?? "Дерево №\(tree.index + 1)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(tree.title).font(.title3.bold())
                        Text(tree.isLastStage
                             ? "До переезда в сад: \(tree.wakesToNext) утр"
                             : "До следующей стадии: \(tree.wakesToNext) утр")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if tree.fruits {
                            Label("Плоды: месяц без провалов", systemImage: "sparkles").font(.caption).foregroundStyle(.green)
                        } else if tree.flowers {
                            Label("Цветёт: неделя без провалов. Плоды через \(max(0, TreeState.fruitsStreak - snapshot.currentStreak)) утр",
                                  systemImage: "camera.macro").font(.caption).foregroundStyle(.pink)
                        } else if tree.wilt == 0 && tree.stage > 0 {
                            Text("Цветы появятся через \(max(0, TreeState.flowersStreak - snapshot.currentStreak)) утр подряд")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if tree.wilt > 0 {
                            Text("Листья вянут от недавних провалов. Несколько подъёмов подряд вернут цвет.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    if species == nil {
                        Button {
                            showSpeciesPicker = true
                        } label: {
                            Label("Выбрать дерево", systemImage: "leaf")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    NavigationLink {
                        GardenView()
                    } label: {
                        Label("Мой сад (\(snapshot.garden.count))", systemImage: "tree")
                    }
                }
            }
        }
    }

    private func levelCard(_ snapshot: ProgressSnapshot) -> some View {
        NavigationLink {
            ChronicleView()
        } label: {
            card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.title).font(.title3.bold())
                            Text("Уровень \(snapshot.level)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(snapshot.unlocked.count) значков")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    ProgressView(value: snapshot.levelProgress).tint(Theme.accent)
                    Text("\(snapshot.xp) опыта · до следующего уровня \(snapshot.xpForNextLevel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Серия \(snapshot.currentStreak) · рекорд \(snapshot.longestStreak) · всего утр \(snapshot.totalWakes)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func weekCard(_ snapshot: ProgressSnapshot) -> some View {
        let week = snapshot.thisWeek
        let last = snapshot.lastWeek
        return card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Итоги недели").font(.headline)
                if week.mornings == 0 {
                    Text("На этой неделе утр с заданием ещё не было.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Встали \(week.successes) из \(week.mornings) · \(Int((week.regularity * 100).rounded()))%")
                    if let minutes = week.averageWakeMinutes {
                        Text("Средний подъём: \(String(format: "%02d:%02d", minutes / 60, minutes % 60))")
                            .foregroundStyle(.secondary)
                    }
                    Text("Опыт за неделю: +\(week.xp)").foregroundStyle(.secondary)
                }
                if last.mornings > 0 {
                    Text("Прошлая неделя: \(last.successes) из \(last.mornings)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var challengesCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Челленджи").font(.headline)
                    Spacer()
                    Button {
                        showNewChallenge = true
                    } label: {
                        Label("Новый", systemImage: "plus")
                    }
                }
                if challenges.active.isEmpty {
                    Text("Нет идущих челленджей. Начните с недели без провалов.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(challenges.active) { challenge in
                        ChallengeRow(challenge: challenge)
                    }
                }
            }
        }
    }
}

struct ChallengeRow: View {
    @EnvironmentObject private var challenges: ChallengeStore
    let challenge: Challenge
    @State private var confirmStop = false

    var body: some View {
        let progress = challenges.progress(for: challenge)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(challenge.title).font(.subheadline.weight(.semibold))
                if challenge.isPrivate {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(challenge.status.title).font(.caption).foregroundStyle(.secondary)
            }
            if let days = challenge.durationDays {
                ProgressView(value: min(1, Double(progress.daysPassed) / Double(days))).tint(Theme.accent)
                Text("День \(min(progress.daysPassed, days)) из \(days) · успешных утр \(progress.successDays)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Бессрочный · идёт \(progress.daysPassed) дн. · успешных утр \(progress.successDays)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if challenge.status == .active {
                Button("Остановить", role: .destructive) { confirmStop = true }
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Остановить челлендж?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Остановить", role: .destructive) { challenges.abandon(challenge.id) }
        } message: {
            Text("Он сохранится в летописи как остановленный.")
        }
    }
}

/// Новый личный челлендж.
struct ChallengeEditView: View {
    @EnvironmentObject private var challenges: ChallengeStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var goal: ChallengeGoal = .noMisses
    @State private var title = ""
    @State private var duration: Int? = 7
    @State private var wakeBefore = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()

    static let durations: [Int?] = [7, 14, 21, 30, 60, 90, 100, 180, 365, nil]

    private var goals: [ChallengeGoal] {
        ChallengeGoal.allCases.filter { $0 != .prayer || settings.isEnabled(.prayer) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Цель", selection: $goal) {
                        ForEach(goals) { Text($0.title).tag($0) }
                    }
                    Text(goal.detail).font(.footnote).foregroundStyle(.secondary)
                    if goal == .wakeBefore {
                        DatePicker("Встать не позже", selection: $wakeBefore, displayedComponents: .hourAndMinute)
                            .environment(\.locale, Locale(identifier: "ru_RU"))
                    }
                }
                Section("Срок") {
                    Picker("Длительность", selection: $duration) {
                        ForEach(ChallengeEditView.durations, id: \.self) { value in
                            Text(value.map { "\($0) дней" } ?? "Бессрочно").tag(value)
                        }
                    }
                }
                Section {
                    TextField("Название (необязательно)", text: $title)
                } footer: {
                    if goal == .prayer {
                        Text("Челлендж по Фаджру остаётся на телефоне и не показывается другим.")
                    }
                }
            }
            .navigationTitle("Новый челлендж")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Начать") {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: wakeBefore)
                        let name = title.trimmingCharacters(in: .whitespaces)
                        challenges.add(Challenge(
                            title: name.isEmpty ? defaultTitle : name,
                            goal: goal,
                            wakeBeforeMinutes: goal == .wakeBefore ? (parts.hour ?? 7) * 60 + (parts.minute ?? 0) : nil,
                            durationDays: duration,
                            startDate: Date()
                        ))
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }

    private var defaultTitle: String {
        let span = duration.map { "\($0) дней" } ?? "без срока"
        return "\(goal.title), \(span)"
    }
}

/// Выбор вида для текущего дерева. Выбор окончательный, пока дерево не вырастет.
struct SpeciesPickerView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let treeIndex: Int
    @State private var selected: TreeSpecies = .oak

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Дерево растёт \(TreeState.cycle) удачных утр, потом переезжает в ваш сад навсегда. Вид выбирается один раз на всё дерево.")
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                        ForEach(TreeSpecies.allCases) { species in
                            Button {
                                selected = species
                            } label: {
                                VStack(spacing: 6) {
                                    TreeView(stage: 6, wilt: 0, species: species, flowers: true).frame(height: 130)
                                    Text(species.title).font(.headline)
                                    Text(species.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected == species ? Theme.accent : .clear, lineWidth: 3))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Какое дерево растим?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Позже") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Посадить") {
                        settings.chooseSpecies(selected, forTree: treeIndex)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }
}

/// Сад: все выросшие деревья и то, что растёт сейчас.
struct GardenView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var challenges: ChallengeStore

    var body: some View {
        let snapshot = ProgressEngine.compute(entries: journal.realEntries, challenges: challenges.challenges)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if snapshot.garden.isEmpty {
                    Text("Сад пока пуст. Первое дерево переедет сюда после \(TreeState.cycle) удачных утр. Сейчас у него \(snapshot.tree.progress).")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                    ForEach(snapshot.garden) { tree in
                        let species = settings.species(forTree: tree.index) ?? .oak
                        VStack(spacing: 4) {
                            TreeView(stage: 7, wilt: 0, species: species, flowers: true, fruits: true).frame(height: 110)
                            Text("\(species.title) №\(tree.index + 1)").font(.caption.weight(.semibold))
                            Text("вырос \(Format.fullDate(tree.date))").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                    }
                    VStack(spacing: 4) {
                        TreeView(stage: snapshot.tree.stage, wilt: snapshot.tree.wilt,
                                 species: settings.species(forTree: snapshot.tree.index) ?? .oak,
                                 flowers: snapshot.tree.flowers, fruits: snapshot.tree.fruits)
                            .frame(height: 110)
                        Text("Растёт сейчас").font(.caption.weight(.semibold))
                        Text("\(snapshot.tree.progress) из \(TreeState.cycle)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Мой сад")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Все стадии дерева для наглядности.
struct TreePreviewView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 16) {
                    ForEach(0..<8, id: \.self) { stage in
                        VStack {
                            TreeView(stage: stage, wilt: 0).frame(height: 140)
                            Text(TreeState.stageTitles[stage]).font(.subheadline.weight(.semibold))
                            Text("\(TreeState.thresholds[stage]) подъёмов").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Как растёт дерево")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { dismiss() } } }
        }
    }
}
