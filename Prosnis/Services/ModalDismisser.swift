import UIKit

/// Закрывает открытые окна поверх приложения. Нужно, когда задание будильника должно появиться
/// на экране, а iOS не показывает второе окно поверх первого.
@MainActor
enum ModalDismisser {
    static func dismissAll() {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
        guard let root, root.presentedViewController != nil else { return }
        root.dismiss(animated: false)
    }
}
