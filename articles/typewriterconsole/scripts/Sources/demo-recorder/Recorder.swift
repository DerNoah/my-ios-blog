import AppKit
import AVFoundation
import QuartzCore

enum RecorderError: Error {
    case noBitmapRep
    case startFailed
    case writeFailed
    case pngFailed
}

/// Captures a view at ~30 Hz via `cacheDisplay` (no screen-recording permission needed — it's
/// in-process drawing) and encodes the frames to an H.264 .mp4 with `AVAssetWriter`.
@MainActor
final class Recorder {
    private let view: NSView
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let pixelsWide: Int
    private let pixelsHigh: Int
    private var timer: Timer?
    private var t0: CFTimeInterval?
    private(set) var captured = 0
    private(set) var dropped = 0
    let gif: GifWriter?

    init(view: NSView, outURL: URL, gif: GifWriter?) throws {
        self.view = view
        self.gif = gif

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw RecorderError.noBitmapRep
        }
        pixelsWide = rep.pixelsWide
        pixelsHigh = rep.pixelsHigh
        print("recording \(pixelsWide)x\(pixelsHigh) → \(outURL.path)")

        try? FileManager.default.removeItem(at: outURL)
        writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelsWide,
            AVVideoHeightKey: pixelsHigh,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: pixelsWide,
            kCVPixelBufferHeightKey as String: pixelsHigh,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecorderError.startFailed }
        writer.startSession(atSourceTime: .zero)
    }

    func start(fps: Double = 30) {
        let timer = Timer(timeInterval: 1.0 / fps, repeats: true) { _ in
            MainActor.assumeIsolated { self.captureFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func finish() async throws {
        timer?.invalidate()
        timer = nil
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RecorderError.writeFailed }
        try gif?.finalize()
    }

    private func captureFrame() {
        guard let cgImage = Self.snapshot(view: view) else { dropped += 1; return }
        let now = CACurrentMediaTime()
        if t0 == nil { t0 = now }
        let t = now - t0!

        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { dropped += 1; return }
        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
        guard let pixelBuffer = pixelBufferOut else { dropped += 1; return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        if adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600)) {
            captured += 1
            gif?.add(cgImage, at: t)
        } else {
            dropped += 1
        }
    }

    private static func snapshot(view: NSView) -> CGImage? {
        view.window?.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// Writes a single PNG frame — the pre-flight check that `cacheDisplay` actually renders
    /// the SwiftUI hosting hierarchy before committing to a full run.
    static func smokePNG(view: NSView, to url: URL) throws {
        guard let cgImage = snapshot(view: view) else { throw RecorderError.noBitmapRep }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw RecorderError.pngFailed }
        try data.write(to: url)
    }
}
