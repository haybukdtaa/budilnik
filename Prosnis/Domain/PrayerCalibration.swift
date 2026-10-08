import Foundation

/// «Подогнать под мою мечеть»: человек один раз вводит время Фаджра из источника, которому доверяет,
/// а приложение подбирает угол погружения солнца, при котором расчёт даёт то же время.
/// Дальше Фаджр считается по этому углу каждый день.
enum PrayerCalibration {
    /// Реальные способы расчёта лежат в этих пределах (15°…19,5°). За их пределами — скорее всего,
    /// ошибка в городе, дате или введённом времени.
    static let range: ClosedRange<Double> = 12...20

    /// Допустимая разница между введённым временем и расчётом по подобранному углу.
    static let toleranceSeconds: TimeInterval = 120

    /// Момент «часы:минуты» в часовом поясе города на дату `date`.
    static func fajrDate(minutes: Int, on date: Date, settings: PrayerSettings) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = settings.city.timeZone
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: date)
    }

    /// Угол (с точностью до 0,1°), при котором Фаджр в этот день выходит в `target`. nil — такое время не подходит городу.
    static func angle(forFajr target: Date, on date: Date, settings: PrayerSettings) -> Double? {
        var base = settings
        base.method = .custom
        base.adjustmentMinutes = 0
        func fajr(_ angle: Double) -> Date? {
            var item = base
            item.customAngle = angle
            return PrayerTimes.day(for: date, settings: item).fajr
        }
        // Чем больше угол, тем раньше Фаджр.
        guard let earliest = fajr(range.upperBound), let latest = fajr(range.lowerBound),
              target >= earliest.addingTimeInterval(-60), target <= latest.addingTimeInterval(60) else { return nil }
        var low = range.lowerBound
        var high = range.upperBound
        for _ in 0..<30 {
            let middle = (low + high) / 2
            guard let time = fajr(middle) else { return nil }
            if time > target { low = middle } else { high = middle }
        }
        let angle = ((low + high) / 2 * 10).rounded() / 10
        guard let check = fajr(angle), abs(check.timeIntervalSince(target)) <= toleranceSeconds else { return nil }
        return angle
    }

    /// «17,1» — с запятой, как принято в России.
    static func angleText(_ angle: Double) -> String {
        String(format: "%.1f", angle).replacingOccurrences(of: ".", with: ",")
    }
}
