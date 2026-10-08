import SwiftUI

/// Вкладка «Лекарства»: что принять сегодня и список лекарств. Ничего лишнего.
struct MedsView: View {
    @ObservedObject private var store = MedStore.shared
    @State private var editing: Medication?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                List {
                    if store.loudWithoutPermission {
                        Section {
                            Label("Громкие напоминания не работают: нет разрешения на будильники. Пока приходят тихие уведомления. Разрешите будильники в Настройках iPhone → Prosnis.",
                                  systemImage: "exclamationmark.circle")
                                .font(.app(.footnote))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    if store.meds.isEmpty {
                        emptyState
                    } else {
                        todaySection(now: context.date)
                        Section("Мои лекарства") {
                            ForEach(store.meds) { med in
                                NavigationLink {
                                    MedDetailView(medicationID: med.id)
                                } label: {
                                    MedListRow(med: med)
                                }
                            }
                        }
                    }
                    Section {
                    } footer: {
                        Text("Приложение только напоминает. Схему приёма назначает врач. Сведения о лекарствах не уходят на сервер и друзьям.")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .background(Theme.background)
            .navigationTitle("Лекарства")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = Medication()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { med in
                MedEditView(original: med)
            }
        }
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "pills")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.mint)
                Text("Добавьте лекарство").font(.app(.title3))
                Text("Напомним вовремя, подскажем про еду и предупредим, когда упаковка будет заканчиваться.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Добавить") { editing = Medication() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.mint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    @ViewBuilder
    private func todaySection(now: Date) -> some View {
        let doses = store.todayDoses(now: now)
        Section {
            if doses.isEmpty {
                Text("Сегодня приёмов нет").foregroundStyle(.secondary)
            }
            ForEach(doses) { dose in
                if let med = store.med(dose.medicationID) {
                    DoseRow(dose: dose, med: med, state: store.state(of: dose, now: now))
                }
            }
        } header: {
            Text("Сегодня")
        } footer: {
            if !doses.isEmpty {
                let taken = doses.filter { if case .taken = store.state(of: $0, now: now) { return true } else { return false } }.count
                Text("Принято \(taken) из \(doses.count)")
            }
        }
    }
}

/// Один приём на сегодня. Кружок справа — отметить «принял(а)»; удержание — пропустить или снять отметку.
private struct DoseRow: View {
    @ObservedObject private var store = MedStore.shared
    let dose: Dose
    let med: Medication
    let state: DoseState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: med.form.icon)
                .font(.system(size: 18))
                .foregroundStyle(Theme.mint)
                .frame(width: 34, height: 34)
                .background(Theme.mint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(med.name).font(.app(.headline))
                Text(details).font(.app(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.time(dose.scheduled))
                .font(.app(.subheadline))
                .monospacedDigit()
                .foregroundStyle(isTaken ? .secondary : .primary)
            Button {
                if isTaken { store.unmark(dose) } else { store.mark(medicationID: dose.medicationID, scheduled: dose.scheduled, .taken) }
            } label: {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(isTaken ? Theme.mint : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isTaken ? "Снять отметку" : "Принял(а)")
        }
        .opacity(state == .skipped || state == .missed ? 0.55 : 1)
        .contextMenu {
            if isTaken || state == .skipped {
                Button("Снять отметку", systemImage: "arrow.uturn.backward") { store.unmark(dose) }
            } else {
                Button("Принял(а)", systemImage: "checkmark") { store.mark(medicationID: dose.medicationID, scheduled: dose.scheduled, .taken) }
                Button("Пропустить", systemImage: "forward") { store.mark(medicationID: dose.medicationID, scheduled: dose.scheduled, .skipped) }
            }
        }
    }

    private var isTaken: Bool {
        if case .taken = state { return true }
        return false
    }

    private var icon: String {
        switch state {
        case .taken: return "checkmark.circle.fill"
        case .skipped, .missed: return "minus.circle"
        case .due, .upcoming: return "circle"
        }
    }

    private var details: String {
        var parts: [String] = []
        if !med.dose.isEmpty { parts.append(med.dose) }
        if let hint = med.meal.hint { parts.append(hint) }
        switch state {
        case .taken(let at): parts.append("принято в \(Format.time(at))")
        case .skipped: parts.append("пропущено")
        case .missed: parts.append("не отмечено")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

/// Лекарство в списке: расписание и предупреждение о запасе.
private struct MedListRow: View {
    let med: Medication

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: med.form.icon)
                .foregroundStyle(Theme.mint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(med.name).font(.app(.headline))
                Text(MedText.schedule(med)).font(.app(.caption)).foregroundStyle(.secondary)
                if med.needsRefill, let days = med.daysLeft {
                    Text(days == 0 ? "Закончилось — пора купить" : "Осталось на \(Words.days(days)) — пора купить")
                        .font(.app(.caption))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

enum MedText {
    static func schedule(_ med: Medication) -> String {
        var text: String
        if let minutes = med.afterWakeMinutes {
            text = minutes == 0 ? "сразу после подъёма" : "через \(minutes) мин после подъёма"
        } else {
            text = med.times.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }.joined(separator: ", ")
        }
        if let end = med.endDate { text += " · до \(Format.fullDate(end))" }
        if med.loud { text += " · громко" }
        return text
    }
}

/// Подробно: календарь приёмов за месяц и спокойные отметки.
struct MedDetailView: View {
    @ObservedObject private var store = MedStore.shared
    let medicationID: UUID
    @State private var editing: Medication?

    var body: some View {
        if let med = store.med(medicationID) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: med.form.icon)
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.mint)
                            .frame(width: 52, height: 52)
                            .background(Theme.mint.opacity(0.15), in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(med.name).font(.app(.title3))
                            Text([med.dose, med.meal.hint ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.app(.subheadline)).foregroundStyle(.secondary)
                            Text(MedText.schedule(med)).font(.app(.caption)).foregroundStyle(.secondary)
                        }
                    }
                    if let stock = med.stock {
                        HStack {
                            Text("В упаковке")
                            Spacer()
                            Text("\(stock) шт. · на \(Words.days(med.daysLeft ?? 0))").foregroundStyle(med.needsRefill ? Theme.accent : Color.secondary)
                        }
                    }
                }

                let now = context.date
                if MedSchedule.courseCompleted(med, records: store.records, wakeTimes: store.wakeTimes, now: now) {
                    Section {
                        Label("Курс пройден полностью", systemImage: "checkmark.seal").foregroundStyle(Theme.mint)
                    }
                } else if MedSchedule.cleanWeek(med, records: store.records, wakeTimes: store.wakeTimes, now: now) {
                    Section {
                        Label("Неделя без пропусков", systemImage: "leaf").foregroundStyle(Theme.mint)
                    }
                }

                Section("Последние 4 недели") {
                    MedCalendar(med: med)
                }
            }
            .scrollContentBackground(.hidden)
            }
            .background(Theme.background)
            .navigationTitle(med.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Изменить") { editing = med }
                }
            }
            .sheet(item: $editing) { MedEditView(original: $0) }
        } else {
            Text("Лекарство удалено").foregroundStyle(.secondary)
        }
    }
}

/// 28 дней кружками: принято, пропущено или без приёмов. Удобно показать врачу.
private struct MedCalendar: View {
    @ObservedObject private var store = MedStore.shared
    let med: Medication

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = (0..<28).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
                ForEach(days, id: \.self) { day in
                    let state = dayState(day)
                    VStack(spacing: 3) {
                        Circle()
                            .fill(state.fill)
                            .overlay(Circle().stroke(state.stroke, lineWidth: 1))
                            .frame(width: 22, height: 22)
                        Text("\(calendar.component(.day, from: day))").font(.app(.caption2)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 14) {
                legend(Theme.mint, "все приёмы")
                legend(Theme.mint.opacity(0.35), "часть")
                legend(Color.secondary.opacity(0.2), "пропуск")
            }
            .font(.app(.caption2))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title)
        }
    }

    private func dayState(_ day: Date) -> (fill: Color, stroke: Color) {
        let doses = store.doses(of: med, from: day, to: day.addingTimeInterval(86400))
        guard !doses.isEmpty else { return (.clear, Color.secondary.opacity(0.15)) }
        let now = Date()
        let taken = doses.filter { if case .taken = MedSchedule.state(of: $0, records: store.records, now: now) { return true } else { return false } }.count
        let pending = doses.filter {
            let state = MedSchedule.state(of: $0, records: store.records, now: now)
            return state == .due || state == .upcoming
        }.count
        if taken == doses.count { return (Theme.mint, .clear) }
        // Сегодня ещё ничего не отмечено, а время не вышло — день не «часть» и не «пропуск».
        if taken == 0 && pending > 0 { return (.clear, Theme.mint.opacity(0.5)) }
        if taken > 0 || pending > 0 { return (Theme.mint.opacity(0.35), .clear) }
        return (Color.secondary.opacity(0.2), .clear)
    }
}

/// Добавление и изменение лекарства: один экран, всё по порядку.
struct MedEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = MedStore.shared
    let original: Medication
    @State private var med = Medication()
    @State private var hasCourse = false
    @State private var countsStock = false
    @State private var confirmDelete = false

    private var isNew: Bool { store.med(original.id) == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $med.name)
                    TextField("Доза, например «1 таблетка»", text: $med.dose)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(MedForm.allCases) { form in
                                Button {
                                    med.form = form
                                } label: {
                                    Label(form.title, systemImage: form.icon)
                                        .font(.app(.subheadline))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(med.form == form ? Theme.mint.opacity(0.22) : Color.secondary.opacity(0.08), in: Capsule())
                                        .foregroundStyle(med.form == form ? Theme.ink : Color.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section {
                    Picker("Когда", selection: Binding(
                        get: { med.isAfterWake },
                        set: { med.afterWakeMinutes = $0 ? (med.afterWakeMinutes ?? 30) : nil }
                    )) {
                        Text("По часам").tag(false)
                        Text("После подъёма").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if let minutes = med.afterWakeMinutes {
                        Stepper(value: Binding(get: { minutes }, set: { med.afterWakeMinutes = $0 }), in: 0...240, step: 5) {
                            Text(minutes == 0 ? "Сразу после подъёма" : "Через \(minutes) мин после подъёма")
                        }
                        DatePicker("Если будильника не было", selection: minutesBinding(\.afterWakeFallback), displayedComponents: .hourAndMinute)
                    } else {
                        ForEach(med.times.indices, id: \.self) { index in
                            DatePicker("Приём \(index + 1)", selection: timeBinding(index), displayedComponents: .hourAndMinute)
                        }
                        .onDelete { offsets in
                            if med.times.count > 1 { med.times.remove(atOffsets: offsets) }
                        }
                        .deleteDisabled(med.times.count <= 1)
                        if med.times.isEmpty {
                            Button("Добавить время") { med.times = [9 * 60] }
                        } else if med.times.count < 6 {
                            Button("Добавить время") {
                                let last = med.times.max() ?? 9 * 60
                                med.times.append(min(last + 4 * 60, 23 * 60))
                            }
                        }
                    }

                    Picker("Еда", selection: $med.meal) {
                        ForEach(MealRelation.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Когда принимать")
                }

                Section {
                    Toggle("Курс до определённой даты", isOn: $hasCourse)
                    if hasCourse {
                        DatePicker("Последний день", selection: Binding(
                            get: { med.endDate ?? Date().addingTimeInterval(6 * 86400) },
                            set: { med.endDate = $0 }
                        ), in: Calendar.current.startOfDay(for: med.startDate)..., displayedComponents: .date)
                    }
                    Toggle("Считать запас", isOn: $countsStock)
                    if countsStock {
                        Stepper("В упаковке: \(med.stock ?? 0)", value: Binding(get: { med.stock ?? 0 }, set: { med.stock = $0 }), in: 0...999)
                        Stepper("За приём: \(med.unitsPerDose)", value: $med.unitsPerDose, in: 1...20)
                    }
                } header: {
                    Text("Курс и запас")
                } footer: {
                    if countsStock {
                        Text("Когда останется на \(Words.days(Medication.refillDays)), напомним купить.")
                    }
                }

                Section {
                    Picker("Напоминание", selection: $med.loud) {
                        Text("Тихое уведомление").tag(false)
                        Text("Громко, как будильник").tag(true)
                    }
                } footer: {
                    Text(med.loud
                         ? "Звонит даже в беззвучном режиме. На экране — «Принял(а)» и «Через \(MedStore.snoozeMinutes) минут»."
                         : "Обычное уведомление с кнопками «Принял(а)» и «Через \(MedStore.snoozeMinutes) минут».")
                }

                if !isNew {
                    Section {
                        Button("Удалить лекарство", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(isNew ? "Новое лекарство" : "Лекарство")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .disabled(med.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Удалить «\(med.name)» и все отметки?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    store.delete(med)
                    dismiss()
                }
            }
            .onAppear {
                med = original
                hasCourse = original.endDate != nil
                countsStock = original.stock != nil
            }
        }
    }

    private func save() {
        var item = med
        if !hasCourse {
            item.endDate = nil
        } else if item.endDate == nil {
            item.endDate = Date().addingTimeInterval(6 * 86400)
        }
        if !countsStock {
            item.stock = nil
        } else if item.stock == original.stock, let current = store.med(item.id) {
            // Пока экран был открыт, приём могли отметить с экрана блокировки: не затираем запас.
            item.stock = current.stock
        }
        if item.isAfterWake { item.times = [] } else if item.times.isEmpty { item.times = [9 * 60] }
        store.save(item)
        // Разрешение — только то, которое нужно: будильники для громких, уведомления для тихих.
        Task {
            if item.loud {
                _ = await AlarmService.shared.requestAuthorization()
            } else {
                _ = await DeadlineNotifications.requestPermission()
            }
            store.refresh()
        }
        dismiss()
    }

    private func timeBinding(_ index: Int) -> Binding<Date> {
        Binding(
            get: {
                let minutes = med.times.indices.contains(index) ? med.times[index] : 9 * 60
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                guard med.times.indices.contains(index) else { return }
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                med.times[index] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func minutesBinding(_ keyPath: WritableKeyPath<Medication, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = med[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                med[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

/// Строка на утреннем экране: что принять этим утром.
struct MorningMedsLine: View {
    @ObservedObject private var store = MedStore.shared

    var body: some View {
        let now = Date()
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        let morning = store.doses(from: now.addingTimeInterval(-3600), to: max(noon, now.addingTimeInterval(3600)))
            .filter { MedSchedule.record(for: $0, in: store.records) == nil }
        let names = morning.compactMap { dose -> String? in
            guard let med = store.med(dose.medicationID) else { return nil }
            return med.name + (med.meal.hint.map { " \($0)" } ?? "")
        }
        if !names.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "pills").foregroundStyle(Theme.mint)
                Text("Этим утром: " + Array(Set(names)).sorted().joined(separator: ", "))
                    .font(.app(.subheadline))
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}
