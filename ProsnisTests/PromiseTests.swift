import XCTest
@testable import Prosnis

final class PromiseTests: XCTestCase {
    private func promise() -> StepPromise {
        StepPromise(title: "Пробежка", start: T.date(2026, 10, 8, 22, 0), end: T.date(2026, 10, 8, 23, 30), minSteps: 5000, stake: 500)
    }

    func testNothingBeforeTheWindow() {
        XCTAssertNil(PromiseRules.resolve(promise(), read: .steps(9000), now: T.date(2026, 10, 8, 21, 59)))
    }

    func testKeptEarlyWhenGoalReachedInsideTheWindow() {
        XCTAssertEqual(PromiseRules.resolve(promise(), read: .steps(5200), now: T.date(2026, 10, 8, 22, 40)), .kept(steps: 5200))
        XCTAssertNil(PromiseRules.resolve(promise(), read: .steps(3000), now: T.date(2026, 10, 8, 22, 40)), "Окно ещё идёт")
    }

    func testBrokenAfterTheWindowWithTooFewSteps() {
        let now = T.date(2026, 10, 9, 8, 0)
        XCTAssertEqual(PromiseRules.resolve(promise(), read: .steps(4000), now: now), .broken(.notEnough, steps: 4000))
        XCTAssertEqual(PromiseRules.resolve(promise(), read: .steps(5000), now: now), .kept(steps: 5000), "Ровно норма — выполнено")
    }

    func testDeniedAccessIsTheUsersChoice() {
        XCTAssertNil(PromiseRules.resolve(promise(), read: .denied, now: T.date(2026, 10, 8, 22, 40)), "Пока окно идёт — ждём")
        XCTAssertEqual(PromiseRules.resolve(promise(), read: .denied, now: T.date(2026, 10, 9, 8, 0)), .broken(.denied, steps: nil))
    }

    func testReadErrorsRetryAndOnlyBecomeTechnicalAfterTheDeadline() {
        let soon = T.date(2026, 10, 9, 8, 0)
        XCTAssertNil(PromiseRules.resolve(promise(), read: .unavailable, now: soon), "Сбой чтения — повторим при следующем открытии")
        var failed = promise()
        failed.readFailed = true
        let late = T.date(2026, 10, 16, 8, 0)
        XCTAssertEqual(PromiseRules.resolve(failed, read: nil, now: late), .technical, "Не читалось из-за сбоя — не списываем")
        XCTAssertEqual(PromiseRules.resolve(promise(), read: nil, now: late), .broken(.unverified, steps: nil), "Не открывали — невыполнено")
    }

    func testLockTwoHoursBeforeStart() {
        let item = promise()
        XCTAssertFalse(PromiseRules.isLocked(item, now: T.date(2026, 10, 8, 19, 59)))
        XCTAssertTrue(PromiseRules.isLocked(item, now: T.date(2026, 10, 8, 20, 0)))
        XCTAssertTrue(PromiseRules.isLocked(item, now: T.date(2026, 10, 8, 22, 30)))
    }

    func testEventTexts() {
        let item = promise()
        XCTAssertEqual(PromiseRules.eventText(.broken(.notEnough, steps: 4000), promise: item), "Насчитано 4000 шагов из 5000")
        XCTAssertTrue(PromiseRules.eventText(.kept(steps: 5200), promise: item).contains("выполнено"))
        XCTAssertTrue(PromiseRules.eventText(.technical, promise: item).contains("списания нет"))
    }

    func testPromiseEntriesStayOutOfWakeStatsButCountAsMoney() {
        var kept = T.entry(T.date(2026, 10, 8, 22, 0), .success, stake: 500)
        kept.isPromise = true
        var broken = T.entry(T.date(2026, 10, 8, 22, 0), .failed, stake: 500)
        broken.isPromise = true
        XCTAssertFalse(kept.counts)
        XCTAssertFalse(broken.counts, "Невыполненная пробежка не сушит дерево подъёмов")
        XCTAssertEqual(broken.charged, 500, "Деньги по обещанию учитываются")
        let snapshot = ProgressEngine.compute(entries: [kept, broken].filter(\.counts), challenges: [])
        XCTAssertEqual(snapshot.totalWakes, 0)
        XCTAssertNil(JournalStore.firstUnseenCharge(in: [broken]), "Карточка показывается только если списание помечено непросмотренным")
    }

    func testTermsMentionStepPromisesAndVersionBumped() {
        let text = StakeTerms.clauses(amount: 500, isTraining: false).joined(separator: " ")
        XCTAssertTrue(text.contains("Обещание по шагам"))
        XCTAssertTrue(text.contains("6 дней"))
        XCTAssertGreaterThanOrEqual(StakeTerms.version, 4)
        let old = StakeConsent(version: 3, acceptedAt: Date(), maxAmount: 10_000)
        XCTAssertTrue(StakeTerms.needsConsent(old, amount: 100), "Условия изменились — согласие заново")
    }
}
