import SwiftUI

/// Экран задания: напечатать предложение, пока не вышло время.
struct WakeTaskView: View {
    @EnvironmentObject private var wake: WakeCoordinator
    let session: WakeSession
    @State private var typed = ""

    var body: some View {
        ZStack {
            WallpaperView(wallpaper: session.wallpaper)
                .ignoresSafeArea()
            Color.black.opacity(0.58).ignoresSafeArea()

            VStack(spacing: 16) {
                Text(session.stage == 1 ? "Задание 1 из 2" : "Повторная проверка · задание 2 из 2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(session.deadline.timeIntervalSince(context.date)))
                    Text(String(format: "%02d:%02d", remaining / 60, remaining % 60))
                        .font(.system(size: 64, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(remaining < 120 ? Color.red : Color.white)
                }

                Text("Напечатайте предложение без ошибок")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))

                ScrollView {
                    Text(styledSentence)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 170)

                NoPasteTextView(text: $typed)
                    .frame(height: 130)

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .id(session.stage)
        .onChange(of: typed) { _, newValue in
            if newValue == session.sentence { wake.submit() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                wake.evaluate()
            }
        }
    }

    /// Верно набранное зелёным, ошибки красным, остальное приглушено.
    private var styledSentence: AttributedString {
        let target = Array(session.sentence)
        let input = Array(typed)
        var result = AttributedString()
        for index in 0..<target.count {
            var piece = AttributedString(String(target[index]))
            if index < input.count {
                piece.foregroundColor = input[index] == target[index] ? Color.green : Color.red
            } else {
                piece.foregroundColor = Color.white.opacity(0.6)
            }
            result += piece
        }
        return result
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
