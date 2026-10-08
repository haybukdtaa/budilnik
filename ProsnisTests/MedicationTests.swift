import XCTest
@testable import Prosnis

final class MedicationTests: XCTestCase {
    private let calendar = T.calendar

    private func med(times: [Int] = [9 * 60, 21 * 60], start: Date, end: Date? = nil) -> Medication {
        var med = Medication(name: "Тест", dose: "1 таблетка", form: .tablet, times: times)
        med.startDate = start
        med.endDate = end
        return med
    }

    func testDosesFollowTimesAndCourse() {
        let start = T.date(2026, 10, 5, 8, 0)
        let course = med(start: start, end: T.date(2026, 10, 7))
        let doses = MedSchedule.doses(for: course, from: T.date(2026, 10, 1), to: T.date(2026, 10, 20), calendar: calendar)
        XCTAssertEqual(doses.count, 6, "3 дня курса по 2 приёма")
        XCTAssertEqual(doses.first?.scheduled, T.date(2026, 10, 5, 9, 0))
        XCTAssertEqual(doses.last?.scheduled, T.date(2026, 10, 7, 21, 0), "Последний день курса включён")
    }

    func testFirstDayDoesNotIncludeTimesBeforeAdding() {
        let added = T.date(2026, 10, 5, 12, 0)
        let doses = MedSchedule.doses(for: med(start: added), from: T.date(2026, 10, 5), to: T.date(2026, 10, 6), calendar: calendar)
        XCTAssertEqual(doses.map(\.scheduled), [T.date(2026, 10, 5, 21, 0)], "Утренний приём до добавления лекарства не считается")
    }

    func testAfterWakeUsesWakeTimeOrFallback() {
        var morning = med(times: [], start: T.date(2026, 10, 5))
        morning.afterWakeMinutes = 30
        morning.afterWakeFallback = 9 * 60
        let woke = T.date(2026, 10, 5, 6, 40)
        let wakes = [calendar.startOfDay(for: woke): woke]
        let doses = MedSchedule.doses(for: morning, from: T.date(2026, 10, 5), to: T.date(2026, 10, 7), wakeTimes: wakes, calendar: calendar)
        XCTAssertEqual(doses.map(\.scheduled), [T.date(2026, 10, 5, 7, 10), T.date(2026, 10, 6, 9, 0)],
                       "Встал в 6:40 — приём в 7:10; на следующий день будильника нет — в 9:00")
        XCTAssertEqual(morning.dosesPerDay, 1)
    }

    func testTakenAfterWakeDoseStaysWhereItWasMarked() {
        var morning = med(times: [], start: T.date(2026, 10, 5))
        morning.afterWakeMinutes = 30
        morning.afterWakeFallback = 9 * 60
        // В 9:00 (будильника ещё не было) приём отметили; будильник в 10:00 не должен создать второй приём.
        let marked = DoseRecord(medicationID: morning.id, scheduled: T.date(2026, 10, 5, 9, 0), status: .taken, at: T.date(2026, 10, 5, 9, 0))
        let woke = T.date(2026, 10, 5, 10, 0)
        let doses = MedSchedule.doses(for: morning, from: T.date(2026, 10, 5), to: T.date(2026, 10, 6),
                                      wakeTimes: [calendar.startOfDay(for: woke): woke], records: [marked], calendar: calendar)
        XCTAssertEqual(doses.map(\.scheduled), [T.date(2026, 10, 5, 9, 0)])
    }

    func testScheduleChangeKeepsPastDays() {
        var changed = med(times: [10 * 60], start: T.date(2026, 10, 1))
        changed.history = [ScheduleVersion(times: [9 * 60], afterWakeMinutes: nil, afterWakeFallback: 540, until: T.date(2026, 10, 3, 15, 0))]
        let doses = MedSchedule.doses(for: changed, from: T.date(2026, 10, 1), to: T.date(2026, 10, 5), calendar: calendar)
        XCTAssertEqual(doses.map(\.scheduled), [
            T.date(2026, 10, 1, 9, 0), T.date(2026, 10, 2, 9, 0),
            T.date(2026, 10, 3, 10, 0), T.date(2026, 10, 4, 10, 0),
        ], "До дня смены — прежнее время, с него — новое")
    }

    func testStateTakenSkippedMissedDue() {
        let dose = Dose(medicationID: UUID(), scheduled: T.date(2026, 10, 5, 9, 0))
        XCTAssertEqual(MedSchedule.state(of: dose, records: [], now: T.date(2026, 10, 5, 7, 0)), .upcoming)
        XCTAssertEqual(MedSchedule.state(of: dose, records: [], now: T.date(2026, 10, 5, 8, 45)), .due)
        XCTAssertEqual(MedSchedule.state(of: dose, records: [], now: T.date(2026, 10, 5, 10, 0)), .due, "Час после — ещё можно отметить")
        XCTAssertEqual(MedSchedule.state(of: dose, records: [], now: T.date(2026, 10, 5, 11, 30)), .missed)
        let takenAt = T.date(2026, 10, 5, 9, 5)
        let taken = DoseRecord(medicationID: dose.medicationID, scheduled: dose.scheduled, status: .taken, at: takenAt)
        XCTAssertEqual(MedSchedule.state(of: dose, records: [taken], now: T.date(2026, 10, 5, 12, 0)), .taken(takenAt))
        let skipped = DoseRecord(medicationID: dose.medicationID, scheduled: dose.scheduled, status: .skipped, at: takenAt)
        XCTAssertEqual(MedSchedule.state(of: dose, records: [skipped], now: T.date(2026, 10, 5, 12, 0)), .skipped)
    }

    func testStockAndRefill() {
        var med = self.med(start: Date())
        XCTAssertNil(med.daysLeft)
        XCTAssertFalse(med.needsRefill)
        med.stock = 20
        med.unitsPerDose = 2
        XCTAssertEqual(med.daysLeft, 5, "20 штук, 2 приёма по 2 — на 5 дней")
        XCTAssertTrue(med.needsRefill)
        med.stock = 30
        XCTAssertFalse(med.needsRefill)
    }

    func testCourseCompletedAndCleanWeek() {
        let course = med(times: [9 * 60], start: T.date(2026, 10, 1), end: T.date(2026, 10, 3))
        let doses = MedSchedule.doses(for: course, from: course.startDate, to: T.date(2026, 10, 4), calendar: calendar)
        let all = doses.map { DoseRecord(medicationID: course.id, scheduled: $0.scheduled, status: .taken, at: $0.scheduled) }
        XCTAssertFalse(MedSchedule.courseCompleted(course, records: all, now: T.date(2026, 10, 3, 22, 0), calendar: calendar), "Курс ещё идёт")
        XCTAssertTrue(MedSchedule.courseCompleted(course, records: all, now: T.date(2026, 10, 5), calendar: calendar))
        XCTAssertFalse(MedSchedule.courseCompleted(course, records: Array(all.dropLast()), now: T.date(2026, 10, 5), calendar: calendar))

        let daily = med(times: [9 * 60], start: T.date(2026, 9, 1))
        let week = MedSchedule.doses(for: daily, from: T.date(2026, 10, 1), to: T.date(2026, 10, 8), calendar: calendar)
        let taken = week.map { DoseRecord(medicationID: daily.id, scheduled: $0.scheduled, status: .taken, at: $0.scheduled) }
        XCTAssertTrue(MedSchedule.cleanWeek(daily, records: taken, now: T.date(2026, 10, 8, 10, 0), calendar: calendar))
        XCTAssertFalse(MedSchedule.cleanWeek(daily, records: Array(taken.dropFirst()), now: T.date(2026, 10, 8, 10, 0), calendar: calendar))
    }

    func testReminderHidesNameByDefault() {
        var med = self.med(start: Date())
        med.name = "Амоксициллин"
        med.meal = .after
        XCTAssertFalse(MedSchedule.reminderBody(med, showName: false).contains("Амоксициллин"), "На экране блокировки без названия")
        XCTAssertEqual(MedSchedule.reminderBody(med, showName: true), "Амоксициллин · 1 таблетка · после еды")
    }

    func testMedicationDecodesWithDefaults() throws {
        let json = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Магний","dose":"","form":"tablet","times":[1260],"afterWakeFallback":540,"meal":"any","startDate":0,"unitsPerDose":1,"loud":false}"#.utf8)
        let med = try JSONDecoder().decode(Medication.self, from: json)
        XCTAssertEqual(med.times, [21 * 60])
        XCTAssertNil(med.endDate)
        XCTAssertNil(med.stock)
    }
}
