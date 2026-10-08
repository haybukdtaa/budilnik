import AVFoundation
import Foundation
import UIKit

/// Утренние фото: одно на день, хранятся только на телефоне (Documents/MorningPhotos).
@MainActor
final class MorningPhotoStore: ObservableObject {
    static let shared = MorningPhotoStore()

    /// Дни с фото, «гггг-мм-дд», по возрастанию.
    @Published private(set) var days: [String] = []

    nonisolated static var folder: URL {
        AppFiles.documents.appendingPathComponent("MorningPhotos", isDirectory: true)
    }

    private init() {
        reload()
    }

    func reload() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: MorningPhotoStore.folder.path)) ?? []
        days = names.filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) }.sorted()
    }

    nonisolated static func url(for day: String) -> URL {
        folder.appendingPathComponent(day + ".jpg")
    }

    func hasPhoto(on date: Date) -> Bool { days.contains(AppSettings.dayKey(date)) }

    func image(for day: String) -> UIImage? {
        UIImage(contentsOfFile: MorningPhotoStore.url(for: day).path)
    }

    /// Сохраняет фото утра. Повернуто «как видно» и уменьшено, чтобы не занимать много места.
    @discardableResult
    func save(_ image: UIImage, for date: Date) -> Bool {
        let manager = FileManager.default
        try? manager.createDirectory(at: MorningPhotoStore.folder, withIntermediateDirectories: true)
        let normalized = MorningPhotoStore.normalized(image, maxSide: 1600)
        guard let data = normalized.jpegData(compressionQuality: 0.82) else { return false }
        let day = AppSettings.dayKey(date)
        do {
            try data.write(to: MorningPhotoStore.url(for: day), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return false
        }
        reload()
        return true
    }

    func delete(day: String) {
        try? FileManager.default.removeItem(at: MorningPhotoStore.url(for: day))
        reload()
    }

    /// Месяцы с фото, «гггг-мм», новые сверху.
    var months: [String] {
        Array(Set(days.map { String($0.prefix(7)) })).sorted(by: >)
    }

    func days(inMonth month: String) -> [String] {
        days.filter { $0.hasPrefix(month) }
    }

    private static func normalized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Собирает ролик из утренних фото: каждое фото держится полторы секунды.
enum SlideshowExporter {
    enum ExportError: LocalizedError {
        case failed

        var errorDescription: String? { "Не удалось собрать ролик. Попробуйте ещё раз." }
    }

    static let size = CGSize(width: 1080, height: 1920)
    static let secondsPerPhoto = 1.5

    /// Работает долго: вызывать не на главном потоке.
    nonisolated static func export(photos: [URL], to output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard writer.canAdd(input) else { throw ExportError.failed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError.failed }
        writer.startSession(atSourceTime: .zero)

        var written = 0
        var last: CVPixelBuffer?
        for url in photos {
            guard let image = UIImage(contentsOfFile: url.path)?.cgImage,
                  let buffer = pixelBuffer(for: image) else { continue }
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            let time = CMTime(seconds: Double(written) * secondsPerPhoto, preferredTimescale: 600)
            guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? ExportError.failed }
            last = buffer
            written += 1
        }
        guard written > 0, let last else {
            writer.cancelWriting()
            throw ExportError.failed
        }
        // Последний кадр ещё раз в конце, чтобы последнее фото тоже держалось полторы секунды.
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
        let end = CMTime(seconds: Double(written) * secondsPerPhoto, preferredTimescale: 600)
        adaptor.append(last, withPresentationTime: end)
        input.markAsFinished()
        writer.endSession(atSourceTime: end)

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? ExportError.failed }
    }

    /// Кадр с фото, заполняющим экран (лишнее по краям обрезается).
    private nonisolated static func pixelBuffer(for image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                  kCVPixelFormatType_32ARGB, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = max(size.width / imageSize.width, size.height / imageSize.height)
        let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2)
        context.draw(image, in: CGRect(origin: origin, size: drawn))
        return buffer
    }
}
