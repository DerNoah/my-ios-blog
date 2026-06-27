// encode_frames.swift — encode a numbered PNG sequence into a web-friendly H.264 .mp4
// (AVAssetWriter — no ffmpeg). The shell expands the glob into the frame arguments.
//
//   xcrun swift encode_frames.swift <out.mp4> <fps> <width|0> <frame1.png> <frame2.png> …
//
// width 0 keeps the source size; otherwise frames are scaled to that width (aspect-preserved).

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

let a = CommandLine.arguments
guard a.count >= 5 else { fputs("usage: encode_frames.swift <out.mp4> <fps> <width|0> <frames…>\n", stderr); exit(2) }
let outPath = a[1]
let fps = Int(a[2]) ?? 60
let targetW = Int(a[3]) ?? 0
let framePaths = Array(a[4...]).sorted()

func loadCG(_ p: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

guard let first = loadCG(framePaths.first ?? "") else { fputs("no frames\n", stderr); exit(1) }
var w = first.width, h = first.height
if targetW > 0 { let s = Double(targetW) / Double(w); w = targetW; h = Int((Double(h) * s).rounded(.toNearestOrEven)) }
w -= w % 2; h -= h % 2                                   // H.264 wants even dimensions

let url = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: url)
let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: w, AVVideoHeightKey: h,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: w * h * 10,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    ],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

for (i, p) in framePaths.enumerated() {
    guard let cg = loadCG(p) else { continue }
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
guard writer.status == .completed else {
    fputs("encode failed: \(writer.error?.localizedDescription ?? "")\n", stderr); exit(1)
}
print("  wrote \((outPath as NSString).lastPathComponent) (\(framePaths.count) frames, \(w)x\(h) @ \(fps)fps)")
