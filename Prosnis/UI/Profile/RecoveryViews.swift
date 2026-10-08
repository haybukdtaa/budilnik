import SwiftUI

/// Код восстановления: 16 слов, которые возвращают аккаунт на новом телефоне.
struct RecoveryCodeView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var revealed = false
    @State private var words: [String] = []

    var body: some View {
        List {
            if AccountStore.shared.needsRecoveryCode {
                Section {
                    Label("Код этого аккаунта не перенёсся на телефон. Введите его в «Восстановить аккаунт по коду».", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Text("Регистрации нет: ни телефона, ни почты. Ваш аккаунт — это эти 16 слов. Запишите их на бумаге и храните дома. На новом телефоне они вернут дерево, друзей и дневник подъёмов.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if revealed {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                            HStack(spacing: 4) {
                                Text("\(index + 1).").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                Text(word).font(.body.weight(.medium))
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                } else if words.count == RecoveryPhrase.wordCount {
                    Button("Показать код") { revealed = true }
                } else {
                    Text("Код сейчас недоступен. Разблокируйте телефон и откройте экран снова.").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Никому не показывайте и не отправляйте этот код: кто его знает, тот получит доступ к аккаунту. Мы его никогда не спросим.")
            }
            if revealed && words.count == RecoveryPhrase.wordCount {
                Section {
                    Toggle("Я записал(а) код", isOn: $settings.data.recoverySaved)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Код восстановления")
        .onAppear {
            AccountStore.shared.ensureIdentity()
            words = AccountStore.shared.recoveryWords
        }
    }
}

/// Ввод кода восстановления на новом телефоне.
struct RestoreAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var working = false
    @State private var result: String?
    @State private var done = false

    var body: some View {
        List {
            Section {
                TextField("\(RecoveryPhrase.wordCount) слов через пробел", text: $text, axis: .vertical)
                    .lineLimit(3...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Введите слова в том же порядке. Восстановить можно только на телефоне без своих будильников и дневника.")
            }
            Section {
                Button(working ? "Восстанавливаем…" : "Восстановить") {
                    working = true
                    Task {
                        let error = await AccountStore.shared.restore(phraseText: text)
                        working = false
                        result = error ?? "Аккаунт восстановлен."
                        done = error == nil
                    }
                }
                .disabled(working || RecoveryPhrase.parse(text) == nil)
            }
            if let result {
                Section {
                    Label(result, systemImage: done ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(done ? Color.green : Color.orange)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Восстановить аккаунт")
    }
}

/// Мой номер для друзей.
struct FriendNumberRow: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        if let number = AccountStore.shared.friendNumber {
            VStack(alignment: .leading, spacing: 8) {
                Text(number)
                    .font(.system(size: 26, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    ShareLink(item: "Добавь меня в Prosnis: мой номер \(number)") {
                        Label("Отправить номер", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    if AppConfig.serverURL == nil {
                        Text("демо").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text("Номер появится, когда подключим сервер.").foregroundStyle(.secondary)
        }
    }
}
