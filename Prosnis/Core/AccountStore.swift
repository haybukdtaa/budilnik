import Foundation
import Security
import SwiftUI

/// Аккаунт: токен сервера и удаление всех данных.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    private static let tokenKey = "auth.token"
    private static let secretKey = "auth.secret"
    private static let phraseKey = "auth.phrase.v2"

    @Published private(set) var token: String?
    /// Почему не удалось войти на сервер (показывается в Профиле).
    @Published private(set) var signInProblem: String?

    private init() {
        token = Keychain.get(AccountStore.tokenKey)
    }

    var isSignedIn: Bool { token != nil }

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
        ensureIdentity()
        return (Keychain.get(AccountStore.phraseKey) ?? "").split(separator: " ").map(String.init)
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
        // Новый код — только если старого точно нет. Закрытая связка ключей (до первой разблокировки) — не повод.
        guard Keychain.exists(AccountStore.phraseKey) == false else { return }
        let phrase = RecoveryPhrase.generate()
        adopt(phrase: phrase)
    }

    /// Делает этот код восстановления кодом текущего аккаунта.
    private func adopt(phrase: [String]) {
        let identity = RecoveryPhrase.identity(for: phrase)
        // Переносится на новый телефон с зашифрованной резервной копией; без неё — по коду.
        Keychain.set(identity.secret, for: AccountStore.secretKey, migratable: true)
        Keychain.set(phrase.joined(separator: " "), for: AccountStore.phraseKey, migratable: true)
        if AppSettings.shared.data.profile.id != identity.userID {
            AppSettings.shared.data.profile.id = identity.userID
            AppSettings.shared.data.friendNumber = nil
            signOut()
        }
    }

    /// Секрет устройства, выведенный из кода восстановления. nil — связка ключей закрыта (до первой разблокировки).
    private var deviceSecret: String? {
        ensureIdentity()
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
        guard token == nil, !isRestoring, let url = AppConfig.serverURL, let secret = deviceSecret else { return }
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
        if phrase == recoveryWords { return "Это код этого же аккаунта: восстанавливать нечего." }
        guard !isRestoring else { return "Восстановление уже идёт." }
        if WakeCoordinator.shared.session != nil {
            return "Сейчас идёт утренняя проверка. Восстановить аккаунт можно после неё."
        }
        // Данные этого телефона принадлежат другому аккаунту: смешивать их с восстановленным нельзя.
        if !JournalStore.shared.realEntries.isEmpty || !AlarmStore.shared.alarms.isEmpty || !ChallengeStore.shared.challenges.isEmpty {
            return "На этом телефоне уже есть свои будильники или дневник. Восстановить аккаунт можно только на чистом телефоне: сначала удалите данные в Профиле."
        }
        guard let url = AppConfig.serverURL else {
            return "Сервер ещё не подключён: восстанавливать пока неоткуда. Код начнёт работать вместе с сервером."
        }
        let identity = RecoveryPhrase.identity(for: phrase)
        let backend = BackendRegistry.httpBackend(url)
        var profile = AppSettings.shared.data.profile
        profile.id = identity.userID
        isRestoring = true
        defer { isRestoring = false }
        do {
            let result = try await backend.register(profile: profile, secret: identity.secret, restore: true)
            // Неотправленные изменения прежнего аккаунта не должны уйти в восстановленный.
            SyncEngine.shared.clear()
            adopt(phrase: phrase)
            signIn(token: result.token)
            if let number = result.number { AppSettings.shared.data.friendNumber = number }
            AppSettings.shared.data.recoverySaved = true
            let snapshot = try await backend.restoreSnapshot()
            AlarmStore.shared.mergeRestored(snapshot.alarms ?? [])
            JournalStore.shared.mergeRestored(snapshot.journal ?? [])
            ChallengeStore.shared.mergeRestored(snapshot.challenges ?? [])
            return nil
        } catch BackendError.notFound {
            return "Аккаунт с таким кодом не найден. Проверьте слова и их порядок."
        } catch BackendError.forbidden {
            return "Код не подошёл. Проверьте слова и их порядок."
        } catch {
            return "Не получилось связаться с сервером. Попробуйте позже."
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
            return "Будильник со ставкой зазвонит меньше чем через 2 часа. Удалить данные можно после утра."
        }
        await PaymentsStore.shared.retryPending()
        if PaymentsStore.shared.hasOpenOperations {
            return "Есть незавершённые операции по ставкам. Попробуйте позже, когда они завершатся."
        }
        let backend = BackendRegistry.current
        if backend.isOnline && !backend.isDemo {
            do {
                try await backend.deleteAccount()
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
        await WeeklyNotification.update(enabled: false)
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
            return httpBackend(url)
        }
        if AppSettings.shared.data.useDemoSocial { return DemoBackend.shared }
        return offline
    }
}
