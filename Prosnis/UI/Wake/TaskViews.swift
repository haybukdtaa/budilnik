import CoreMotion
import SwiftUI
import UIKit

// MARK: - Печать

struct TypingTaskView: View {
    let sentence: String
    let onDone: () -> Void
    @State private var typed = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("Напечатайте предложение без ошибок")
                .font(.app(.subheadline))
                .foregroundStyle(.white.opacity(0.8))
            ScrollView {
                Text(styledSentence)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 170)
            NoPasteTextView(text: $typed)
                .frame(height: 130)
        }
        .onChange(of: typed) { _, newValue in
            if newValue == sentence { onDone() }
        }
    }

    /// Верно набранное зелёным, ошибки красным, остальное приглушено.
    private var styledSentence: AttributedString {
        let target = Array(sentence)
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

// MARK: - Примеры

struct MathTaskView: View {
    let onDone: () -> Void
    @State private var problems = MathProblem.batch(count: TaskRules.mathProblems)
    @State private var index = 0
    @State private var input = ""
    @State private var wrong = false

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "✓"]

    var body: some View {
        VStack(spacing: 14) {
            Text("Пример \(min(index + 1, problems.count)) из \(problems.count)")
                .font(.app(.subheadline))
                .foregroundStyle(.white.opacity(0.8))
            if index < problems.count {
                Text(problems[index].text)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Text(input.isEmpty ? "?" : input)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(wrong ? Color.red : Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        press(key)
                    } label: {
                        Text(key)
                            .font(.app(.title2).weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(key == "✓" ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.15)),
                                        in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(key == "✓" ? Color.black : Color.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func press(_ key: String) {
        wrong = false
        switch key {
        case "⌫":
            if !input.isEmpty { input.removeLast() }
        case "✓":
            check()
        default:
            if input.count < 4 { input += key }
        }
    }

    private func check() {
        guard index < problems.count else { return }
        if Int(input) == problems[index].answer {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            index += 1
            input = ""
            if index == problems.count { onDone() }
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            wrong = true
            input = ""
        }
    }
}

// MARK: - Память

struct MemoryTaskView: View {
    let onDone: () -> Void

    @State private var sequence: [Int] = []
    @State private var highlighted: Int?
    @State private var showing = true
    @State private var inputIndex = 0
    @State private var roundsDone = 0
    @State private var attempt = 0
    @State private var message = "Запомните порядок клеток"

    var body: some View {
        VStack(spacing: 14) {
            Text("Раунд \(min(roundsDone + 1, TaskRules.memoryRounds)) из \(TaskRules.memoryRounds)")
                .font(.app(.subheadline))
                .foregroundStyle(.white.opacity(0.8))
            Text(message)
                .font(.app(.headline))
                .foregroundStyle(.white)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(0..<MemorySequence.gridSize, id: \.self) { cell in
                    RoundedRectangle(cornerRadius: 12)
                        .fill(highlighted == cell ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.15)))
                        .aspectRatio(1, contentMode: .fit)
                        .onTapGesture { tap(cell) }
                }
            }
        }
        .task(id: attempt) { await play() }
    }

    private func play() async {
        sequence = MemorySequence.make(length: TaskRules.memoryLength)
        showing = true
        inputIndex = 0
        message = "Запомните порядок клеток"
        try? await Task.sleep(nanoseconds: 600_000_000)
        for cell in sequence {
            if Task.isCancelled { return }
            highlighted = cell
            try? await Task.sleep(nanoseconds: 650_000_000)
            highlighted = nil
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        showing = false
        message = "Нажмите клетки в том же порядке"
    }

    private func tap(_ cell: Int) {
        guard !showing, inputIndex < sequence.count else { return }
        if cell == sequence[inputIndex] {
            highlighted = cell
            inputIndex += 1
            if inputIndex == sequence.count {
                roundsDone += 1
                if roundsDone >= TaskRules.memoryRounds {
                    onDone()
                } else {
                    attempt += 1
                }
            }
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            message = "Ошибка. Смотрим заново"
            attempt += 1
        }
    }
}

// MARK: - Код

struct QRTaskView: View {
    let expected: String
    let onDone: () -> Void
    let onUnavailable: (String) -> Void
    @State private var status = "Дойдите до зарегистрированного кода и наведите на него камеру"

    var body: some View {
        VStack(spacing: 14) {
            CodeScannerView { code in
                if code == expected {
                    onDone()
                } else {
                    status = "Это другой код. Найдите тот, что зарегистрирован для этого будильника."
                }
            } onError: {
                onUnavailable("Камера недоступна, задание заменено на печать")
            }
            .frame(height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            Text(status)
                .font(.app(.subheadline))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Шаги

@MainActor
final class StepCounter: ObservableObject {
    @Published private(set) var steps = 0
    private let pedometer = CMPedometer()

    func start(from date: Date = Date(), onUnavailable: @escaping (String) -> Void) {
        guard CMPedometer.isStepCountingAvailable() else {
            onUnavailable("Счётчик шагов недоступен, задание заменено на печать")
            return
        }
        let status = CMPedometer.authorizationStatus()
        if status == .denied || status == .restricted {
            onUnavailable("Нет доступа к данным о движении, задание заменено на печать")
            return
        }
        pedometer.startUpdates(from: date) { [weak self] data, error in
            let count = data?.numberOfSteps.intValue
            let failed = error != nil
            DispatchQueue.main.async {
                if failed {
                    onUnavailable("Не удалось получить шаги, задание заменено на печать")
                } else if let count {
                    self?.steps = count
                }
            }
        }
    }

    /// Шаги с начала дня (для утренней программы «Спорт»).
    func loadToday() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        let start = Calendar.current.startOfDay(for: Date())
        pedometer.queryPedometerData(from: start, to: Date()) { [weak self] data, _ in
            let count = data?.numberOfSteps.intValue ?? 0
            DispatchQueue.main.async { self?.steps = count }
        }
    }

    func stop() {
        pedometer.stopUpdates()
    }
}

struct StepsTaskView: View {
    let goal: Int
    let onDone: () -> Void
    let onUnavailable: (String) -> Void
    @StateObject private var counter = StepCounter()
    @State private var finished = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 16)
                Circle()
                    .trim(from: 0, to: min(1, Double(counter.steps) / Double(goal)))
                    .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack {
                    Text("\(min(counter.steps, goal))")
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("из \(goal) шагов")
                        .font(.app(.subheadline))
                }
                .foregroundStyle(.white)
            }
            .frame(width: 220, height: 220)

            Text("Встаньте и пройдитесь с телефоном в руке")
                .font(.app(.headline))
                .foregroundStyle(.white)
        }
        .onAppear { counter.start(onUnavailable: onUnavailable) }
        .onDisappear { counter.stop() }
        .onChange(of: counter.steps) { _, steps in
            if steps >= goal && !finished {
                finished = true
                onDone()
            }
        }
    }
}
