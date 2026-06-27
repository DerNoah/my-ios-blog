// export_mp4.swift — convert a simctl screen recording (.mov, H.264) into a web-friendly,
// downscaled, optionally-trimmed, BITRATE-CONTROLLED .mp4 via AVAssetReader → AVAssetWriter
// (AVAssetExportSession can't cap bitrate; this keeps files small). No ffmpeg required.
//
//   xcrun swift export_mp4.swift <in.mov> <out.mp4> [outWidth=600] [start] [dur] [square|full]
//
// "square" (default) crops a centered square; "full" keeps the native aspect (tall edge demo).

import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { fputs("usage: export_mp4.swift <in.mov> <out.mp4> [w] [start] [dur] [square|full]\n", stderr); exit(2) }
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let targetW = CGFloat(args.count > 3 ? (Double(args[3]) ?? 600) : 600)
let trimStart = args.count > 4 ? Double(args[4]) : nil
let trimDur = args.count > 5 ? Double(args[5]) : nil
let mode = args.count > 6 ? args[6] : "square"

let asset = AVURLAsset(url: inURL)
let tracks = try await asset.loadTracks(withMediaType: .video)
guard let track = tracks.first else { fputs("no video track\n", stderr); exit(1) }
let natural = try await track.load(.naturalSize)
let xform = try await track.load(.preferredTransform)

let disp = natural.applying(xform)
let dispW = abs(disp.width), dispH = abs(disp.height)
let scale = targetW / dispW
let cropY = mode == "full" ? 0 : (dispH - dispW) / 2
var renderW = Int((targetW).rounded(.toNearestOrEven))
var renderH = Int((mode == "full" ? dispH * scale : dispW * scale).rounded(.toNearestOrEven))
renderW -= renderW % 2; renderH -= renderH % 2

let comp = AVMutableVideoComposition()
comp.renderSize = CGSize(width: renderW, height: renderH)
comp.frameDuration = CMTime(value: 1, timescale: 60)
let inst = AVMutableVideoCompositionInstruction()
inst.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
layer.setTransform(xform
    .concatenating(CGAffineTransform(translationX: 0, y: -cropY))
    .concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
inst.layerInstructions = [layer]
comp.instructions = [inst]

let reader = try AVAssetReader(asset: asset)
if let s = trimStart, let d = trimDur {
    reader.timeRange = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                                   duration: CMTime(seconds: d, preferredTimescale: 600))
}
let readerOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track],
    videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
readerOutput.videoComposition = comp
reader.add(readerOutput)

try? FileManager.default.removeItem(at: outURL)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: renderW, AVVideoHeightKey: renderH,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: renderW * renderH * 6,        // ~controlled bitrate
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    ],
])
input.expectsMediaDataInRealTime = false
writer.add(input)
writer.shouldOptimizeForNetworkUse = true

reader.startReading()
writer.startWriting()
writer.startSession(atSourceTime: CMTime(seconds: trimStart ?? 0, preferredTimescale: 600))

let sem = DispatchSemaphore(value: 0)
input.requestMediaDataWhenReady(on: DispatchQueue(label: "transcode")) {
    while input.isReadyForMoreMediaData {
        guard reader.status == .reading, let sb = readerOutput.copyNextSampleBuffer() else {
            input.markAsFinished()
            writer.finishWriting { sem.signal() }
            return
        }
        input.append(sb)
    }
}
sem.wait()

if writer.status == .completed {
    print("  wrote \(outURL.lastPathComponent) \(renderW)x\(renderH)")
} else {
    fputs("export failed: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")\n", stderr)
    exit(1)
}
