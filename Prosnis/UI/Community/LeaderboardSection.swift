import SwiftUI

struct LeaderboardSection: View {
    @EnvironmentObject private var social: SocialStore
    @EnvironmentObject private var settings: AppSettings
    @State private var kind: LeaderboardKind = .weekRegularity

    var body: some View {
        List {
            Section {
                Picker("Таблица", selection: $kind) {
                    ForEach(LeaderboardKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(kind.detail).font(.app(.footnote)).foregroundStyle(.secondary)
            }

            if !settings.data.privacy.joinLeaderboards {
                Section {
                    Text("Вы не участвуете в таблицах. Ваше имя и результаты никто не видит.")
                    Button("Участвовать") { settings.data.privacy.joinLeaderboards = true }
                }
            }

            if let board = social.leaderboards[kind] {
                if let record = board.record {
                    Section("Рекорд") {
                        HStack(spacing: 12) {
                            Image(systemName: "crown.fill").foregroundStyle(.yellow)
                            AvatarView(profile: record.profile, size: 34)
                            VStack(alignment: .leading) {
                                Text(record.profile.displayName).font(.app(.headline))
                                Text("Держится с \(Format.dateTime(record.since))").font(.app(.caption)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(record.value)").font(.app(.title3, weight: .bold))
                        }
                    }
                }
                Section("Лучшие") {
                    ForEach(board.rows) { row in
                        HStack(spacing: 12) {
                            Text("\(row.rank)").font(.app(.headline)).frame(width: 30)
                            AvatarView(profile: row.profile, size: 32)
                            Text(row.profile.displayName + (row.profile.id == settings.data.profile.id ? " (вы)" : ""))
                                .fontWeight(row.profile.id == settings.data.profile.id ? .bold : .regular)
                            Spacer()
                            Text(row.valueText).monospacedDigit()
                        }
                        .listRowBackground(row.profile.id == settings.data.profile.id ? Theme.accent.opacity(0.18) : Theme.card)
                    }
                }
            } else if social.errorText != nil {
                Section {
                    Button("Повторить загрузку") { Task { await social.loadLeaderboard(kind) } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .scrollContentBackground(.hidden)
        .task(id: "\(kind.rawValue)-\(settings.data.privacy.joinLeaderboards)") { await social.loadLeaderboard(kind) }
    }
}

struct RegionSection: View {
    var body: some View {
        List {
            if AppConfig.regionCommunities.isEmpty {
                Section {
                    Text("Сообщества регионов появятся позже")
                        .font(.app(.headline))
                    Text("Здесь будут ссылки на модерируемые группы для своего региона. Общий чат с незнакомыми людьми мы сознательно не делаем внутри приложения: он требует постоянной модерации и отдельных обязательств по закону.")
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(AppConfig.regionCommunities) { link in
                    Link(destination: link.url) {
                        VStack(alignment: .leading) {
                            Text(link.title).font(.app(.headline))
                            Text(link.region).font(.app(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}
