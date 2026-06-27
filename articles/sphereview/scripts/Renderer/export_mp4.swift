// export_mp4.swift — convert a simctl screen recording (.mov, H.264) into a web-friendly,
// downscaled, optionally-trimmed .mp4 (H.264) using AVFoundation. No ffmpeg required.
//
//   xcrun swift export_mp4.swift <in.mov> <out.mp4> [outWidth=600] [startSec] [durSec]
//
// If startSec/durSec are given, the output is trimmed to that range (for a clean loop length).

import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { fputs("usage: export_mp4.swift <in.mov> <out.mp4> [w] [start] [dur]\n", stderr); exit(2) }
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let targetW = CGFloat(args.count > 3 ? (Double(args[3]) ?? 600) : 600)
let trimStart = args.count > 4 ? Double(args[4]) : nil
let trimDur = args.count > 5 ? Double(args[5]) : nil

let asset = AVURLAsset(url: inURL)
let tracks = try await asset.loadTracks(withMediaType: .video)
guard let track = tracks.first else { fputs("no video track\n", stderr); exit(1) }
let natural = try await track.load(.naturalSize)
let xform = try await track.load(.preferredTransform)
let duration = try await asset.load(.duration)

let disp = natural.applying(xform)
let dispW = abs(disp.width), dispH = abs(disp.height)
// Crop to a centered square (the sphere is screen-centered) and scale to targetW×targetW.
let side = dispW
let cropY = (dispH - side) / 2
let scale = targetW / side
let render = targetW.rounded(.toNearestOrEven)

let comp = AVMutableVideoComposition()
comp.renderSize = CGSize(width: render, height: render)
comp.frameDuration = CMTime(value: 1, timescale: 60)
let inst = AVMutableVideoCompositionInstruction()
inst.timeRange = CMTimeRange(start: .zero, duration: duration)
let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
let xf = xform
    .concatenating(CGAffineTransform(translationX: 0, y: -cropY))
    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
layer.setTransform(xf, at: .zero)
inst.layerInstructions = [layer]
comp.instructions = [inst]

try? FileManager.default.removeItem(at: outURL)
guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
    fputs("no export session\n", stderr); exit(1)
}
export.outputURL = outURL
export.outputFileType = .mp4
export.videoComposition = comp
export.shouldOptimizeForNetworkUse = true
if let s = trimStart, let d = trimDur {
    export.timeRange = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                                   duration: CMTime(seconds: d, preferredTimescale: 600))
}

await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
    export.exportAsynchronously { cont.resume() }
}

if export.status == .completed {
    print("  wrote \(outURL.lastPathComponent) \(Int(render))x\(Int(render))")
} else {
    fputs("export failed: \(export.error?.localizedDescription ?? "status \(export.status.rawValue)")\n", stderr)
    exit(1)
}
