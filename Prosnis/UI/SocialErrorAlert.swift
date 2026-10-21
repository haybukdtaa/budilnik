import SwiftUI

/// Ошибка сообщества внутри самого окна: тревога на родительском экране закрыта окном и не видна.
struct SocialErrorAlert: ViewModifier {
    @EnvironmentObject private var social: SocialStore

    func body(content: Content) -> some View {
        content.alert(
            "Сообщество",
            isPresented: Binding(get: { social.errorText != nil }, set: { if !$0 { social.errorText = nil } })
        ) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(social.errorText ?? "")
        }
    }
}

extension View {
    func socialErrorAlert() -> some View { modifier(SocialErrorAlert()) }
}
