import Foundation
import UserNotifications
import Security
import SwiftUI
import UIKit

/// Аккаунт: токен сервера и удаление всех данных.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    private static let tokenKey = "auth.token"
    private static let secretKey = "auth.secret"
    private static let phraseKey = "auth.phrase.v2"
    /// Номер аккаунта, выведенный из кода (чтобы не считать PBKDF2 при каждом запуске).
    private static let userIDKey = "auth.userid.v2"

    @Published private(set) var token: String?
    /// Почему не удалось войти на сервер (показывается в Профиле).
    @Published private(set) var signInProblem: String?

    private init() {
        token = Keychain.get(AccountStore.tokenKey)
    }

    var isSignedIn: Bool { token != nil }

    // MARK: Почта и согласия

    /// Можно ли сейчас обращаться к серверу, и если нет — что сказать человеку.
    private func serverForAccount() -> (backend: HTTPBackend?, problem: String?) {
        guard let url = AppConfig.serverURL else {
            return (nil, "Сервер ещё не подключён: эта возможность заработает вместе с ним.")
        }
        guard ConsentRules.serverAllowed(AppSettings.shared.data.consents) else {
            return (nil, "Нужны согласия: Профиль → Документы и согласия (соглашение и обработка персональных данных).")
        }
        return (BackendRegistry.httpBackend(url), nil)
    }

    private func message(for error: Error) -> String {
        switch error {
        case BackendError.notFound: return "Аккаунт с такой почтой не найден."
        case BackendError.invalidCode, BackendError.forbidden: return "Код не подошёл или устарел. Запросите новый."
        case BackendError.rateLimited: return "Слишком много попыток. Подождите немного и повторите."
        case BackendError.roomFull: return "Эта почта уже привязана к другому аккаунту."
        case BackendError.serverUnavailable: return "Нет связи с сервером. Повторите позже."
        default: return "Не получилось. Повторите позже."
        }
    }

    /// Просит сервер отправить на почту код. Возвращает текст ошибки или nil.
    func requestEmailCode(_ rawEmail: String, restore: Bool) async -> String? {
        guard let email = EmailAddress.normalize(rawEmail) else { return "Проверьте адрес почты." }
        let (backend, problem) = serverForAccount()
        guard let backend else { return problem }
        if !restore && !isSignedIn { await ensureSignedIn() }
        if !restore && !isSignedIn { return "Не удалось войти на сервер. Повторите позже." }
        do {
            try await backend.requestEmailCode(email: email, restore: restore)
            return nil
        } catch BackendError.invalidCode {
            return "Проверьте адрес почты."
        } catch {
            return message(for: error)
        }
    }

    /// Подтверждает привязку почты кодом из письма.
    func confirmEmail(_ rawEmail: String, code rawCode: String) async -> String? {
        guard let email = EmailAddress.normalize(rawEmail), let code = EmailAddress.normalizeCode(rawCode) else {
            return "Проверьте адрес и код (6 цифр)."
        }
        let (backend, problem) = serverForAccount()
        guard let backend else { return problem }
        do {
            try await backend.verifyEmail(email: email, code: code)
            AppSettings.shared.data.recoveryEmail = email
            AppSettings.shared.data.recoveryEmailVerified = true
            return nil
        } catch {
            return message(for: error)
        }
    }

    /// Отвязывает почту (на сервере и на телефоне).
    func removeEmail() async -> String? {
        let (backend, problem) = serverForAccount()
        guard let backend else { return problem }
        do {
            try await backend.removeEmail()
            AppSettings.shared.data.recoveryEmail = nil
            AppSettings.shared.data.recoveryEmailVerified = false
            return nil
        } catch {
            return message(for: error)
        }
    }

    /// Восстанавливает аккаунт по письму с кодом. У этого телефона будет свой секрет; код из 16 слов остаётся прежним.
    func restoreByEmail(email rawEmail: String, code rawCode: String) async -> String? {
        guard let email = EmailAddress.normalize(rawEmail), let code = EmailAddress.normalizeCode(rawCode) else {
            return "Проверьте адрес и код (6 цифр)."
        }
        guard !isRestoring else { return "Восстановление уже идёт." }
        if WakeCoordinator.shared.session != nil {
            return "Сейчас идёт утренняя проверка. Восстановить аккаунт можно после неё."
        }
        if hasLocalData {
            return "На этом телефоне уже есть свои будильники или дневник. Восстановить аккаунт можно только на чистом телефоне: сначала удалите данные в Профиле."
        }
        let (backend, problem) = serverForAccount()
        guard let backend else { return problem }
        isRestoring = true
        defer { isRestoring = false }
        let secret = AccountStore.randomSecret()
        let result: (token: String, userID: UUID, number: String?)
        do {
            result = try await backend.restoreByEmail(email: email, code: code, secret: secret)
        } catch {
            return message(for: error)
        }
        if hasLocalData { return "Пока шло восстановление, на телефоне появились свои данные. Удалите их в Профиле и повторите." }
        // Неотправленные изменения этого телефона не должны уйти в восстановленный аккаунт.
        SyncEngine.shared.clear()
        guard Keychain.set(secret, for: AccountStore.secretKey, migratable: true),
              Keychain.set(result.userID.uuidString, for: AccountStore.userIDKey, migratable: true) else {
            return "Не удалось сохранить ключ на телефоне. Разблокируйте телефон и повторите."
        }
        // Кода из 16 слов у этого телефона нет: старый код (если был) больше не принадлежит этому телефону.
        Keychain.set(nil, for: AccountStore.phraseKey)
        switchProfile(to: result.userID)
        AppSettings.shared.data.identityCreated = true
        AppSettings.shared.data.restoredByEmail = true
        AppSettings.shared.data.recoveryEmail = email
        AppSettings.shared.data.recoveryEmailVerified = true
        AppSettings.shared.data.recoverySaved = true
        AppSettings.shared.data.pendingRestoreMerge = true
        signIn(token: result.token)
        if let number = result.number { AppSettings.shared.data.friendNumber = number }
        if let problem = await mergeRestoredData() { return "Аккаунт восстановлен. \(problem)" }
        return nil
    }

    /// Случайный секрет устройства: 32 байта, шестнадцатеричной строкой.
    private static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess { bytes = (0..<32).map { _ in UInt8.random(in: 0...255) } }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Сохраняет токен, выданный сервером после входа.
    func signIn(token: String) {
        Keychain.set(token, for: AccountStore.tokenKey)
        self.token = token
    }

    func signOut() {
        Keychain.set(nil, for: AccountStore.tokenKey)
        token = nil
    }

    /// Код восстановления из 16 слов. Создаётся один раз; из него выводятся номер аккаунта и секрет устройства.
    var recoveryWords: [String] {
        (Keychain.get(AccountStore.phraseKey) ?? "").split(separator: " ").map(String.init)
    }

    /// Код восстановления пропал (перенос на новый телефон без связки ключей): нужно ввести свой код.
    var needsRecoveryCode: Bool {
        AppSettings.shared.data.identityCreated && !AppSettings.shared.data.restoredByEmail
            && Keychain.exists(AccountStore.phraseKey) == false
    }

    /// Номер для друзей: выданный сервером, а в демо-режиме — демонстрационный.
    var friendNumber: String? {
        if let number = AppSettings.shared.data.friendNumber { return number }
        if AppConfig.serverURL == nil && AppSettings.shared.data.useDemoSocial {
            return FriendNumber.demo(for: AppSettings.shared.data.profile.id)
        }
        return nil
    }

    /// Создаёт аккаунт из нового кода восстановления, если его ещё нет.
    /// Старый случайный секрет (версии до кода восстановления) заменяется: на сервере его ещё не было.
    func ensureIdentity() {
        // До первой разблокировки связка ключей закрыта: ничего не решаем, чтобы не создать второй аккаунт.
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        if let phrase = Keychain.get(AccountStore.phraseKey) {
            // Код есть (например, приложение переустановили: связка ключей пережила удаление, настройки — нет).
            // Аккаунт всегда тот, что выводится из этого кода.
            let userID = Keychain.get(AccountStore.userIDKey).flatMap(UUID.init(uuidString:))
                ?? cacheUserID(for: phrase)
            if let userID { switchProfile(to: userID) }
            if !AppSettings.shared.data.identityCreated { AppSettings.shared.data.pendingRestoreMerge = true }
            AppSettings.shared.data.identityCreated = true
            return
        }
        guard Keychain.exists(AccountStore.phraseKey) == false else { return }
        // Приложение переустановили после восстановления по почте: ключ и номер аккаунта есть, кода из 16 слов нет и не было.
        if let userID = Keychain.get(AccountStore.userIDKey).flatMap(UUID.init(uuidString:)),
           Keychain.get(AccountStore.secretKey) != nil {
            switchProfile(to: userID)
            if !AppSettings.shared.data.identityCreated { AppSettings.shared.data.pendingRestoreMerge = true }
            AppSettings.shared.data.identityCreated = true
            AppSettings.shared.data.restoredByEmail = true
            return
        }
        // Код когда-то был, а теперь пропал: новый не создаём, человек вводит свой (см. needsRecoveryCode).
        guard !AppSettings.shared.data.identityCreated else { return }
        let phrase = RecoveryPhrase.generate()
        _ = adopt(phrase: phrase, identity: RecoveryPhrase.identity(for: phrase))
    }

    private func cacheUserID(for phrase: String) -> UUID? {
        let words = phrase.split(separator: " ").map(String.init)
        guard words.count == RecoveryPhrase.wordCount else { return nil }
        let userID = RecoveryPhrase.identity(for: words).userID
        Keychain.set(userID.uuidString, for: AccountStore.userIDKey, migratable: true)
        return userID
    }

    /// Делает этот код восстановления кодом текущего аккаунта. Аккаунт меняется,
    /// только если всё записалось в связку ключей. Возвращает false при сбое записи.
    private func adopt(phrase: [String], identity: (userID: UUID, secret: String)) -> Bool {
        let text = phrase.joined(separator: " ")
        // Переносится на новый телефон с зашифрованной резервной копией; без неё — по коду.
        guard Keychain.set(identity.secret, for: AccountStore.secretKey, migratable: true),
              Keychain.set(identity.userID.uuidString, for: AccountStore.userIDKey, migratable: true),
              Keychain.set(text, for: AccountStore.phraseKey, migratable: true),
              Keychain.get(AccountStore.phraseKey) == text else { return false }
        switchProfile(to: identity.userID)
        AppSettings.shared.data.identityCreated = true
        AppSettings.shared.data.restoredByEmail = false
        return true
    }

    private func switchProfile(to userID: UUID) {
        guard AppSettings.shared.data.profile.id != userID else { return }
        AppSettings.shared.data.profile.id = userID
        AppSettings.shared.data.friendNumber = nil
        signOut()
        // Демо-сообщество помнило прежний номер «меня»: начинаем его заново.
        DemoBackend.shared.resetForNewIdentity()
    }

    /// Секрет устройства, выведенный из кода восстановления. nil — связка ключей закрыта (до первой разблокировки).
    private var deviceSecret: String? {
        ensureIdentity()
        guard !needsRecoveryCode else { return nil }
        return Keychain.get(AccountStore.secretKey)
    }

    /// Идёт восстановление: обычный вход на сервер в это время не выполняется.
    private var isRestoring = false

    /// Подпись секретом устройства (для событий утра).
    func sign(_ message: String) -> String {
        // Без секрета подписи нет: сервер такое событие не примет, но и подделать его пустым ключом нельзя.
        guard let secret = deviceSecret, !secret.isEmpty else { return "" }
        return WakeEvent.sign(message, secret: secret)
    }

    /// Если сервер подключён, а токена нет, регистрирует устройство. Без сервера ничего не делает.
    func ensureSignedIn() async {
        guard token == nil, !isRestoring, let url = AppConfig.serverURL,
              ConsentRules.serverAllowed(AppSettings.shared.data.consents), let secret = deviceSecret else { return }
        let backend = BackendRegistry.httpBackend(url)
        let profile = AppSettings.shared.data.profile
        do {
            let result = try await backend.register(profile: profile, secret: secret)
            // Пока ждали ответ, аккаунт сменился (восстановление): чужой токен не сохраняем.
            guard !isRestoring, AppSettings.shared.data.profile.id == profile.id else { return }
            signIn(token: result.token)
            if let number = result.number { AppSettings.shared.data.friendNumber = number }
            signInProblem = nil
        } catch BackendError.forbidden {
            signInProblem = "Сервер не узнал это устройство. Если вы перенесли данные со старого телефона без резервной копии связки ключей, обратитесь в поддержку."
        } catch {
            signInProblem = nil // нет сети: попробуем при следующем открытии
        }
    }

    /// Восстанавливает аккаунт по коду восстановления на этом телефоне. Возвращает текст ошибки или nil.
    /// Данные с сервера добавляются к тем, что уже есть на телефоне; ничего не удаляется.
    func restore(phraseText: String) async -> String? {
        guard let phrase = RecoveryPhrase.parse(phraseText) else {
            return "Нужно \(RecoveryPhrase.wordCount) слов из кода восстановления. Проверьте, что все слова написаны без ошибок."
        }
        if phrase == recoveryWords {
            // Тот же аккаунт: если данные ещё не загрузились, догружаем.
            guard AppSettings.shared.data.pendingRestoreMerge else { return "Это код этого же аккаунта: восстанавливать нечего." }
            return await mergeRestoredData()
        }
        guard !isRestoring else { return "Восстановление уже идёт." }
        if WakeCoordinator.shared.session != nil {
            return "Сейчас идёт утренняя проверка. Восстановить аккаунт можно после неё."
        }
        // Код пропал при переносе — данные на телефоне и так этого аккаунта. Иначе они чужие, смешивать нельзя.
        let ownDataMissingCode = needsRecoveryCode
        if !ownDataMissingCode && hasLocalData {
            return "На этом телефоне уже есть свои будильники или дневник. Восстановить аккаунт можно только на чистом телефоне: сначала удалите данные в Профиле."
        }
        guard let url = AppConfig.serverURL else {
            return "Сервер ещё не подключён: восстанавливать пока неоткуда. Код начнёт работать вместе с сервером."
        }
        guard ConsentRules.serverAllowed(AppSettings.shared.data.consents) else {
            return "Нужны согласия: Профиль → Документы и согласия (соглашение и обработка персональных данных)."
        }
        isRestoring = true
        defer { isRestoring = false }
        // Медленный вывод ключа — не на главном потоке.
        let identity = await Task.detached(priority: .userInitiated) { RecoveryPhrase.identity(for: phrase) }.value
        let backend = BackendRegistry.httpBackend(url)
        var profile = AppSettings.shared.data.profile
        profile.id = identity.userID
        let result: (token: String, number: String?)
        do {
            result = try await backend.register(profile: profile, secret: identity.secret, restore: true)
        } catch BackendError.notFound {
            return "Аккаунт с таким кодом не найден. Проверьте слова и их порядок."
        } catch BackendError.forbidden {
            return "Код не подошёл. Проверьте слова и их порядок."
        } catch {
            return "Не получилось связаться с сервером. Попробуйте позже."
        }
        // Пока ждали сервер, на телефоне могли появиться свои данные.
        if !ownDataMissingCode && hasLocalData {
            return "Пока шло восстановление, на телефоне появились свои данные. Удалите их в Профиле и повторите."
        }
        // Неотправленные изменения прежнего аккаунта не должны уйти в восстановленный.
        if !ownDataMissingCode { SyncEngine.shared.clear() }
        guard adopt(phrase: phrase, identity: identity) else {
            return "Не удалось сохранить код на телефоне. Разблокируйте телефон и повторите."
        }
        signIn(token: result.token)
        if let number = result.number { AppSettings.shared.data.friendNumber = number }
        AppSettings.shared.data.recoverySaved = true
        AppSettings.shared.data.pendingRestoreMerge = true
        if let problem = await mergeRestoredData() {
            return "Аккаунт восстановлен. \(problem)"
        }
        return nil
    }

    private var hasLocalData: Bool {
        !JournalStore.shared.realEntries.isEmpty || !AlarmStore.shared.alarms.isEmpty || !ChallengeStore.shared.challenges.isEmpty
    }

    /// Загружает данные восстановленного аккаунта. Если не вышло — повторит при следующем открытии.
    @discardableResult
    func mergeRestoredData() async -> String? {
        guard AppSettings.shared.data.pendingRestoreMerge, let url = AppConfig.serverURL, token != nil else { return nil }
        do {
            let snapshot = try await BackendRegistry.httpBackend(url).restoreSnapshot()
            if let restored = snapshot.profile {
                var profile = restored
                profile.id = AppSettings.shared.data.profile.id
                AppSettings.shared.data.profile = profile
            }
            if let privacy = snapshot.privacy { AppSettings.shared.applyRestoredPrivacy(privacy) }
            AlarmStore.shared.mergeRestored(snapshot.alarms ?? [])
            JournalStore.shared.mergeRestored(snapshot.journal ?? [])
            ChallengeStore.shared.mergeRestored(snapshot.challenges ?? [])
            AppSettings.shared.data.pendingRestoreMerge = false
            return nil
        } catch {
            return "Данные ещё не загрузились: попробуем снова при следующем открытии приложения."
        }
    }

    /// Сервер отверг токен, с которым был запрос. Если тем временем пришёл новый, его не трогаем.
    func tokenRejected(_ usedToken: String?) {
        guard usedToken != nil, usedToken == token else { return }
        signOut()
    }

    /// Удаляет аккаунт на сервере (если он есть) и все данные на телефоне.
    /// Возвращает текст ошибки, если сервер не подтвердил удаление: тогда на телефоне ничего не трогается.
    func deleteAccountAndData() async -> String? {
        if WakeCoordinator.shared.session != nil {
            return "Сейчас идёт утренняя проверка. Удалить данные можно после её окончания."
        }
        if AlarmStore.shared.alarms.contains(where: { AlarmStore.shared.isLocked($0) }) {
            return "Будильник с обязательством зазвонит меньше чем через 2 часа. Удалить данные можно после утра."
        }
        if FocusStore.shared.current != nil {
            return "Идёт фокус-сессия. Удалить данные можно после её окончания."
        }
        if PromiseStore.shared.hasActive {
            return "Есть непроверенное обещание по шагам. Удалить аккаунт и данные можно после того, как оно будет проверено."
        }
        if ChallengeStore.shared.hasActiveStake {
            return "Идёт челлендж с обязательством. Удалить данные можно после его окончания."
        }
        await PaymentsStore.shared.retryPending()
        if PaymentsStore.shared.hasOpenOperations {
            return "Есть незавершённые операции по обязательствам. Попробуйте позже, когда они завершатся."
        }
        // Удаление на сервере работает всегда, в том числе после отзыва согласия.
        let backend: SocialBackend
        if let url = AppConfig.serverURL { backend = BackendRegistry.httpBackend(url) } else { backend = BackendRegistry.current }
        // Без токена на сервере для этого телефона ничего нет, удалять там нечего: локальная очистка не блокируется.
        if backend.isOnline && !backend.isDemo && isSignedIn {
            do {
                try await backend.deleteAccount()
            } catch BackendError.notFound {
                // Аккаунта на сервере уже нет.
            } catch {
                return "Сервер не подтвердил удаление аккаунта: \(error.localizedDescription) Данные на телефоне не тронуты, попробуйте позже."
            }
        }

        AlarmService.shared.cancelEverything()
        Keychain.removeAll()
        token = nil
        AppFiles.wipeAll()
        // Порядок важен: будильники пустеют раньше, чем перечитываются настройки.
        AlarmStore.shared.reload()
        WakeCoordinator.shared.reload()
        JournalStore.shared.reload()
        ChallengeStore.shared.reload()
        PaymentsStore.shared.reload()
        AppSettings.shared.reload()
        SocialStore.shared.resetAfterWipe()
        DemoBackend.shared.reload()
        VoiceLibrary.shared.reload()
        MorningPhotoStore.shared.reload()
        MedStore.shared.reload()
        MedStore.shared.refresh()
        PromiseStore.shared.reload()
        FocusStore.shared.reload()
        await PromiseStore.shared.cancelAllNotifications()
        await WeeklyNotification.update(enabled: false)
        // Ни одно запланированное уведомление («Списано …», напоминания) не должно пережить удаление данных.
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        // Последним: перезагрузки выше могли поставить изменения в очередь.
        SyncEngine.shared.clear()
        return nil
    }
}

/// Какой сервер сейчас используется.
@MainActor
enum BackendRegistry {
    private static var http: HTTPBackend?
    private static let offline = OfflineBackend()

    static func httpBackend(_ url: URL) -> HTTPBackend {
        if let http { return http }
        let created = HTTPBackend(baseURL: url)
        http = created
        return created
    }

    static var current: SocialBackend & SyncBackend {
        if let url = AppConfig.serverURL {
            // Без соглашения и согласия на обработку данных приложение с сервером не общается.
            guard ConsentRules.serverAllowed(AppSettings.shared.data.consents) else { return offline }
            return httpBackend(url)
        }
        if AppSettings.shared.data.useDemoSocial { return DemoBackend.shared }
        return offline
    }
}

/// Отправка журнала согласий на сервер. Работает и после отзыва согласия: отзыв тоже нужно записать.
@MainActor
enum ConsentSync {
    static func flush() async {
        guard let url = AppConfig.serverURL else { return }
        let records = AppSettings.shared.data.unsentConsents
        guard !records.isEmpty else { return }
        // Согласие только что дано, а токена ещё нет: сначала входим, потом отправляем.
        if !AccountStore.shared.isSignedIn { await AccountStore.shared.ensureSignedIn() }
        guard AccountStore.shared.isSignedIn else { return }
        do {
            try await BackendRegistry.httpBackend(url).recordConsents(records)
            let sent = Set(records.map(\.id))
            AppSettings.shared.data.unsentConsents.removeAll { sent.contains($0.id) }
        } catch {
            // Не ушло: повторим при следующем открытии.
        }
    }
}
