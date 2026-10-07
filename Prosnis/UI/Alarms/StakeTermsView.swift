import SwiftUI

/// Условия ставки. Будильник со ставкой сохраняется только после «Согласен».
struct StakeTermsView: View {
    @Environment(\.dismiss) private var dismiss
    let amount: Int
    let onAccept: () -> Void
    @State private var agreed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(StakeTerms.clauses(amount: amount, isTraining: PaymentsStore.shared.isTraining).enumerated()), id: \.offset) { index, clause in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(clause)
                        }
                    }
                } footer: {
                    Text("Условия, версия \(StakeTerms.version). Согласие сохраняется вместе с датой и нужно при спорах о списании.")
                }
                Section {
                    Toggle("Я прочитал(а) условия и согласен(на)", isOn: $agreed)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Условия ставки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Согласен") { onAccept() }
                        .bold()
                        .disabled(!agreed)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
