import XCTest
@testable import Prosnis

final class MissedMorningsTests: XCTestCase {
    private let ring = Date(timeIntervalSince1970: 1_791_255_600)

    func testSingleRingIsDueOnce() {
        let candidates = [RingCandidate(at: ring, day: "2026-10-08")]
        let due = MissedMornings.due(candidates: candidates, after: ring.addingTimeInterval(-3600), until: ring.addingTimeInterval(600)) { _ in false }
        XCTAssertEqual(due, [[ring]])
        XCTAssertTrue(MissedMornings.due(candidates: candidates, after: ring.addingTimeInterval(-3600),
                                         until: ring.addingTimeInterval(600)) { _ in true }.isEmpty, "Есть запись — не списываем")
    }

    func testTimeZoneChangeKeepsMorningAndChargesOnce() {
        // Ожидалось при постановке (старый пояс) и посчитано по новому поясу: один и тот же день.
        let old = RingCandidate(at: ring, day: "2026-10-08")
        let shifted = RingCandidate(at: ring.addingTimeInterval(7 * 3600), day: "2026-10-08")
        let candidates = MissedMornings.merged([old], [shifted])
        // Прошло только старое время: ждём нового — человек мог встать по нему.
        XCTAssertTrue(MissedMornings.due(candidates: candidates, after: ring.addingTimeInterval(-60),
                                         until: ring.addingTimeInterval(600)) { _ in false }.isEmpty)
        // Прошли оба и записей нет: одно утро — одно списание.
        let due = MissedMornings.due(candidates: candidates, after: ring.addingTimeInterval(600),
                                     until: shifted.at.addingTimeInterval(600)) { _ in false }
        XCTAssertEqual(due, [[shifted.at]])
        // Встал по новому времени — утро закрыто.
        XCTAssertTrue(MissedMornings.due(candidates: candidates, after: ring.addingTimeInterval(600),
                                         until: shifted.at.addingTimeInterval(600)) { $0 == shifted.at }.isEmpty)
        // Перевод часов вперёд: новое время раньше проверенного, старое — нет. Утро не теряется.
        let earlier = RingCandidate(at: ring.addingTimeInterval(-3 * 3600), day: "2026-10-08")
        let forward = MissedMornings.merged([old], [earlier])
        XCTAssertEqual(MissedMornings.due(candidates: forward, after: ring.addingTimeInterval(-3600),
                                          until: ring.addingTimeInterval(600)) { _ in false }, [[ring]])
    }

    func testMergeDropsDuplicatesWithinMinute() {
        let merged = MissedMornings.merged([RingCandidate(at: ring, day: "a")], [RingCandidate(at: ring.addingTimeInterval(30), day: "a")])
        XCTAssertEqual(merged.count, 1)
    }

    func testUnresolvedMorning() {
        let candidates = [RingCandidate(at: ring, day: "d"), RingCandidate(at: ring.addingTimeInterval(5 * 3600), day: "d")]
        XCTAssertTrue(MissedMornings.hasUnresolved(candidates: candidates, now: ring.addingTimeInterval(3600)) { _ in false })
        XCTAssertFalse(MissedMornings.hasUnresolved(candidates: candidates, now: ring.addingTimeInterval(3600)) { $0 == ring })
        XCTAssertFalse(MissedMornings.hasUnresolved(candidates: candidates, now: ring.addingTimeInterval(-60)) { _ in false })
    }

    func testDayLabelUsesGivenCalendar() {
        var moscow = Calendar(identifier: .gregorian)
        moscow.timeZone = TimeZone(identifier: "Europe/Moscow")!
        var honolulu = Calendar(identifier: .gregorian)
        honolulu.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        // 2026-10-08 07:00 по Москве — ещё 7 октября на Гавайях.
        let date = Date(timeIntervalSince1970: 1_791_432_000)
        XCTAssertEqual(MissedMornings.dayLabel(date, calendar: moscow), "2026-10-08")
        XCTAssertEqual(MissedMornings.dayLabel(date, calendar: honolulu), "2026-10-07")
    }

    func testQueuedMatchesSpecificRing() {
        let alarm = UUID()
        let rings = [alarm.uuidString: ring]
        XCTAssertTrue(WakeRules.isQueued(alarmID: alarm, ring: ring, queue: [alarm], rings: rings))
        XCTAssertFalse(WakeRules.isQueued(alarmID: alarm, ring: ring.addingTimeInterval(86400), queue: [alarm], rings: rings),
                       "Другой звонок того же будильника не в очереди")
        XCTAssertFalse(WakeRules.isQueued(alarmID: alarm, ring: ring, queue: [], rings: rings))
        XCTAssertTrue(WakeRules.isQueued(alarmID: alarm, ring: ring, queue: [alarm], rings: nil))
    }

    func testEvidenceSurvivesOverflowAndGoesFirst() {
        let event = OutboxItem(kind: .wakeEvent, entityID: UUID(), payload: Data(), deleted: false, createdAt: Date())
        var items = [event]
        for _ in 0..<(SyncEngine.maxItems + 5) {
            items = SyncEngine.merged(items, adding: OutboxItem(kind: .journalEntry, entityID: UUID(), payload: Data(), deleted: false, createdAt: Date()))
        }
        XCTAssertEqual(items.count, SyncEngine.maxItems)
        XCTAssertTrue(items.contains(event), "Событие утра — доказательство, при переполнении не выбрасывается")
        XCTAssertEqual(SyncEngine.batch(Array(items.reversed()), limit: 3).first, event, "События утра уходят первыми")
    }
}
