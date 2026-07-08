import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GifError: Error {
    case noFrames
    case destinationFailed
    case finalizeFailed
}

/// Collects a time-gated subsample of the captured frames (downscaled at add-time so only small
/// bitmaps are buffered) and writes an infinitely-looping GIF via ImageIO.
@MainActor
final class GifWriter {
    private let url: URL
    private let targetWidth: Int
    private let minInterval: TimeInterval
    private var frames: [(image: CGImage, t: TimeInterval)] = []
    private var lastKept: TimeInterval = -.infinity

    init(url: URL, targetWidth: Int = 960, fps: Double = 13) {
        self.url = url
        self.targetWidth = targetWidth
        minInterval = 1.0 / fps
    }

    func add(_ image: CGImage, at t: TimeInterval) {
        guard t - lastKept >= minInterval else { return }
        lastKept = t
        let width = min(targetWidth, image.width)
        let height = Int((Double(image.height) / Double(image.width) * Double(width)).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return }
        frames.append((small, t))
    }

    func finalize() throws {
        guard !frames.isEmpty else { throw GifError.noFrames }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil
        ) else { throw GifError.destinationFailed }

        let fileProperties = [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0],
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)

        for (i, frame) in frames.enumerated() {
            let next = i + 1 < frames.count ? frames[i + 1].t : frame.t + minInterval
            // GIF delays have centisecond resolution; browsers clamp anything below 0.02.
            let delay = max(0.02, ((next - frame.t) * 100).rounded() / 100)
            let frameProperties = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: delay,
                    kCGImagePropertyGIFUnclampedDelayTime as String: delay,
                ],
            ] as CFDictionary
            CGImageDestinationAddImage(destination, frame.image, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw GifError.finalizeFailed }
        print("gif: \(frames.count) frames → \(url.path)")
    }
}
