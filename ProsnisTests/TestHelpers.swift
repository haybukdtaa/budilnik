import Foundation
@testable import Prosnis

enum T {
    static let moscow = TimeZone(identifier: "Europe/Moscow")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = moscow
        calendar.locale = Locale(identifier: "ru_RU")
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Минуты от полуночи по Москве.
    static func minutes(_ date: Date, in zone: TimeZone = moscow) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func entry(
        _ date: Date,
        _ outcome: Outcome,
        stake: Int = 0,
        isPrayer: Bool? = nil,
        isDemo: Bool? = nil,
        task: TaskKind? = .typing,
        routineDone: [String]? = nil,
        routineTotal: Int? = nil
    ) -> JournalEntry {
        JournalEntry(
            date: date,
            alarmID: UUID(),
            alarmTitle: "Тест",
            timeText: "07:00",
            stake: stake,
            outcome: outcome,
            events: [],
            isDemo: isDemo,
            isPrayer: isPrayer,
            taskKind: task,
            routineDone: routineDone,
            routineTotal: routineTotal
        )
    }
}
