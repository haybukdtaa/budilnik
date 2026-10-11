import XCTest
@testable import Prosnis

final class DialTests: XCTestCase {
    func testHandsPointAtTheAlarmTime() {
        let calendar = T.calendar
        let sixThirty = DialAngles.hands(for: T.date(2026, 10, 9, 6, 30), calendar: calendar)
        XCTAssertEqual(sixThirty.minute, 180, accuracy: 0.01, "30 минут — стрелка вниз")
        XCTAssertEqual(sixThirty.hour, 195, accuracy: 0.01, "6:30 — между шестью и семью часами")
        let noon = DialAngles.hands(for: T.date(2026, 10, 9, 12, 0), calendar: calendar)
        XCTAssertEqual(noon.hour, 0, accuracy: 0.01)
        XCTAssertEqual(noon.minute, 0, accuracy: 0.01)
        let evening = DialAngles.hands(for: T.date(2026, 10, 9, 18, 15), calendar: calendar)
        XCTAssertEqual(evening.hour, 187.5, accuracy: 0.01, "18:15 показывается как 6:15")
    }

    func testDurationText() {
        XCTAssertEqual(DurationText.until(7 * 3600 + 40 * 60), "7 ч 40 мин")
        XCTAssertEqual(DurationText.until(3600), "1 ч")
        XCTAssertEqual(DurationText.until(25 * 60), "25 мин")
        XCTAssertEqual(DurationText.until(20), "1 мин", "Меньше минуты — не «0 мин»")
        XCTAssertEqual(DurationText.until(26 * 3600), "1 д 2 ч")
        XCTAssertEqual(DurationText.until(-5), "1 мин")
    }
}
