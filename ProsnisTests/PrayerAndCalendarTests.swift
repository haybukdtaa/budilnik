import XCTest
@testable import Prosnis

/// Эталоны посчитаны независимой библиотекой astral (Python); допуск 2 минуты.
final class PrayerTimesTests: XCTestCase {
    private func compute(_ y: Int, _ m: Int, _ d: Int, lat: Double, lng: Double, angle: Double) -> PrayerDay {
        PrayerTimes.compute(year: y, month: m, day: d, latitude: lat, longitude: lng,
                            timeZone: T.moscow, fajrAngle: angle, highLatitude: .angleBased)
    }

    private func assertMinutes(_ date: Date?, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let date else { return XCTFail("Нет времени", file: file, line: line) }
        XCTAssertLessThanOrEqual(abs(T.minutes(date) - expected), 2, "Получено \(T.minutes(date)), ожидалось \(expected)", file: file, line: line)
    }

    func testMoscowAutumnDUMRF() {
        let day = compute(2026, 10, 6, lat: 55.7558, lng: 37.6173, angle: 16)
        assertMinutes(day.fajr, 4 * 60 + 52)
        assertMinutes(day.sunrise, 6 * 60 + 42)
        XCTAssertFalse(day.fajrAdjusted)
    }

    func testKazanAutumnDUMRT() {
        let day = compute(2026, 10, 6, lat: 55.7963, lng: 49.1088, angle: 18)
        assertMinutes(day.fajr, 3 * 60 + 51)
        assertMinutes(day.sunrise, 5 * 60 + 56)
    }

    func testGroznySummerNoHighLatitudeRule() {
        let day = compute(2026, 6, 21, lat: 43.3178, lng: 45.6949, angle: 16)
        assertMinutes(day.fajr, 2 * 60 + 17)
        assertMinutes(day.sunrise, 4 * 60 + 17)
        XCTAssertFalse(day.fajrAdjusted)
    }

    func testMoscowSummerUsesHighLatitudeRule() {
        // Солнце не опускается на 16°: astral не находит рассвет, приложение берёт правило высоких широт.
        let day = compute(2026, 6, 21, lat: 55.7558, lng: 37.6173, angle: 16)
        XCTAssertTrue(day.fajrAdjusted)
        guard let fajr = day.fajr, let sunrise = day.sunrise else { return XCTFail("Нет времени") }
        XCTAssertLessThan(fajr, sunrise)
        assertMinutes(sunrise, 3 * 60 + 44)
    }

    func testMurmanskPolarDayAndNightDoNotCrash() {
        let summer = compute(2026, 6, 21, lat: 68.9585, lng: 33.0827, angle: 16)
        XCTAssertNil(summer.sunrise)
        XCTAssertNil(summer.fajr)
        let winter = compute(2026, 12, 21, lat: 68.9585, lng: 33.0827, angle: 16)
        XCTAssertNil(winter.fajr)
    }

    func testAdjustmentMinutes() {
        var settings = PrayerSettings()
        settings.cityID = "moscow"
        let base = PrayerTimes.day(for: T.date(2026, 10, 6, 12), settings: settings).fajr!
        settings.adjustmentMinutes = 5
        let adjusted = PrayerTimes.day(for: T.date(2026, 10, 6, 12), settings: settings).fajr!
        XCTAssertEqual(adjusted.timeIntervalSince(base), 300, accuracy: 1)
    }
}

final class HolidayCalendarTests: XCTestCase {
    private func nonWorkingWeekdays(_ year: Int) -> [String] {
        let calendar = T.calendar
        var result: [String] = []
        var day = T.date(year, 1, 1)
        while calendar.component(.year, from: day) == year {
            if HolidayCalendarRU.isHolidayWeekday(day, calendar: calendar) {
                let parts = calendar.dateComponents([.month, .day], from: day)
                result.append(String(format: "%02d.%02d", parts.day!, parts.month!))
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    private func workingDays(_ year: Int) -> Int {
        let calendar = T.calendar
        var count = 0
        var day = T.date(year, 1, 1)
        while calendar.component(.year, from: day) == year {
            if HolidayCalendarRU.isWorkingDay(day, calendar: calendar) { count += 1 }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return count
    }

    func test2026MatchesOfficialCalendar() {
        XCTAssertEqual(nonWorkingWeekdays(2026), [
            "01.01", "02.01", "05.01", "06.01", "07.01", "08.01", "09.01",
            "23.02", "09.03", "01.05", "11.05", "12.06", "04.11", "31.12",
        ])
        XCTAssertEqual(workingDays(2026), 247)
    }

    func test2027MatchesDecree1187() {
        XCTAssertEqual(nonWorkingWeekdays(2027), [
            "01.01", "04.01", "05.01", "06.01", "07.01", "08.01",
            "22.02", "23.02", "08.03", "03.05", "10.05", "14.06", "04.11", "05.11", "31.12",
        ])
        XCTAssertEqual(workingDays(2027), 247)
        XCTAssertTrue(HolidayCalendarRU.isWorkingWeekend(T.date(2027, 2, 20), calendar: T.calendar))
        XCTAssertTrue(HolidayCalendarRU.isWorkingDay(T.date(2027, 2, 20), calendar: T.calendar))
    }

    func testOtherYearsStillHaveHolidays() {
        XCTAssertFalse(HolidayCalendarRU.hasTransferData(for: 2030))
        XCTAssertFalse(HolidayCalendarRU.isWorkingDay(T.date(2030, 6, 12), calendar: T.calendar))
    }
}

final class ScheduleTests: XCTestCase {
    private var context: ScheduleContext { ScheduleContext(prayer: PrayerSettings(), calendar: T.calendar) }

    func testSkipHolidaysOnWeekdays() {
        var alarm = AlarmItem()
        alarm.hour = 7
        alarm.weekdays = [1, 2, 3, 4, 5]
        alarm.holidayMode = .skipHolidays
        let dates = ScheduleCalculator.occurrences(for: alarm, from: T.date(2026, 1, 1), to: T.date(2026, 1, 13, 23), context: context)
        XCTAssertEqual(dates.first, T.date(2026, 1, 12, 7))
        XCTAssertEqual(dates.count, 2)
    }

    func testWorkCalendarIncludesWorkingSaturday() {
        var alarm = AlarmItem()
        alarm.hour = 6
        alarm.minute = 30
        alarm.holidayMode = .workCalendar
        let dates = ScheduleCalculator.occurrences(for: alarm, from: T.date(2027, 2, 19, 12), to: T.date(2027, 2, 24, 23), context: context)
        XCTAssertEqual(dates, [T.date(2027, 2, 20, 6, 30), T.date(2027, 2, 24, 6, 30)])
    }

    func testPlainWeeklyAndLastOccurrence() {
        var alarm = AlarmItem()
        alarm.hour = 8
        alarm.weekdays = [6, 7]
        let now = T.date(2026, 10, 6, 12) // вторник
        XCTAssertEqual(ScheduleCalculator.nextOccurrence(for: alarm, after: now, context: context), T.date(2026, 10, 10, 8))
        XCTAssertEqual(ScheduleCalculator.lastOccurrence(for: alarm, onOrBefore: now, context: context), T.date(2026, 10, 4, 8))
    }

    func testOneTimeAlarmFiresOnceAfterCreation() {
        var alarm = AlarmItem()
        alarm.hour = 7
        alarm.createdAt = T.date(2026, 10, 6, 8)
        XCTAssertEqual(ScheduleCalculator.onceDate(for: alarm, context: context), T.date(2026, 10, 7, 7))
        let dates = ScheduleCalculator.effectiveOccurrences(for: alarm, from: T.date(2026, 10, 6, 8), to: T.date(2026, 10, 12), context: context)
        XCTAssertEqual(dates, [T.date(2026, 10, 7, 7)])
    }

    func testFajrAlarmFollowsPrayerTime() {
        var alarm = AlarmItem()
        alarm.module = .prayer
        alarm.fajrOffset = -20
        alarm.weekdays = [1, 2, 3, 4, 5, 6, 7]
        let ring = ScheduleCalculator.ringDate(for: alarm, onDayOf: T.date(2026, 10, 6, 12), context: context)!
        let fajr = PrayerTimes.day(for: T.date(2026, 10, 6, 12), settings: PrayerSettings()).fajr!
        XCTAssertEqual(ring.timeIntervalSince(fajr), -20 * 60, accuracy: 1)
        XCTAssertTrue(alarm.needsDatedSchedule)
        XCTAssertTrue(alarm.isPrayerRelated)
    }
}
