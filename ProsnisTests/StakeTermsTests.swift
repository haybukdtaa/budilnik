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
