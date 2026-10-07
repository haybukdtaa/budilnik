import Foundation
import SwiftUI

/// Настройки, которые хранятся на телефоне.
struct SettingsData: Codable, Equatable {
    var onboardingDone = false
    var isAdult = false
    var modules: [WakeModule] = [.basic]
    /// Чек-листы по модулям (ключ = WakeModule.rawValue). Нет ключа = чек-лист по умолчанию.
    var checklists: [String: [String]] = [:]
    var prayer = PrayerSettings()
    var sportStepGoal = 1000
    var focusMinutes = 25
    /// Главная задача дня (ключ = дата «гггг-мм-дд»).
    var mainTasks: [String: String] = [:]
    var useDemoSocial = false
    var unlockedRewards: [String] = []
    var privacy = PrivacySettings()
    var profile = UserProfile.newLocal()
    /// Когда я «будил» друзей (ключ = id друга), для лимита в сутки.
    var nudges: [String: [Date]] = [:]
    var blockedUsers: [UUID] = []
    /// Вид каждого дерева (ключ — номер дерева). Нет ключа — вид ещё не выбран.
    var treeSpecies: [String: TreeSpecies] = [:]
    /// Друзья-свидетели: получают сообщение, если я проспал (без сумм).
    var witnesses: [UUID] = []
    /// «Зачем я встаю» — своя фраза. Видна только мне.
    var wakeReason = ""

    init() {}

    // Каждое поле читается отдельно: новые поля в будущих версиях не сбросят старые настройки.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = SettingsData()
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? base.onboardingDone
        isAdult = try c.decodeIfPresent(Bool.self, forKey: .isAdult) ?? base.isAdult
        modules = try c.decodeIfPresent([WakeModule].self, forKey: .modules) ?? base.modules
        checklists = try c.decodeIfPresent([String: [String]].self, forKey: .checklists) ?? base.checklists
        prayer = try c.decodeIfPresent(PrayerSettings.self, forKey: .prayer) ?? base.prayer
        sportStepGoal = try c.decodeIfPresent(Int.self, forKey: .sportStepGoal) ?? base.sportStepGoal
        focusMinutes = try c.decodeIfPresent(Int.self, forKey: .focusMinutes) ?? base.focusMinutes
        mainTasks = try c.decodeIfPresent([String: String].self, forKey: .mainTasks) ?? base.mainTasks
        useDemoSocial = try c.decodeIfPresent(Bool.self, forKey: .useDemoSocial) ?? base.useDemoSocial
        unlockedRewards = try c.decodeIfPresent([String].self, forKey: .unlockedRewards) ?? base.unlockedRewards
        privacy = try c.decodeIfPresent(PrivacySettings.self, forKey: .privacy) ?? base.privacy
        profile = try c.decodeIfPresent(UserProfile.self, forKey: .profile) ?? base.profile
        nudges = try c.decodeIfPresent([String: [Date]].self, forKey: .nudges) ?? base.nudges
        blockedUsers = try c.decodeIfPresent([UUID].self, forKey: .blockedUsers) ?? base.blockedUsers
        treeSpecies = try c.decodeIfPresent([String: TreeSpecies].self, forKey: .treeSpecies) ?? base.treeSpecies
        witnesses = try c.decodeIfPresent([UUID].self, forKey: .witnesses) ?? base.witnesses
        wakeReason = try c.decodeIfPresent(String.self, forKey: .wakeReason) ?? base.wakeReason
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var data: SettingsData {
        didSet {
            guard data != oldValue else { return }
            file.save(data)
            // При перезагрузке с диска побочные действия не нужны: они бы сработали на старых данных.
            guard !suppressSideEffects else { return }
            if oldValue.privacy.syncPrayerData && !data.privacy.syncPrayerData {
                SyncEngine.shared.purgeSensitive()
            }
            if data.prayer != oldValue.prayer {
                AlarmStore.shared.refreshDatedAlarms(force: true)
            }
            if data.privacy != oldValue.privacy {
                SyncEngine.shared.enqueue(.privacy, id: data.profile.id, value: data.privacy)
                SocialStore.shared.publishStatus()
            }
            if data.profile != oldValue.profile {
                SyncEngine.shared.enqueue(.profile, id: data.profile.id, value: data.profile)
            }
        }
    }

    private let file = FileStore<SettingsData>("settings")
    private var suppressSideEffects = false
    private var loadFailed = false

    private init() {
        let result = file.loadWithState()
        data = result.value ?? SettingsData()
        loadFailed = result.state == .unreadable
    }

    /// Перечитывает настройки с диска без побочных действий.
    func reload() {
        let result = file.loadWithState()
        suppressSideEffects = true
        data = result.value ?? SettingsData()
        suppressSideEffects = false
        loadFailed = result.state == .unreadable
    }

    /// Если при запуске файл был закрыт (телефон ещё не разблокировали), перечитывает его.
    func reloadIfNeeded() {
        guard loadFailed else { return }
        reload()
    }

    var scheduleContext: ScheduleContext { ScheduleContext(prayer: data.prayer) }

    func isEnabled(_ module: WakeModule) -> Bool { data.modules.contains(module) }

    func setModule(_ module: WakeModule, enabled: Bool) {
        if enabled {
            if !data.modules.contains(module) { data.modules.append(module) }
        } else {
            data.modules.removeAll { $0 == module }
            if data.modules.isEmpty { data.modules = [.basic] }
        }
    }

    func checklist(for module: WakeModule) -> [String] {
        data.checklists[module.rawValue] ?? module.defaultChecklist
    }

    func setChecklist(_ items: [String], for module: WakeModule) {
        data.checklists[module.rawValue] = items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func mainTask(for date: Date) -> String { data.mainTasks[AppSettings.dayKey(date)] ?? "" }

    func setMainTask(_ text: String, for date: Date) {
        data.mainTasks[AppSettings.dayKey(date)] = text
        // Старше 30 дней не храним.
        let cutoff = AppSettings.dayKey(date.addingTimeInterval(-30 * 86400))
        data.mainTasks = data.mainTasks.filter { $0.key >= cutoff }
    }

    func isBlocked(_ id: UUID) -> Bool { data.blockedUsers.contains(id) }

    /// Вид дерева с этим номером, если выбран.
    func species(forTree index: Int) -> TreeSpecies? { data.treeSpecies[String(index)] }

    /// Выбирает вид для дерева. Выбор окончательный, пока дерево не вырастет.
    func chooseSpecies(_ species: TreeSpecies, forTree index: Int) {
        guard data.treeSpecies[String(index)] == nil else { return }
        data.treeSpecies[String(index)] = species
    }

    func isWitness(_ id: UUID) -> Bool { data.witnesses.contains(id) }

    func setWitness(_ id: UUID, _ isOn: Bool) {
        if isOn {
            if !data.witnesses.contains(id) { data.witnesses.append(id) }
        } else {
            data.witnesses.removeAll { $0 == id }
        }
    }

    var wakeReason: String? {
        let text = data.wakeReason.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
