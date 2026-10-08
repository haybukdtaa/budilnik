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

    private init() {
        reload()
    }

    func reload() {
        // Запись без файла (например, файл удалён системой) не показываем.
        recordings = (file.load() ?? []).filter { FileManager.default.fileExists(atPath: VoiceLibrary.fileURL(soundID: $0.soundID).path) }
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
        let manager = FileManager.default
        let recording = VoiceRecording(
            id: UUID(),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Мой голос" : title,
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

    /// Будильники, на которых стоит эта запись.
    func alarmsUsing(_ soundID: String) -> [AlarmItem] {
        AlarmStore.shared.alarms.filter { $0.soundID == soundID }
    }

    /// Удаляет запись. Нельзя удалить запись, которая стоит на будильнике: он остался бы без своего звука.
    @discardableResult
    func delete(_ recording: VoiceRecording) -> Bool {
        guard alarmsUsing(recording.soundID).isEmpty else { return false }
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
