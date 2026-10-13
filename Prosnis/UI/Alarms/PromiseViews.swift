import SwiftUI

/// Обещание в списке будильников: окно, шаги и ставка.
struct PromiseRow: View {
    @ObservedObject private var store = PromiseStore.shared
    let promise: StepPromise
    let now: Date
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.run")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.app(.body))
                Text(progressText)
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if PromiseRules.isLocked(promise, now: now) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    /// «22:00 · Пробежка», а если не сегодня — с датой.
    private var title: String {
        let base = "\(Format.time(promise.start)) · \(promise.title)"
        return Calendar.current.isDateInToday(promise.start) ? base : "\(Format.dayMonth(promise.start)), \(base)"
    }

    private var progressText: String {
        if now < promise.start {
            return "до \(Format.time(promise.end)) · \(promise.minSteps) шагов · \(promise.stake) ₽"
        }
        let done = store.liveSteps[promise.id] ?? 0
        return "до \(Format.time(promise.end)) · шаги \(done) из \(promise.minSteps) · \(promise.stake) ₽"
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
                    row("Обязательство", "\(promise.stake) ₽")
                    if now >= promise.start {
                        row("Сейчас", "\(store.liveSteps[promise.id] ?? 0) шагов")
                    }
                } footer: {
                    Text("Шаги считает счётчик телефона. Телефон должен быть с вами. После окна откройте приложение — оно посчитает итог.")
                }
                Section {
                    if locked {
                        Label("Отменить нельзя: с создания прошло больше 5 минут.", systemImage: "lock.fill")
                            .foregroundStyle(Theme.accent)
                    } else {
                        let left = max(1, Int((promise.createdAt.addingTimeInterval(PromiseRules.cancelWindow).timeIntervalSince(now) / 60).rounded(.up)))
                        Button("Отменить обещание", role: .destructive) {
                            message = store.delete(promise)
                            if message == nil { dismiss() }
                        }
                        Text("Отменить можно ещё \(left) мин. Потом обещание останется до проверки шагов.")
                            .font(.app(.footnote))
                            .foregroundStyle(.secondary)
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
    @State private var showConfirm = false
    /// Номер последнего запроса доступа: поздний ответ на отменённый запрос игнорируется.
    @State private var accessRequest = 0

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
                    DatePicker("Начало", selection: $start, in: Date().addingTimeInterval(PromiseRules.minLead)..., displayedComponents: [.date, .hourAndMinute])
                    Picker("Окно", selection: $windowMinutes) {
                        ForEach(PromiseRules.windows, id: \.self) { Text("\($0) минут").tag($0) }
                    }
                    Stepper("Не меньше \(minSteps) шагов", value: $minSteps, in: 500...50000, step: 500)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Нужно набрать шаги с \(Format.time(start)) до \(Format.time(end)). Не набрали — сумма спишется.")
                        Text("Отменить обещание можно только в течение 5 минут после создания. Потом его нельзя ни отменить, ни изменить.")
                            .foregroundStyle(Theme.accent)
                    }
                }

                Section {
                    if settings.data.isAdult {
                        HStack {
                            Text("Обязательство")
                            Spacer()
                            TextField("500", value: $stake, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                            Text("₽").foregroundStyle(.secondary)
                        }
                        if stake < AppConfig.minObligation {
                            Label("Минимальная сумма — \(AppConfig.minObligation) ₽", systemImage: "exclamationmark.circle")
                                .font(.app(.footnote))
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Label("Обязательства доступны с \(AppConfig.adultAge) лет. Подтвердить возраст можно в Профиле.", systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Приложение может считать мои шаги", isOn: Binding(
                        get: { agreed },
                        set: { isOn in
                            accessRequest += 1
                            guard isOn else {
                                agreed = false
                                return
                            }
                            let request = accessRequest
                            Task {
                                let granted = await StepCounting.requestAccess()
                                guard request == accessRequest else { return }
                                agreed = granted
                                message = granted ? nil : "Нет доступа к данным о движении. Разрешите его в Настройках iPhone → Prosnis."
                            }
                        }
                    ))
                } footer: {
                    Text("Шаги берутся только из счётчика телефона и никуда не уходят. Телефон должен быть с вами. Шаги проверяются при открытии приложения и, если система позволит, в фоне.")
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
                        .disabled(!agreed || stake < AppConfig.minObligation || !settings.data.isAdult)
                }
            }
            .sheet(isPresented: $showTerms) {
                StakeTermsView(amount: stake) {
                    settings.acceptStakeTerms(amount: stake)
                    showTerms = false
                    // Окно предупреждения показываем, когда окно условий уже закрылось.
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        showConfirm = true
                    }
                }
            }
            .alert("Создать обещание?", isPresented: $showConfirm) {
                Button("Создать") { create() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Отменить обещание можно только в течение 5 минут после создания. Потом его нельзя ни отменить, ни изменить: если не наберёте \(minSteps) шагов, спишется \(stake) ₽.")
            }
        }
    }

    private func save() {
        guard StepCounting.isAvailable else {
            message = "На этом телефоне счётчик шагов недоступен."
            return
        }
        // Доступ могли выключить после того, как поставили галочку.
        guard StepCounting.hasAccess else {
            agreed = false
            message = "Нет доступа к данным о движении. Разрешите его в Настройках iPhone → Prosnis и поставьте галочку снова."
            return
        }
        if StakeTerms.needsConsent(settings.data.stakeConsent, amount: stake) {
            showTerms = true
        } else {
            showConfirm = true
        }
    }

    private func create() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let promise = StepPromise(title: name.isEmpty ? "Пробежка" : ContentFilter.clean(name),
                                  start: start, end: end, minSteps: minSteps, stake: stake, createdAt: TrustedClock.now)
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
