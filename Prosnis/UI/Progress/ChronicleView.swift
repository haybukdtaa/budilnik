import SwiftUI

/// Летопись: рекорды, значки и история всех челленджей.
struct ChronicleView: View {
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var challenges: ChallengeStore

    var body: some View {
        let snapshot = ProgressEngine.compute(entries: journal.realEntries, challenges: challenges.challenges)
        let unlockedIDs = Set(snapshot.unlocked.map(\.id))
        List {
            Section("Рекорды") {
                record("Самая длинная серия", "\(snapshot.longestStreak)")
                record("Всего подъёмов", "\(snapshot.totalWakes)")
                record("Опыт", "\(snapshot.xp)")
                record("Уровень", "\(snapshot.level)")
            }

            Section("Значки") {
                ForEach(ProgressEngine.badges) { badge in
                    let item = snapshot.unlocked.first { $0.id == badge.id }
                    HStack(spacing: 12) {
                        Image(systemName: badge.icon)
                            .font(.app(.title3))
                            .frame(width: 32)
                            .foregroundStyle(unlockedIDs.contains(badge.id) ? Theme.accent : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(badge.title).font(.app(.subheadline).weight(.semibold))
                                if badge.isPrivate {
                                    Image(systemName: "lock.fill").font(.app(.caption2)).foregroundStyle(.secondary)
                                }
                            }
                            Text(badge.detail).font(.app(.caption)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let item {
                            Text(Format.dateTime(item.date)).font(.app(.caption2)).foregroundStyle(.secondary)
                        }
                    }
                    .opacity(item == nil ? 0.5 : 1)
                }
            }

            Section("История челленджей") {
                if challenges.finished.isEmpty {
                    Text("Завершённых челленджей пока нет.").foregroundStyle(.secondary)
                } else {
                    ForEach(challenges.finished) { challenge in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(challenge.title).font(.app(.subheadline).weight(.semibold))
                            Text("\(challenge.status.title) · с \(Format.dateTime(challenge.startDate))" +
                                 (challenge.endedAt.map { " по \(Format.dateTime($0))" } ?? ""))
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Летопись")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func record(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).bold()
        }
    }
}
