import SwiftUI

/// Вкладка «Профиль»: имя, модули, приватность, деньги, данные.
struct ProfileView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var challenges: ChallengeStore
    @EnvironmentObject private var sync: SyncEngine
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteError: String?

    var body: some View {
        let snapshot = ProgressEngine.compute(entries: journal.realEntries, challenges: challenges.challenges)
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ProfileEditView()
                    } label: {
                        HStack(spacing: 14) {
                            AvatarView(profile: settings.data.profile, size: 56)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(settings.data.profile.displayName).font(.title3.bold())
                                Text("\(snapshot.title) · уровень \(snapshot.level) · серия \(snapshot.currentStreak)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        WakeReasonView()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Зачем я встаю", systemImage: "heart.text.square")
                            Text(settings.wakeReason.map { "«\($0)»" } ?? "Напишите свою причину: она будет на экране задания и утром")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }

                Section("Настройки") {
                    NavigationLink { ModulesView() } label: { Label("Модули и чек-листы", systemImage: "square.grid.2x2") }
                    NavigationLink { PrivacyView() } label: { Label("Приватность", systemImage: "hand.raised") }
                    NavigationLink { PaymentsView() } label: { Label("Ставки и платежи", systemImage: "creditcard") }
                }

                Section {
                    Toggle("Мне \(AppConfig.adultAge) лет или больше", isOn: $settings.data.isAdult)
                } footer: {
                    Text("Ставки и чаты доступны только совершеннолетним.")
                }

                Section {
                    Toggle("Демо-режим сообщества", isOn: $settings.data.useDemoSocial)
                    if !settings.data.blockedUsers.isEmpty {
                        Button("Разблокировать всех (\(settings.data.blockedUsers.count))") {
                            SocialStore.shared.unblockAll()
                        }
                    }
                } header: {
                    Text("Сообщество")
                } footer: {
                    Text(AccountStore.shared.signInProblem ?? (AppConfig.serverURL == nil
                         ? "Сервер ещё не подключён. Демо-режим показывает вымышленных людей; ваши данные никуда не уходят."
                         : "Сервер подключён."))
                }

                Section {
                    HStack {
                        Text("Ждут отправки на сервер")
                        Spacer()
                        Text("\(sync.items.count)").foregroundStyle(.secondary)
                    }
                    Button("Удалить аккаунт и все данные", role: .destructive) { confirmDelete = true }
                        .disabled(deleting)
                } header: {
                    Text("Данные")
                } footer: {
                    Text("Удаляются будильники, журнал, челленджи, настройки и фоны на телефоне, а при подключённом сервере и аккаунт на нём.")
                }

                Section("О приложении") {
                    HStack {
                        Text("Версия")
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                            .foregroundStyle(.secondary)
                    }
                    Text("Производственный календарь РФ заложен на 2026 и 2027 годы (постановление № 1187 от 17.09.2026). Для других лет учитываются праздники и обычные переносы.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Профиль")
            .confirmationDialog("Удалить всё безвозвратно?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Удалить всё", role: .destructive) {
                    deleting = true
                    Task {
                        deleteError = await AccountStore.shared.deleteAccountAndData()
                        deleting = false
                    }
                }
            } message: {
                Text("Отменить это действие нельзя.")
            }
            .alert(
                "Не удалось удалить",
                isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
            ) {
                Button("Понятно", role: .cancel) {}
            } message: {
                Text(deleteError ?? "")
            }
        }
    }
}

/// «Зачем я встаю»: своя причина. Видна только владельцу.
struct WakeReasonView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var text = ""

    static let examples = [
        "Утро — единственное время только для меня",
        "Хочу успевать на тренировку до работы",
        "Чтобы дети видели меня бодрым",
        "Каждый подъём приближает меня к цели",
    ]

    var body: some View {
        Form {
            Section {
                TextField("Например: хочу успевать всё до обеда", text: $text, axis: .vertical)
                    .lineLimit(2...4)
            } footer: {
                Text("Фраза показывается на экране задания, утром и вечером. Её видите только вы.")
            }
            Section("Примеры") {
                ForEach(WakeReasonView.examples, id: \.self) { example in
                    Button(example) { text = example }
                }
            }
        }
        .navigationTitle("Зачем я встаю")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = settings.data.wakeReason }
        // Сохраняем сразу, чтобы текст не пропал, если приложение закроют во время правки.
        .onChange(of: text) { _, value in settings.data.wakeReason = String(value.prefix(200)) }
    }
}

struct ProfileEditView: View {
    @EnvironmentObject private var settings: AppSettings

    static let avatars = ["🌅", "🦅", "🐺", "🦉", "🐻", "🦊", "🌸", "🌙", "☀️", "🔥", "🏃", "📚", "☕️", "🍀", "⚡️", "🎯"]

    var body: some View {
        Form {
            Section("Имя") {
                TextField("Как вас видят друзья", text: $settings.data.profile.displayName)
            }
            Section("Аватар") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                    ForEach(ProfileEditView.avatars, id: \.self) { emoji in
                        Text(emoji)
                            .font(.title2)
                            .frame(width: 36, height: 36)
                            .background(settings.data.profile.avatar == emoji ? Theme.accent.opacity(0.35) : Color.clear, in: Circle())
                            .onTapGesture { settings.data.profile.avatar = emoji }
                    }
                }
            }
        }
        .navigationTitle("Профиль")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Встал или нет", isOn: $settings.data.privacy.shareWakeStatus)
                Toggle("Время подъёма", isOn: $settings.data.privacy.shareWakeTime)
                Toggle("Серия", isOn: $settings.data.privacy.shareStreak)
                Toggle("Уровень", isOn: $settings.data.privacy.shareLevel)
                Toggle("Дерево", isOn: $settings.data.privacy.shareTree)
            } header: {
                Text("Что могут видеть друзья")
            } footer: {
                Text("Всё выключено по умолчанию. Для каждого друга можно сузить список в его карточке. Ставки, деньги и журнал не видит никто.")
            }

            Section {
                Toggle("Участвовать в таблицах", isOn: $settings.data.privacy.joinLeaderboards)
            } footer: {
                Text("В таблицах видны имя, аватар и результат. Без участия вы видите таблицы, но вас в них нет.")
            }

            if settings.isEnabled(.prayer) {
                Section {
                    Toggle("Показывать подъём на Фаджр", isOn: $settings.data.privacy.sharePrayer)
                    Toggle("Хранить данные о намазе на сервере", isOn: $settings.data.privacy.syncPrayerData)
                } header: {
                    Text("Намаз")
                } footer: {
                    Text("Это сведения о религиозных взглядах, закон относит их к особой категории. Без этих переключателей будильники и утра по Фаджру остаются только на телефоне и не учитываются в статусе для друзей.")
                }
            }
        }
        .navigationTitle("Приватность")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PaymentsView: View {
    @EnvironmentObject private var payments: PaymentsStore
    @State private var checking = false

    var body: some View {
        List {
            Section {
                Label(payments.provider.title, systemImage: payments.isTraining ? "graduationcap" : "creditcard")
                if let status = payments.lastStatus {
                    HStack {
                        Image(systemName: status.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(status.isOK ? Color.green : Color.orange)
                        VStack(alignment: .leading) {
                            Text(status.message)
                            Text("Проверено \(Format.dateTime(status.checkedAt))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(checking ? "Проверяем…" : "Проверить способ оплаты") {
                    checking = true
                    Task {
                        await payments.checkIfNeeded(now: .distantFuture)
                        checking = false
                    }
                }
                .disabled(checking)
            } header: {
                Text("Способ оплаты")
            } footer: {
                Text("Сейчас ставки тренировочные: операции записываются, но деньги не двигаются. Карта и СБП подключаются после регистрации, без переделки остального приложения.")
            }

            Section("Операции (видны только вам)") {
                if payments.ledger.isEmpty {
                    Text("Операций пока не было.").foregroundStyle(.secondary)
                }
                ForEach(payments.ledger) { record in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(record.kind.title)
                            Text(Format.dateTime(record.date) + (record.isTraining ? " · тренировка" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(record.amount) ₽").monospacedDigit()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Ставки и платежи")
        .navigationBarTitleDisplayMode(.inline)
    }
}
