import SwiftUI

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

            VStack(spacing: 14) {
                Text(session.stage == 1 ? "Задание 1 из 2" : "Повторная проверка · задание 2 из 2")
                    .font(.subheadline.weight(.semibold))
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
                        .font(.subheadline)
                        .italic()
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                        .layoutPriority(-1)
                }

                Label(session.taskKind.title, systemImage: session.taskKind.icon)
                    .font(.headline)
                    .foregroundStyle(.white)

                taskBody

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .id("\(session.stage)-\(session.taskKind.rawValue)")
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
        }
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
                    .font(.subheadline.weight(.semibold))
                Text("Не засыпайте: будильник зазвонит снова")
                    .font(.caption)
            }
            .foregroundStyle(.black)
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
