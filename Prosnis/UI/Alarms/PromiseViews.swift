import SwiftUI

/// Обещание в списке будильников: окно, шаги и ставка.
struct PromiseRow: View {
    @ObservedObject private var store = PromiseStore.shared
    let promise: StepPromise
    let now: Date
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Capsule().fill(Theme.leaf).frame(width: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(Format.time(promise.start))
                    .font(.system(size: 40, weight: .light, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 6) {
                    Image(systemName: "figure.run")
                    Text(promise.title)
                    Text("·")
                    Text("до \(Format.time(promise.end))")
                    Image(systemName: "bolt.fill").foregroundStyle(Theme.accent)
                    if PromiseRules.isLocked(promise, now: now) {
                        Image(systemName: "lock.fill")
                    }
                }
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Text(progressText)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var progressText: String {
        let goal = "\(promise.minSteps) шагов"
        if now < promise.start {
            return "\(Format.dayMonth(promise.start)) · нужно \(goal)"
        }
        let done = store.liveSteps[promise.id] ?? 0
        return "Шаги: \(done) из \(promise.minSteps)"
    }
}

/// Подробности обещания и удаление (пока оно не закрыто).
struct PromiseDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PromiseStore.shared
    let promise: StepPromise
    @State private var message: String?

    var body: some View {
        let now = Date()
        let locked = PromiseRules.isLocked(promise, now: now)
        NavigationStack {
            List {
                Section {
                    row("Окно", "\(Format.dayMonth(promise.start)), \(promise.windowText)")
                    row("Нужно шагов", "\(promise.minSteps)")
                    row("Ставка", "\(promise.stake) ₽")
                    if now >= promise.start {
                        row("Сейчас", "\(store.liveSteps[promise.id] ?? 0) шагов")
                    }
                } footer: {
                    Text("Шаги считает счётчик телефона. Телефон должен быть с вами. После окна откройте приложение — оно посчитает итог.")
                }
                Section {
                    if locked {
                        Label("Изменить или удалить можно не позже чем за 2 часа до начала.", systemImage: "lock.fill")
                            .foregroundStyle(Theme.accent)
                    } else {
                        Button("Удалить обещание", role: .destructive) {
                            message = store.delete(promise)
                            if message == nil { dismiss() }
                        }
                    }
                    if let message { Text(message).font(.app(.footnote)).foregroundStyle(Theme.accent) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(promise.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { dismiss() } } }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

/// Новое обещание: название, окно, минимум шагов, ставка и согласие на счёт шагов.
struct PromiseEditView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @State private var title = "Пробежка"
    @State private var start = PromiseEditView.defaultStart()
    @State private var windowMinutes = 90
    @State private var minSteps = 5000
    @State private var stake = 500
    @State private var agreed = false
    @State private var message: String?
    @State private var showTerms = false

    /// Ближайшие 22:00, до которых больше двух часов.
    static func defaultStart() -> Date {
        let calendar = Calendar.current
        let today = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: Date()) ?? Date()
        if today > Date().addingTimeInterval(2 * 3600 + 60) { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    private var end: Date { start.addingTimeInterval(Double(windowMinutes) * 60) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $title)
                    DatePicker("Начало", selection: $start, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    Picker("Окно", selection: $windowMinutes) {
                        ForEach(PromiseRules.windows, id: \.self) { Text("\($0) минут").tag($0) }
                    }
                    Stepper("Не меньше \(minSteps) шагов", value: $minSteps, in: 500...50000, step: 500)
                } footer: {
                    Text("Нужно набрать шаги с \(Format.time(start)) до \(Format.time(end)). Не набрали — ставка спишется.")
                }

                Section {
                    if settings.data.isAdult {
                        HStack {
                            Text("Ставка")
                            Spacer()
                            TextField("500", value: $stake, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                            Text("₽").foregroundStyle(.secondary)
                        }
                    } else {
                        Label("Ставки доступны с \(AppConfig.adultAge) лет. Подтвердить возраст можно в Профиле.", systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Приложение может считать мои шаги", isOn: Binding(
                        get: { agreed },
                        set: { isOn in
                            guard isOn else {
                                agreed = false
                                return
                            }
                            Task {
                                agreed = await StepCounting.requestAccess()
                                message = agreed ? nil : "Нет доступа к данным о движении. Разрешите его в Настройках iPhone → Prosnis."
                            }
                        }
                    ))
                } footer: {
                    Text("Шаги берутся только из счётчика телефона и никуда не уходят. Телефон должен быть с вами. Изменить или удалить обещание можно не позже чем за 2 часа до начала.")
                }

                if let message {
                    Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(Theme.accent) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Обещание по шагам")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") { save() }
                        .disabled(!agreed || stake <= 0 || !settings.data.isAdult)
                }
            }
            .sheet(isPresented: $showTerms) {
                StakeTermsView(amount: stake) {
                    settings.acceptStakeTerms(amount: stake)
                    showTerms = false
                    create()
                }
            }
        }
    }

    private func save() {
        guard StepCounting.isAvailable else {
            message = "На этом телефоне счётчик шагов недоступен."
            return
        }
        if StakeTerms.needsConsent(settings.data.stakeConsent, amount: stake) {
            showTerms = true
        } else {
            create()
        }
    }

    private func create() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let promise = StepPromise(title: name.isEmpty ? "Пробежка" : ContentFilter.clean(name),
                                  start: start, end: end, minSteps: minSteps, stake: stake)
        Task {
            _ = await DeadlineNotifications.requestPermission()
            if let error = PromiseStore.shared.add(promise) {
                message = error
            } else {
                dismiss()
            }
        }
    }
}
