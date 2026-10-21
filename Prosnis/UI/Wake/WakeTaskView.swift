import SwiftUI
import UIKit

/// Экран задания: выполнить задание, пока не вышло время.
struct WakeTaskView: View {
    @EnvironmentObject private var wake: WakeCoordinator
    @EnvironmentObject private var settings: AppSettings
    let session: WakeSession

    var body: some View {
        ZStack {
            WallpaperView(wallpaper: session.wallpaper)
                .ignoresSafeArea()
            Color.black.opacity(0.6).ignoresSafeArea()

            GeometryReader { geo in
            ScrollView {
            VStack(spacing: 14) {
                Text(session.stage == 1 ? (session.needsRecheck ? "Задание 1 из 2" : "Задание") : "Повторная проверка · задание 2 из 2")
                    .font(.app(.subheadline, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(session.deadline.timeIntervalSince(context.date)))
                    Text(String(format: "%02d:%02d", remaining / 60, remaining % 60))
                        .font(.system(size: 60, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(remaining < 120 ? Color.red : Color.white)
                }

                if let reason = settings.wakeReason {
                    // Две строки максимум и низший приоритет: задание важнее, его нельзя сжимать.
                    Text("«\(reason)»")
                        .font(.app(.subheadline))
                        .italic()
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                        .layoutPriority(-1)
                }

                Label(session.taskKind.title, systemImage: session.taskKind.icon)
                    .font(.app(.headline))
                    .foregroundStyle(.white)

                taskBody

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(minHeight: geo.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            }
        }
        // Пока идёт задание (ходьба, камера), экран не должен погаснуть.
        .onAppear { IdleLock.acquire() }
        .onDisappear { IdleLock.release() }
        .id("\(session.alarmID)-\(session.startDate.timeIntervalSince1970)-\(session.stage)-\(session.taskKind.rawValue)")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                wake.evaluate()
            }
        }
    }

    @ViewBuilder
    private var taskBody: some View {
        switch session.taskKind {
        case .typing:
            TypingTaskView(sentence: session.sentence) { wake.submit() }
        case .math:
            MathTaskView { wake.submit() }
        case .memory:
            MemoryTaskView { wake.submit() }
        case .qr:
            QRTaskView(expected: session.qrCode ?? "") {
                wake.submit()
            } onUnavailable: { reason in
                wake.switchToTyping(reason: reason)
            }
        case .steps:
            StepsTaskView(goal: TaskRules.stepsGoal) {
                wake.submit()
            } onUnavailable: { reason in
                wake.switchToTyping(reason: reason)
            }
        case .shake:
            ShakeTaskView(goal: TaskRules.shakeGoal) {
                wake.submit()
            } onUnavailable: { reason in
                wake.switchToTyping(reason: reason)
            }
        }
    }
}

/// Экран не гаснет, пока открыто хотя бы одно окно, которому это нужно (задание, фокус-сессия).
/// Счётчик нужен, потому что при смене окна новое появляется раньше, чем старое исчезает.
@MainActor
enum IdleLock {
    private static var count = 0

    static func acquire() {
        count += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release() {
        count = max(0, count - 1)
        if count == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// Плашка сверху, пока ждём повторную проверку.
struct RecheckBanner: View {
    @EnvironmentObject private var wake: WakeCoordinator
    let session: WakeSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let target = session.recheckDate ?? context.date
            let remaining = max(0, Int(target.timeIntervalSince(context.date)))
            VStack(spacing: 2) {
                Text("Повторная проверка через \(String(format: "%02d:%02d", remaining / 60, remaining % 60))")
                    .font(.app(.subheadline, weight: .semibold))
                Text("Не засыпайте: будильник зазвонит снова")
                    .font(.app(.caption))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Theme.accentGradient)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                wake.evaluate()
            }
        }
    }
}
