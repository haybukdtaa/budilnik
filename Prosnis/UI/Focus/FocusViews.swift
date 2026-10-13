import SwiftUI
import UIKit

/// Запуск фокус-сессии: длительность, обязательство и правила.
struct FocusStartView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    /// Вызывается, когда сессия началась (например, чтобы закрыть утренний экран).
    var onStarted: () -> Void = {}

    @State private var minutes = 45
    @State private var withStake = false
    @State private var stake = 500
    @State private var showTerms = false
    @State private var showConfirm = false
    @State private var message: String?

    private var stakeAmount: Int { withStake && settings.data.isAdult ? stake : 0 }
    private var isValid: Bool { !withStake || stake >= AppConfig.minObligation }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $minutes, in: FocusRules.minMinutes...FocusRules.maxMinutes, step: 5) {
                        Text("Длительность: \(minutes) мин")
                    }
                } footer: {
                    Text("От \(FocusRules.minMinutes) до \(FocusRules.maxMinutes) минут. Сессия начнётся сразу.")
                }

                if settings.data.isAdult {
                    Section {
                        Toggle("С обязательством", isOn: $withStake)
                        if withStake {
                            HStack {
                                Text("Сумма")
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
                        }
                    } footer: {
                        if withStake {
                            Text("Если за сессию вы проведёте вне приложения больше 5 минут суммарно, сумма спишется.")
                        }
                    }
                }

                Section {
                    Label("Не выходите из приложения и не блокируйте экран: суммарно вне приложения можно провести 5 минут (звонок, села зарядка и так далее). Экран во время сессии не гаснет.", systemImage: "iphone")
                    Label("Отменить сессию без последствий можно только в первые 5 минут. Завершить её позже раньше времени значит не выполнить.", systemImage: "clock.badge.exclamationmark")
                }
                .font(.app(.footnote))
                .foregroundStyle(.secondary)

                if let message {
                    Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(Theme.accent) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Фокус-сессия")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Начать") { tapStart() }
                        .bold()
                        .disabled(!isValid)
                }
            }
            .onAppear { minutes = FocusRules.clampMinutes(settings.data.focusMinutes) }
            .sheet(isPresented: $showTerms) {
                StakeTermsView(amount: stake) {
                    settings.acceptStakeTerms(amount: stake)
                    showTerms = false
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        showConfirm = true
                    }
                }
            }
            .alert("Начать сессию?", isPresented: $showConfirm) {
                Button("Начать") { begin() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text(confirmText)
            }
        }
    }

    private var confirmText: String {
        let base = "Сессия на \(minutes) мин начнётся сразу. Отменить без последствий можно в первые 5 минут."
        guard stakeAmount > 0 else { return base }
        return base + " Если вы проведёте вне приложения больше 5 минут суммарно, спишется \(stakeAmount) ₽."
    }

    private func tapStart() {
        if stakeAmount > 0 && StakeTerms.needsConsent(settings.data.stakeConsent, amount: stakeAmount) {
            showTerms = true
        } else {
            showConfirm = true
        }
    }

    private func begin() {
        Task {
            _ = await DeadlineNotifications.requestPermission()
            if let error = FocusStore.shared.start(minutes: minutes, stake: stakeAmount) {
                message = error
            } else {
                dismiss()
                onStarted()
            }
        }
    }
}

/// Что показывать поверх приложения: идущую сессию или её итог.
struct FocusCoverView: View {
    @ObservedObject private var store = FocusStore.shared

    var body: some View {
        if let session = store.current {
            FocusSessionView(session: session)
        } else if let result = store.result {
            FocusResultView(result: result)
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

/// Идущая сессия: обратный отсчёт, время вне приложения и отмена.
struct FocusSessionView: View {
    @ObservedObject private var store = FocusStore.shared
    let session: FocusSession
    @State private var confirmEnd = false
    /// Решается в момент нажатия кнопки: это отмена без последствий или досрочное завершение.
    @State private var endIsCancel = true

    var body: some View {
        let live = store.current ?? session
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = TrustedClock.now
            let total = Double(live.minutes) * 60
            let remaining = max(0, live.endsAt.timeIntervalSince(now))
            let away = FocusRules.awayTotal(live, now: now)
            let canCancel = FocusRules.canCancel(live, now: now)
            VStack(spacing: 22) {
                Text("Фокус")
                    .font(.app(.subheadline, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ZStack {
                    Circle().stroke(Theme.card, lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: min(1, max(0, 1 - remaining / max(total, 1))))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(FocusRules.clock(remaining))
                        .font(.system(size: 54, weight: .thin))
                        .monospacedDigit()
                }
                .frame(width: 250, height: 250)
                VStack(spacing: 6) {
                    Text("Вне приложения: \(FocusRules.clock(away)) из \(FocusRules.clock(FocusRules.awayLimit))")
                        .font(.app(.subheadline))
                        .monospacedDigit()
                        .foregroundStyle(away > FocusRules.awayLimit * 0.6 ? Color.orange : Color.secondary)
                    ProgressView(value: min(1, away / FocusRules.awayLimit))
                        .tint(away > FocusRules.awayLimit * 0.6 ? Color.orange : Theme.accent)
                        .frame(width: 180)
                }
                Text(live.stake > 0
                     ? "Обязательство \(live.stake) ₽: если вне приложения будет больше 5 минут суммарно, сумма спишется."
                     : "Не выходите из приложения и не блокируйте экран.")
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                Spacer(minLength: 0)
                Button(role: canCancel ? .cancel : .destructive) {
                    endIsCancel = FocusRules.canCancel(live, now: TrustedClock.now)
                    confirmEnd = true
                } label: {
                    Text(canCancel ? "Отменить сессию" : "Завершить раньше времени")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                Text(canCancel
                     ? "Отменить без последствий можно ещё \(FocusRules.clock(FocusRules.cancelWindow - now.timeIntervalSince(live.startedAt)))."
                     : "Отмена без последствий уже недоступна.")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { Theme.background.ignoresSafeArea() }
        }
        .confirmationDialog(
            endIsCancel ? "Отменить сессию?" : "Завершить раньше времени?",
            isPresented: $confirmEnd, titleVisibility: .visible
        ) {
            Button(endIsCancel ? "Отменить сессию" : "Завершить", role: .destructive) { store.endEarly() }
            Button("Продолжить", role: .cancel) {}
        } message: {
            Text(endIsCancel
                 ? (live.stake > 0 ? "Без последствий, если подтвердить сразу. Через несколько секунд после 5-й минуты спишется \(live.stake) ₽." : "Без последствий.")
                 : (live.stake > 0 ? "Сессия не засчитается, спишется \(live.stake) ₽." : "Сессия не засчитается."))
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                store.evaluate()
            }
        }
        // Экран во время сессии не гаснет.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// Итог сессии.
struct FocusResultView: View {
    @ObservedObject private var store = FocusStore.shared
    let result: FocusResult

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: result.outcome.isSuccess ? "checkmark.circle" : "xmark.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(result.outcome.isSuccess ? Color.green : Theme.accent)
            Text(result.outcome.isSuccess ? "Сессия засчитана" : "Сессия не засчитана")
                .font(.app(.title))
            Text(result.outcome.reason)
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 4) {
                Text("\(result.minutes) мин · вне приложения \(FocusRules.clock(result.away))")
                    .font(.app(.subheadline))
                    .monospacedDigit()
                if result.stake > 0 {
                    Text(result.outcome.isSuccess ? "Обязательство \(result.stake) ₽ не списано" : "Списано \(result.stake) ₽")
                        .font(.app(.headline))
                        .foregroundStyle(result.outcome.isSuccess ? Color.green : Theme.accent)
                }
            }
            Spacer()
            Button {
                store.result = nil
            } label: {
                Text("Готово")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.burgundy)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Theme.background.ignoresSafeArea() }
    }
}
