import Foundation

/// Собирает статус для друзей строго по настройкам приватности.
/// Денег в статусе нет по устройству типа; утра, связанные с намазом, без согласия не учитываются вовсе,
/// чтобы ранний подъём не выдавал религиозную практику.
enum PublicStatusBuilder {
    static func build(
        entries: [JournalEntry],
        snapshot: ProgressSnapshot,
        privacy: PrivacySettings,
        now: Date,
        calendar: Calendar = .current
    ) -> PublicStatus {
        let todays = entries.filter { $0.counts && calendar.isDate($0.date, inSameDayAs: now) }
        let visible = privacy.sharePrayer ? todays : todays.filter { $0.isPrayer != true }

        var status = PublicStatus(day: calendar.startOfDay(for: now))
        if privacy.shareWakeStatus, !visible.isEmpty {
            status.woke = visible.contains { $0.outcome == .success }
        }
        if privacy.shareWakeTime {
            status.wakeTime = visible.filter { $0.outcome == .success }.map(\.date).min()
        }
        if privacy.shareStreak { status.streak = snapshot.currentStreak }
        if privacy.shareLevel { status.level = snapshot.level }
        if privacy.shareTree { status.treeStage = snapshot.tree.stage }
        if privacy.sharePrayer {
            let prayer = todays.filter { $0.isPrayer == true }
            if !prayer.isEmpty { status.prayerDone = prayer.contains { $0.outcome == .success } }
        }
        return status
    }
}
