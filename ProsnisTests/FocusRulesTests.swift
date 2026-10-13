import XCTest
@testable import Prosnis

final class FocusRulesTests: XCTestCase {
    private let start = T.date(2026, 10, 8, 20, 0)

    private func session(minutes: Int = 60, away: TimeInterval = 0, leftAt: Date? = nil) -> FocusSession {
        var item = FocusSession(minutes: minutes, startedAt: start, stake: 500)
        item.away = away
        item.leftAt = leftAt
        return item
    }

    func testMinutesAreClampedToThirtyToHundredTwenty() {
        XCTAssertEqual(FocusRules.clampMinutes(25), 30)
        XCTAssertEqual(FocusRules.clampMinutes(45), 45)
        XCTAssertEqual(FocusRules.clampMinutes(300), 120)
    }

    func testRunsUntilTheEndThenCompletes() {
        let item = session(minutes: 60)
        XCTAssertNil(FocusRules.resolve(item, now: start.addingTimeInterval(59 * 60)))
        XCTAssertEqual(FocusRules.resolve(item, now: start.addingTimeInterval(60 * 60)), .completed)
    }

    func testExactlyFiveMinutesAwayIsStillFine() {
        let item = session(away: 300)
        XCTAssertNil(FocusRules.resolve(item, now: start.addingTimeInterval(30 * 60)))
        XCTAssertEqual(FocusRules.resolve(item, now: start.addingTimeInterval(60 * 60)), .completed)
    }

    func testMoreThanFiveMinutesAwayInTotalFails() {
        // Три выхода: 2 + 2 + 1:01 минут.
        let item = session(away: 4 * 60 + 1)
        XCTAssertNil(FocusRules.resolve(item, now: start.addingTimeInterval(30 * 60)))
        let away = session(away: 4 * 60, leftAt: start.addingTimeInterval(20 * 60))
        XCTAssertNil(FocusRules.resolve(away, now: start.addingTimeInterval(20 * 60 + 59)))
        XCTAssertEqual(FocusRules.resolve(away, now: start.addingTimeInterval(21 * 60 + 1)), .tooLongAway,
                       "Ещё идущий выход тоже считается, даже если человек не вернулся")
        XCTAssertEqual(FocusRules.failureTime(away, now: start.addingTimeInterval(40 * 60)), start.addingTimeInterval(21 * 60),
                       "Лимит кончился ровно через минуту после выхода: 4 минуты уже были")
    }

    func testAwayTimeAfterTheEndDoesNotCount() {
        // Вышел за минуту до конца и не возвращался час: лимит не превышен, сессия засчитана.
        let item = session(minutes: 30, leftAt: start.addingTimeInterval(29 * 60))
        XCTAssertEqual(FocusRules.awayTotal(item, now: start.addingTimeInterval(120 * 60)), 60)
        XCTAssertEqual(FocusRules.resolve(item, now: start.addingTimeInterval(120 * 60)), .completed)
    }

    func testLeftForTooLongBeforeTheEndFails() {
        let item = session(minutes: 30, leftAt: start.addingTimeInterval(10 * 60))
        XCTAssertEqual(FocusRules.resolve(item, now: start.addingTimeInterval(200 * 60)), .tooLongAway)
    }

    func testCancelOnlyInFirstFiveMinutes() {
        let item = session()
        XCTAssertTrue(FocusRules.canCancel(item, now: start))
        XCTAssertTrue(FocusRules.canCancel(item, now: start.addingTimeInterval(300)))
        XCTAssertFalse(FocusRules.canCancel(item, now: start.addingTimeInterval(301)))
    }

    func testClockFormatting() {
        XCTAssertEqual(FocusRules.clock(0), "0:00")
        XCTAssertEqual(FocusRules.clock(245), "4:05")
        XCTAssertEqual(FocusRules.clock(3723), "1:02:03")
        XCTAssertEqual(FocusRules.clock(-5), "0:00")
    }

    func testSessionRoundTripsThroughJSON() throws {
        var item = session(away: 12, leftAt: start)
        item.paymentRef = UUID()
        let decoded = try JSONDecoder().decode(FocusSession.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.endsAt, start.addingTimeInterval(3600))
    }

    func testFocusEntriesStayOutOfWakeStatsButCountAsMoney() {
        var entry = T.entry(start, .failed, stake: 500)
        entry.isPromise = true
        entry.kind = .focus
        XCTAssertFalse(entry.counts)
        XCTAssertEqual(entry.charged, 500)
        XCTAssertEqual(ChargeCardView.heading(entry), "Фокус-сессия не засчитана")
        entry.kind = .challenge
        XCTAssertEqual(ChargeCardView.heading(entry), "Челлендж сорван")
        entry.kind = .promise
        XCTAssertEqual(ChargeCardView.heading(entry), "Обещание не выполнено")
    }
}
