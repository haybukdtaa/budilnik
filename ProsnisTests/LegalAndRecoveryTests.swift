import XCTest
@testable import Prosnis

final class LegalAndRecoveryTests: XCTestCase {
    // MARK: Почта

    func testEmailNormalization() {
        XCTAssertEqual(EmailAddress.normalize("  Test@Example.RU "), "test@example.ru")
        XCTAssertNil(EmailAddress.normalize("no-at-sign"))
        XCTAssertNil(EmailAddress.normalize("a@b"))
        XCTAssertNil(EmailAddress.normalize("a b@c.ru"))
        XCTAssertNil(EmailAddress.normalize("@c.ru"))
        XCTAssertNil(EmailAddress.normalize("a@c..ru"))
        XCTAssertNil(EmailAddress.normalize("a@@c.ru"))
    }

    func testEmailCodeIsSixDigits() {
        XCTAssertEqual(EmailAddress.normalizeCode("123 456"), "123456")
        XCTAssertNil(EmailAddress.normalizeCode("12345"))
        XCTAssertNil(EmailAddress.normalizeCode("1234567"))
        XCTAssertNil(EmailAddress.normalizeCode("١٢٣٤٥٦"), "Цифры не из латиницы сервер не примет")
    }

    // MARK: Согласия

    private func entry(_ granted: Bool, version: Int = LegalVersion.current) -> ConsentEntry {
        ConsentEntry(version: version, date: Date(), granted: granted, textHash: nil)
    }

    func testConsentMustMatchCurrentVersion() {
        XCTAssertFalse(ConsentRules.isGranted(.terms, in: [:]))
        XCTAssertTrue(ConsentRules.isGranted(.terms, in: ["terms": entry(true)]))
        XCTAssertFalse(ConsentRules.isGranted(.terms, in: ["terms": entry(false)]))
        XCTAssertFalse(ConsentRules.isGranted(.terms, in: ["terms": entry(true, version: LegalVersion.current - 1)]),
                       "Согласие на старую редакцию не действует")
    }

    func testServerNeedsBothRequiredConsents() {
        XCTAssertFalse(ConsentRules.serverAllowed([:]))
        XCTAssertFalse(ConsentRules.serverAllowed(["terms": entry(true)]))
        XCTAssertFalse(ConsentRules.serverAllowed(["personalData": entry(true)]))
        XCTAssertTrue(ConsentRules.serverAllowed(["terms": entry(true), "personalData": entry(true)]))
        XCTAssertFalse(ConsentRules.serverAllowed(["terms": entry(true), "personalData": entry(false)]),
                       "Отозванное согласие закрывает сервер")
    }

    func testPromptOnlyForNewVersionNotForRefusal() {
        XCTAssertTrue(ConsentRules.needsPrompt([:]))
        XCTAssertFalse(ConsentRules.needsPrompt(["terms": entry(false)]), "Отказ тоже ответ: не донимаем")
        XCTAssertTrue(ConsentRules.needsPrompt(["terms": entry(true, version: LegalVersion.current - 1)]))
    }

    func testOptionalConsentsAreNotRequiredForServer() {
        XCTAssertEqual(Set(ConsentKind.allCases.filter(\.requiredForServer)), [.terms, .personalData])
    }

    func testEveryDocumentHasText() {
        for kind in LegalDocumentKind.allCases {
            let document = LegalTexts.document(kind)
            XCTAssertFalse(document.sections.isEmpty, kind.title)
            XCTAssertFalse(document.plainText.isEmpty)
        }
        for kind in ConsentKind.allCases {
            if let document = kind.document { XCTAssertEqual(LegalTexts.document(document).kind, document) }
        }
        XCTAssertEqual(ConsentRules.hash("a"), ConsentRules.hash("a"))
        XCTAssertNotEqual(ConsentRules.hash("a"), ConsentRules.hash("b"))
    }

    func testChoiceSubscript() {
        var choice = ConsentChoice()
        for kind in ConsentKind.allCases { XCTAssertFalse(choice[kind], "Ничего не отмечено заранее") }
        choice[.marketing] = true
        XCTAssertTrue(choice.marketing)
    }

    func testSettingsWithoutConsentFieldsStillDecode() throws {
        let data = Data("{\"onboardingDone\":true}".utf8)
        let decoded = try JSONDecoder().decode(SettingsData.self, from: data)
        XCTAssertTrue(decoded.onboardingDone)
        XCTAssertTrue(decoded.consents.isEmpty)
        XCTAssertNil(decoded.recoveryEmail)
    }

    // MARK: Чтение списков по одной записи

    func testLossyListKeepsReadableItems() throws {
        var first = AlarmItem(); first.hour = 6
        var second = AlarmItem(); second.hour = 8
        let encoded = try JSONEncoder().encode([first, second])
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        objects[1]["id"] = 12345 // испорченная запись
        let broken = try JSONSerialization.data(withJSONObject: objects)

        XCTAssertNil(try? JSONDecoder().decode([AlarmItem].self, from: broken), "Обычное чтение споткнулось бы")
        let salvaged = try XCTUnwrap([AlarmItem].lossyDecode(broken))
        XCTAssertEqual(salvaged.count, 1)
        XCTAssertEqual(salvaged.first?.hour, 6)
    }

    func testLossyListRefusesWhenNothingReadable() throws {
        let data = Data("[{\"nonsense\":1},{\"nonsense\":2}]".utf8)
        XCTAssertNil([AlarmItem].lossyDecode(data), "Другой формат — не «пустой список»")
    }

    func testLossyEmptyListIsEmptyList() throws {
        XCTAssertEqual([AlarmItem].lossyDecode(Data("[]".utf8))?.count, 0)
    }

    // MARK: Копии файлов

    func testBackupNameParsing() throws {
        let name = "zztest.corrupt-1700000000.json"
        let url = AppFiles.documents.appendingPathComponent(name)
        try Data("[]".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let found = AppFiles.corruptBackups().first { $0.base == "zztest" }
        XCTAssertEqual(found?.date, Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: Выгрузка

    func testJSONValueRoundTrip() throws {
        let text = "{\"a\":[1,true,null,\"x\"],\"b\":{\"c\":2.5}}"
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(value, again)
    }
}
