import XCTest
@testable import Prosnis

final class NewFeaturesTests: XCTestCase {
    private func success(_ date: Date, module: WakeModule, stake: Int = 0, rechecked: Bool? = nil) -> JournalEntry {
        var entry = T.entry(date, .success, stake: stake)
        entry.module = module
        entry.rechecked = rechecked
        return entry
    }

    // MARK: Истории

    func testStoriesUnlockOneChapterPerSuccessfulMorningOfThatModule() {
        let day = T.date(2026, 10, 5, 6, 0)
        var entries = [success(day, module: .prayer), success(day.addingTimeInterval(86400), module: .prayer)]
        entries.append(success(day, module: .sport))
        entries.append(T.entry(day.addingTimeInterval(2 * 86400), .failed))
        XCTAssertEqual(StoryLibrary.unlockedCount(module: .prayer, entries: entries), 2)
        XCTAssertEqual(StoryLibrary.unlockedCount(module: .sport, entries: entries), 1)
        XCTAssertEqual(StoryLibrary.unlockedCount(module: .study, entries: entries), 0)
        XCTAssertEqual(StoryLibrary.chapterOpened(module: .prayer, entries: entries), 1, "Второе утро открыло вторую главу")
        XCTAssertNil(StoryLibrary.chapterOpened(module: .study, entries: entries))
    }

    func testStoriesStopAfterLastChapterAndDemoDoesNotCount() {
        let day = T.date(2026, 10, 5, 6, 0)
        let count = StoryLibrary.series(for: .work).chapters.count
        var entries = (0...count).map { success(day.addingTimeInterval(Double($0) * 86400), module: .work) }
        XCTAssertNil(StoryLibrary.chapterOpened(module: .work, entries: entries), "Серия прочитана — новой главы нет")
        XCTAssertEqual(StoryLibrary.unlockedCount(module: .work, entries: entries), count)
        entries = [success(day, module: .basic)]
        entries[0].isDemo = true
        XCTAssertEqual(StoryLibrary.unlockedCount(module: .basic, entries: entries), 0)
    }

    func testEverySeriesHasChaptersWithText() {
        for module in WakeModule.allCases {
            let series = StoryLibrary.series(for: module)
            XCTAssertEqual(series.module, module)
            XCTAssertGreaterThanOrEqual(series.chapters.count, 7)
            XCTAssertEqual(Set(series.chapters.map(\.title)).count, series.chapters.count, "Названия глав не повторяются")
            for chapter in series.chapters {
                XCTAssertGreaterThan(chapter.text.count, 400, "\(chapter.title): глава на пару минут чтения")
            }
        }
        XCTAssertEqual(StoryLibrary.series(for: .prayer).title, "Праведные халифы")
    }

    // MARK: Выигранные часы и итоги недели

    func testHoursWonCountsOnlyEarlierSuccessfulMorningsOncePerDay() {
        let calendar = T.calendar
        let usual = 8 * 60 + 30
        let monday = T.date(2026, 10, 5, 6, 30)
        let entries = [
            T.entry(monday, .success),                                  // +2 ч
            T.entry(monday.addingTimeInterval(1800), .success),         // то же утро позже — не суммируется
            T.entry(T.date(2026, 10, 6, 9, 0), .success),               // позже обычного — 0
            T.entry(T.date(2026, 10, 7, 7, 30), .failed),               // провал — 0
            T.entry(T.date(2026, 10, 8, 8, 0), .success),               // +30 мин
        ]
        let total = HoursWon.total(entries: entries, usualWakeMinutes: usual,
                                   from: T.date(2026, 10, 1), to: T.date(2026, 11, 1), calendar: calendar)
        XCTAssertEqual(total, 150)
        XCTAssertEqual(HoursWon.text(minutes: 150), "2 ч 30 мин")
        XCTAssertTrue(HoursWon.equivalents(minutes: 150).contains("1 фильм"))
        XCTAssertTrue(HoursWon.equivalents(minutes: 30).isEmpty)
        XCTAssertEqual(HoursWon.plural(21, "полив", "полива", "поливов"), "полив")
        XCTAssertEqual(HoursWon.plural(12, "полив", "полива", "поливов"), "поливов")
        XCTAssertEqual(HoursWon.plural(3, "полив", "полива", "поливов"), "полива")
    }

    func testWeeklySummary() {
        let calendar = T.calendar
        let now = T.date(2026, 10, 11, 20, 0) // воскресенье
        let entries = [
            success(T.date(2026, 10, 5, 6, 0), module: .basic, stake: 500, rechecked: true),
            success(T.date(2026, 10, 6, 6, 0), module: .basic, rechecked: false),
            T.entry(T.date(2026, 10, 7, 6, 0), .failed, stake: 300),
            success(T.date(2026, 9, 30, 6, 0), module: .basic), // прошлая неделя
        ]
        let summary = WeeklySummary.compute(entries: entries, now: now, usualWakeMinutes: 7 * 60, calendar: calendar)
        XCTAssertEqual(summary.weekStart, T.date(2026, 10, 5), "Неделя с понедельника")
        XCTAssertEqual(summary.mornings, 3)
        XCTAssertEqual(summary.successes, 2)
        XCTAssertEqual(summary.failures, 1)
        XCTAssertEqual(summary.rechecked, 1, "Утро без повторной проверки видно отдельно")
        XCTAssertEqual(summary.saved, 500)
        XCTAssertEqual(summary.minutesWon, 120)
        XCTAssertEqual(summary.previousSuccesses, 1)
        XCTAssertTrue(summary.isBetterThanPrevious)
    }

    // MARK: Повторная проверка

    func testRecheckRequiredWithStakeOptionalWithout() {
        var alarm = AlarmItem()
        alarm.taskEnabled = true
        XCTAssertFalse(alarm.wantsRecheck, "Без ставки по умолчанию повторной проверки нет")
        alarm.recheckEnabled = true
        XCTAssertTrue(alarm.wantsRecheck)
        alarm.recheckEnabled = false
        alarm.stakeEnabled = true
        XCTAssertTrue(alarm.wantsRecheck, "Со ставкой она обязательна")
    }

    func testOldSessionsKeepRecheck() {
        // Сессия старой версии без поля: проверка была всегда.
        var session = WakeSession(
            alarmID: UUID(), alarmTitle: "", timeText: "", stake: 0, wallpaper: .gradient(0), soundID: "",
            startDate: Date(), stage: 1, phase: .task, ringDate: Date(), sentence: "", events: []
        )
        XCTAssertTrue(session.needsRecheck)
        session.withRecheck = false
        XCTAssertFalse(session.needsRecheck)
    }

    // MARK: Общий сад

    func testGardenGrowthAndStages() {
        XCTAssertEqual(SharedGarden.growthForWatering(wateredBefore: 0, members: 3), 1)
        XCTAssertEqual(SharedGarden.growthForWatering(wateredBefore: 2, members: 3), 2, "Последний полил — бонус за дружное утро")
        XCTAssertEqual(SharedGarden.growthForWatering(wateredBefore: 0, members: 1), 1, "Один в саду — без бонуса")
        XCTAssertEqual(SharedGarden.stage(forGrowth: 0), 0)
        XCTAssertEqual(SharedGarden.stage(forGrowth: 10), 2)
        XCTAssertEqual(SharedGarden.stage(forGrowth: 1000), 7)
    }

    func testGardenPolicy() {
        let now = Date()
        var privacy = PrivacySettings()
        let entry = T.entry(now.addingTimeInterval(-600), .success)
        XCTAssertTrue(GardenPolicy.shouldWater(entry: entry, privacy: privacy, now: now, lastWateredDay: nil))
        XCTAssertFalse(GardenPolicy.shouldWater(entry: entry, privacy: privacy, now: now,
                                                lastWateredDay: WitnessPolicy.dayKey(entry.date)), "Один полив в день")
        XCTAssertFalse(GardenPolicy.shouldWater(entry: T.entry(now, .failed), privacy: privacy, now: now, lastWateredDay: nil))
        let prayer = T.entry(now, .success, isPrayer: true)
        XCTAssertFalse(GardenPolicy.shouldWater(entry: prayer, privacy: privacy, now: now, lastWateredDay: nil),
                       "Утро с намазом без согласия не выдаём даже поливом")
        privacy.sharePrayer = true
        XCTAssertTrue(GardenPolicy.shouldWater(entry: prayer, privacy: privacy, now: now, lastWateredDay: nil))
    }

    func testGardenDecodesUnknownSpecies() throws {
        let json = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Сад","species":"baobab","inviteCode":"ABCDEF","members":[],"growth":4,"createdAt":0}"#.utf8)
        let garden = try JSONDecoder().decode(SharedGarden.self, from: json)
        XCTAssertEqual(garden.species, .oak)
        XCTAssertEqual(garden.toNextStage, 6)
    }

    // MARK: Свой голос

    @MainActor
    func testVoiceSoundFallsBackWhenFileMissing() {
        let missing = VoiceLibrary.soundID(for: UUID())
        XCTAssertTrue(VoiceLibrary.isVoice(missing))
        XCTAssertEqual(SoundLibrary.option(missing).id, SoundLibrary.defaultID, "Нет файла — звонит классический сигнал")
        XCTAssertEqual(SoundLibrary.option("siren").fileName, "siren.wav")
        XCTAssertEqual(SoundOption(id: missing, title: "", category: nil, isVoice: true).fileName, missing + ".caf")
    }
}
