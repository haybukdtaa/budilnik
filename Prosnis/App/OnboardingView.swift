import SwiftUI

/// Первый запуск: идея, модули, профиль, разрешения.
struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var page = 0
    @State private var modules: Set<WakeModule> = [.basic]
    @State private var name = ""
    @State private var reason = ""
    @State private var isAdult = false
    @State private var permissionText: String?

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                intro(
                    icon: "alarm.waves.left.and.right",
                    title: "Будильник, который заставляет встать",
                    text: "Чтобы выключить звонок, нужно выполнить задание. Через 10 минут будильник проверит, что вы не уснули снова."
                ).tag(0)
                intro(
                    icon: "tree",
                    title: "Серия, дерево и друзья",
                    text: "Каждый подъём растит ваше дерево и серию. Друзья видят только то, что вы сами разрешили. Ставки и деньги не видит никто."
                ).tag(1)
                modulesPage.tag(2)
                profilePage.tag(3)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < 3 {
                    withAnimation { page += 1 }
                } else {
                    finish()
                }
            } label: {
                Text(page < 3 ? "Дальше" : "Начать")
                    .font(.app(.headline))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func intro(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 72))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.app(.title).bold())
                .multilineTextAlignment(.center)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }

    private var modulesPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Для чего вам будильник?")
                .font(.app(.title2).bold())
                .padding(.top, 32)
            Text("Можно выбрать несколько. Изменить можно в Профиле.")
                .foregroundStyle(.secondary)
            ForEach(WakeModule.allCases) { module in
                Button {
                    if modules.contains(module) { modules.remove(module) } else { modules.insert(module) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: module.icon).frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(module.title).font(.app(.headline))
                            Text(module.subtitle).font(.app(.caption)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: modules.contains(module) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(modules.contains(module) ? Theme.accent : Color.secondary)
                    }
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            if modules.contains(.prayer) {
                Text("Всё, что связано с намазом, остаётся на телефоне, пока вы сами не разрешите иное.")
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private var profilePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Пара деталей")
                .font(.app(.title2).bold())
                .padding(.top, 32)
            TextField("Ваше имя для друзей", text: $name)
                .padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            TextField("Зачем вы хотите вставать вовремя? (необязательно)", text: $reason, axis: .vertical)
                .lineLimit(1...3)
                .padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            Toggle("Мне \(AppConfig.adultAge) лет или больше", isOn: $isAdult)
            Text("Нужно для ставок и чатов. Без этого будильник, задания и прогресс работают полностью.")
                .font(.app(.footnote))
                .foregroundStyle(.secondary)
            Button("Разрешить будильники") {
                Task {
                    let granted = await AlarmService.shared.requestAuthorization()
                    permissionText = granted
                        ? "Готово: будильники будут звонить даже на заблокированном телефоне."
                        : "Без разрешения будильники не зазвонят. Включить можно в Настройках iPhone."
                }
            }
            .buttonStyle(.bordered)
            if let permissionText {
                Text(permissionText).font(.app(.footnote)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func finish() {
        var data = settings.data
        data.modules = WakeModule.allCases.filter { modules.contains($0) }
        if data.modules.isEmpty { data.modules = [.basic] }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { data.profile.displayName = trimmed }
        data.isAdult = isAdult
        data.wakeReason = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        data.onboardingDone = true
        settings.data = data
    }
}
