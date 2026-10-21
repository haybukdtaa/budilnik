import SwiftUI

/// Главный экран, как «Часы» iPhone: «Сон», обещания и будильники плоским списком.
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
    @State private var showFocus = false
    @State private var openPromise: StepPromise?
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                list(now: context.date)
            }
            .overlay(alignment: .bottom) {
                if let toast = store.toast {
                    Text(toast)
                        .font(.app(.subheadline))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.card, in: Capsule())
                        .overlay(Capsule().stroke(Theme.separator))
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: toast) {
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            if store.toast == toast { store.toast = nil }
                        }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: store.toast)
            .background(Theme.background)
            .navigationTitle("Будильники")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editMode.isEditing ? "Готово" : "Изменить") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .opacity(store.alarms.isEmpty ? 0 : 1)
                    .disabled(store.alarms.isEmpty)
                    .accessibilityHidden(store.alarms.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            var item = AlarmItem()
                            item.module = settings.data.modules.first ?? .basic
                            editing = item
                        } label: {
                            Label("Будильник", systemImage: "alarm")
                        }
                        Button {
                            showPromise = true
                        } label: {
                            Label("Обещание по шагам", systemImage: "figure.run")
                        }
                        if settings.isEnabled(.study) {
                            Button {
                                showFocus = true
                            } label: {
                                Label("Фокус-сессия", systemImage: "timer")
                            }
                        }
                    } label: {
                        Image(systemName: "plus").font(.app(.title3))
                    }
                    .accessibilityLabel("Добавить")
                }
            }
            .sheet(item: $editing) { alarm in
                AlarmEditView(alarm: alarm, isNew: !store.alarms.contains { $0.id == alarm.id })
            }
            .sheet(isPresented: $showBedtime) {
                BedtimeView()
            }
            .sheet(isPresented: $showPromise) { PromiseEditView() }
            .sheet(isPresented: $showFocus) { FocusStartView() }
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

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.app(.title3, weight: .bold))
            .foregroundStyle(.white)
            .textCase(nil)
            .padding(.top, 6)
    }

    /// Ближайший звонок среди включённых будильников.
    private func nextAlarm(now: Date) -> Date? {
        store.alarms.filter(\.isEnabled).compactMap { store.nextOccurrence(of: $0, after: now) }.min()
    }

    private func list(now: Date) -> some View {
        List {
            Section {
                SleepRow(next: nextAlarm(now: now), hasEnabled: store.alarms.contains(where: \.isEnabled), now: now) { showBedtime = true }
            } header: {
                header("Сон")
            }

            if !promises.promises.isEmpty {
                Section {
                    ForEach(promises.promises) { promise in
                        PromiseRow(promise: promise, now: now) { openPromise = promise }
                    }
                } header: {
                    header("Обещания")
                }
            }

            Section {
                if store.alarms.isEmpty {
                    Text("Пока нет будильников. Нажмите «+», чтобы добавить первый.")
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                }
                ForEach(store.alarms) { alarm in
                    let locked = store.isLocked(alarm)
                    AlarmRow(alarm: alarm, isLocked: locked, next: alarm.isEnabled ? store.nextOccurrence(of: alarm, after: now) : nil) {
                        editing = alarm
                    }
                    .swipeActions {
                        if !locked {
                            Button("Удалить", role: .destructive) { store.delete(alarm) }
                        }
                    }
                    .deleteDisabled(locked)
                }
                .onDelete { offsets in
                    // Сначала выбираем будильники: после первого удаления номера сдвигаются.
                    let doomed = offsets.compactMap { store.alarms.indices.contains($0) ? store.alarms[$0] : nil }
                    for alarm in doomed where !store.isLocked(alarm) { store.delete(alarm) }
                }
            } header: {
                header("Другие")
            }

            if !journal.realEntries.isEmpty {
                Section {
                    SavedCard()
                } header: {
                    header("Месяц")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Режим «Изменить» действует только на этот список, а не на окна поверх него.
        .environment(\.editMode, $editMode)
        .onChange(of: store.alarms.isEmpty) { _, isEmpty in
            if isEmpty { editMode = .inactive }
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(alarm.timeText)
                    .font(.system(size: 56, weight: .thin))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 6) {
                    Text("\(alarm.displayTitle) · \(alarm.repeatText)")
                    if alarm.hasTask {
                        Image(systemName: alarm.effectiveTask.icon)
                    }
                    if isLocked {
                        Image(systemName: "lock.fill")
                    }
                }
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if alarm.stakeEnabled {
                    Text("Обязательство \(alarm.stakeAmount) ₽")
                        .font(.app(.caption))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(Theme.burgundy.opacity(0.28), in: Capsule())
                }
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
                "\(alarm.timeText) \(alarm.displayTitle)",
                isOn: Binding(
                    get: { alarm.isEnabled },
                    set: { store.setEnabled(alarm, $0) }
                )
            )
            .labelsHidden()
            .disabled(isLocked)
        }
        .padding(.vertical, 4)
        .opacity(alarm.isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(.isButton)
    }
}
