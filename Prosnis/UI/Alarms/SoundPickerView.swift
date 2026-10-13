import SwiftUI

/// Список звуков по категориям. Нажатие выбирает звук и проигрывает пробный фрагмент.
struct SoundPickerView: View {
    @Binding var selection: String
    @ObservedObject private var voices = VoiceLibrary.shared
    @State private var deleteProblem: String?
    @State private var editingVoice: VoiceRecording?

    var body: some View {
        List {
            Section {
                ForEach(voices.recordings) { recording in
                    voiceRow(recording)
                        .swipeActions {
                            Button("Удалить", role: .destructive) { delete(recording) }
                            Button("Изменить") { editingVoice = recording }
                                .tint(Theme.burgundy)
                        }
                }
                NavigationLink {
                    VoiceRecorderView { soundID in
                        selection = soundID
                    }
                } label: {
                    Label("Записать свой голос", systemImage: "mic.fill")
                }
            } header: {
                Text("Мой голос")
            } footer: {
                Text("Запишите себе утреннее послание: «Вставай, сегодня важный день!». Запись до 30 секунд, хранится только на телефоне. Нажмите на карандаш, чтобы переименовать запись или записать её заново.")
            }

            ForEach(SoundCategory.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(SoundLibrary.options(in: category)) { option in
                        row(option)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Звук")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { SoundPreview.shared.stop() }
        .sheet(item: $editingVoice) { VoiceEditView(recording: $0) }
        .alert("Запись не удалена", isPresented: Binding(get: { deleteProblem != nil }, set: { if !$0 { deleteProblem = nil } })) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(deleteProblem ?? "")
        }
    }

    /// Своя запись: нажатие выбирает и проигрывает, карандаш открывает переименование и перезапись.
    private func voiceRow(_ recording: VoiceRecording) -> some View {
        let option = SoundLibrary.option(recording.soundID)
        return HStack(spacing: 12) {
            Button {
                selection = option.id
                SoundPreview.shared.play(option)
            } label: {
                HStack {
                    Image(systemName: "waveform").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording.title).foregroundStyle(.primary)
                        Text(Format.dateTime(recording.createdAt))
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if option.id == selection {
                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                    }
                }
            }
            .buttonStyle(.borderless)
            Button {
                editingVoice = recording
            } label: {
                Image(systemName: "pencil").foregroundStyle(Theme.accent)
            }
            .buttonStyle(.borderless)
        }
    }

    private func row(_ option: SoundOption) -> some View {
        Button {
            selection = option.id
            SoundPreview.shared.play(option)
        } label: {
            HStack {
                if option.isVoice {
                    Image(systemName: "waveform").foregroundStyle(Theme.accent)
                }
                Text(option.title).foregroundStyle(.primary)
                Spacer()
                if option.id == selection {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func delete(_ recording: VoiceRecording) {
        if recording.soundID == selection {
            deleteProblem = "Эта запись выбрана для будильника, который вы сейчас редактируете. Сначала выберите другой звук."
            return
        }
        let used = voices.alarmsUsing(recording.soundID)
        guard used.isEmpty else {
            let names = used.map(\.displayTitle).joined(separator: ", ")
            deleteProblem = "Эта запись стоит на будильниках: \(names). Сначала выберите для них другой звук."
            return
        }
        voices.delete(recording)
    }
}

/// Запись своего голоса для будильника.
struct VoiceRecorderView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VoiceRecorder()
    @State private var title = ""
    let onSaved: (String) -> Void

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    Image(systemName: recorder.state == .recording ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(recorder.state == .recording ? Color.red : Theme.accent)
                        .symbolEffect(.pulse, isActive: recorder.state == .recording)
                    Text(String(format: "%.0f / %.0f с", recorder.elapsed, VoiceLibrary.maxSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    controls
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } footer: {
                Text(message)
            }

            if recorder.state == .recorded {
                Section("Название") {
                    TextField(VoiceLibrary.defaultTitle(), text: $title)
                }
                Section {
                    Button("Сохранить и поставить на будильник") {
                        recorder.stopPlayback()
                        if let soundID = VoiceLibrary.shared.saveDraft(title: title) {
                            onSaved(soundID)
                            dismiss()
                        }
                    }
                    .bold()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Свой голос")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            if recorder.state == .recording { recorder.stop() }
            recorder.stopPlayback()
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch recorder.state {
        case .recording:
            Button("Остановить") { recorder.stop() }
                .buttonStyle(.stop)
        case .recorded:
            HStack {
                Button("Прослушать") { recorder.playDraft() }
                    .buttonStyle(.bordered)
                Button("Записать заново") { recorder.discard() }
                    .buttonStyle(.bordered)
            }
        default:
            Button("Начать запись") { Task { await recorder.start() } }
                .buttonStyle(.burgundy)
        }
    }

    private var message: String {
        switch recorder.state {
        case .denied: return "Нет доступа к микрофону. Разрешите его в Настройках iPhone → Prosnis."
        case .failed: return "Запись не получилась. Попробуйте ещё раз и говорите хотя бы секунду."
        case .recording: return "Говорите. Запись остановится сама через 30 секунд."
        case .recorded: return "Прослушайте запись. Если нравится — сохраните."
        case .idle: return "Скажите себе то, что поможет встать: зачем вы встаёте, что ждёт вас сегодня."
        }
    }
}

/// Переименование и перезапись своего голоса. Номер записи не меняется, поэтому будильники с ней менять не нужно.
struct VoiceEditView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VoiceRecorder()
    let recording: VoiceRecording
    @State private var title: String
    @State private var replaced = false

    init(recording: VoiceRecording) {
        self.recording = recording
        _title = State(initialValue: recording.title)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Название") {
                    TextField("Название", text: $title)
                }
                Section {
                    Button {
                        recorder.play(VoiceLibrary.fileURL(soundID: recording.soundID))
                    } label: {
                        Label("Прослушать запись", systemImage: "play.fill")
                    }
                }
                Section {
                    controls
                } header: {
                    Text("Записать заново")
                } footer: {
                    Text(message)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Моя запись")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        VoiceLibrary.shared.rename(recording, to: title)
                        dismiss()
                    }
                    .bold()
                }
            }
            .onDisappear {
                if recorder.state == .recording { recorder.stop() }
                recorder.stopPlayback()
                recorder.discard()
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch recorder.state {
        case .recording:
            Button("Остановить (\(Int(recorder.elapsed)) с)") { recorder.stop() }
                .buttonStyle(.stop)
        case .recorded:
            Button("Прослушать новую запись") { recorder.playDraft() }
            Button("Заменить старую запись новой") {
                recorder.stopPlayback()
                if VoiceLibrary.shared.replaceAudio(of: recording) {
                    replaced = true
                    recorder.discard()
                }
            }
            .bold()
            Button("Отменить новую запись", role: .destructive) { recorder.discard() }
        default:
            Button("Начать запись") {
                replaced = false
                Task { await recorder.start() }
            }
        }
    }

    private var message: String {
        if replaced { return "Запись заменена. Будильники, где она стоит, зазвонят новым голосом." }
        switch recorder.state {
        case .denied: return "Нет доступа к микрофону. Разрешите его в Настройках iPhone → Prosnis."
        case .failed: return "Запись не получилась. Попробуйте ещё раз и говорите хотя бы секунду."
        case .recording: return "Говорите. Запись остановится сама через 30 секунд."
        case .recorded: return "Прослушайте новую запись. Если нравится, замените ею старую."
        case .idle: return "Новая запись заменит старую под тем же названием."
        }
    }
}
