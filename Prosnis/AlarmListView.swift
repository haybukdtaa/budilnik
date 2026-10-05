import SwiftUI

/// Главный экран: список будильников.
struct AlarmListView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var journal: JournalStore
    @State private var editing: AlarmItem?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if store.alarms.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Будильники")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Проверить звонок через минуту", systemImage: "bell.badge") {
                            store.runTest()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = AlarmItem()
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
            .sheet(item: $editing) { alarm in
                AlarmEditView(alarm: alarm, isNew: !store.alarms.contains { $0.id == alarm.id })
            }
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

    private var list: some View {
        List {
            if !journal.entries.isEmpty {
                SavedCard()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            ForEach(store.alarms) { alarm in
                AlarmRow(alarm: alarm) { editing = alarm }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions {
                        Button("Удалить", role: .destructive) { store.delete(alarm) }
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
                .font(.title3.bold())
            Text("Нажмите «+», чтобы добавить первый")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AlarmRow: View {
    @EnvironmentObject private var store: AlarmStore
    let alarm: AlarmItem
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            WallpaperView(wallpaper: alarm.wallpaper)
                .frame(width: 8)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 4) {
                Text(alarm.timeText)
                    .font(.system(size: 46, weight: .light, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 6) {
                    Text(alarm.displayTitle)
                    Text("·")
                    Text(alarm.repeatText)
                    if alarm.stakeEnabled {
                        Image(systemName: "bolt.fill").foregroundStyle(Theme.accent)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        .opacity(alarm.isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
