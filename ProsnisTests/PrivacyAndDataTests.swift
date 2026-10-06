import XCTest
@testable import Prosnis

final class PublicStatusTests: XCTestCase {
    private let now = T.date(2026, 10, 6, 12)

    private func snapshot(_ entries: [JournalEntry]) -> ProgressSnapshot {
        ProgressEngine.compute(entries: entries, challenges: [], now: now, calendar: T.calendar)
    }

    func testEverythingHiddenByDefault() {
        let entries = [T.entry(T.date(2026, 10, 6, 7), .success, stake: 500)]
        let status = PublicStatusBuilder.build(entries: entries, snapshot: snapshot(entries), privacy: PrivacySettings(), now: now, calendar: T.calendar)
        XCTAssertNil(status.woke)
        XCTAssertNil(status.wakeTime)
        XCTAssertNil(status.streak)
        XCTAssertNil(status.level)
        XCTAssertNil(status.treeStage)
        XCTAssertNil(status.prayerDone)
    }

    func testPrayerMorningsHiddenWithoutConsent() {
        let entries = [T.entry(T.date(2026, 10, 6, 4), .success, isPrayer: true)]
        var privacy = PrivacySettings()
        privacy.shareWakeStatus = true
        privacy.shareWakeTime = true
        let status = PublicStatusBuilder.build(entries: entries, snapshot: snapshot(entries), privacy: privacy, now: now, calendar: T.calendar)
        XCTAssertNil(status.woke, "Подъём на Фаджр не должен выдаваться без согласия")
        XCTAssertNil(status.wakeTime)

        privacy.sharePrayer = true
        let shared = PublicStatusBuilder.build(entries: entries, snapshot: snapshot(entries), privacy: privacy, now: now, calendar: T.calendar)
        XCTAssertEqual(shared.woke, true)
        XCTAssertEqual(shared.prayerDone, true)
    }

    func testPrayerExcludedFromSharedProgress() {
        let entries = [
            T.entry(T.date(2026, 10, 5, 4), .success, isPrayer: true),
            T.entry(T.date(2026, 10, 6, 7), .success),
        ]
        let shareable = PublicStatusBuilder.shareableEntries(entries, privacy: PrivacySettings())
        XCTAssertEqual(shareable.count, 1)
        let prayerChallenge = Challenge(title: "Фаджр", goal: .prayer, durationDays: 7, startDate: T.date(2026, 10, 1))
        XCTAssertTrue(PublicStatusBuilder.shareableChallenges([prayerChallenge], privacy: PrivacySettings()).isEmpty)
    }

    func testStatusNeverContainsMoney() throws {
        let entries = [T.entry(T.date(2026, 10, 6, 7), .failed, stake: 5000)]
        var privacy = PrivacySettings()
        privacy.shareWakeStatus = true
        privacy.shareWakeTime = true
        privacy.shareStreak = true
        privacy.shareLevel = true
        privacy.shareTree = true
        let status = PublicStatusBuilder.build(entries: entries, snapshot: snapshot(entries), privacy: privacy, now: now, calendar: T.calendar)
        let json = String(data: try JSONEncoder().encode(status), encoding: .utf8)!
        XCTAssertFalse(json.contains("5000"))
        XCTAssertFalse(json.lowercased().contains("stake"))
        XCTAssertEqual(status.woke, false)
    }
}

final class DataCompatibilityTests: XCTestCase {
    func testOldAlarmJSONStillDecodes() throws {
        let json = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","hour":6,"minute":30,"weekdays":[1,2],"label":"Работа",
         "isEnabled":true,"soundID":"siren","wallpaper":{"gradient":{"_0":1}},"stakeEnabled":true,"stakeAmount":700}
        """
        let alarm = try JSONDecoder().decode(AlarmItem.self, from: Data(json.utf8))
        XCTAssertEqual(alarm.hour, 6)
        XCTAssertEqual(alarm.effectiveTask, .typing)
        XCTAssertEqual(alarm.effectiveModule, .basic)
        XCTAssertEqual(alarm.effectiveHolidayMode, .off)
        XCTAssertFalse(alarm.isFajr)
        XCTAssertTrue(alarm.hasTask)
    }

    func testEmptySettingsDecodeToDefaults() throws {
        let settings = try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.onboardingDone)
        XCTAssertEqual(settings.modules, [.basic])
        XCTAssertFalse(settings.privacy.shareWakeStatus)
        XCTAssertEqual(settings.prayer.method, .dumRF)
    }

    func testSettingsRoundTrip() throws {
        var settings = SettingsData()
        settings.modules = [.basic, .prayer]
        settings.prayer.cityID = "kazan"
        settings.privacy.joinLeaderboards = true
        let decoded = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }
}

final class MiscLogicTests: XCTestCase {
    func testContentFilterMasksAndTrims() {
        XCTAssertEqual(ContentFilter.clean("  привет  "), "привет")
        XCTAssertFalse(ContentFilter.clean("ну ты сука").contains("сука"))
        XCTAssertEqual(ContentFilter.clean(String(repeating: "а", count: 2000)).count, ContentFilter.maxLength)
        XCTAssertFalse(ContentFilter.isSendable("   "))
    }

    func testOutboxDeduplicatesAndCaps() {
        let id = UUID()
        let first = OutboxItem(kind: .alarm, entityID: id, payload: Data("1".utf8), deleted: false, createdAt: Date())
        let second = OutboxItem(kind: .alarm, entityID: id, payload: Data("2".utf8), deleted: false, createdAt: Date())
        let merged = SyncEngine.merged(SyncEngine.merged([], adding: first), adding: second)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.payload, Data("2".utf8))

        var many: [OutboxItem] = []
        for _ in 0..<(SyncEngine.maxItems + 5) {
            many = SyncEngine.merged(many, adding: OutboxItem(kind: .journalEntry, entityID: UUID(), payload: Data(), deleted: false, createdAt: Date()))
        }
        XCTAssertEqual(many.count, SyncEngine.maxItems)
    }

    func testSensitiveItemsArePurged() {
        let normal = OutboxItem(kind: .alarm, entityID: UUID(), payload: Data(), deleted: false, createdAt: Date())
        let prayer = OutboxItem(kind: .journalEntry, entityID: UUID(), payload: Data(), deleted: false, createdAt: Date(), isSensitive: true)
        XCTAssertEqual(SyncEngine.withoutSensitive([normal, prayer]), [normal])
    }

    func testServerDatesWithAndWithoutFractions() {
        XCTAssertNotNil(HTTPBackend.parseDate("2026-10-06T04:00:00Z"))
        XCTAssertNotNil(HTTPBackend.parseDate("2026-10-06T04:00:00.123Z"))
        XCTAssertNil(HTTPBackend.parseDate("06.10.2026"))
    }

    func testSyncPayloadUsesISODates() throws {
        let data = try SyncEngine.makeEncoder().encode(T.entry(T.date(2026, 10, 6, 7), .success))
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("2026-10-06T04:00:00Z"), json)
    }

    func testStakeAdvisor() {
        let fails = (1...7).map { T.entry(T.date(2026, 9, $0, 7), $0 % 2 == 0 ? .success : .failed) }
        let hint = StakeAdvisor.hint(entries: fails, current: 500)
        XCTAssertEqual(hint?.suggested, 750)
        let good = (1...7).map { T.entry(T.date(2026, 9, $0, 7), .success) }
        XCTAssertNil(StakeAdvisor.hint(entries: good, current: 500)?.suggested)
        XCTAssertNil(StakeAdvisor.hint(entries: Array(good.prefix(3)), current: 500))
    }

    func testTaskGenerators() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let problem = MathProblem.random(using: &generator)
            XCTAssertEqual(problem.answer, problem.a * problem.b + problem.c)
            let sequence = MemorySequence.make(length: 5, using: &generator)
            XCTAssertEqual(sequence.count, 5)
            XCTAssertTrue(sequence.allSatisfy { (0..<MemorySequence.gridSize).contains($0) })
            for index in 1..<sequence.count {
                XCTAssertNotEqual(sequence[index], sequence[index - 1])
            }
        }
    }

    func testSentenceBankHasNoInnerPeriods() {
        for sentence in SentenceBank.all {
            XCTAssertFalse(sentence.contains("."), sentence)
            XCTAssertGreaterThan(sentence.count, 50, sentence)
        }
    }
}
