import XCTest
@testable import Prosnis

final class TrustedClockTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    func testFirstRunTrustsWallClock() {
        let result = TrustedClock.resolve(wall: base, mono: 100, boot: "A", anchor: nil)
        XCTAssertEqual(result.now, base)
        XCTAssertNotNil(result.anchor)
    }

    func testClockSetBackIsDetected() {
        let anchor = TrustedClock.Anchor(wall: base, mono: 100, boot: "A")
        // Прошёл час, а часы телефона перевели на 3 часа назад.
        let wall = base.addingTimeInterval(3600 - 3 * 3600)
        let result = TrustedClock.resolve(wall: wall, mono: 100 + 3600, boot: "A", anchor: anchor)
        XCTAssertEqual(result.now, base.addingTimeInterval(3600))
        XCTAssertNil(result.anchor, "Точка отсчёта не сдвигается на поддельное время")
    }

    func testRebootWithLargerUptimeIsDetected() {
        // Точка записана при малом счётчике, после перезагрузки счётчик уже больше — раньше это не замечалось.
        let anchor = TrustedClock.Anchor(wall: base, mono: 1800, boot: "A")
        let wall = base.addingTimeInterval(2 * 86400)
        let result = TrustedClock.resolve(wall: wall, mono: 5000, boot: "B", anchor: anchor)
        XCTAssertEqual(result.now, wall, "Другая загрузка — верим часам телефона, а не застреваем в прошлом")
        XCTAssertEqual(result.anchor?.boot, "B")
    }

    func testNormalDriftReanchors() {
        let anchor = TrustedClock.Anchor(wall: base, mono: 100, boot: "A")
        let wall = base.addingTimeInterval(600 + 30)
        let result = TrustedClock.resolve(wall: wall, mono: 700, boot: "A", anchor: anchor)
        XCTAssertEqual(result.now, wall)
        XCTAssertNotNil(result.anchor)
    }

    func testOverrideExpires() {
        let anchor = TrustedClock.Anchor(wall: base, mono: 100, boot: "A")
        let elapsed = TrustedClock.maxOverride + 3600
        let wall = base.addingTimeInterval(elapsed - 7200)
        let result = TrustedClock.resolve(wall: wall, mono: 100 + elapsed, boot: "A", anchor: anchor)
        XCTAssertEqual(result.now, wall, "Без новой сверки защищённое время не держится дольше трёх суток")
    }
}

final class ContentFilterWordsTests: XCTestCase {
    func testOrdinaryWordsAreNotMasked() {
        for word in ["рубля", "корабля", "употребляю", "оскорбляет", "сукно", "Нахождение"] {
            XCTAssertEqual(ContentFilter.clean(word), word, word)
        }
    }

    func testRudeWordsAreMasked() {
        for word in ["бля", "Бля!", "нахуй", "сука", "пиздец", "мудак"] {
            XCTAssertFalse(ContentFilter.clean(word).contains(where: { $0.isLetter }), word)
        }
    }
}
