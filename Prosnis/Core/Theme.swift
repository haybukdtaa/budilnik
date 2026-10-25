import SwiftUI
import UIKit

extension Font {
    /// Шрифт приложения: один, системный (как в «Часах» iPhone).
    static func app(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        Font.system(style, design: .default, weight: weight)
    }
}

/// Кнопка из «закалённого стекла»: полупрозрачная ледяная заливка, тонкая рамка, светлый текст.
/// Имя осталось прежним, чтобы не трогать все экраны.
struct BurgundyButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        configuration.label
            .font(.app(.headline))
            .foregroundStyle(color == .red ? Color.white : Theme.glassText)
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .background(color.opacity(configuration.isPressed ? 0.34 : 0.22), in: shape)
            .overlay(shape.strokeBorder(color.opacity(0.55), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

extension ButtonStyle where Self == BurgundyButtonStyle {
    static var burgundy: BurgundyButtonStyle { BurgundyButtonStyle() }
    /// Красная кнопка для остановки записи.
    static var stop: BurgundyButtonStyle { BurgundyButtonStyle(color: .red) }
}

enum Theme {
    /// «Закалённое стекло»: тёмный фон с холодным свечением сверху, полупрозрачные блоки, ледяной акцент.
    static let background = LinearGradient(
        colors: [Color(red: 0.086, green: 0.165, blue: 0.247), Color(red: 0.027, green: 0.043, blue: 0.067), Color(red: 0.020, green: 0.031, blue: 0.047)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let card = Color.white.opacity(0.07)
    static let ink = Color.white
    /// Ледяной голубой: ссылки, активная вкладка, выделения.
    static let accent = Color(red: 0.561, green: 0.816, blue: 1.0)
    /// Глубокий голубой: заливки и рамки (имя от прежней палитры).
    static let burgundy = Color(red: 0.290, green: 0.639, blue: 0.871)
    /// Включённый переключатель.
    static let toggle = Color(red: 0.290, green: 0.639, blue: 0.871)
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.180, green: 0.447, blue: 0.690), Color(red: 0.290, green: 0.639, blue: 0.871)],
        startPoint: .leading,
        endPoint: .trailing
    )
    /// Тонкие линии между строками.
    static let separator = Color.white.opacity(0.10)
    /// Приглушённый ледяной цвет цифр на циферблате.
    static let numeral = Color(red: 0.200, green: 0.340, blue: 0.470)
    /// Светлый текст на стеклянных кнопках.
    static let glassText = Color(red: 0.875, green: 0.949, blue: 1.0)
    /// Цвет лекарств: мягкий мятный, чтобы с первого взгляда отличаться от будильников подъёма.
    static let mint = Color(red: 0.30, green: 0.64, blue: 0.62)

    /// Внешний вид навигации, вкладок и переключателей.
    @MainActor
    static func applyAppearance() {
        let bar = UINavigationBarAppearance()
        bar.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
        let tabs = UITabBarAppearance()
        tabs.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = tabs
        UITabBar.appearance().scrollEdgeAppearance = tabs
    }

    /// Готовые фоны будильника.
    static let wallpaperNames = ["Рассвет", "Океан", "Лес", "Ночь", "Закат", "Лёд", "Аврора"]
    /// Фоны-награды: номер фона → награда, которая его открывает.
    static let rewardWallpapers: [Int: String] = [6: "aurora"]
    private static let wallpaperColors: [[Color]] = [
        [Color(red: 1.0, green: 0.70, blue: 0.30), Color(red: 0.95, green: 0.35, blue: 0.45)],
        [Color(red: 0.10, green: 0.45, blue: 0.85), Color(red: 0.05, green: 0.15, blue: 0.40)],
        [Color(red: 0.25, green: 0.65, blue: 0.40), Color(red: 0.05, green: 0.25, blue: 0.20)],
        [Color(red: 0.15, green: 0.12, blue: 0.40), Color(red: 0.02, green: 0.02, blue: 0.12)],
        [Color(red: 0.95, green: 0.45, blue: 0.25), Color(red: 0.35, green: 0.10, blue: 0.45)],
        [Color(red: 0.70, green: 0.88, blue: 0.98), Color(red: 0.30, green: 0.55, blue: 0.80)],
        [Color(red: 0.20, green: 0.95, blue: 0.70), Color(red: 0.35, green: 0.20, blue: 0.75)],
    ]

    static func gradient(_ index: Int) -> [Color] {
        wallpaperColors[min(max(index, 0), wallpaperColors.count - 1)]
    }
}

/// Файлы своих фонов хранятся в Documents/Wallpapers.
enum WallpaperStorage {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(_ image: UIImage) -> String? {
        guard let data = image.resized(maxSide: 1400).jpegData(compressionQuality: 0.85) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try data.write(to: directory.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    static func load(_ name: String) -> UIImage? {
        UIImage(contentsOfFile: directory.appendingPathComponent(name).path)
    }

    /// Удаляет фото фонов, которые ни к чему не относятся. Свежие (меньше часа) не трогает:
    /// их может держать открытый редактор будильника.
    static func deleteAll(except used: Set<String>, olderThan age: TimeInterval = 3600) {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        let now = Date()
        for name in names where !used.contains(name) {
            let path = directory.appendingPathComponent(name).path
            let modified = (try? manager.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? now
            if now.timeIntervalSince(modified) > age { delete(name) }
        }
    }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(size.width, size.height))
        if scale == 1 { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

/// Рисует выбранный фон на всю доступную область.
struct WallpaperView: View {
    let wallpaper: Wallpaper

    var body: some View {
        switch wallpaper {
        case .gradient(let index):
            LinearGradient(colors: Theme.gradient(index), startPoint: .topLeading, endPoint: .bottomTrailing)
        case .photo(let name):
            if let image = WallpaperStorage.load(name) {
                // Фото заполняет область, но не раздвигает её: иначе экран задания вылезает за края.
                Color.clear.overlay(Image(uiImage: image).resizable().scaledToFill()).clipped()
            } else {
                LinearGradient(colors: Theme.gradient(0), startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}
