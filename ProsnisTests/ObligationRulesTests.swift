import XCTest
@testable import Prosnis

final class ObligationRulesTests: XCTestCase {
    private func promise(createdAt: Date) -> StepPromise {
        var item = StepPromise(title: "Пробежка", start: createdAt.addingTimeInterval(3600),
                               end: createdAt.addingTimeInterval(7200), minSteps: 5000, stake: 500)
        item.createdAt = createdAt
        return item
    }

    func testPromiseCanBeCancelledOnlyInFirstFiveMinutes() {
        let created = T.date(2026, 10, 8, 12, 0)
        let item = promise(createdAt: created)
        XCTAssertTrue(PromiseRules.canCancel(item, now: created))
        XCTAssertTrue(PromiseRules.canCancel(item, now: created.addingTimeInterval(300)))
        XCTAssertFalse(PromiseRules.canCancel(item, now: created.addingTimeInterval(301)))
        XCTAssertTrue(PromiseRules.isLocked(item, now: created.addingTimeInterval(600)))
        XCTAssertTrue(PromiseRules.isLocked(item, now: created.addingTimeInterval(86_400)), "Потом никогда")
    }

    func testMinimumObligationIs250() {
        XCTAssertEqual(AppConfig.minObligation, 250)
        let text = StakeTerms.clauses(amount: 300, isTraining: false).joined(separator: " ")
        XCTAssertTrue(text.contains("250 ₽"))
        XCTAssertTrue(text.contains("сумма списывается"), "В условиях остаётся явная формулировка о списании")
        XCTAssertFalse(text.contains("Ставка"))
        XCTAssertFalse(text.contains("ставка"))
        XCTAssertGreaterThanOrEqual(StakeTerms.version, 5)
    }

    func testTermsDescribeFocusChallengeAndPromiseCancellation() {
        let text = StakeTerms.clauses(amount: 500, isTraining: false).joined(separator: " ")
        XCTAssertTrue(text.contains("Фокус-сессия"))
        XCTAssertTrue(text.contains("от 30 до 120 минут"))
        XCTAssertTrue(text.contains("в течение 5 минут"))
        XCTAssertTrue(text.contains("большая из двух сумм"))
    }

    func testChallengeChargesTheLargerOfTwoAmountsOnce() {
        XCTAssertEqual(ChallengeEvaluator.extraCharge(amount: 500, alreadyCharged: 0), 500, "Будильник не списал: платится сумма челленджа")
        XCTAssertEqual(ChallengeEvaluator.extraCharge(amount: 500, alreadyCharged: 300), 200, "Доплата до большей суммы")
        XCTAssertEqual(ChallengeEvaluator.extraCharge(amount: 500, alreadyCharged: 800), 0, "Сумма будильника больше: доплаты нет")
        XCTAssertEqual(ChallengeEvaluator.extraCharge(amount: 500, alreadyCharged: 500), 0)
    }

    func testStakedChallengeIsDecodedWithAndWithoutStake() throws {
        let old = Data("""
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Неделя","goal":"noMisses","startDate":0,"status":"active"}
        """.utf8)
        let decoder = JSONDecoder()
        let item = try decoder.decode(Challenge.self, from: old)
        XCTAssertNil(item.stake)
        XCTAssertFalse(item.hasStake)
        var staked = item
        staked.stake = 500
        XCTAssertTrue(staked.hasStake)
        let round = try decoder.decode(Challenge.self, from: JSONEncoder().encode(staked))
        XCTAssertEqual(round.stake, 500)
    }

    @MainActor
    func testStakedChallengeCannotBeStoppedAfterFiveMinutes() {
        let store = ChallengeStore.shared
        var item = Challenge(title: "Неделя", goal: .noMisses, durationDays: 7, startDate: T.date(2026, 10, 8, 12, 0), stake: 500)
        XCTAssertTrue(store.canStop(item, now: T.date(2026, 10, 8, 12, 5)))
        XCTAssertFalse(store.canStop(item, now: T.date(2026, 10, 8, 12, 6)))
        item.stake = nil
        XCTAssertTrue(store.canStop(item, now: T.date(2026, 10, 15, 12, 0)), "Без обязательства останавливать можно всегда")
    }

    func testAlarmRepeatsUntilDoneOnlyWithTaskAndWithoutObligation() {
        var alarm = AlarmItem()
        XCTAssertFalse(alarm.repeatsUntilDone, "Без задания повторять нечего")
        alarm.taskEnabled = true
        XCTAssertTrue(alarm.repeatsUntilDone, "По умолчанию включено")
        alarm.repeatUntilDone = false
        XCTAssertFalse(alarm.repeatsUntilDone)
        alarm.repeatUntilDone = nil
        alarm.stakeEnabled = true
        XCTAssertFalse(alarm.repeatsUntilDone, "С обязательством действует правило 10 минут")
    }

    func testUntilDoneSessionGetsLongerFirstTaskWindow() {
        let ring = T.date(2026, 10, 8, 7, 0)
        var session = WakeSession(
            alarmID: UUID(), alarmTitle: "Будильник", timeText: "07:00", stake: 0, wallpaper: .gradient(0),
            soundID: "classic_beep", startDate: ring, stage: 1, phase: .task, ringDate: ring, sentence: "", events: []
        )
        XCTAssertEqual(session.deadline, ring.addingTimeInterval(600))
        session.untilDone = true
        XCTAssertEqual(session.deadline, ring.addingTimeInterval(35 * 60), "6 повторов по 5 минут и ещё 5 минут после последнего")
        session.stage = 2
        XCTAssertEqual(session.deadline, ring.addingTimeInterval(600), "Вторая проверка — прежние 10 минут")
    }

    func testNoteIsTrimmedAndEmptyIsNil() {
        var alarm = AlarmItem()
        XCTAssertNil(alarm.trimmedNote)
        alarm.note = "  \n "
        XCTAssertNil(alarm.trimmedNote)
        alarm.note = "  Позвонить маме  "
        XCTAssertEqual(alarm.trimmedNote, "Позвонить маме")
    }

    func testVoiceDefaultTitle() {
        XCTAssertEqual(VoiceLibrary.defaultTitle(T.date(2026, 10, 11, 7, 12), calendar: T.calendar), "Голос · 11 окт, 07:12")
        XCTAssertEqual(VoiceLibrary.defaultTitle(T.date(2026, 5, 1, 21, 5), calendar: T.calendar), "Голос · 1 мая, 21:05")
    }

    func testMedsTabIsAlwaysOn() throws {
        XCTAssertTrue(SettingsData().medsEnabled)
        let decoded = try JSONDecoder().decode(SettingsData.self, from: Data(#"{"medsEnabled":false}"#.utf8))
        XCTAssertTrue(decoded.medsEnabled, "Вкладка «Лекарства» показывается всегда")
    }
}
