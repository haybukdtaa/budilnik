import SwiftUI

struct FriendsSection: View {
    @EnvironmentObject private var social: SocialStore
    @State private var showInvite = false

    var body: some View {
        List {
            if let stats = social.stats {
                StatsCard(stats: stats)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }

            Section {
                Button {
                    showInvite = true
                } label: {
                    Label("Пригласить или добавить друга", systemImage: "person.badge.plus")
                }
            }

            if !social.witnessNotices.isEmpty {
                Section {
                    ForEach(social.witnessNotices) { notice in
                        HStack(spacing: 12) {
                            AvatarView(profile: notice.friend, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(notice.friend.displayName) проспал(а)").font(.subheadline.weight(.semibold))
                                Text(Format.dayKey(notice.day)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Вы свидетель")
                } footer: {
                    Text("Поддержите друга сообщением. Суммы и ставки вам не сообщаются.")
                }
            }

            Section("Друзья") {
                if social.friends.isEmpty {
                    Text("Пока никого. Пригласите друга по коду.").foregroundStyle(.secondary)
                }
                ForEach(social.friends) { friend in
                    NavigationLink {
                        FriendDetailView(friendID: friend.id)
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(profile: friend.profile)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(friend.profile.displayName).font(.headline)
                                StatusLine(status: friend.status)
                            }
                            Spacer()
                            if let stage = friend.status?.treeStage {
                                TreeView(stage: stage, wilt: 0, species: friend.status?.treeSpecies ?? .oak)
                                    .frame(width: 34, height: 40)
                            }
                        }
                    }
                }
            }

            if !social.pairs.isEmpty {
                Section("Парные челленджи") {
                    ForEach(social.pairs) { pair in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(pair.title) · с \(pair.partner.displayName)").font(.subheadline.weight(.semibold))
                            Text("Вы: \(pair.myDays) из \(pair.durationDays) · \(pair.partner.displayName): \(pair.partnerDays) из \(pair.durationDays)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !social.rewards.isEmpty {
                Section("Награды за приглашения") {
                    ForEach(social.rewards) { reward in
                        HStack {
                            Image(systemName: reward.unlocked ? "gift.fill" : "lock.fill")
                                .foregroundStyle(reward.unlocked ? Theme.accent : Color.secondary)
                            VStack(alignment: .leading) {
                                Text(reward.title).font(.subheadline.weight(.semibold))
                                Text(reward.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await social.refresh() }
        .sheet(isPresented: $showInvite) { InviteSheet() }
    }
}

/// Приглашение: свой код и ввод кода друга.
struct InviteSheet: View {
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var added = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let invite = social.invite {
                        Text(invite.code)
                            .font(.system(size: 40, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                        ShareLink(item: "Добавь меня в «Проснись»: мой код \(invite.code)") {
                            Label("Отправить код", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button("Получить мой код") { Task { await social.createInvite() } }
                    }
                } header: {
                    Text("Мой код")
                } footer: {
                    Text("Код действует 7 дней. Когда приглашённый друг проведёт 7 утр, вы оба получите награду.")
                }

                Section("Код друга") {
                    TextField("Например, K7QX2M", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button("Добавить") {
                        Task {
                            added = await social.acceptInvite(code: code)
                            if added { dismiss() }
                        }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespaces).count < 6)
                }
            }
            .navigationTitle("Друзья")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }
}

struct FriendDetailView: View {
    @EnvironmentObject private var social: SocialStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let friendID: UUID

    @State private var visibility = Visibility()
    @State private var showPair = false
    @State private var confirmRemove = false

    private var friend: Friend? { social.friends.first { $0.id == friendID } }

    var body: some View {
        if let friend {
            List {
                Section {
                    HStack(spacing: 14) {
                        AvatarView(profile: friend.profile, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(friend.profile.displayName).font(.title2.bold())
                            Text("Друзья с \(Format.dateTime(friend.since))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    StatusLine(status: friend.status)
                    if let stage = friend.status?.treeStage {
                        HStack {
                            TreeView(stage: stage, wilt: 0, species: friend.status?.treeSpecies ?? .oak)
                                .frame(width: 60, height: 70)
                            Text(((friend.status?.treeSpecies?.title).map { "\($0) · " } ?? "")
                                 + TreeState.stageTitles[min(max(stage, 0), 7)])
                        }
                    }
                }

                Section {
                    if friend.status?.woke == false {
                        Button {
                            Task {
                                if await social.nudge(friend) {
                                    social.errorText = "Отправлено: \(friend.profile.displayName) получит мягкое напоминание."
                                }
                            }
                        } label: {
                            Label("Разбудить (осталось \(social.nudgesLeft(for: friend)))", systemImage: "bell.and.waves.left.and.right")
                        }
                        .disabled(social.nudgesLeft(for: friend) == 0)
                    }
                    NavigationLink {
                        ChatView(conversation: ConversationID(kind: .friend, id: friend.id), title: friend.profile.displayName)
                    } label: {
                        Label("Написать", systemImage: "bubble.left.and.bubble.right")
                    }
                    Button {
                        showPair = true
                    } label: {
                        Label("Парный челлендж", systemImage: "person.2.fill")
                    }
                }

                Section {
                    Toggle("Свидетель моих утр", isOn: Binding(
                        get: { settings.isWitness(friend.id) },
                        set: { settings.setWitness(friend.id, $0) }
                    ))
                } footer: {
                    Text("Если вы проспите, \(friend.profile.displayName) получит сообщение. Только сам факт: ни времени, ни суммы ставки. Подъём на Фаджр без вашего согласия не сообщается.")
                }

                Section {
                    Toggle("Встал или нет", isOn: $visibility.wakeStatus)
                    Toggle("Время подъёма", isOn: $visibility.wakeTime)
                    Toggle("Серия", isOn: $visibility.streak)
                    Toggle("Уровень", isOn: $visibility.level)
                    Toggle("Дерево", isOn: $visibility.tree)
                    if settings.data.privacy.sharePrayer {
                        Toggle("Подъём на Фаджр", isOn: $visibility.prayer)
                    }
                } header: {
                    Text("Что видит \(friend.profile.displayName)")
                } footer: {
                    Text("Работает только в пределах общих настроек приватности в Профиле. Деньги и ставки не видит никто.")
                }

                Section {
                    Button("Заблокировать", role: .destructive) {
                        Task {
                            await social.block(friend.profile)
                            await social.removeFriend(friend)
                            dismiss()
                        }
                    }
                    Button("Удалить из друзей", role: .destructive) { confirmRemove = true }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(friend.profile.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { visibility = friend.myVisibility }
            .onChange(of: visibility) { _, value in
                guard value != friend.myVisibility else { return }
                Task { await social.setVisibility(value, for: friend) }
            }
            .sheet(isPresented: $showPair) { PairCreateView(friend: friend) }
            .confirmationDialog("Удалить из друзей?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    Task {
                        await social.removeFriend(friend)
                        dismiss()
                    }
                }
            }
        } else {
            Text("Друг не найден").foregroundStyle(.secondary)
        }
    }
}

struct PairCreateView: View {
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss
    let friend: Friend
    @State private var title = "Встаём вовремя"
    @State private var days = 14

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $title)
                Stepper("Дней: \(days)", value: $days, in: 3...365)
                Text("Оба должны не сорваться. Прогресс виден вам обоим.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Вместе с \(friend.profile.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        Task {
                            await social.createPair(with: friend, title: title, days: days)
                            dismiss()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
