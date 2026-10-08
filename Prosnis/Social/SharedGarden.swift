import Foundation

/// Участник общего сада. Видно только, полил ли он сегодня и сколько раз поливал всего — без времени и денег.
struct GardenMember: Codable, Identifiable, Equatable {
    var profile: UserProfile
    var wateredToday: Bool
    var waterings: Int
    var isOwner: Bool

    var id: UUID { profile.id }
}

/// Общий сад 3–5 друзей: одно дерево, которое поливает каждое успешное утро участников.
/// Если кто-то проспал, дерево не вянет — просто в этот день растёт меньше.
struct SharedGarden: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var species: TreeSpecies
    var inviteCode: String
    var members: [GardenMember]
    /// Сколько всего поливов (плюс бонус за дни, когда полили все).
    var growth: Int
    var createdAt: Date

    static let maxMembers = 5
    /// Сколько поливов нужно для каждой стадии дерева.
    static let thresholds = [0, 3, 10, 25, 50, 100, 180, 300]

    var stage: Int { SharedGarden.stage(forGrowth: growth) }
    var wateredToday: Int { members.filter(\.wateredToday).count }

    /// Сколько поливов до следующей стадии (nil — дерево выросло полностью).
    var toNextStage: Int? {
        let next = stage + 1
        return next < SharedGarden.thresholds.count ? SharedGarden.thresholds[next] - growth : nil
    }

    static func stage(forGrowth growth: Int) -> Int {
        max(0, thresholds.lastIndex { growth >= $0 } ?? 0)
    }

    /// Рост за один полив: +1, и ещё +1, если этим поливом сад сегодня полили все участники.
    static func growthForWatering(wateredBefore: Int, members: Int) -> Int {
        wateredBefore + 1 == members && members > 1 ? 2 : 1
    }

    init(id: UUID, name: String, species: TreeSpecies, inviteCode: String, members: [GardenMember], growth: Int, createdAt: Date) {
        self.id = id
        self.name = name
        self.species = species
        self.inviteCode = inviteCode
        self.members = members
        self.growth = growth
        self.createdAt = createdAt
    }

    /// Неизвестный вид дерева из новой версии не ломает список садов.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        species = (try? c.decode(TreeSpecies.self, forKey: .species)) ?? .oak
        inviteCode = try c.decode(String.self, forKey: .inviteCode)
        members = try c.decode([GardenMember].self, forKey: .members)
        growth = try c.decode(Int.self, forKey: .growth)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

/// Заявка в друзья по номеру. Дружба начинается, только когда её примут.
struct FriendRequest: Codable, Identifiable, Equatable {
    var id: UUID
    var from: UserProfile
    var sentAt: Date
}

/// Данные аккаунта с сервера для восстановления на новом телефоне.
struct RestoreSnapshot: Codable {
    var alarms: [AlarmItem]?
    var journal: [JournalEntry]?
    var challenges: [Challenge]?
}

struct GardenDraft: Codable, Equatable {
    var name: String
    var species: TreeSpecies
}

/// Когда поливать общие сады: только успешное утро, один раз в день, утро с намазом — только с согласием.
enum GardenPolicy {
    static func shouldWater(entry: JournalEntry, privacy: PrivacySettings, now: Date, lastWateredDay: String?) -> Bool {
        guard entry.counts, entry.outcome == .success else { return false }
        if entry.isPrayer == true && !privacy.sharePrayer { return false }
        guard now.timeIntervalSince(entry.date) < WitnessPolicy.freshness else { return false }
        return WitnessPolicy.dayKey(entry.date) != lastWateredDay
    }
}
