import Foundation

/// Демо-сервер на телефоне: показывает, как будут работать друзья, комнаты, чаты и таблицы.
/// Все люди в нём вымышленные. Включается в Профиле, по умолчанию выключен.
@MainActor
final class DemoBackend: SocialBackend, SyncBackend {
    static let shared = DemoBackend()

    var isOnline: Bool { true }
    var isDemo: Bool { true }

    private struct State: Codable {
        var friends: [Friend]
        var rooms: [Room]
        var messages: [String: [ChatMessage]]
        var pairs: [PairChallenge]
        var myStatus: PublicStatus?
        /// Общие сады (nil у демо-данных старых версий).
        var gardens: [SharedGarden]?
        /// День, которым я уже поливал сады.
        var wateredDay: String?
    }

    private var state: State
    private let file = FileStore<State>("demo_social")

    private init() {
        state = file.load() ?? DemoBackend.seed()
    }

    func reload() {
        state = file.load() ?? DemoBackend.seed()
    }

    private func save() { file.save(state) }

    private static func person(_ name: String, _ avatar: String) -> UserProfile {
        UserProfile(id: UUID(), displayName: name, avatar: avatar)
    }

    private static let extraPeople: [(String, String, Int, Int)] = [
        ("Руслан", "🐺", 86, 94), ("Дина", "🌙", 41, 100), ("Артём", "🚴", 23, 71),
        ("Камила", "🌷", 57, 86), ("Илья", "📚", 12, 57), ("Зарина", "🍀", 34, 100),
    ]

    private static func status(woke: Bool?, hour: Int, minute: Int, streak: Int, level: Int, tree: Int) -> PublicStatus {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return PublicStatus(
            day: today,
            woke: woke,
            wakeTime: woke == true ? calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today) : nil,
            streak: streak,
            level: level,
            treeStage: tree,
            treeSpecies: [TreeSpecies.oak, .sakura, .pine, .birch, .maple][tree % 5],
            prayerDone: nil
        )
    }

    private static func seed() -> State {
        let now = Date()
        let aydar = person("Айдар", "🦅")
        let maria = person("Мария", "🌸")
        let timur = person("Тимур", "🏃")
        let olga = person("Ольга", "☕️")
        let ruslan = person("Руслан", "🐺")

        let friends = [
            Friend(profile: aydar, since: now.addingTimeInterval(-40 * 86400),
                   status: status(woke: true, hour: 6, minute: 12, streak: 12, level: 4, tree: 4), myVisibility: Visibility()),
            Friend(profile: maria, since: now.addingTimeInterval(-12 * 86400),
                   status: status(woke: false, hour: 0, minute: 0, streak: 0, level: 2, tree: 2), myVisibility: Visibility()),
            Friend(profile: timur, since: now.addingTimeInterval(-90 * 86400),
                   status: status(woke: true, hour: 5, minute: 40, streak: 31, level: 7, tree: 5), myVisibility: Visibility()),
            Friend(profile: olga, since: now.addingTimeInterval(-3 * 86400), status: nil, myVisibility: Visibility()),
        ]

        let family = Room(
            id: UUID(), name: "Семья", isClub: false, topic: nil, rules: nil, targetWakeMinutes: 7 * 60,
            inviteCode: "FAM7Q2",
            members: [
                RoomMember(profile: maria, status: friends[1].status, isOwner: true),
                RoomMember(profile: aydar, status: friends[0].status, isOwner: false),
            ],
            createdAt: now.addingTimeInterval(-20 * 86400)
        )
        let club = Room(
            id: UUID(), name: "5:00 club", isClub: true, topic: "Подъём в пять утра",
            rules: "Уважаем друг друга. Без рекламы и споров о политике.", targetWakeMinutes: 5 * 60,
            inviteCode: "CLUB55",
            members: [
                RoomMember(profile: timur, status: friends[2].status, isOwner: true),
                RoomMember(profile: ruslan, status: status(woke: true, hour: 4, minute: 58, streak: 86, level: 9, tree: 6), isOwner: false),
            ],
            createdAt: now.addingTimeInterval(-60 * 86400)
        )

        func message(_ room: Room, _ author: UserProfile, _ text: String, _ minutesAgo: Double) -> ChatMessage {
            ChatMessage(id: UUID(), conversation: ConversationID(kind: .room, id: room.id), author: author,
                        text: text, sentAt: now.addingTimeInterval(-minutesAgo * 60))
        }
        let messages: [String: [ChatMessage]] = [
            key(ConversationID(kind: .room, id: family.id)): [
                message(family, maria, "Всем доброе утро! Кто уже встал?", 95),
                message(family, aydar, "Я в 6:12, задание с примерами сегодня было злое", 80),
            ],
            key(ConversationID(kind: .room, id: club.id)): [
                message(club, timur, "31 день подряд. Держимся!", 300),
                message(club, ruslan, "Сегодня в 4:58, дерево уже большое", 290),
            ],
        ]

        let pairs = [
            PairChallenge(title: "Встаём до 7:00", partner: aydar, durationDays: 14,
                          startDate: now.addingTimeInterval(-5 * 86400), myDays: 0, partnerDays: 5, status: .active),
        ]

        return State(friends: friends, rooms: [family, club], messages: messages, pairs: pairs, myStatus: nil, gardens: nil, wateredDay: nil)
    }

    private static func key(_ conversation: ConversationID) -> String {
        "\(conversation.kind.rawValue):\(conversation.id.uuidString)"
    }

    private var me: UserProfile { AppSettings.shared.data.profile }

    private func makeCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    private func validCode(_ code: String) -> String? {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return cleaned.count == 6 ? cleaned : nil
    }

    // MARK: - Друзья

    func friends() async throws -> [Friend] { state.friends }

    func createInvite() async throws -> Invite {
        Invite(code: makeCode(), expiresAt: Date().addingTimeInterval(7 * 86400))
    }

    func acceptInvite(code: String) async throws -> Friend {
        guard validCode(code) != nil else { throw BackendError.invalidCode }
        let friend = Friend(
            profile: DemoBackend.person("Новый друг", "🙂"), since: Date(),
            status: nil, myVisibility: Visibility()
        )
        state.friends.append(friend)
        save()
        return friend
    }

    func removeFriend(_ id: UUID) async throws {
        state.friends.removeAll { $0.id == id }
        save()
    }

    func setVisibility(_ visibility: Visibility, for friend: UUID) async throws {
        guard let index = state.friends.firstIndex(where: { $0.id == friend }) else { throw BackendError.notFound }
        state.friends[index].myVisibility = visibility
        save()
    }

    func nudge(friend: UUID) async throws {
        guard state.friends.contains(where: { $0.id == friend }) else { throw BackendError.notFound }
    }

    // MARK: - Комнаты

    func rooms() async throws -> [Room] { state.rooms }

    func createRoom(_ draft: RoomDraft) async throws -> Room {
        let room = Room(
            id: UUID(), name: draft.name, isClub: draft.isClub, topic: draft.topic, rules: draft.rules,
            targetWakeMinutes: draft.targetWakeMinutes, inviteCode: makeCode(),
            members: [RoomMember(profile: me, status: state.myStatus, isOwner: true)],
            createdAt: Date()
        )
        state.rooms.append(room)
        save()
        return room
    }

    func joinRoom(code: String) async throws -> Room {
        guard let cleaned = validCode(code) else { throw BackendError.invalidCode }
        if let existing = state.rooms.first(where: { $0.inviteCode == cleaned }) { return existing }
        let room = Room(
            id: UUID(), name: "Комната \(cleaned)", isClub: false, topic: nil, rules: nil, targetWakeMinutes: nil,
            inviteCode: cleaned,
            members: [
                RoomMember(profile: DemoBackend.person("Владелец", "🦉"), status: nil, isOwner: true),
                RoomMember(profile: me, status: state.myStatus, isOwner: false),
            ],
            createdAt: Date()
        )
        state.rooms.append(room)
        save()
        return room
    }

    func leaveRoom(_ id: UUID) async throws {
        state.rooms.removeAll { $0.id == id }
        save()
    }

    // MARK: - Чаты

    func messages(in conversation: ConversationID) async throws -> [ChatMessage] {
        state.messages[DemoBackend.key(conversation)] ?? []
    }

    func send(_ text: String, to conversation: ConversationID) async throws -> ChatMessage {
        let message = ChatMessage(
            id: UUID(), conversation: conversation, author: me,
            text: ContentFilter.clean(text), sentAt: Date()
        )
        state.messages[DemoBackend.key(conversation), default: []].append(message)
        save()
        return message
    }

    func report(message: UUID, reason: String) async throws {}
    func block(user: UUID) async throws {}

    // MARK: - Таблицы и статистика

    func leaderboard(_ kind: LeaderboardKind) async throws -> Leaderboard {
        let privacy = AppSettings.shared.data.privacy
        let snapshot = ProgressEngine.compute(
            entries: PublicStatusBuilder.shareableEntries(JournalStore.shared.realEntries, privacy: privacy),
            challenges: PublicStatusBuilder.shareableChallenges(ChallengeStore.shared.challenges, privacy: privacy)
        )
        var people: [(UserProfile, Int)] = state.friends.compactMap { friend in
            guard let status = friend.status else { return nil }
            switch kind {
            case .weekRegularity: return (friend.profile, status.woke == true ? 100 : 71)
            case .allTimeStreak: return (friend.profile, max(status.streak ?? 0, 5) + 40)
            case .allTimeWakes: return (friend.profile, (status.streak ?? 0) * 3 + 20)
            }
        }
        for (name, avatar, streak, regularity) in DemoBackend.extraPeople {
            let value: Int
            switch kind {
            case .weekRegularity: value = regularity
            case .allTimeStreak: value = streak + 100
            case .allTimeWakes: value = streak * 2 + 50
            }
            people.append((UserProfile(id: UUID(), displayName: name, avatar: avatar), value))
        }

        let myValue: Int
        switch kind {
        case .weekRegularity: myValue = Int((snapshot.thisWeek.regularity * 100).rounded())
        case .allTimeStreak: myValue = snapshot.longestStreak
        case .allTimeWakes: myValue = snapshot.totalWakes
        }
        let joined = AppSettings.shared.data.privacy.joinLeaderboards
        if joined { people.append((me, myValue)) }

        func text(_ value: Int) -> String {
            switch kind {
            case .weekRegularity: return "\(value)%"
            case .allTimeStreak: return "\(value) дн."
            case .allTimeWakes: return "\(value)"
            }
        }

        let sorted = people.sorted { $0.1 > $1.1 }
        let rows = sorted.enumerated().map { index, item in
            LeaderboardRow(rank: index + 1, profile: item.0, value: item.1, valueText: text(item.1))
        }
        let mine = joined ? rows.first { $0.profile.id == me.id } : nil
        var record: RecordHolder?
        if kind != .weekRegularity, let top = rows.first {
            record = RecordHolder(profile: top.profile, value: top.value, since: Date().addingTimeInterval(-37 * 86400))
        }
        return Leaderboard(kind: kind, rows: Array(rows.prefix(50)), me: mine, record: record)
    }

    func globalStats() async throws -> GlobalStats {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        return GlobalStats(wokeToday: 12_000 + (day * 37) % 900, activeChallenges: 3_400 + (day * 13) % 300)
    }

    func publishStatus(_ status: PublicStatus) async throws {
        state.myStatus = status
        for roomIndex in state.rooms.indices {
            for memberIndex in state.rooms[roomIndex].members.indices where state.rooms[roomIndex].members[memberIndex].profile.id == me.id {
                state.rooms[roomIndex].members[memberIndex].status = status
            }
        }
        save()
    }

    func inviteRewards() async throws -> [InviteReward] {
        [
            InviteReward(id: "aurora", title: "Фон «Аврора»", detail: "Открыт: приглашённый друг провёл 7 утр", unlocked: true),
            InviteReward(id: "mentor", title: "Значок «Наставник»", detail: "Пригласите трёх друзей, которые проведут по 7 утр", unlocked: false),
        ]
    }

    func pairChallenges() async throws -> [PairChallenge] { state.pairs }

    func createPairChallenge(with friend: UUID, title: String, days: Int) async throws -> PairChallenge {
        guard let partner = state.friends.first(where: { $0.id == friend }) else { throw BackendError.notFound }
        let pair = PairChallenge(title: title, partner: partner.profile, durationDays: days,
                                 startDate: Date(), myDays: 0, partnerDays: 0, status: .active)
        state.pairs.append(pair)
        save()
        return pair
    }

    func deleteAccount() async throws {
        state = DemoBackend.seed()
        file.delete()
    }

    func notifyWitnesses(_ notice: MissedMorningNotice) async throws {
        // Вымышленные друзья: сообщение никуда не уходит.
    }

    // MARK: - Общие сады

    private func demoGardens() -> [SharedGarden] {
        if let gardens = state.gardens { return gardens }
        let people = state.friends.prefix(2).map(\.profile)
        var members = people.enumerated().map { index, profile in
            GardenMember(profile: profile, wateredToday: index == 0, waterings: 24 - index * 6, isOwner: index == 0)
        }
        members.append(GardenMember(profile: me, wateredToday: false, waterings: 0, isOwner: false))
        let garden = SharedGarden(
            id: UUID(), name: "Утренний сад", species: .sakura, inviteCode: "SAD5KQ",
            members: members, growth: 41, createdAt: Date().addingTimeInterval(-30 * 86400)
        )
        state.gardens = [garden]
        save()
        return [garden]
    }

    func gardens() async throws -> [SharedGarden] { demoGardens() }

    func createGarden(_ draft: GardenDraft) async throws -> SharedGarden {
        let garden = SharedGarden(
            id: UUID(), name: draft.name, species: draft.species, inviteCode: makeCode(),
            members: [GardenMember(profile: me, wateredToday: false, waterings: 0, isOwner: true)],
            growth: 0, createdAt: Date()
        )
        state.gardens = demoGardens() + [garden]
        save()
        return garden
    }

    func joinGarden(code: String) async throws -> SharedGarden {
        guard let cleaned = validCode(code) else { throw BackendError.invalidCode }
        var all = demoGardens()
        if let existing = all.first(where: { $0.inviteCode == cleaned }) { return existing }
        let garden = SharedGarden(
            id: UUID(), name: "Сад \(cleaned)", species: .oak, inviteCode: cleaned,
            members: [
                GardenMember(profile: DemoBackend.person("Хозяин сада", "🌳"), wateredToday: true, waterings: 5, isOwner: true),
                GardenMember(profile: me, wateredToday: false, waterings: 0, isOwner: false),
            ],
            growth: 5, createdAt: Date()
        )
        all.append(garden)
        state.gardens = all
        save()
        return garden
    }

    func leaveGarden(_ id: UUID) async throws {
        state.gardens = demoGardens().filter { $0.id != id }
        save()
    }

    func waterGardens(day: String) async throws -> [SharedGarden] {
        var all = demoGardens()
        guard state.wateredDay != day else { return all }
        // Новый день: отметки «полил сегодня» сбрасываются.
        for gardenIndex in all.indices {
            for memberIndex in all[gardenIndex].members.indices {
                all[gardenIndex].members[memberIndex].wateredToday = false
            }
        }
        for gardenIndex in all.indices {
            guard let memberIndex = all[gardenIndex].members.firstIndex(where: { $0.profile.id == me.id }),
                  !all[gardenIndex].members[memberIndex].wateredToday else { continue }
            let before = all[gardenIndex].wateredToday
            all[gardenIndex].growth += SharedGarden.growthForWatering(wateredBefore: before, members: all[gardenIndex].members.count)
            all[gardenIndex].members[memberIndex].wateredToday = true
            all[gardenIndex].members[memberIndex].waterings += 1
        }
        state.gardens = all
        state.wateredDay = day
        save()
        return all
    }

    func witnessNotices() async throws -> [WitnessNotice] {
        // Мария (вымышленная) проспала сегодня, а вы её свидетель.
        guard let maria = state.friends.first(where: { $0.profile.displayName == "Мария" }) else { return [] }
        return [WitnessNotice(id: UUID(), friend: maria.profile, day: WitnessPolicy.dayKey(Date()))]
    }

    /// Демо не принимает очередь: настоящие данные должны дождаться настоящего сервера.
    func push(_ items: [OutboxItem]) async throws -> [UUID] { throw BackendError.serverUnavailable }
    func serverTime() async throws -> Date { Date() }
}
