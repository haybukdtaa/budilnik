import SwiftUI

/// Текст одного документа.
struct LegalDocumentView: View {
    let kind: LegalDocumentKind

    var body: some View {
        let document = LegalTexts.document(kind)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !LegalOperator.isFilled {
                    Label("Черновик: данные оператора ещё не заполнены. Перед публикацией приложения заполните их в LegalTexts.swift и покажите тексты юристу.", systemImage: "exclamationmark.triangle")
                        .font(.app(.footnote))
                        .foregroundStyle(.orange)
                }
                Text("Редакция от \(LegalVersion.dateText)")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                ForEach(document.sections) { section in
                    Text(section.heading)
                        .font(.app(.headline))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.paragraphs, id: \.self) { paragraph in
                        Text(paragraph).font(.app(.body))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Выбор человека на экране согласий. Ничего не отмечено заранее.
struct ConsentChoice: Equatable {
    var terms = false
    var personalData = false
    var specialData = false
    var distribution = false
    var marketing = false

    subscript(kind: ConsentKind) -> Bool {
        get {
            switch kind {
            case .terms: return terms
            case .personalData: return personalData
            case .specialData: return specialData
            case .distribution: return distribution
            case .marketing: return marketing
            }
        }
        set {
            switch kind {
            case .terms: terms = newValue
            case .personalData: personalData = newValue
            case .specialData: specialData = newValue
            case .distribution: distribution = newValue
            case .marketing: marketing = newValue
            }
        }
    }

    /// Текущее состояние согласий (для повторного показа окна).
    @MainActor
    static func current(_ settings: AppSettings) -> ConsentChoice {
        var choice = ConsentChoice()
        for kind in ConsentKind.allCases {
            choice[kind] = ConsentRules.isGranted(kind, in: settings.data.consents)
        }
        return choice
    }

    /// Записывает выбор. Соглашение записывается всегда (в том числе отказ), чтобы не спрашивать снова.
    @MainActor
    func apply(to settings: AppSettings) {
        for kind in ConsentKind.allCases {
            let existing = settings.data.consents[kind.rawValue]
            // Согласие на старую редакцию, которое не подтвердили заново, не считается отзывом: сервер об этом не уведомляем.
            if let existing, existing.granted, existing.version != LegalVersion.current, !self[kind] { continue }
            if kind == .terms || existing != nil || self[kind] {
                settings.setConsent(kind, granted: self[kind])
            }
        }
    }
}

/// Список согласий с отдельными галочками.
struct ConsentChoiceForm: View {
    @Binding var choice: ConsentChoice
    var showSpecial: Bool
    @State private var reading: LegalDocumentKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(.terms, documents: [.terms, .privacy])
            row(.personalData, documents: [.personalData])
            if showSpecial { row(.specialData, documents: [.specialData]) }
            row(.distribution, documents: [.distribution])
            row(.marketing, documents: [])
        }
        .sheet(item: $reading) { kind in
            NavigationStack {
                LegalDocumentView(kind: kind)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { reading = nil } }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func row(_ kind: ConsentKind, documents: [LegalDocumentKind]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { choice[kind] }, set: { choice[kind] = $0 })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title).font(.app(.subheadline, weight: .semibold))
                    Text(kind.summary).font(.app(.caption)).foregroundStyle(.secondary)
                }
            }
            if !documents.isEmpty {
                HStack(spacing: 14) {
                    ForEach(documents) { document in
                        Button("Читать: \(shortTitle(document))") { reading = document }
                            .font(.app(.caption))
                    }
                }
            }
            if kind.requiredForServer {
                Text("Нужно для друзей, сообщества и восстановления. Будильники работают и без этого.")
                    .font(.app(.caption2))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func shortTitle(_ kind: LegalDocumentKind) -> String {
        switch kind {
        case .terms: return "соглашение"
        case .privacy: return "политику"
        default: return "текст согласия"
        }
    }
}

/// Окно «документы обновились / решите, что разрешить». Закрыть можно: будильники от этого не зависят.
struct ConsentGateSheet: View {
    @EnvironmentObject private var settings: AppSettings
    let onClose: () -> Void
    @State private var choice = ConsentChoice()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Документы и согласия")
                        .font(.app(.title2, weight: .bold))
                    Text("Выберите, что вы разрешаете. Каждая галочка отдельная и ничего не включено заранее. Позже всё можно изменить в Профиль → Документы и согласия.")
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)
                    ConsentChoiceForm(choice: $choice, showSpecial: settings.isEnabled(.prayer))
                    Button {
                        choice.apply(to: settings)
                        onClose()
                    } label: {
                        Text("Сохранить выбор")
                            .font(.app(.headline))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                    Button("Позже", action: onClose)
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
            .background(Theme.background)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                choice = ConsentChoice.current(settings)
            }
        }
    }
}

/// Запрос одного согласия в момент, когда оно понадобилось (например, при включении переключателя).
struct ConsentRequestSheet: View {
    @EnvironmentObject private var settings: AppSettings
    let kind: ConsentKind
    let onGranted: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// Особые согласия имеют смысл только вместе с соглашением и согласием на обработку.
    private var blocked: Bool { !kind.requiredForServer && kind != .marketing && !ConsentRules.serverAllowed(settings.data.consents) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(kind.title).font(.app(.title3, weight: .bold))
                    Text(kind.summary)
                    if blocked {
                        Text("Сначала дайте согласие на условия и на обработку персональных данных (Профиль → Документы и согласия): без них серверные функции выключены.")
                            .font(.app(.footnote)).foregroundStyle(.orange)
                    }
                    if let document = kind.document {
                        NavigationLink("Прочитать полный текст") { LegalDocumentView(kind: document) }
                    }
                    Button {
                        settings.setConsent(kind, granted: true)
                        onGranted()
                        dismiss()
                    } label: {
                        Text("Согласен")
                            .font(.app(.headline))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                    .disabled(blocked).opacity(blocked ? 0.4 : 1)
                    Button("Не сейчас") { dismiss() }
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
            .background(Theme.background)
        }
        .presentationDetents([.medium, .large])
    }
}

/// Профиль → Документы и согласия.
struct ConsentsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var requesting: ConsentKind?
    @State private var withdrawing: ConsentKind?
    @State private var exportURL: URL?
    @State private var exportNote: String?
    @State private var preparing = false

    var body: some View {
        List {
            Section("Документы") {
                ForEach(LegalDocumentKind.allCases) { kind in
                    NavigationLink(kind.title) { LegalDocumentView(kind: kind) }
                }
            }

            Section {
                ForEach(ConsentKind.allCases) { kind in
                    if kind != .specialData || settings.isEnabled(.prayer) || ConsentRules.isGranted(.specialData, in: settings.data.consents) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: binding(kind)) {
                                Text(kind.title).font(.app(.body))
                            }
                            Text(kind.summary).font(.app(.caption)).foregroundStyle(.secondary)
                            if let entry = settings.data.consents[kind.rawValue] {
                                Text("\(entry.granted ? "Дано" : "Отозвано") \(Format.dateTime(entry.date)), редакция \(entry.version)\(entry.version == LegalVersion.current ? "" : " (устарела)")")
                                    .font(.app(.caption2))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Согласия")
            } footer: {
                Text("Согласие можно отозвать в любой момент. Серверные возможности (друзья, сообщество, восстановление) работают, только пока даны соглашение и согласие на обработку данных.")
            }

            Section {
                NavigationLink("Какие данные где хранятся") { DataMapView() }
                Button(preparing ? "Готовим файл…" : "Подготовить копию моих данных") {
                    preparing = true
                    Task {
                        let result = await DataExport.prepare()
                        exportURL = result.url
                        exportNote = result.note
                        preparing = false
                    }
                }
                .disabled(preparing)
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Сохранить или отправить файл", systemImage: "square.and.arrow.up")
                    }
                }
                if let exportNote {
                    Text(exportNote).font(.app(.footnote)).foregroundStyle(.secondary)
                }
            } header: {
                Text("Ваши права")
            } footer: {
                Text("В копию входят данные с телефона и, если сервер подключён, данные аккаунта с сервера. Секреты и код восстановления в неё не попадают. Удалить всё можно в Профиль → Данные. Обращения оператору: \(LegalOperator.email).")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Документы и согласия")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $requesting) { kind in
            ConsentRequestSheet(kind: kind) {}
                .preferredColorScheme(.dark)
        }
        .confirmationDialog(
            "Отозвать согласие?",
            isPresented: Binding(get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Отозвать", role: .destructive) {
                if let kind = withdrawing { settings.setConsent(kind, granted: false) }
                withdrawing = nil
            }
            Button("Оставить", role: .cancel) { withdrawing = nil }
        } message: {
            Text(withdrawMessage(withdrawing))
        }
    }

    private func binding(_ kind: ConsentKind) -> Binding<Bool> {
        Binding(
            get: { ConsentRules.isGranted(kind, in: settings.data.consents) },
            set: { on in
                if on { requesting = kind } else { withdrawing = kind }
            }
        )
    }

    private func withdrawMessage(_ kind: ConsentKind?) -> String {
        switch kind {
        case .terms?: return "Друзья, сообщество и восстановление перестанут работать. Будильники и всё на телефоне останутся."
        case .personalData?: return "Приложение перестанет обмениваться данными с сервером. Данные на сервере удалятся в течение 30 дней. Будильники останутся."
        case .specialData?: return "Данные о намазе перестанут передаваться, а сохранённые на сервере удалятся в течение 30 дней."
        case .distribution?: return "Вы пропадёте из таблиц и клубов, показ прекратится."
        default: return "Рассылка прекратится."
        }
    }
}

/// Где что хранится: простая таблица.
struct DataMapView: View {
    private struct Row: Identifiable {
        let id = UUID()
        let what: String
        let phone: Bool
        let server: String
    }

    private let rows = [
        Row(what: "Будильники и результаты заданий", phone: true, server: "На сервер — только с согласием на обработку данных"),
        Row(what: "Дневник подъёмов, прогресс, дерево", phone: true, server: "На сервер — только с согласием; друзьям — только то, что вы разрешили"),
        Row(what: "Заметки себе, причина «Зачем я встаю», чек-листы", phone: true, server: "Не передаются"),
        Row(what: "Лекарства", phone: true, server: "Не передаются никогда"),
        Row(what: "Утренние фото, записи голоса", phone: true, server: "Не передаются"),
        Row(what: "Данные о намазе", phone: true, server: "Только с отдельным согласием"),
        Row(what: "Имя и аватар", phone: true, server: "С согласием; в таблицах и клубах — с согласием на распространение"),
        Row(what: "Электронная почта", phone: true, server: "Только если вы сами привязали её для восстановления"),
        Row(what: "Код восстановления (16 слов)", phone: true, server: "Не передаётся: на сервер уходит только производный секрет"),
        Row(what: "Суммы обязательств и платежи", phone: true, server: "Нужны для расчёта; другим людям не показываются"),
    ]

    var body: some View {
        List(rows) { row in
            VStack(alignment: .leading, spacing: 3) {
                Text(row.what).font(.app(.body))
                Text(row.server).font(.app(.caption)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Какие данные где хранятся")
        .navigationBarTitleDisplayMode(.inline)
    }
}
