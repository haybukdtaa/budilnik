import SwiftUI
import UIKit

/// Поле ввода для задания: без вставки, без подсказок и без автозамены.
struct NoPasteTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = NoPasteUITextView()
        view.delegate = context.coordinator
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.autocapitalizationType = .sentences
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.inlinePredictionType = .no
        // Перетаскивание текста в поле тоже обход: выключаем.
        view.textDragInteraction?.isEnabled = false
        view.font = .systemFont(ofSize: 20, weight: .medium)
        view.textColor = .white
        view.backgroundColor = UIColor(white: 1, alpha: 0.14)
        view.layer.cornerRadius = 14
        view.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // Печатаемый текст приходит только из самого поля. Переписывать его обратно нельзя:
        // устаревшее значение стирало бы только что набранные буквы. Сбрасываем лишь пустое значение.
        if text.isEmpty && !view.text.isEmpty { view.text = "" }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NoPasteTextView

        init(_ parent: NoPasteTextView) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" { return false }
            // Вставка заблокирована отдельно (paste). Слово целиком, набранное проведением по клавиатуре,
            // допускается; слишком длинный кусок за один раз — нет.
            if text.count > 30 { return false }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}

final class NoPasteUITextView: UITextView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.paste(_:)) { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {}
}
