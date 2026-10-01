import SwiftUI

/// Список звуков по категориям. Нажатие выбирает звук и проигрывает пробный фрагмент.
struct SoundPickerView: View {
    @Binding var selection: String

    var body: some View {
        List {
            ForEach(SoundCategory.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(SoundLibrary.options(in: category)) { option in
                        Button {
                            selection = option.id
                            SoundPreview.shared.play(option)
                        } label: {
                            HStack {
                                Text(option.title).foregroundStyle(.primary)
                                Spacer()
                                if option.id == selection {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Звук")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { SoundPreview.shared.stop() }
    }
}
