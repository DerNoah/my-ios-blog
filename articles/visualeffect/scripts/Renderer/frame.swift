// frame.swift — extract a single frame from a video to a PNG (for verifying mp4 output).
//   xcrun swift frame.swift <video> <out.png> [seconds=1]
import AVFoundation
import AppKit
import Foundation

let a = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
let t = CMTime(seconds: a.count > 3 ? (Double(a[3]) ?? 1) : 1, preferredTimescale: 600)
let cg = try gen.copyCGImage(at: t, actualTime: nil)
let rep = NSBitmapImageRep(cgImage: cg)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("  wrote \(a[2]) \(cg.width)x\(cg.height)")
