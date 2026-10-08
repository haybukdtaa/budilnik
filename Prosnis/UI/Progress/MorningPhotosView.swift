import SwiftUI
import UIKit

/// Камера (или галерея, если камеры нет) для утреннего фото.
struct PhotoCaptureView: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: PhotoCaptureView

        init(_ parent: PhotoCaptureView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Карточка на утреннем экране: одно фото утра.
struct MorningPhotoCard: View {
    @ObservedObject private var photos = MorningPhotoStore.shared
    let date: Date
    @State private var showCamera = false

    var body: some View {
        let day = AppSettings.dayKey(date)
        VStack(alignment: .leading, spacing: 10) {
            Label("Утреннее фото", systemImage: "camera").font(.headline)
            if photos.days.contains(day), let image = photos.image(for: day) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Button("Переснять") { showCamera = true }.font(.footnote)
            } else {
                Text("Рассвет, кофе, вид из окна — одно фото в день. В конце месяца соберём из них ролик «Мой месяц утром». Фото хранятся только на телефоне.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Сделать фото") { showCamera = true }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        .sheet(isPresented: $showCamera) {
            PhotoCaptureView { image in photos.save(image, for: date) }
                .ignoresSafeArea()
        }
    }
}

/// «Мои утра»: фото по месяцам, просмотр роликом и сохранение видео.
struct MorningPhotosView: View {
    @ObservedObject private var photos = MorningPhotoStore.shared
    @State private var month: String?
    @State private var showSlideshow = false
    @State private var exporting = false
    @State private var exported: URL?
    @State private var exportError: String?

    private var currentMonth: String? { month ?? photos.months.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if photos.months.isEmpty {
                    Text("Пока нет ни одного утреннего фото. После успешного подъёма на утреннем экране можно сделать фото дня.")
                        .foregroundStyle(.secondary)
                } else if let current = currentMonth {
                    Picker("Месяц", selection: Binding(get: { current }, set: { month = $0; exported = nil })) {
                        ForEach(photos.months, id: \.self) { Text(MorningPhotosView.monthTitle($0)).tag($0) }
                    }
                    .pickerStyle(.menu)

                    let days = photos.days(inMonth: current)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                        ForEach(days, id: \.self) { day in
                            if let image = photos.image(for: day) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(minWidth: 0, maxWidth: .infinity)
                                    .frame(height: 140)
                                    .clipped()
                                    .overlay(alignment: .bottomLeading) {
                                        Text(Format.dayKey(day))
                                            .font(.caption2.bold())
                                            .padding(4)
                                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                                            .padding(4)
                                    }
                                    .contextMenu {
                                        Button("Удалить фото", role: .destructive) { photos.delete(day: day) }
                                    }
                            }
                        }
                    }

                    Button {
                        showSlideshow = true
                    } label: {
                        Label("Смотреть «\(MorningPhotosView.monthTitle(current)) утром»", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if let exported {
                        ShareLink(item: exported) {
                            Label("Сохранить или отправить ролик", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            export(days: days)
                        } label: {
                            Label(exporting ? "Собираем ролик…" : "Собрать видео", systemImage: "film")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(exporting)
                    }
                    if let exportError {
                        Text(exportError).font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Мои утра")
        // Фото удалили или пересняли: старый ролик уже не тот.
        .onChange(of: photos.days) { _, _ in exported = nil }
        .fullScreenCover(isPresented: $showSlideshow) {
            SlideshowView(days: currentMonth.map { photos.days(inMonth: $0) } ?? [])
        }
    }

    private func export(days: [String]) {
        exporting = true
        exportError = nil
        let urls = days.map { MorningPhotoStore.url(for: $0) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Мои утра \(currentMonth ?? "").mp4")
        Task {
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    try SlideshowExporter.export(photos: urls, to: output)
                    return .success(output)
                } catch {
                    return .failure(error)
                }
            }.value
            exporting = false
            switch result {
            case .success(let url): exported = url
            case .failure(let error): exportError = error.localizedDescription
            }
        }
    }

    static func monthTitle(_ month: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM"
        guard let date = parser.date(from: month) else { return month }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: date).capitalized
    }
}

/// Ролик внутри приложения: фото сменяются каждые полторы секунды.
struct SlideshowView: View {
    @Environment(\.dismiss) private var dismiss
    let days: [String]
    @State private var index = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if days.indices.contains(index), let image = MorningPhotoStore.shared.image(for: days[index]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .id(index)
                    .transition(.opacity)
                VStack {
                    Spacer()
                    Text(Format.dayKey(days[index]))
                        .font(.headline)
                        .padding(8)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 40)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.8))
            }
            .padding()
        }
        .task {
            while !Task.isCancelled && index < days.count - 1 {
                try? await Task.sleep(nanoseconds: UInt64(SlideshowExporter.secondsPerPhoto * 1_000_000_000))
                withAnimation(.easeInOut(duration: 0.5)) { index += 1 }
            }
        }
    }
}
