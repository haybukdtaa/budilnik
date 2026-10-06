import SwiftUI
import UIKit

enum Theme {
    static let background = Color(red: 0.04, green: 0.04, blue: 0.06)
    static let card = Color(red: 0.09, green: 0.09, blue: 0.12)
    static let accent = Color(red: 1.0, green: 0.54, blue: 0.24)
    static let accentGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.62, blue: 0.25), Color(red: 1.0, green: 0.36, blue: 0.30)],
        startPoint: .leading,
        endPoint: .trailing
    )

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
