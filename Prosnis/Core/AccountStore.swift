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
    func deleteAccountAndData() async {
        try? await BackendRegistry.current.deleteAccount()
        for alarm in AlarmStore.shared.alarms {
            AlarmService.shared.cancelAll(for: alarm.id)
        }
        if let session = WakeCoordinator.shared.session, let recheck = session.recheckAlarmID {
            AlarmService.shared.cancel(id: recheck)
        }
        Keychain.removeAll()
        token = nil
        AppFiles.wipeAll()
        AppSettings.shared.reload()
        AlarmStore.shared.reload()
        JournalStore.shared.reload()
        ChallengeStore.shared.reload()
        WakeCoordinator.shared.reload()
        PaymentsStore.shared.reload()
        SyncEngine.shared.reload()
        SocialStore.shared.resetAfterWipe()
        DemoBackend.shared.reload()
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
