import XCTest
@testable import Prosnis

final class ProgressEngineTests: XCTestCase {
    private func days(_ outcomes: [Outcome], startDay: Int = 1, hour: Int = 7) -> [JournalEntry] {
        outcomes.enumerated().map { index, outcome in
            T.entry(T.date(2026, 9, startDay + index, hour), outcome)
        }
    }

    func testStreakXPAndBadges() {
        let entries = days([.success, .success, .success, .failed, .success])
        let snapshot = ProgressEngine.compute(entries: entries, challenges: [], now: T.date(2026, 9, 10), calendar: T.calendar)
        XCTAssertEqual(snapshot.totalWakes, 4)
        XCTAssertEqual(snapshot.currentStreak, 1)
        XCTAssertEqual(snapshot.longestStreak, 3)
        // 11 + 12 + 13 + 11
        XCTAssertEqual(snapshot.xp, 47)
        let ids = Set(snapshot.unlocked.map(\.id))
        XCTAssertTrue(ids.contains("first_wake"))
        XCTAssertTrue(ids.contains("streak_3"))
        XCTAssertFalse(ids.contains("streak_7"))
        XCTAssertEqual(snapshot.tree.stage, 2)
        XCTAssertEqual(snapshot.tree.wilt, 1)
    }

    func testStreakCountsMorningsNotAlarms() {
        let entries = [
            T.entry(T.date(2026, 9, 1, 5), .success, isPrayer: true),
            T.entry(T.date(2026, 9, 1, 7, 30), .success),
            T.entry(T.date(2026, 9, 2, 5), .success),
            T.entry(T.date(2026, 9, 2, 7, 30), .failed),
        ]
        let snapshot = ProgressEngine.compute(entries: entries, challenges: [], now: T.date(2026, 9, 3), calendar: T.calendar)
        XCTAssertEqual(snapshot.longestStreak, 1, "Два будильника в одно утро — это одно утро")
        XCTAssertEqual(snapshot.currentStreak, 0, "Провал в тот же день обнуляет серию")
        XCTAssertEqual(snapshot.totalWakes, 1)
        // 11 + 11 за первый день, 10 за удачный будильник в неудачный день.
        XCTAssertEqual(snapshot.xp, 32)
    }

    func testDemoAndTechnicalEntriesAreIgnored() {
        var entries = days([.success, .success])
        entries.append(T.entry(T.date(2026, 9, 3, 7), .failed, isDemo: true))
        entries.append(T.entry(T.date(2026, 9, 4, 7), .technical))
        let snapshot = ProgressEngine.compute(entries: entries, challenges: [], now: T.date(2026, 9, 5), calendar: T.calendar)
        XCTAssertEqual(snapshot.currentStreak, 2)
        XCTAssertEqual(snapshot.tree.wilt, 0)
    }

    func testRoutineXP() {
        let entry = T.entry(T.date(2026, 9, 1, 7), .success, routineDone: ["a", "b"], routineTotal: 2)
        let snapshot = ProgressEngine.compute(entries: [entry], challenges: [], now: T.date(2026, 9, 2), calendar: T.calendar)
        XCTAssertEqual(snapshot.xp, 11 + 4)
    }

    func testLevels() {
        XCTAssertEqual(ProgressEngine.level(forXP: 0).level, 1)
        XCTAssertEqual(ProgressEngine.level(forXP: 99).level, 1)
        XCTAssertEqual(ProgressEngine.level(forXP: 100).level, 2)
        XCTAssertEqual(ProgressEngine.level(forXP: 300).level, 3)
        XCTAssertEqual(ProgressEngine.level(forXP: 250).toNext, 50)
    }

    func testPrivatePrayerBadge() {
        let entries = (1...7).map { T.entry(T.date(2026, 9, $0, 4), .success, isPrayer: true) }
        let snapshot = ProgressEngine.compute(entries: entries, challenges: [], now: T.date(2026, 9, 8), calendar: T.calendar)
        let fajr = snapshot.unlocked.first { $0.id == "fajr_7" }
        XCTAssertNotNil(fajr)
        XCTAssertTrue(fajr!.badge.isPrivate)
        XCTAssertTrue(snapshot.unlocked.contains { $0.id == "early_bird" } == false)
    }

    func testWeekSummary() {
        // 5–9 октября 2026 — понедельник–пятница.
        let entries = (5...9).map { T.entry(T.date(2026, 10, $0, 6, 30), $0 == 7 ? .failed : .success) }
        let snapshot = ProgressEngine.compute(entries: entries, challenges: [], now: T.date(2026, 10, 9, 20), calendar: T.calendar)
        XCTAssertEqual(snapshot.thisWeek.mornings, 5)
        XCTAssertEqual(snapshot.thisWeek.successes, 4)
        XCTAssertEqual(snapshot.thisWeek.averageWakeMinutes, 6 * 60 + 30)
    }

    func testCompletedChallengeGivesXP() {
        let challenge = Challenge(title: "7", goal: .noMisses, durationDays: 7, startDate: T.date(2026, 9, 1),
                                  status: .completed, endedAt: T.date(2026, 9, 8))
        let snapshot = ProgressEngine.compute(entries: [], challenges: [challenge], now: T.date(2026, 9, 9), calendar: T.calendar)
        XCTAssertEqual(snapshot.xp, 57)
        XCTAssertTrue(snapshot.unlocked.contains { $0.id == "challenge_first" })
    }
}

final class ChallengeEvaluatorTests: XCTestCase {
    func testNoMissesCompletes() {
        let challenge = Challenge(title: "Неделя", goal: .noMisses, durationDays: 7, startDate: T.date(2026, 9, 1, 6))
        let entries = (1...7).map { T.entry(T.date(2026, 9, $0, 7), .success) }
        let result = ChallengeEvaluator.evaluate(challenge, entries: entries, now: T.date(2026, 9, 8, 12), calendar: T.calendar)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.successDays, 7)
    }

    func testNoMissesFailsOnFirstFailure() {
        let challenge = Challenge(title: "Неделя", goal: .noMisses, durationDays: 7, startDate: T.date(2026, 9, 1))
        let entries = [T.entry(T.date(2026, 9, 1, 7), .success), T.entry(T.date(2026, 9, 2, 7), .failed)]
        let result = ChallengeEvaluator.evaluate(challenge, entries: entries, now: T.date(2026, 9, 3), calendar: T.calendar)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failedOn, T.date(2026, 9, 2, 7))
    }

    func testWakeBefore() {
        let challenge = Challenge(title: "До 7", goal: .wakeBefore, wakeBeforeMinutes: 7 * 60, durationDays: nil, startDate: T.date(2026, 9, 1))
        let ok = ChallengeEvaluator.evaluate(challenge, entries: [T.entry(T.date(2026, 9, 1, 6, 55), .success)],
                                             now: T.date(2026, 9, 2), calendar: T.calendar)
        XCTAssertEqual(ok.status, .active)
        let late = ChallengeEvaluator.evaluate(challenge, entries: [T.entry(T.date(2026, 9, 1, 7, 30), .success)],
                                               now: T.date(2026, 9, 2), calendar: T.calendar)
        XCTAssertEqual(late.status, .failed)
    }

    func testPrayerChallengeIgnoresOtherMornings() {
        let challenge = Challenge(title: "Фаджр", goal: .prayer, durationDays: 3, startDate: T.date(2026, 9, 1))
        let entries = [
            T.entry(T.date(2026, 9, 1, 4), .success, isPrayer: true),
            T.entry(T.date(2026, 9, 1, 8), .failed),
        ]
        let result = ChallengeEvaluator.evaluate(challenge, entries: entries, now: T.date(2026, 9, 2), calendar: T.calendar)
        XCTAssertEqual(result.status, .active)
    }

    func testRoutineIsPendingUntilChecklistSaved() {
        let challenge = Challenge(title: "Чек-лист", goal: .routine, durationDays: 7, startDate: T.date(2026, 9, 1))
        let today = T.entry(T.date(2026, 9, 2, 7), .success)
        let pending = ChallengeEvaluator.evaluate(challenge, entries: [today], now: T.date(2026, 9, 2, 8), calendar: T.calendar)
        XCTAssertEqual(pending.status, .active, "Сразу после подъёма чек-лист ещё не отмечен — это не провал")
        let nextDay = ChallengeEvaluator.evaluate(challenge, entries: [today], now: T.date(2026, 9, 3, 8), calendar: T.calendar)
        XCTAssertEqual(nextDay.status, .failed, "Если до конца дня не отметили, утро не засчитано")
        let done = T.entry(T.date(2026, 9, 2, 7), .success, routineDone: ["a", "b"], routineTotal: 2)
        let ok = ChallengeEvaluator.evaluate(challenge, entries: [done], now: T.date(2026, 9, 3, 8), calendar: T.calendar)
        XCTAssertEqual(ok.status, .active)
    }

    func testMorningsBeforeChallengeStartAreIgnored() {
        let challenge = Challenge(title: "x", goal: .noMisses, durationDays: 7, startDate: T.date(2026, 9, 1, 12))
        let result = ChallengeEvaluator.evaluate(challenge, entries: [T.entry(T.date(2026, 9, 1, 7), .failed)],
                                                 now: T.date(2026, 9, 1, 13), calendar: T.calendar)
        XCTAssertEqual(result.status, .active)
    }

    func testAbandonedStaysAbandoned() {
        var challenge = Challenge(title: "x", goal: .noMisses, durationDays: 3, startDate: T.date(2026, 9, 1))
        challenge.status = .abandoned
        let result = ChallengeEvaluator.evaluate(challenge, entries: [T.entry(T.date(2026, 9, 1, 7), .failed)],
                                                 now: T.date(2026, 9, 2), calendar: T.calendar)
        XCTAssertEqual(result.status, .abandoned)
    }

    func testDemoEntriesDoNotBreakChallenge() {
        let challenge = Challenge(title: "x", goal: .noMisses, durationDays: 3, startDate: T.date(2026, 9, 1))
        let result = ChallengeEvaluator.evaluate(challenge, entries: [T.entry(T.date(2026, 9, 1, 7), .failed, isDemo: true)],
                                                 now: T.date(2026, 9, 2), calendar: T.calendar)
        XCTAssertEqual(result.status, .active)
    }
}
