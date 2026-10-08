import SwiftUI

/// Главный экран: список будильников.
struct AlarmListView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var settings: AppSettings
    // Наблюдаем за утренней проверкой: от неё зависит значок блокировки.
    @EnvironmentObject private var wake: WakeCoordinator
    @ObservedObject private var promises = PromiseStore.shared
    @State private var editing: AlarmItem?
    @State private var showBedtime = false
    @State private var showPromise = false
    @State private var openPromise: StepPromise?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if store.alarms.isEmpty && promises.promises.isEmpty {
                    emptyState
                } else {
                    TimelineView(.everyMinute) { context in
                        list(now: context.date)
                    }
                }
            }
            .navigationTitle("Будильники")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Проверить звонок через минуту", systemImage: "bell.badge") {
                            store.runTest()
                        }
                        Section("Проверить задание и повторную проверку") {
                            ForEach([TaskKind.typing, .math, .memory, .steps]) { kind in
                                Button(kind.title, systemImage: kind.icon) {
                                    WakeCoordinator.shared.startDemo(task: kind)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Будильник", systemImage: "alarm") {
                            var item = AlarmItem()
                            item.module = settings.data.modules.first ?? .basic
                            editing = item
                        }
                        Button("Обещание по шагам", systemImage: "figure.run") { showPromise = true }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.app(.title2))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showBedtime = true
                } label: {
                    Label("Ложусь спать", systemImage: "moon.stars.fill")
                        .font(.app(.headline))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .sheet(item: $editing) { alarm in
                AlarmEditView(alarm: alarm, isNew: !store.alarms.contains { $0.id == alarm.id })
            }
            .sheet(isPresented: $showBedtime) {
                BedtimeView()
            }
            .sheet(isPresented: $showPromise) { PromiseEditView() }
            .sheet(item: $openPromise) { PromiseDetailView(promise: $0) }
            .alert(
                "Внимание",
                isPresented: Binding(
                    get: { store.message != nil },
                    set: { if !$0 { store.message = nil } }
                )
            ) {
                Button("Понятно", role: .cancel) {}
            } message: {
                Text(store.message ?? "")
            }
        }
    }

    private func list(now: Date) -> some View {
        List {
            if !journal.realEntries.isEmpty {
                SavedCard()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            ForEach(promises.promises) { promise in
                PromiseRow(promise: promise, now: now) { openPromise = promise }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            ForEach(store.alarms) { alarm in
                let locked = store.isLocked(alarm)
                AlarmRow(alarm: alarm, isLocked: locked, next: alarm.isEnabled ? store.nextOccurrence(of: alarm, after: now) : nil) {
                    editing = alarm
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .swipeActions {
                    if !locked {
                        Button("Удалить", role: .destructive) { store.delete(alarm) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "alarm")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
            Text("Пока нет будильников")
                .font(.app(.title3, weight: .bold))
            Text("Нажмите «+», чтобы добавить первый")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AlarmRow: View {
    @EnvironmentObject private var store: AlarmStore
    let alarm: AlarmItem
    let isLocked: Bool
    let next: Date?
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            WallpaperView(wallpaper: alarm.wallpaper)
                .frame(width: 8)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 4) {
                Text(alarm.timeText)
                    .font(.system(size: alarm.isFajr ? 34 : 46, weight: .light, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 6) {
                    Image(systemName: alarm.effectiveModule.icon)
                    Text(alarm.displayTitle)
                    Text("·")
                    Text(alarm.repeatText)
                    if alarm.hasTask {
                        Image(systemName: alarm.effectiveTask.icon)
                    }
                    if alarm.stakeEnabled {
                        Image(systemName: "bolt.fill").foregroundStyle(Theme.accent)
                    }
                    if isLocked {
                        Image(systemName: "lock.fill")
                    }
                }
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if store.isScheduleFailed(alarm) {
                    Label("Не поставлен в систему: проверьте разрешение на будильники", systemImage: "exclamationmark.triangle.fill")
                        .font(.app(.caption))
                        .foregroundStyle(.orange)
                } else if alarm.needsDatedSchedule, let next {
                    Text("Ближайший: \(Format.weekday(next)), \(Format.time(next))")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { alarm.isEnabled },
                    set: { store.setEnabled(alarm, $0) }
                )
            )
            .labelsHidden()
            .disabled(isLocked)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        .opacity(alarm.isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
