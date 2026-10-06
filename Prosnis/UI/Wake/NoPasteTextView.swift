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
        view.font = .systemFont(ofSize: 20, weight: .medium)
        view.textColor = .white
        view.backgroundColor = UIColor(white: 1, alpha: 0.14)
        view.layer.cornerRadius = 14
        view.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NoPasteTextView

        init(_ parent: NoPasteTextView) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Вставка, подсказки и диктовка приносят больше одного символа за раз.
            if text.count > 1 { return false }
            if text == "\n" { return false }
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
