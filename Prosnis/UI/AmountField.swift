import SwiftUI

/// Поле суммы в рублях. Значение меняется с каждой цифрой, а не после ухода из поля,
/// поэтому кнопка «Сохранить» всегда видит то, что на экране.
struct AmountField: View {
    @Binding var value: Int
    @FocusState private var focused: Bool

    var body: some View {
        TextField("500", text: Binding(
            get: { value > 0 ? String(value) : "" },
            set: { text in
                let digits = text.filter(\.isNumber)
                value = Int(digits.prefix(7)) ?? 0
            }
        ))
        .keyboardType(.numberPad)
        .focused($focused)
        .toolbar {
            // У цифровой клавиатуры нет кнопки возврата: закрыть её иначе нечем.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                if focused { Button("Готово") { focused = false } }
            }
        }
        .multilineTextAlignment(.trailing)
        .frame(width: 100)
    }
}
