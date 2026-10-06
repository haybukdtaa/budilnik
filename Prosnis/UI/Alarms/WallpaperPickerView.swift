import PhotosUI
import SwiftUI

/// Выбор фона будильника: готовые градиенты или своё фото из галереи.
struct WallpaperPickerView: View {
    @EnvironmentObject private var settings: AppSettings
    @Binding var selection: Wallpaper
    @State private var pickedItem: PhotosPickerItem?
    @State private var errorText: String?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    ZStack {
                        Theme.card
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.title2)
                            Text("Своё фото").font(.footnote)
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                if case .photo = selection {
                    tile(for: selection, title: "Моё фото")
                }

                ForEach(0..<Theme.wallpaperNames.count, id: \.self) { index in
                    if let reward = Theme.rewardWallpapers[index], !settings.data.unlockedRewards.contains(reward) {
                        lockedTile(index: index)
                    } else {
                        tile(for: .gradient(index), title: Theme.wallpaperNames[index])
                    }
                }
            }
            .padding(16)

            if let errorText {
                Text(errorText).foregroundStyle(.red).padding()
            }
        }
        .background(Theme.background)
        .navigationTitle("Фон")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
    }

    /// Фон-награда, который ещё не открыт: откроется за приглашённого друга.
    private func lockedTile(index: Int) -> some View {
        ZStack {
            WallpaperView(wallpaper: .gradient(index))
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipped()
                .opacity(0.35)
            VStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.title2)
                Text(Theme.wallpaperNames[index]).font(.footnote.weight(.semibold))
                Text("За приглашённого друга").font(.caption2)
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func tile(for wallpaper: Wallpaper, title: String) -> some View {
        Button {
            selection = wallpaper
        } label: {
            ZStack(alignment: .bottomLeading) {
                WallpaperView(wallpaper: wallpaper)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipped()
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .padding(10)
                if selection == wallpaper {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(selection == wallpaper ? Theme.accent : .clear, lineWidth: 3)
            )
        }
        .buttonStyle(.plain)
    }

    private func load(_ item: PhotosPickerItem) async {
        errorText = nil
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let name = WallpaperStorage.save(image) else {
            errorText = "Не удалось загрузить фото"
            return
        }
        if case .photo(let old) = selection {
            WallpaperStorage.delete(old)
        }
        selection = .photo(name)
    }
}
