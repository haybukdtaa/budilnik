import XCTest
@testable import Prosnis

final class TreeAndTitlesTests: XCTestCase {
    private func successDays(_ count: Int, failFirst: Bool = false) -> [JournalEntry] {
        var entries: [JournalEntry] = []
        if failFirst {
            entries.append(T.entry(T.date(2025, 12, 31, 7), .failed))
        }
        for offset in 0..<count {
            let day = T.calendar.date(byAdding: .day, value: offset, to: T.date(2026, 1, 1, 7))!
            entries.append(T.entry(day, .success))
        }
        return entries
    }

    private func snapshot(_ entries: [JournalEntry]) -> ProgressSnapshot {
        ProgressEngine.compute(entries: entries, challenges: [], now: T.date(2026, 12, 31), calendar: T.calendar)
    }

    func testTreeMovesToGardenAfterCycle() {
        let grown = snapshot(successDays(100))
        XCTAssertEqual(grown.garden.count, 1)
        XCTAssertEqual(grown.garden.first?.index, 0)
        XCTAssertEqual(grown.tree.index, 1, "После 100 утр растёт второе дерево")
        XCTAssertEqual(grown.tree.progress, 0)
        XCTAssertEqual(grown.tree.stage, 0)

        let next = snapshot(successDays(107))
        XCTAssertEqual(next.garden.count, 1)
        XCTAssertEqual(next.tree.progress, 7)
        XCTAssertEqual(next.tree.stage, 3)
    }

    func testLastStageBeforeGarden() {
        let tree = snapshot(successDays(90)).tree
        XCTAssertEqual(tree.stage, 7)
        XCTAssertTrue(tree.isLastStage)
        XCTAssertEqual(tree.wakesToNext, 10, "До сада остаётся 10 утр")
    }

    func testFlowersAndFruitsFollowStreak() {
        XCTAssertFalse(snapshot(successDays(6)).tree.flowers)
        let week = snapshot(successDays(7)).tree
        XCTAssertTrue(week.flowers)
        XCTAssertFalse(week.fruits)
        let month = snapshot(successDays(30)).tree
        XCTAssertTrue(month.flowers)
        XCTAssertTrue(month.fruits)
    }

    func testFailureRemovesFlowersAndWilts() {
        var entries = successDays(10)
        XCTAssertTrue(snapshot(entries).tree.flowers)
        entries.append(T.entry(T.date(2026, 1, 11, 7), .failed))
        let tree = snapshot(entries).tree
        XCTAssertFalse(tree.flowers, "После провала цветы пропадают")
        XCTAssertEqual(tree.wilt, 1, "Провал в последних 7 утрах — дерево слегка увяло")
        entries.append(contentsOf: (12...18).map { T.entry(T.date(2026, 1, $0, 7), .success) })
        let recovered = snapshot(entries).tree
        XCTAssertEqual(recovered.wilt, 0, "Неделя подъёмов возвращает цвет")
        XCTAssertTrue(recovered.flowers)
    }

    func testTitles() {
        XCTAssertEqual(Titles.title(forLevel: 1), "Новичок")
        XCTAssertEqual(Titles.title(forLevel: 4), "Жаворонок")
        XCTAssertEqual(Titles.title(forLevel: 9), "Легенда рассвета")
        XCTAssertEqual(Titles.title(forLevel: 40), "Легенда рассвета")
        XCTAssertEqual(Titles.title(forLevel: 0), "Новичок")
        XCTAssertNil(Titles.nextTitleLevel(after: Titles.names.count))
        XCTAssertEqual(snapshot([]).title, "Новичок")
    }

    func testWitnessPolicy() {
        let witness = [UUID()]
        let failed = T.entry(T.date(2026, 10, 6, 7), .failed)
        XCTAssertTrue(WitnessPolicy.shouldNotify(entry: failed, privacy: PrivacySettings(), witnesses: witness))
        XCTAssertFalse(WitnessPolicy.shouldNotify(entry: failed, privacy: PrivacySettings(), witnesses: []))
        XCTAssertFalse(WitnessPolicy.shouldNotify(entry: T.entry(T.date(2026, 10, 6, 7), .success),
                                                  privacy: PrivacySettings(), witnesses: witness))
        XCTAssertFalse(WitnessPolicy.shouldNotify(entry: T.entry(T.date(2026, 10, 6, 7), .technical),
                                                  privacy: PrivacySettings(), witnesses: witness), "Сбой — не провал")
        XCTAssertFalse(WitnessPolicy.shouldNotify(entry: T.entry(T.date(2026, 10, 6, 7), .failed, isDemo: true),
                                                  privacy: PrivacySettings(), witnesses: witness))

        let prayer = T.entry(T.date(2026, 10, 6, 4), .failed, isPrayer: true)
        XCTAssertFalse(WitnessPolicy.shouldNotify(entry: prayer, privacy: PrivacySettings(), witnesses: witness),
                       "Проспанный Фаджр без согласия не сообщается")
        var consent = PrivacySettings()
        consent.sharePrayer = true
        XCTAssertTrue(WitnessPolicy.shouldNotify(entry: prayer, privacy: consent, witnesses: witness))
    }

    func testNoticeHasNoMoneyOrTime() {
        let labels = Mirror(reflecting: MissedMorningNotice(day: Date(), witnesses: [])).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), ["day", "witnesses"])
    }

    func testTreeSpeciesSharedOnlyWithTreeConsent() {
        let entries = successDays(3)
        let snap = snapshot(entries)
        let hidden = PublicStatusBuilder.build(entries: entries, snapshot: snap, privacy: PrivacySettings(),
                                               now: T.date(2026, 1, 3, 12), species: .sakura, calendar: T.calendar)
        XCTAssertNil(hidden.treeSpecies)
        var privacy = PrivacySettings()
        privacy.shareTree = true
        let shown = PublicStatusBuilder.build(entries: entries, snapshot: snap, privacy: privacy,
                                              now: T.date(2026, 1, 3, 12), species: .sakura, calendar: T.calendar)
        XCTAssertEqual(shown.treeSpecies, .sakura)
        XCTAssertEqual(shown.treeStage, snap.tree.stage)
    }

    func testNewSettingsFieldsDecodeAndRoundTrip() throws {
        let empty = try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.treeSpecies.isEmpty)
        XCTAssertTrue(empty.witnesses.isEmpty)
        XCTAssertEqual(empty.wakeReason, "")

        var settings = SettingsData()
        settings.treeSpecies = ["0": .pine, "1": .sakura]
        settings.witnesses = [UUID()]
        settings.wakeReason = "Утро только для меня"
        let decoded = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }
}
