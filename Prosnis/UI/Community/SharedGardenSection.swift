import SwiftUI

/// Общие сады с друзьями: одно дерево на 3–5 человек, его поливает каждое успешное утро.
struct SharedGardenSection: View {
    @EnvironmentObject private var social: SocialStore
    @State private var showCreate = false
    @State private var showJoin = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Растите дерево вместе").font(.headline)
                    Text("Каждое ваше успешное утро поливает общее дерево. Если кто-то проспал, дерево не вянет — просто в этот день растёт меньше. А если полили все, оно растёт вдвое быстрее. Друзья видят, полили ли вы сегодня и сколько раз всего. Время будильника и деньги им не видны.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))

                ForEach(social.gardens) { garden in
                    GardenCard(garden: garden)
                }

                HStack {
                    Button {
                        showCreate = true
                    } label: {
                        Label("Посадить сад", systemImage: "leaf.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        showJoin = true
                    } label: {
                        Label("Войти по коду", systemImage: "key.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
        }
        .refreshable { await social.refresh() }
        .sheet(isPresented: $showCreate) { CreateGardenView() }
        .sheet(isPresented: $showJoin) { JoinGardenView() }
    }
}

private struct GardenCard: View {
    @EnvironmentObject private var social: SocialStore
    @EnvironmentObject private var settings: AppSettings
    let garden: SharedGarden
    @State private var confirmLeave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                TreeView(stage: garden.stage, wilt: 0, species: garden.species)
                    .frame(width: 100, height: 120)
                VStack(alignment: .leading, spacing: 4) {
                    Text(garden.name).font(.title3.bold())
                    Text("\(garden.species.title) · \(TreeState.stageTitles[min(garden.stage, 7)])")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Сегодня полили: \(garden.wateredToday) из \(garden.members.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(garden.wateredToday == garden.members.count ? Color.green : Theme.accent)
                    if let left = garden.toNextStage {
                        Text("До следующей стадии: \(left) \(HoursWon.plural(left, "полив", "полива", "поливов"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Дерево выросло полностью!").font(.caption).foregroundStyle(.green)
                    }
                }
                Spacer(minLength: 0)
            }

            ForEach(garden.members) { member in
                HStack {
                    AvatarView(profile: member.profile, size: 30)
                    Text(member.profile.id == settings.data.profile.id ? "Вы" : member.profile.displayName)
                    if member.isOwner {
                        Image(systemName: "crown.fill").font(.caption).foregroundStyle(.yellow)
                    }
                    Spacer()
                    Text("\(member.waterings)").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: member.wateredToday ? "drop.fill" : "drop")
                        .foregroundStyle(member.wateredToday ? Color.blue : Color.secondary)
                }
            }

            HStack {
                if garden.members.count < SharedGarden.maxMembers {
                    ShareLink(item: "Присоединяйся к нашему саду в «Проснись»: код \(garden.inviteCode)") {
                        Label("Позвать друга · \(garden.inviteCode)", systemImage: "person.badge.plus")
                    }
                } else {
                    Text("В саду максимум \(SharedGarden.maxMembers) человек").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Выйти", role: .destructive) { confirmLeave = true }
                    .font(.footnote)
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        .confirmationDialog("Выйти из сада «\(garden.name)»?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { Task { await social.leaveGarden(garden) } }
        }
    }
}

private struct CreateGardenView: View {
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Утренний сад"
    @State private var species: TreeSpecies = .oak

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $name)
                Picker("Дерево", selection: $species) {
                    ForEach(TreeSpecies.allCases) { Text($0.title).tag($0) }
                }
                Section {
                    Text("После создания вы получите код. Отправьте его 2–4 друзьям: в саду до \(SharedGarden.maxMembers) человек.")
                        .foregroundStyle(.secondary)
                }
            }
            .alert("Сад", isPresented: Binding(get: { social.errorText != nil }, set: { if !$0 { social.errorText = nil } })) {
                Button("Понятно", role: .cancel) {}
            } message: {
                Text(social.errorText ?? "")
            }
            .navigationTitle("Новый сад")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Посадить") {
                        let cleaned = ContentFilter.clean(name.trimmingCharacters(in: .whitespacesAndNewlines))
                        Task {
                            if await social.createGarden(GardenDraft(name: cleaned.isEmpty ? "Утренний сад" : cleaned, species: species)) {
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct JoinGardenView: View {
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Код из 6 символов", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            .alert("Сад", isPresented: Binding(get: { social.errorText != nil }, set: { if !$0 { social.errorText = nil } })) {
                Button("Понятно", role: .cancel) {}
            } message: {
                Text(social.errorText ?? "")
            }
            .navigationTitle("Войти в сад")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Войти") {
                        Task { if await social.joinGarden(code: code) { dismiss() } }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespaces).count != 6)
                }
            }
        }
    }
}
