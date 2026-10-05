import SwiftUI

/// Создание и редактирование будильника.
struct AlarmEditView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var journal: JournalStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: AlarmItem
    private let isNew: Bool

    init(alarm: AlarmItem, isNew: Bool) {
        _draft = State(initialValue: alarm)
        self.isNew = isNew
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: draft.hour, minute: draft.minute)) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.hour = parts.hour ?? 7
                draft.minute = parts.minute ?? 0
            }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "ru_RU"))
                        .frame(maxWidth: .infinity)
                }

                Section("Повтор") {
                    weekdayChips
                }

                Section {
                    TextField("Название", text: $draft.label)
                    NavigationLink {
                        SoundPickerView(selection: $draft.soundID)
                    } label: {
                        HStack {
                            Text("Звук")
                            Spacer()
                            Text(SoundLibrary.option(draft.soundID).title).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Фон") {
                    preview
                    NavigationLink {
                        WallpaperPickerView(selection: $draft.wallpaper)
                    } label: {
                        Label("Выбрать фон", systemImage: "photo")
                    }
                }

                Section {
                    Toggle("Со ставкой", isOn: $draft.stakeEnabled)
                    if draft.stakeEnabled {
                        HStack {
                            Text("Сумма")
                            Spacer()
                            TextField("500", value: $draft.stakeAmount, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                            Text("₽").foregroundStyle(.secondary)
                        }
                        if let hint = StakeAdvisor.hint(entries: journal.entries, current: draft.stakeAmount) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(hint.text, systemImage: "lightbulb")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if let suggested = hint.suggested {
                                    Button("Поставить \(suggested) ₽") { draft.stakeAmount = suggested }
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Сейчас это тренировка: деньги не списываются.")
                }

                if !isNew {
                    Section {
                        Button("Удалить будильник", role: .destructive) {
                            store.delete(draft)
                            dismiss()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(isNew ? "Новый будильник" : "Будильник")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        draft.isEnabled = true
                        store.upsert(draft)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }

    private var weekdayChips: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { day in
                let isOn = draft.weekdays.contains(day)
                Button {
                    if isOn { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
                } label: {
                    Text(Weekdays.short[day - 1])
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(isOn ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.card), in: Circle())
                        .foregroundStyle(isOn ? Color.black : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    private var preview: some View {
        ZStack {
            WallpaperView(wallpaper: draft.wallpaper)
            Color.black.opacity(0.25)
            VStack(spacing: 4) {
                Text(String(format: "%02d:%02d", draft.hour, draft.minute))
                    .font(.system(size: 54, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(draft.displayTitle)
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .shadow(radius: 6)
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }
}
