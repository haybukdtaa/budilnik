import CoreText
import SwiftUI
import UIKit

extension Font {
    /// Шрифт приложения для стиля текста: Lora для заголовков, Manrope для остального.
    static func app(_ style: Font.TextStyle) -> Font {
        let ui: UIFont.TextStyle
        switch style {
        case .largeTitle: ui = .largeTitle
        case .title: ui = .title1
        case .title2: ui = .title2
        case .title3: ui = .title3
        case .headline: ui = .headline
        case .subheadline: ui = .subheadline
        case .callout: ui = .callout
        case .footnote: ui = .footnote
        case .caption: ui = .caption1
        case .caption2: ui = .caption2
        default: ui = .body
        }
        return Font(Theme.uiFont(for: ui))
    }
}

enum Theme {
    /// Фон «Небо на рассвете»: персиковый сверху, сиреневый в середине, голубой внизу.
    static let skyTop = Color(red: 0.976, green: 0.788, blue: 0.714)
    static let skyMiddle = Color(red: 0.910, green: 0.765, blue: 0.878)
    static let skyBottom = Color(red: 0.725, green: 0.784, blue: 0.949)
    static let background = LinearGradient(colors: [skyTop, skyMiddle, skyBottom], startPoint: .top, endPoint: .bottom)
    /// Полупрозрачные белые карточки поверх неба.
    static let card = Color.white.opacity(0.58)
    /// Тёмный сливовый текст вместо чёрного.
    static let ink = Color(red: 0.165, green: 0.141, blue: 0.251)
    static let accent = Color(red: 0.482, green: 0.361, blue: 0.788)
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.58, green: 0.45, blue: 0.88), Color(red: 0.482, green: 0.361, blue: 0.788)],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let leaf = Color(red: 0.365, green: 0.643, blue: 0.541)

    /// Шрифт с нужной толщиной. Lora и Manrope — переменные шрифты: толщина задаётся осью «wght».
    static func uiFont(_ family: String, size: CGFloat, weight: CGFloat) -> UIFont {
        let wght = 0x7767_6874 // 'wght'
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: family,
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: weight],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    /// Заголовки — Lora (с засечками, как в книге), остальное — Manrope.
    static func uiFont(for style: UIFont.TextStyle) -> UIFont {
        let font: UIFont
        switch style {
        case .largeTitle: font = uiFont("Lora", size: 34, weight: 500)
        case .title1: font = uiFont("Lora", size: 28, weight: 500)
        case .title2: font = uiFont("Lora", size: 22, weight: 500)
        case .title3: font = uiFont("Lora", size: 20, weight: 500)
        case .headline: font = uiFont("Manrope", size: 17, weight: 650)
        case .subheadline: font = uiFont("Manrope", size: 15, weight: 450)
        case .callout: font = uiFont("Manrope", size: 16, weight: 450)
        case .footnote: font = uiFont("Manrope", size: 13, weight: 450)
        case .caption1: font = uiFont("Manrope", size: 12, weight: 500)
        case .caption2: font = uiFont("Manrope", size: 11, weight: 500)
        default: font = uiFont("Manrope", size: 17, weight: 450)
        }
        // Крупный шрифт из настроек iPhone тоже работает.
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }

    /// Внешний вид навигации и вкладок в новом стиле.
    @MainActor
    static func applyAppearance() {
        let bar = UINavigationBarAppearance()
        bar.configureWithTransparentBackground()
        let ink = UIColor(ink)
        bar.largeTitleTextAttributes = [.font: uiFont(for: .largeTitle), .foregroundColor: ink]
        bar.titleTextAttributes = [.font: uiFont("Lora", size: 18, weight: 500), .foregroundColor: ink]
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
        let tabItem = UITabBarItemAppearance()
        tabItem.normal.titleTextAttributes = [.font: uiFont("Manrope", size: 11, weight: 600)]
        tabItem.selected.titleTextAttributes = [.font: uiFont("Manrope", size: 11, weight: 700)]
        let tabs = UITabBarAppearance()
        tabs.configureWithDefaultBackground()
        tabs.stackedLayoutAppearance = tabItem
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
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: Theme.gradient(0), startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}
