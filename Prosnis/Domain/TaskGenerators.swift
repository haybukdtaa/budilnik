import Foundation

/// Пример для задания «Решить примеры»: a × b + c.
struct MathProblem: Equatable {
    let a: Int
    let b: Int
    let c: Int

    var text: String { "\(a) × \(b) + \(c)" }
    var answer: Int { a * b + c }

    static func random<G: RandomNumberGenerator>(using generator: inout G) -> MathProblem {
        MathProblem(
            a: Int.random(in: 6...14, using: &generator),
            b: Int.random(in: 3...9, using: &generator),
            c: Int.random(in: 11...49, using: &generator)
        )
    }

    static func batch(count: Int) -> [MathProblem] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in random(using: &generator) }
    }
}

/// Последовательность клеток для задания «Запомнить клетки» (сетка 4×4).
enum MemorySequence {
    static let gridSize = 16

    /// Клетки без повторов подряд.
    static func make<G: RandomNumberGenerator>(length: Int, using generator: inout G) -> [Int] {
        var result: [Int] = []
        while result.count < length {
            let cell = Int.random(in: 0..<gridSize, using: &generator)
            if result.last != cell { result.append(cell) }
        }
        return result
    }

    static func make(length: Int) -> [Int] {
        var generator = SystemRandomNumberGenerator()
        return make(length: length, using: &generator)
    }
}

enum TaskRules {
    static let mathProblems = 3
    static let memoryLength = 5
    static let memoryRounds = 2
    static let stepsGoal = 40
}
