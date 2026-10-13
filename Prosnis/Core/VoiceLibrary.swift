import AVFoundation
import Foundation

/// Своя запись голоса, которую можно поставить на будильник.
struct VoiceRecording: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date

    var soundID: String { VoiceLibrary.soundID(for: id) }
}

/// Записи своего голоса. Файлы лежат в Library/Sounds: оттуда система берёт звук будильника.
/// Записи не покидают телефон.
@MainActor
final class VoiceLibrary: ObservableObject {
    static let shared = VoiceLibrary()
    nonisolated static let prefix = "voice-"
    /// Дольше система звук будильника может не принять.
    nonisolated static let maxSeconds: TimeInterval = 30

    @Published private(set) var recordings: [VoiceRecording] = []
    private let file = FileStore<[VoiceRecording]>("voices")
    /// Файл списка был закрыт (телефон ещё не разблокировали): сохранять нельзя, иначе потеряем записи.
    private var loadFailed = false

    private init() {
        reload()
    }

    func reload() {
        let result = file.loadWithState()
        loadFailed = result.state == .unreadable
        // Запись без файла (например, файл удалён системой) не показываем.
        recordings = (result.value ?? []).filter { FileManager.default.fileExists(atPath: VoiceLibrary.fileURL(soundID: $0.soundID).path) }
    }

    func reloadIfNeeded() {
        if loadFailed { reload() }
    }

    nonisolated static var soundsFolder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Sounds", isDirectory: true)
    }

    nonisolated static func soundID(for id: UUID) -> String { prefix + id.uuidString }

    nonisolated static func isVoice(_ soundID: String) -> Bool { soundID.hasPrefix(prefix) }

    nonisolated static func fileURL(soundID: String) -> URL {
        soundsFolder.appendingPathComponent(soundID + ".caf")
    }

    /// Временный файл для новой записи (до сохранения).
    nonisolated static var draftURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voice-draft.caf")
    }

    func recording(soundID: String) -> VoiceRecording? {
        recordings.first { $0.soundID == soundID }
    }

    /// Сохраняет черновик записи под названием. Возвращает id звука или nil при ошибке.
    func saveDraft(title: String) -> String? {
        reloadIfNeeded()
        guard !loadFailed else { return nil }
        let manager = FileManager.default
        let recording = VoiceRecording(
            id: UUID(),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? VoiceLibrary.defaultTitle() : title,
            createdAt: Date()
        )
        do {
            try manager.createDirectory(at: VoiceLibrary.soundsFolder, withIntermediateDirectories: true)
            let target = VoiceLibrary.fileURL(soundID: recording.soundID)
            try manager.moveItem(at: VoiceLibrary.draftURL, to: target)
            // Будильник звонит и на заблокированном телефоне: файл должен читаться после первой разблокировки.
            try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        } catch {
            return nil
        }
        recordings.append(recording)
        file.save(recordings)
        return recording.soundID
    }

    /// Название по умолчанию: «Голос · 11 окт, 07:12».
    nonisolated static func defaultTitle(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let months = ["янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]
        let parts = calendar.dateComponents([.day, .month, .hour, .minute], from: date)
        let month = months[max(0, min(11, (parts.month ?? 1) - 1))]
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        return "Голос · \(parts.day ?? 1) \(month), \(time)"
    }

    /// Переименовывает запись. Пустое название игнорируется.
    func rename(_ recording: VoiceRecording, to title: String) {
        reloadIfNeeded()
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !loadFailed, !clean.isEmpty, let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[index].title = clean
        file.save(recordings)
    }

    /// Заменяет звук записи новым из черновика. Номер и название остаются, поэтому будильники с этой записью
    /// менять не нужно: они сами зазвонят новым голосом.
    @discardableResult
    func replaceAudio(of recording: VoiceRecording) -> Bool {
        reloadIfNeeded()
        guard !loadFailed, recordings.contains(where: { $0.id == recording.id }),
              FileManager.default.fileExists(atPath: VoiceLibrary.draftURL.path) else { return false }
        let manager = FileManager.default
        let target = VoiceLibrary.fileURL(soundID: recording.soundID)
        do {
            if manager.fileExists(atPath: target.path) {
                _ = try manager.replaceItemAt(target, withItemAt: VoiceLibrary.draftURL)
            } else {
                try manager.createDirectory(at: VoiceLibrary.soundsFolder, withIntermediateDirectories: true)
                try manager.moveItem(at: VoiceLibrary.draftURL, to: target)
            }
            try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        } catch {
            return false
        }
        objectWillChange.send()
        return true
    }

    /// Будильники, на которых стоит эта запись.
    func alarmsUsing(_ soundID: String) -> [AlarmItem] {
        AlarmStore.shared.alarms.filter { $0.soundID == soundID }
    }

    /// Удаляет запись. Нельзя удалить запись, которая стоит на будильнике: он остался бы без своего звука.
    @discardableResult
    func delete(_ recording: VoiceRecording) -> Bool {
        reloadIfNeeded()
        guard !loadFailed, alarmsUsing(recording.soundID).isEmpty else { return false }
        try? FileManager.default.removeItem(at: VoiceLibrary.fileURL(soundID: recording.soundID))
        recordings.removeAll { $0.id == recording.id }
        file.save(recordings)
        return true
    }

    /// Удаляет все записи с телефона (при удалении всех данных).
    nonisolated static func wipeFiles() {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: soundsFolder, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix(prefix) {
            try? manager.removeItem(at: item)
        }
    }
}

/// Запись голоса с микрофона: несжатый звук, который система точно примет как звук будильника.
@MainActor
final class VoiceRecorder: ObservableObject {
    enum State: Equatable {
        case idle, recording, recorded, denied, failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func start() async {
        stopPlayback()
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .denied
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            try? FileManager.default.removeItem(at: VoiceLibrary.draftURL)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let recorder = try AVAudioRecorder(url: VoiceLibrary.draftURL, settings: settings)
            guard recorder.record(forDuration: VoiceLibrary.maxSeconds) else {
                state = .failed
                return
            }
            self.recorder = recorder
            elapsed = 0
            state = .recording
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            state = .failed
        }
    }

    private func tick() {
        guard let recorder else { return }
        if recorder.isRecording {
            elapsed = recorder.currentTime
        } else {
            // Запись сама остановилась на 30 секундах.
            finishRecording()
        }
    }

    func stop() {
        recorder?.stop()
        finishRecording()
    }

    private func finishRecording() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        let exists = FileManager.default.fileExists(atPath: VoiceLibrary.draftURL.path)
        state = exists && elapsed >= 0.5 ? .recorded : .failed
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func playDraft() {
        play(VoiceLibrary.draftURL)
    }

    func play(_ url: URL) {
        stopPlayback()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    func stopPlayback() {
        player?.stop()
        player = nil
    }

    func discard() {
        stopPlayback()
        try? FileManager.default.removeItem(at: VoiceLibrary.draftURL)
        elapsed = 0
        state = .idle
    }
}
