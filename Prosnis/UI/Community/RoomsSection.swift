import SwiftUI

struct RoomsSection: View {
    @EnvironmentObject private var social: SocialStore
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var joinCode = ""

    var body: some View {
        List {
            Section {
                Button { showCreate = true } label: { Label("Создать комнату или клуб", systemImage: "plus.circle") }
                Button { showJoin = true } label: { Label("Войти по коду", systemImage: "key") }
            }
            roomList(title: "Комнаты", rooms: social.rooms.filter { !$0.isClub })
            roomList(title: "Клубы", rooms: social.rooms.filter(\.isClub))
        }
        .scrollContentBackground(.hidden)
        .refreshable { await social.refresh() }
        .sheet(isPresented: $showCreate) { RoomCreateView() }
        .alert("Код комнаты", isPresented: $showJoin) {
            TextField("Например, FAM7Q2", text: $joinCode)
                .textInputAutocapitalization(.characters)
            Button("Войти") {
                let code = joinCode
                joinCode = ""
                Task { _ = await social.joinRoom(code: code) }
            }
            Button("Отмена", role: .cancel) { joinCode = "" }
        }
    }

    @ViewBuilder
    private func roomList(title: String, rooms: [Room]) -> some View {
        Section(title) {
            if rooms.isEmpty {
                Text(title == "Клубы" ? "Клубов пока нет" : "Комнат пока нет").foregroundStyle(.secondary)
            }
            ForEach(rooms) { room in
                NavigationLink {
                    RoomDetailView(roomID: room.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(room.name).font(.headline)
                        Text(room.topic ?? "\(room.members.count) участников")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let woke = room.members.filter { $0.status?.woke == true && Calendar.current.isDateInToday($0.status!.day) }.count
                        Text("Сегодня встали \(woke) из \(room.members.count)")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }
}

struct RoomCreateView: View {
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss

    static let clubTopics = ["5:00 club", "Бег по утрам", "Учёба до работы", "Чтение по утрам", "Утренний намаз", "Зарядка вместе"]

    @State private var name = ""
    @State private var isClub = false
    @State private var topic = ""
    @State private var rules = "Уважаем друг друга. Без рекламы и оскорблений."
    @State private var hasTarget = false
    @State private var target = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $name)
                    Toggle("Клуб по интересам", isOn: $isClub)
                } footer: {
                    Text("Комната — для своих: семьи, друзей, коллег. Клуб — для общего интереса. В обоих вход только по коду, до \(Room.maxMembers) участников.")
                }
                if isClub {
                    Section("Тема") {
                        Picker("Шаблон", selection: $topic) {
                            Text("Своя").tag("")
                            ForEach(RoomCreateView.clubTopics, id: \.self) { Text($0).tag($0) }
                        }
                        if !RoomCreateView.clubTopics.contains(topic) {
                            TextField("Тема клуба", text: $topic)
                        }
                    }
                    Section("Правила") {
                        TextField("Правила", text: $rules, axis: .vertical).lineLimit(2...5)
                    }
                }
                Section {
                    Toggle("Общая цель по времени", isOn: $hasTarget)
                    if hasTarget {
                        DatePicker("Встать не позже", selection: $target, displayedComponents: .hourAndMinute)
                            .environment(\.locale, Locale(identifier: "ru_RU"))
                    }
                }
            }
            .navigationTitle(isClub ? "Новый клуб" : "Новая комната")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: target)
                        let draft = RoomDraft(
                            name: name.trimmingCharacters(in: .whitespaces),
                            isClub: isClub,
                            topic: isClub && !topic.isEmpty ? topic : nil,
                            rules: isClub ? rules : nil,
                            targetWakeMinutes: hasTarget ? (parts.hour ?? 7) * 60 + (parts.minute ?? 0) : nil
                        )
                        Task {
                            if await social.createRoom(draft) != nil { dismiss() }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct RoomDetailView: View {
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss
    let roomID: UUID
    @State private var confirmLeave = false

    private var room: Room? { social.rooms.first { $0.id == roomID } }

    var body: some View {
        if let room {
            List {
                Section {
                    if let topic = room.topic { Text(topic).font(.headline) }
                    if let target = room.targetWakeMinutes {
                        Label("Цель: встать до \(String(format: "%02d:%02d", target / 60, target % 60))", systemImage: "target")
                    }
                    if let rules = room.rules { Text(rules).font(.footnote).foregroundStyle(.secondary) }
                    HStack {
                        Text("Код: \(room.inviteCode)").font(.system(.body, design: .monospaced))
                        Spacer()
                        ShareLink(item: "Заходи в «\(room.name)» в «Проснись»: код \(room.inviteCode)") {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }

                Section("Сад комнаты") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(room.members) { member in
                                VStack(spacing: 4) {
                                    TreeView(stage: member.status?.treeStage ?? 0, wilt: 0)
                                        .frame(width: 70, height: 80)
                                    Text(member.profile.displayName).font(.caption2)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Участники") {
                    ForEach(room.members) { member in
                        HStack(spacing: 12) {
                            AvatarView(profile: member.profile, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.profile.displayName + (member.isOwner ? " · создатель" : ""))
                                StatusLine(status: member.status)
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        ChatView(conversation: ConversationID(kind: .room, id: room.id), title: room.name)
                    } label: {
                        Label("Чат", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                    Button("Выйти", role: .destructive) { confirmLeave = true }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(room.name)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Выйти из «\(room.name)»?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) {
                    Task {
                        await social.leaveRoom(room)
                        dismiss()
                    }
                }
            }
        } else {
            Text("Комната не найдена").foregroundStyle(.secondary)
        }
    }
}

/// Чат с другом или в комнате.
struct ChatView: View {
    @EnvironmentObject private var social: SocialStore
    @EnvironmentObject private var settings: AppSettings
    let conversation: ConversationID
    let title: String
    @State private var text = ""

    var body: some View {
        let items = social.visibleMessages(conversation)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { message in
                            bubble(message).id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: items.count) { _, _ in
                    if let last = items.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            if settings.data.isAdult {
                HStack(spacing: 8) {
                    TextField("Сообщение", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(10)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                    Button {
                        let value = text
                        text = ""
                        Task { await social.send(value, to: conversation) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    }
                    .disabled(!ContentFilter.isSendable(text))
                }
                .padding(12)
            } else {
                Text("Чаты доступны с \(AppConfig.adultAge) лет. Подтвердить возраст можно в Профиле.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await social.loadMessages(conversation) }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let mine = message.author.id == settings.data.profile.id
        return HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if !mine {
                    Text(message.author.displayName).font(.caption2).foregroundStyle(.secondary)
                }
                Text(message.text)
                    .padding(10)
                    .background(mine ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.card),
                                in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(mine ? Color.black : Color.primary)
                Text(Format.time(message.sentAt)).font(.caption2).foregroundStyle(.secondary)
            }
            .contextMenu {
                if !mine {
                    Button("Пожаловаться", systemImage: "exclamationmark.bubble") {
                        Task { await social.report(message) }
                    }
                    Button("Заблокировать автора", systemImage: "hand.raised", role: .destructive) {
                        Task { await social.block(message.author) }
                    }
                }
            }
            if !mine { Spacer(minLength: 40) }
        }
    }
}
