import AVFoundation
import Foundation

enum SoundCategory: String, CaseIterable {
    case melodies = "Мелодии"
    case bass = "Басы"
    case noise = "Шумы"
    case signals = "Сигналы"
}

struct SoundOption: Identifiable, Hashable {
    let id: String // совпадает с именем файла без расширения
    let title: String
    let category: SoundCategory

    var fileName: String { id + ".wav" }
}

enum SoundLibrary {
    static let all: [SoundOption] = [
        SoundOption(id: "melody_morning", title: "Утро", category: .melodies),
        SoundOption(id: "melody_chimes", title: "Колокольчики", category: .melodies),
        SoundOption(id: "bass_pulse", title: "Бас-пульс", category: .bass),
        SoundOption(id: "bass_deep", title: "Глубокий бас", category: .bass),
        SoundOption(id: "noise_white", title: "Белый шум", category: .noise),
        SoundOption(id: "noise_pink", title: "Розовый шум", category: .noise),
        SoundOption(id: "noise_brown", title: "Коричневый шум", category: .noise),
        SoundOption(id: "classic_beep", title: "Классический сигнал", category: .signals),
        SoundOption(id: "alarm_bell", title: "Звонок", category: .signals),
        SoundOption(id: "siren", title: "Сирена", category: .signals),
        SoundOption(id: "rising_tone", title: "Нарастающий тон", category: .signals),
    ]

    static func option(_ id: String) -> SoundOption {
        all.first { $0.id == id } ?? all.first { $0.id == "classic_beep" }!
    }

    static func options(in category: SoundCategory) -> [SoundOption] {
        all.filter { $0.category == category }
    }
}

/// Проигрывает пробный фрагмент звука при выборе.
@MainActor
final class SoundPreview {
    static let shared = SoundPreview()
    private var player: AVAudioPlayer?

    func play(_ option: SoundOption) {
        stop()
        guard let url = Bundle.main.url(forResource: option.id, withExtension: "wav") else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
