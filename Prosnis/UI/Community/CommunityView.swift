import SwiftUI

/// Вкладка «Сообщество».
struct CommunityView: View {
    @EnvironmentObject private var social: SocialStore
    @EnvironmentObject private var settings: AppSettings

    enum Part: String, CaseIterable, Identifiable {
        case friends = "Друзья"
        case garden = "Сад"
        case rooms = "Комнаты"
        case leaderboards = "Таблицы"
        case region = "Регион"
        var id: String { rawValue }
    }

    @State private var section: Part = .friends

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Раздел", selection: $section) {
                    ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if section == .region {
                    RegionSection()
                } else if !social.isAvailable {
                    OfflineBanner()
                } else {
                    switch section {
                    case .friends: FriendsSection()
                    case .garden: SharedGardenSection()
                    case .rooms: RoomsSection()
                    case .leaderboards: LeaderboardSection()
                    case .region: EmptyView()
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("Сообщество")
            .toolbar {
                if social.isDemo {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("ДЕМО")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
            }
            .task(id: settings.data.useDemoSocial) { await social.refresh() }
            .alert(
                "Сообщество",
                isPresented: Binding(get: { social.errorText != nil }, set: { if !$0 { social.errorText = nil } })
            ) {
                Button("Понятно", role: .cancel) {}
            } message: {
                Text(social.errorText ?? "")
            }
        }
    }
}

struct OfflineBanner: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "person.3.sequence.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.accent)
                Text("Друзья, комнаты и таблицы заработают, когда подключим сервер")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text("Приложение уже готово к нему. Чтобы посмотреть, как это будет выглядеть, включите демо-режим: в нём вымышленные люди, а ваши настоящие данные никуда не уходят.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Включить демо-режим") {
                    settings.data.useDemoSocial = true
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
    }
}

struct StatsCard: View {
    let stats: GlobalStats

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sunrise.fill").font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading) {
                Text("Сегодня встали \(stats.wokeToday.formatted()) человек").font(.subheadline.weight(.semibold))
                Text("Идёт челленджей: \(stats.activeChallenges.formatted())").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Аватар-эмодзи в кружке.
struct AvatarView: View {
    let profile: UserProfile
    var size: CGFloat = 40

    var body: some View {
        Text(profile.avatar)
            .font(.system(size: size * 0.55))
            .frame(width: size, height: size)
            .background(Theme.card, in: Circle())
    }
}

/// Краткий статус человека за сегодня.
struct StatusLine: View {
    let status: PublicStatus?

    var body: some View {
        if let status, Calendar.current.isDateInToday(status.day) {
            HStack(spacing: 8) {
                if let woke = status.woke {
                    Label(woke ? (status.wakeTime.map { "встал \(Format.time($0))" } ?? "встал") : "ещё не встал",
                          systemImage: woke ? "checkmark.circle.fill" : "moon.zzz.fill")
                        .foregroundStyle(woke ? Color.green : Color.orange)
                }
                if let streak = status.streak {
                    Label("\(streak)", systemImage: "flame.fill").foregroundStyle(Theme.accent)
                }
                if let level = status.level {
                    Text(Titles.title(forLevel: level)).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        } else {
            Text("Статус скрыт или ещё не обновлялся")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
