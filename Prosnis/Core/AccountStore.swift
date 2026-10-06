import Foundation
import SwiftUI

/// Аккаунт: токен сервера и удаление всех данных.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    private static let tokenKey = "auth.token"

    @Published private(set) var token: String?

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

    /// Удаляет аккаунт на сервере (если он есть) и все данные на телефоне.
    /// Возвращает текст ошибки, если сервер не подтвердил удаление: тогда на телефоне ничего не трогается.
    func deleteAccountAndData() async -> String? {
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

    static var current: SocialBackend & SyncBackend {
        if let url = AppConfig.serverURL {
            if http == nil { http = HTTPBackend(baseURL: url) }
            return http!
        }
        if AppSettings.shared.data.useDemoSocial { return DemoBackend.shared }
        return offline
    }
}
