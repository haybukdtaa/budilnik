import XCTest
@testable import Prosnis

final class StakeTermsTests: XCTestCase {
    func testConsentNeededWhenMissingOutdatedOrAmountGrows() {
        XCTAssertTrue(StakeTerms.needsConsent(nil, amount: 500))
        let consent = StakeConsent(version: StakeTerms.version, acceptedAt: Date(), maxAmount: 500)
        XCTAssertFalse(StakeTerms.needsConsent(consent, amount: 500))
        XCTAssertFalse(StakeTerms.needsConsent(consent, amount: 300), "Меньшая сумма уже покрыта согласием")
        XCTAssertTrue(StakeTerms.needsConsent(consent, amount: 501), "Сумма больше — согласие заново")
        let old = StakeConsent(version: StakeTerms.version - 1, acceptedAt: Date(), maxAmount: 10_000)
        XCTAssertTrue(StakeTerms.needsConsent(old, amount: 100), "Условия изменились — согласие заново")
    }

    func testTermsStateTheSecondCheckRule() {
        let text = StakeTerms.clauses(amount: 500, isTraining: false).joined(separator: " ")
        XCTAssertTrue(text.contains("500 ₽"))
        XCTAssertTrue(text.contains("даже если вы уже встали"), "Человек заранее соглашается: встал, но не прошёл вторую проверку — списание")
        XCTAssertTrue(text.contains("Прощений"))
        XCTAssertFalse(text.contains("тренировочные"))
        XCTAssertTrue(StakeTerms.clauses(amount: 500, isTraining: true).joined().contains("тренировочные"))
    }

    func testTermsMentionTenDaysAndNoAutoRefund() {
        let text = StakeTerms.clauses(amount: 500, isTraining: false).joined(separator: " ")
        XCTAssertTrue(text.contains("10 дней"))
        XCTAssertTrue(text.contains("автоматического возврата нет"))
        XCTAssertTrue(text.contains("сервер был недоступен"), "Сбой сервера — тоже не по вине человека")
        let previous = StakeConsent(version: StakeTerms.version - 1, acceptedAt: Date(), maxAmount: 10_000)
        XCTAssertTrue(StakeTerms.needsConsent(previous, amount: 100), "Согласие на прошлые условия не действует")
    }

    func testPartialDatedFailureAndHorizon() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let end = now.addingTimeInterval(10 * 86400)
        let scheduled = [now.addingTimeInterval(86400), now.addingTimeInterval(3 * 86400)]
        let failedDay = now.addingTimeInterval(2 * 86400)
        func state(_ ring: Date) -> AlarmService.ScheduleState {
            AlarmService.classify(authorized: true, denied: false, failed: true, dated: true, scheduledDates: scheduled,
                                  failedDates: [failedDay], horizonEnd: end, ring: ring)
        }
        XCTAssertEqual(state(scheduled[0]), .scheduled)
        XCTAssertEqual(state(failedDay), .systemFailure, "Дату не удалось поставить — сбой, без списания")
        XCTAssertEqual(state(now.addingTimeInterval(5 * 86400)), .systemFailure,
                       "Внутри поставленного промежутка, но после последней даты — всё равно не вина человека")
        XCTAssertEqual(state(end.addingTimeInterval(3600)), .notRefreshed, "После конца промежутка — не открывали приложение")
    }

    func testScheduleStateClassification() {
        let ring = Date(timeIntervalSince1970: 1_791_000_000)
        let scheduled = (0..<10).map { ring.addingTimeInterval(Double($0) * 86400 - 9 * 86400) } // последняя дата — ring
        XCTAssertEqual(AlarmService.classify(authorized: true, denied: false, failed: false, dated: true,
                                             scheduledDates: scheduled, ring: ring), .scheduled)
        XCTAssertEqual(AlarmService.classify(authorized: true, denied: false, failed: false, dated: true,
                                             scheduledDates: scheduled, ring: ring.addingTimeInterval(86400)), .notRefreshed,
                       "Звонок после последней поставленной даты: приложение не открывали — провал")
        XCTAssertEqual(AlarmService.classify(authorized: true, denied: false, failed: false, dated: true,
                                             scheduledDates: scheduled, ring: ring.addingTimeInterval(-86400 / 2)), .systemFailure,
                       "Дата внутри поставленного промежутка, но не поставлена — сбой")
        XCTAssertEqual(AlarmService.classify(authorized: false, denied: false, failed: false, dated: false,
                                             scheduledDates: [], ring: ring), .permissionMissing)
        XCTAssertEqual(AlarmService.classify(authorized: true, denied: false, failed: true, dated: false,
                                             scheduledDates: [], ring: ring), .systemFailure)
        XCTAssertEqual(AlarmService.classify(authorized: true, denied: false, failed: false, dated: false,
                                             scheduledDates: [], ring: ring), .scheduled)
    }

    func testWakeEventSignatureMatchesReference() {
        // Эталон посчитан стандартной библиотекой Python (hmac, sha256, base64).
        let message = "6F9619FF-8B86-D011-B42D-00C04FC964FF|1791255600|taskDone|1791256000"
        XCTAssertEqual(WakeEvent.sign(message, secret: "test-secret"), "OU6cIJ2o8EBvYkhQD+5K+lwy6OINVm91GrnOnrhVfok=")
    }

    func testSignedMessageFormat() {
        let alarm = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let ring = Date(timeIntervalSince1970: 1_791_255_600)
        let morning = WakeEvent.morningID(alarmID: alarm, ring: ring)
        XCTAssertEqual(morning, "6F9619FF-8B86-D011-B42D-00C04FC964FF|1791255600")
        let message = WakeEvent.signedMessage(morningID: morning, kind: .taskDone, at: Date(timeIntervalSince1970: 1_791_256_000.7))
        XCTAssertEqual(message, "6F9619FF-8B86-D011-B42D-00C04FC964FF|1791255600|taskDone|1791256000",
                       "Секунды без долей: так же дата уходит на сервер")
    }

    func testConsentRoundTripInSettings() throws {
        var settings = SettingsData()
        settings.stakeConsent = StakeConsent(version: 1, acceptedAt: Date(timeIntervalSince1970: 1_791_000_000), maxAmount: 700)
        let decoded = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.stakeConsent, settings.stakeConsent)
        XCTAssertNil(try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8)).stakeConsent)
    }
}
