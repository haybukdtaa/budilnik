import SwiftUI

/// Привязка почты для восстановления аккаунта. Код приходит письмом на указанный адрес.
struct EmailLinkView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var working = false
    @State private var message: String?
    @State private var confirmRemove = false

    var body: some View {
        List {
            if let linked = settings.data.recoveryEmail, settings.data.recoveryEmailVerified {
                Section {
                    Label(linked, systemImage: "checkmark.seal.fill").foregroundStyle(Theme.mint)
                    Button("Отвязать почту", role: .destructive) {
                        if settings.data.restoredByEmail { confirmRemove = true } else { run { await AccountStore.shared.removeEmail() } }
                    }
                } footer: {
                    Text("Если потеряете телефон и код из 16 слов, аккаунт можно вернуть через письмо на эту почту: Профиль → Восстановить аккаунт.")
                }
            } else {
                Section {
                    TextField("Адрес почты", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(codeSent)
                    if codeSent {
                        TextField("Код из письма (6 цифр)", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    }
                } footer: {
                    Text("Почта нужна только для восстановления: мы не шлём на неё рекламу и не показываем её другим. Для привязки нужны согласия в Профиль → Документы и согласия.")
                }
                Section {
                    if !codeSent {
                        Button(working ? "Отправляем…" : "Отправить код") {
                            run { await AccountStore.shared.requestEmailCode(email, restore: false) } onSuccess: { codeSent = true }
                        }
                        .disabled(working || EmailAddress.normalize(email) == nil)
                    } else {
                        Button(working ? "Проверяем…" : "Подтвердить") {
                            run { await AccountStore.shared.confirmEmail(email, code: code) } onSuccess: { codeSent = false; code = "" }
                        }
                        .disabled(working || EmailAddress.normalizeCode(code) == nil)
                        Button("Ввести другой адрес") { codeSent = false; code = "" }
                    }
                }
            }
            if let message {
                Section { Text(message).font(.app(.footnote)).foregroundStyle(.orange) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .confirmationDialog("Это единственный способ вернуть аккаунт: кода из 16 слов на этом телефоне нет. Отвязать почту?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Отвязать", role: .destructive) { run { await AccountStore.shared.removeEmail() } }
            Button("Отмена", role: .cancel) {}
        }
        .navigationTitle("Почта для восстановления")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run(_ action: @escaping () async -> String?, onSuccess: @escaping () -> Void = {}) {
        working = true
        message = nil
        Task {
            let error = await action()
            working = false
            message = error
            if error == nil { onSuccess() }
        }
    }
}

/// Восстановление аккаунта через письмо с кодом.
struct RestoreByEmailView: View {
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var working = false
    @State private var result: String?
    @State private var done = false

    var body: some View {
        List {
            Section {
                TextField("Адрес почты", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(codeSent)
                if codeSent {
                    TextField("Код из письма (6 цифр)", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                }
            } footer: {
                Text("Введите почту, которую вы привязывали. Восстановить можно только на телефоне без своих будильников и дневника.")
            }
            Section {
                if !codeSent {
                    Button(working ? "Отправляем…" : "Отправить код") {
                        working = true; result = nil
                        Task {
                            let error = await AccountStore.shared.requestEmailCode(email, restore: true)
                            working = false
                            if let error { result = error } else { codeSent = true }
                        }
                    }
                    .disabled(working || EmailAddress.normalize(email) == nil)
                } else {
                    Button(working ? "Восстанавливаем…" : "Восстановить") {
                        working = true; result = nil
                        Task {
                            let error = await AccountStore.shared.restoreByEmail(email: email, code: code)
                            working = false
                            result = error ?? "Аккаунт восстановлен."
                            done = error == nil
                        }
                    }
                    .disabled(working || EmailAddress.normalizeCode(code) == nil)
                    Button("Ввести другой адрес") { codeSent = false; code = "" }
                }
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
        .navigationTitle("Восстановить по почте")
        .navigationBarTitleDisplayMode(.inline)
    }
}
