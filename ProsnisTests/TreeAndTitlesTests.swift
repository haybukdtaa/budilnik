import XCTest
@testable import Prosnis

final class TreeAndTitlesTests: XCTestCase {
    private func successDays(_ count: Int) -> [JournalEntry] {
        var entries: [JournalEntry] = []
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

    func testSecondGardenTreeAndDates() {
        let snap = snapshot(successDays(200))
        XCTAssertEqual(snap.garden.map(\.index), [0, 1])
        // Первое дерево выросло на сотое утро (1 января + 99 дней), второе — на двухсотое.
        XCTAssertEqual(snap.garden[0].date, T.calendar.date(byAdding: .day, value: 99, to: T.date(2026, 1, 1, 7)))
        XCTAssertEqual(snap.garden[1].date, T.calendar.date(byAdding: .day, value: 199, to: T.date(2026, 1, 1, 7)))
        XCTAssertEqual(snap.tree.index, 2)
    }

    func testNewSeedDoesNotBloom() {
        // 101 утро подряд: серия большая, но новое дерево — только росток.
        let tree = snapshot(successDays(101)).tree
        XCTAssertEqual(tree.stage, 1)
        XCTAssertFalse(tree.flowers, "Ростку цвести рано")
        XCTAssertFalse(tree.fruits)
        XCTAssertTrue(snapshot(successDays(103)).tree.flowers, "Саженец уже цветёт при длинной серии")
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
        XCTAssertTrue(Titles.changed(fromLevel: 3, toLevel: 4))
        XCTAssertFalse(Titles.changed(fromLevel: 9, toLevel: 10), "После девятого уровня звание не меняется")
    }

    private func notify(_ entry: JournalEntry, privacy: PrivacySettings = PrivacySettings(),
                        witnesses: [UUID] = [UUID()], now: Date? = nil, last: String? = nil) -> Bool {
        WitnessPolicy.shouldNotify(entry: entry, privacy: privacy, witnesses: witnesses,
                                   now: now ?? entry.date.addingTimeInterval(600), lastNotifiedDay: last, calendar: T.calendar)
    }

    func testWitnessPolicy() {
        let failed = T.entry(T.date(2026, 10, 6, 7), .failed)
        XCTAssertTrue(notify(failed))
        XCTAssertFalse(notify(failed, witnesses: []))
        XCTAssertFalse(notify(T.entry(T.date(2026, 10, 6, 7), .success)))
        XCTAssertFalse(notify(T.entry(T.date(2026, 10, 6, 7), .technical)), "Сбой — не провал")
        XCTAssertFalse(notify(T.entry(T.date(2026, 10, 6, 7), .failed, isDemo: true)))

        let prayer = T.entry(T.date(2026, 10, 6, 4), .failed, isPrayer: true)
        XCTAssertFalse(notify(prayer), "Проспанный Фаджр без согласия не сообщается")
        var consent = PrivacySettings()
        consent.sharePrayer = true
        XCTAssertTrue(notify(prayer, privacy: consent))
    }

    func testWitnessNotifiedOncePerMorningAndOnlyFresh() {
        let first = T.entry(T.date(2026, 10, 6, 7), .failed)
        let day = WitnessPolicy.dayKey(first.date, calendar: T.calendar)
        XCTAssertEqual(day, "2026-10-06")
        XCTAssertFalse(notify(T.entry(T.date(2026, 10, 6, 8), .failed), last: day),
                       "Второй проспанный будильник того же утра — без второго сообщения")
        XCTAssertTrue(notify(T.entry(T.date(2026, 10, 7, 7), .failed), last: day), "Следующее утро — новое сообщение")
        XCTAssertFalse(notify(first, now: T.date(2026, 10, 13, 12)),
                       "Через неделю без открытия приложения старые утра свидетелям не отправляются")
    }

    func testNoticeHasNoMoneyOrTime() {
        let notice = MissedMorningNotice(day: "2026-10-06", witnesses: [])
        let labels = Mirror(reflecting: notice).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), ["day", "witnesses"])
        let json = String(data: try! JSONEncoder().encode(notice), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"2026-10-06\""), "День уходит строкой, без времени и пояса: \(json)")
    }

    func testUnknownTreeSpeciesDoesNotBreakStatus() throws {
        let json = #"{"day": 0, "treeStage": 3, "treeSpecies": "baobab", "streak": 5}"#
        let status = try JSONDecoder().decode(PublicStatus.self, from: Data(json.utf8))
        XCTAssertNil(status.treeSpecies)
        XCTAssertEqual(status.treeStage, 3)
        XCTAssertEqual(status.streak, 5)
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
