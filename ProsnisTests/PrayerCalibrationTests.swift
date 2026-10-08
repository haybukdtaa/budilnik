import XCTest
@testable import Prosnis

final class PrayerCalibrationTests: XCTestCase {
    private var makhachkala: PrayerSettings {
        var settings = PrayerSettings()
        settings.cityID = "makhachkala"
        return settings
    }

    private func fajr(angle: Double, on date: Date) -> Date {
        var settings = makhachkala
        settings.method = .custom
        settings.customAngle = angle
        return PrayerTimes.day(for: date, settings: settings).fajr!
    }

    func testRecoversTheAngleFromAFajrTime() {
        let date = T.date(2026, 10, 8, 12, 0)
        for angle in [15.0, 16.0, 17.1, 18.0, 19.5] {
            let found = PrayerCalibration.angle(forFajr: fajr(angle: angle, on: date), on: date, settings: makhachkala)
            XCTAssertEqual(found ?? 0, angle, accuracy: 0.15, "Угол \(angle)°")
        }
    }

    func testWorksWithMinutePrecision() {
        // Человек вводит только часы и минуты: 4:25 в Махачкале 8 октября — это около 17°.
        let date = T.date(2026, 10, 8, 12, 0)
        let target = PrayerCalibration.fajrDate(minutes: 4 * 60 + 25, on: date, settings: makhachkala)!
        let angle = PrayerCalibration.angle(forFajr: target, on: date, settings: makhachkala)
        XCTAssertNotNil(angle)
        XCTAssertEqual(angle ?? 0, 17.1, accuracy: 0.3)
    }

    func testRejectsTimesThatAreNotFajr() {
        let date = T.date(2026, 10, 8, 12, 0)
        // 4:59 в Махачкале — это угол около 11°: такого способа расчёта нет.
        let late = PrayerCalibration.fajrDate(minutes: 4 * 60 + 59, on: date, settings: makhachkala)!
        XCTAssertNil(PrayerCalibration.angle(forFajr: late, on: date, settings: makhachkala))
        let morning = PrayerCalibration.fajrDate(minutes: 9 * 60, on: date, settings: makhachkala)!
        XCTAssertNil(PrayerCalibration.angle(forFajr: morning, on: date, settings: makhachkala))
    }

    func testEarlierTimeMeansLargerAngle() {
        let date = T.date(2026, 10, 8, 12, 0)
        let early = PrayerCalibration.fajrDate(minutes: 4 * 60 + 20, on: date, settings: makhachkala)!
        let later = PrayerCalibration.fajrDate(minutes: 4 * 60 + 30, on: date, settings: makhachkala)!
        XCTAssertGreaterThan(PrayerCalibration.angle(forFajr: early, on: date, settings: makhachkala)!,
                             PrayerCalibration.angle(forFajr: later, on: date, settings: makhachkala)!)
    }

    func testCalibratedSettingsDecodeAndAngleText() throws {
        var settings = makhachkala
        settings.calibratedMinutes = 265
        settings.calibratedOn = Date(timeIntervalSince1970: 1_791_000_000)
        let decoded = try JSONDecoder().decode(PrayerSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertNil(try JSONDecoder().decode(PrayerSettings.self, from: Data("{}".utf8)).calibratedMinutes)
        XCTAssertEqual(PrayerCalibration.angleText(17.1), "17,1")
    }
}

final class ChargeNoticeTests: XCTestCase {
    func testOnlyOneNotificationAndItSaysCharged() {
        let first = DeadlineNotifications.text(amount: 500, isRecheck: false)
        XCTAssertEqual(first.title, "Списано 500 ₽")
        XCTAssertFalse((first.title + first.body).contains("будет"), "Не предупреждение заранее, а факт")
        XCTAssertFalse((first.title + first.body).contains("тренир"))
        XCTAssertEqual(DeadlineNotifications.text(amount: 300, isRecheck: true).body, "Вторая проверка не пройдена.")
    }

    func testFirstUnseenChargeIsOldestRealCharge() {
        var old = T.entry(T.date(2026, 10, 5, 6, 30), .failed, stake: 500)
        old.chargeSeen = false
        var newer = T.entry(T.date(2026, 10, 6, 6, 30), .failed, stake: 300)
        newer.chargeSeen = false
        var seen = T.entry(T.date(2026, 10, 4, 6, 30), .failed, stake: 500)
        seen.chargeSeen = nil
        var free = T.entry(T.date(2026, 10, 3, 6, 30), .failed, stake: 0)
        free.chargeSeen = false
        var demo = T.entry(T.date(2026, 10, 2, 6, 30), .failed, stake: 500, isDemo: true)
        demo.chargeSeen = false
        XCTAssertEqual(JournalStore.firstUnseenCharge(in: [newer, seen, free, demo, old])?.id, old.id)
        XCTAssertNil(JournalStore.firstUnseenCharge(in: [seen, free, demo]))
    }
}
