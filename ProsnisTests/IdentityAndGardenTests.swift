import simd
import XCTest
@testable import Prosnis

final class IdentityAndGardenTests: XCTestCase {
    // MARK: Код восстановления

    func testWordListHas256UniqueWordsWithoutYo() {
        XCTAssertEqual(RecoveryPhrase.words.count, 256)
        XCTAssertEqual(Set(RecoveryPhrase.words).count, 256, "Слова не повторяются")
        XCTAssertFalse(RecoveryPhrase.words.contains { $0.contains("ё") }, "Без «ё»: её часто пишут как «е»")
        XCTAssertFalse(RecoveryPhrase.words.contains { $0.contains(" ") })
    }

    func testGeneratedPhraseParsesBackAndGivesSameIdentity() {
        let phrase = RecoveryPhrase.generate()
        XCTAssertEqual(phrase.count, RecoveryPhrase.wordCount)
        XCTAssertEqual(RecoveryPhrase.wordCount, 16, "128 бит: 16 слов по 8 бит")
        let typed = phrase.joined(separator: ",  ").uppercased()
        XCTAssertEqual(RecoveryPhrase.parse(typed), phrase, "Регистр, запятые и пробелы не важны")
        let first = RecoveryPhrase.identity(for: phrase)
        let second = RecoveryPhrase.identity(for: phrase)
        XCTAssertEqual(first.userID, second.userID)
        XCTAssertEqual(first.secret, second.secret)
        XCTAssertNotEqual(RecoveryPhrase.identity(for: phrase.reversed()).userID, first.userID, "Порядок слов важен")
    }

    func testParseRejectsWrongCodes() {
        XCTAssertNil(RecoveryPhrase.parse("дом лес сад"))
        let almost = Array(RecoveryPhrase.words.prefix(RecoveryPhrase.wordCount - 1)).joined(separator: " ")
        XCTAssertNil(RecoveryPhrase.parse(almost + " абракадабра"))
        XCTAssertNil(RecoveryPhrase.parse(almost), "Не хватает слова")
        XCTAssertNotNil(RecoveryPhrase.parse(Array(RecoveryPhrase.words.prefix(RecoveryPhrase.wordCount)).joined(separator: " ")))
    }

    // MARK: Номер для друзей

    func testFriendNumberFormat() {
        XCTAssertEqual(FriendNumber.normalize("482913075"), "PRO-482-913-075")
        XCTAssertEqual(FriendNumber.normalize("pro 482-913 075"), "PRO-482-913-075")
        XCTAssertNil(FriendNumber.normalize("PRO-482-913"))
        XCTAssertNil(FriendNumber.normalize("4829130751"))
        let id = UUID()
        XCTAssertEqual(FriendNumber.demo(for: id), FriendNumber.demo(for: id))
        XCTAssertNotNil(FriendNumber.normalize(FriendNumber.demo(for: id)))
    }

    // MARK: Слова с числами

    func testWords() {
        XCTAssertEqual(Words.wakes(1), "1 подъём")
        XCTAssertEqual(Words.wakes(4), "4 подъёма")
        XCTAssertEqual(Words.wakes(11), "11 подъёмов")
        XCTAssertEqual(Words.days(21), "21 день")
        XCTAssertEqual(Words.days(5), "5 дней")
    }

    // MARK: 3D-сад

    func testGardenLayoutKeepsTreesApartAndOnGround() {
        let count = 40
        let positions = (0..<count).map(GardenLayout.position(forGrown:))
        let radius = GardenLayout.groundRadius(grownCount: count)
        for (i, a) in positions.enumerated() {
            XCTAssertGreaterThan(simd_length(a), 1.5, "Выросшие деревья не заслоняют растущее в центре")
            XCTAssertLessThan(simd_length(a), radius - 1, "Дерево стоит на земле, а не у края")
            for b in positions[(i + 1)...] {
                XCTAssertGreaterThan(simd_distance(a, b), 0.9, "Кроны не врастают друг в друга")
            }
        }
        XCTAssertEqual(GardenLayout.preview.filter(\.isCurrent).count, 1)
    }

    func testDaytime() {
        XCTAssertEqual(GardenDaytime.at(hour: 6), .dawn)
        XCTAssertEqual(GardenDaytime.at(hour: 12), .day)
        XCTAssertEqual(GardenDaytime.at(hour: 19), .evening)
        XCTAssertEqual(GardenDaytime.at(hour: 23), .night)
        XCTAssertEqual(GardenDaytime.at(hour: 2), .night)
    }

    func testSeededRandomIsStable() {
        var a = SeededRandom(seed: 7)
        var b = SeededRandom(seed: 7)
        let first = (0..<5).map { _ in a.next() }
        XCTAssertEqual(first, (0..<5).map { _ in b.next() })
        XCTAssertTrue(first.allSatisfy { $0 >= 0 && $0 < 1 })
    }
}
