import Foundation

/// Публичный профиль человека. Никаких денег и ставок здесь нет и быть не должно.
struct UserProfile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var displayName: String
    var avatar: String

    static func newLocal() -> UserProfile {
        UserProfile(id: UUID(), displayName: "Я", avatar: "🌅")
    }
}

/// Что человек вообще разрешает показывать друзьям. Всё выключено по умолчанию.
struct PrivacySettings: Codable, Equatable {
    var shareWakeStatus = false
    var shareWakeTime = false
    var shareStreak = false
    var shareLevel = false
    var shareTree = false
    /// Подъём на Фаджр. Особая категория данных: только по отдельному согласию.
    var sharePrayer = false
    var joinLeaderboards = false
    /// Отправлять на сервер будильники и утра, связанные с намазом.
    var syncPrayerData = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shareWakeStatus = try c.decodeIfPresent(Bool.self, forKey: .shareWakeStatus) ?? false
        shareWakeTime = try c.decodeIfPresent(Bool.self, forKey: .shareWakeTime) ?? false
        shareStreak = try c.decodeIfPresent(Bool.self, forKey: .shareStreak) ?? false
        shareLevel = try c.decodeIfPresent(Bool.self, forKey: .shareLevel) ?? false
        shareTree = try c.decodeIfPresent(Bool.self, forKey: .shareTree) ?? false
        sharePrayer = try c.decodeIfPresent(Bool.self, forKey: .sharePrayer) ?? false
        joinLeaderboards = try c.decodeIfPresent(Bool.self, forKey: .joinLeaderboards) ?? false
        syncPrayerData = try c.decodeIfPresent(Bool.self, forKey: .syncPrayerData) ?? false
    }
}

/// Что видит конкретный друг. Работает только в пределах общих настроек приватности.
struct Visibility: Codable, Equatable {
    var wakeStatus = true
    var wakeTime = false
    var streak = true
    var level = true
    var tree = true
    var prayer = false
}

/// Статус за день, который уходит друзьям. Только то, что разрешено; поля денег отсутствуют намеренно.
struct PublicStatus: Codable, Equatable {
    var day: Date
    var woke: Bool?
    var wakeTime: Date?
    var streak: Int?
    var level: Int?
    var treeStage: Int?
    var treeSpecies: TreeSpecies?
    var prayerDone: Bool?
}

struct Friend: Codable, Identifiable, Equatable {
    var profile: UserProfile
    var since: Date
    var status: PublicStatus?
    /// Что я показываю этому другу.
    var myVisibility: Visibility

    var id: UUID { profile.id }
}

struct Invite: Codable, Equatable {
    var code: String
    var expiresAt: Date
}

struct RoomMember: Codable, Identifiable, Equatable {
    var profile: UserProfile
    var status: PublicStatus?
    var isOwner: Bool

    var id: UUID { profile.id }
}

/// Общая комната друзей или клуб по интересам.
struct Room: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var isClub: Bool
    var topic: String?
    var rules: String?
    /// Общая цель: подъём не позже этого времени (минуты от полуночи).
    var targetWakeMinutes: Int?
    var inviteCode: String
    var members: [RoomMember]
    var createdAt: Date

    static let maxMembers = 30
}

struct RoomDraft: Codable, Equatable {
    var name: String
    var isClub: Bool
    var topic: String?
    var rules: String?
    var targetWakeMinutes: Int?
}

enum ConversationKind: String, Codable {
    case friend, room
}

struct ConversationID: Codable, Hashable {
    var kind: ConversationKind
    var id: UUID
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id: UUID
    var conversation: ConversationID
    var author: UserProfile
    var text: String
    var sentAt: Date
}

enum LeaderboardKind: String, Codable, CaseIterable, Identifiable {
    case weekRegularity, allTimeStreak, allTimeWakes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekRegularity: return "Неделя"
        case .allTimeStreak: return "Рекорд серии"
        case .allTimeWakes: return "Всего подъёмов"
        }
    }

    var detail: String {
        switch self {
        case .weekRegularity: return "Сколько будильников этой недели закончились подъёмом"
        case .allTimeStreak: return "Самая длинная серия подъёмов за всё время. Рекорд держится, пока его не побьют"
        case .allTimeWakes: return "Сколько раз человек встал с заданием за всё время"
        }
    }
}

struct LeaderboardRow: Codable, Identifiable, Equatable {
    var rank: Int
    var profile: UserProfile
    var value: Int
    var valueText: String

    var id: UUID { profile.id }
}

struct RecordHolder: Codable, Equatable {
    var profile: UserProfile
    var value: Int
    var since: Date
}

struct Leaderboard: Codable, Equatable {
    var kind: LeaderboardKind
    var rows: [LeaderboardRow]
    var me: LeaderboardRow?
    var record: RecordHolder?
}

struct GlobalStats: Codable, Equatable {
    var wokeToday: Int
    var activeChallenges: Int
}

/// Награда за приглашённого друга. Открывается, когда друг встанет 7 раз.
struct InviteReward: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var unlocked: Bool
}

/// Сообщение свидетелям о проспанном утре. Только день «гггг-мм-дд»: ни времени, ни сумм.
struct MissedMorningNotice: Codable, Equatable {
    var day: String
    var witnesses: [UUID]
}

/// Друг, у которого я свидетель, проспал.
struct WitnessNotice: Codable, Identifiable, Equatable {
    var id: UUID
    var friend: UserProfile
    var day: String
}

extension PublicStatus {
    /// Неизвестный вид дерева (из более новой версии приложения) не должен ломать весь список друзей.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(Date.self, forKey: .day)
        woke = try c.decodeIfPresent(Bool.self, forKey: .woke)
        wakeTime = try c.decodeIfPresent(Date.self, forKey: .wakeTime)
        streak = try c.decodeIfPresent(Int.self, forKey: .streak)
        level = try c.decodeIfPresent(Int.self, forKey: .level)
        treeStage = try c.decodeIfPresent(Int.self, forKey: .treeStage)
        treeSpecies = (try? c.decodeIfPresent(TreeSpecies.self, forKey: .treeSpecies)) ?? nil
        prayerDone = try c.decodeIfPresent(Bool.self, forKey: .prayerDone)
    }
}

/// Ссылка на сообщество региона (группа в Telegram и т. п.).
struct CommunityLink: Identifiable, Equatable {
    var id: String { url.absoluteString }
    var title: String
    var region: String
    var url: URL
}
