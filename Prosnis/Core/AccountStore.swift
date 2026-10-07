import Foundation
import Security
import SwiftUI

/// Аккаунт: токен сервера и удаление всех данных.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    private static let tokenKey = "auth.token"
    private static let secretKey = "auth.secret"

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

    /// Секрет устройства: создаётся один раз и хранится в связке ключей.
    private var deviceSecret: String {
        if let existing = Keychain.get(AccountStore.secretKey) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let secret = Data(bytes).base64EncodedString()
        // Секрет переносится на новый телефон вместе с зашифрованной резервной копией: аккаунт не теряется.
        Keychain.set(secret, for: AccountStore.secretKey, migratable: true)
        return secret
    }

    /// Если сервер подключён, а токена нет, регистрирует устройство. Без сервера ничего не делает.
    func ensureSignedIn() async {
        guard token == nil, let url = AppConfig.serverURL else { return }
        let backend = BackendRegistry.httpBackend(url)
        do {
            let newToken = try await backend.register(profile: AppSettings.shared.data.profile, secret: deviceSecret)
            signIn(token: newToken)
            signInProblem = nil
        } catch BackendError.forbidden {
            signInProblem = "Сервер не узнал это устройство. Если вы перенесли данные со старого телефона без резервной копии связки ключей, обратитесь в поддержку."
        } catch {
            signInProblem = nil // нет сети: попробуем при следующем открытии
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
