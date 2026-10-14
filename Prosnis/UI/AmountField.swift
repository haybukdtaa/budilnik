import SwiftUI

/// Поле суммы в рублях. Значение меняется с каждой цифрой, а не после ухода из поля,
/// поэтому кнопка «Сохранить» всегда видит то, что на экране.
struct AmountField: View {
    @Binding var value: Int

    var body: some View {
        TextField("500", text: Binding(
            get: { value > 0 ? String(value) : "" },
            set: { text in
                let digits = text.filter(\.isNumber)
                value = Int(digits.prefix(7)) ?? 0
            }
        ))
        .keyboardType(.numberPad)
        .multilineTextAlignment(.trailing)
        .frame(width: 100)
    }
}
