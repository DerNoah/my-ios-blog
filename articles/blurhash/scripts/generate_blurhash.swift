#!/usr/bin/env swift
//
//  generate_blurhash.swift
//
//  Generate the step-by-step output images used in the BlurHash article
//  (index.md), on macOS, with the same Core Image passes the article uses on iOS.
//
//      Step 1   encode .................. prints the BlurHash string
//      Step 2   decode (32x48) .......... 02-decoded.png
//      Step 3   + tonal compression ..... 03-tonal.png    (CIColorMatrix)
//      Step 3   + Gaussian blur (r=2) ... 04-blurred.png   (CIGaussianBlur, the final placeholder)
//      Step 4   reveal animation ........ 04-reveal.gif    (CIDissolveTransition + frosted shimmer)
//      Step 1/4 source image ............ 01-original.png
//
//  If tshirt_example.jpg is present, also emits the Step 3 "black hole" demo
//  (tshirt-original/-raw/-processed.png) showing why the filters matter for
//  high-contrast, dark-on-light product shots.
//
//  The article targets iOS/UIKit (UIImage). UIKit is unavailable on macOS, so
//  Wolt's encode/decode are ported to operate on CGImage bytes directly, while
//  the image-quality passes use the *real* Core Image filters from Step 3
//  (CIColorMatrix + CIGaussianBlur) on a single shared CIContext -- exactly as
//  the article does. The CIContext works in sRGB so the tonal math matches the
//  Python script's `in * 0.65 + 0.175`.
//
//  Usage:
//      swift articles/blurhash/scripts/generate_blurhash.swift [input.jpg] [output_dir]
//  Defaults (resolved from this script's location, so it runs from any directory):
//      input = ../blurhash_example.jpg, output_dir = ../  (the articles/blurhash folder)
//

import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

// MARK: - Article parameters

let xComponents = 4
let yComponents = 3
let decodeW = 32, decodeH = 48          // the article's decode size
let displayW = 320, displayH = 480      // upscaled size for the saved PNGs (2:3)
let tonalScale: CGFloat = 0.65
let tonalBias: CGFloat = 0.175
let blurRadius: Float = 2

// Step 4 reveal animation (GIF): hold placeholder -> cross-dissolve -> hold photo.
let gifHoldStart = 4
let gifTransition = 16
let gifHoldEnd = 8
let gifFrameDelay = 0.05            // seconds per frame
let shimmerMax = 6.0               // peak Gaussian "frosted-glass" radius mid-transition

// MARK: - Base83

let base83 = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
let base83Index: [Character: Int] = {
    var m = [Character: Int]()
    for (i, c) in base83.enumerated() { m[c] = i }
    return m
}()

func base83Encode(_ value: Int, _ length: Int) -> String {
    var out = ""
    for i in 1...length {
        let digit = (value / Int(pow(83.0, Double(length - i)))) % 83
        out.append(base83[digit])
    }
    return out
}

func base83Decode(_ s: Substring) -> Int {
    var value = 0
    for c in s { value = value * 83 + (base83Index[c] ?? 0) }
    return value
}

// MARK: - Color helpers

// sRGB byte (0...255) -> linear, precomputed as a 256-entry lookup table.
let linearLUT: [Double] = (0...255).map { byte in
    let v = Double(byte) / 255.0
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

func linearToSRGBByte(_ value: Double) -> UInt8 {
    let v = min(max(value, 0.0), 1.0)
    let s = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    return UInt8(max(0, min(255, (s * 255.0).rounded())))
}

func signPow(_ x: Double, _ e: Double) -> Double {
    return (x < 0 ? -1.0 : 1.0) * pow(abs(x), e)
}

// MARK: - Read a CGImage's pixels into an sRGB RGBA8 buffer

struct PixelBuffer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: [UInt8]
}

func readPixels(_ image: CGImage, width: Int, height: Int) -> PixelBuffer {
    let bytesPerRow = width * 4
    var data = [UInt8](repeating: 0, count: bytesPerRow * height)
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    data.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return PixelBuffer(width: width, height: height, bytesPerRow: bytesPerRow, data: data)
}

// MARK: - Step 1: encode (separable, full resolution -> matches the Python hash)

func encode(_ px: PixelBuffer) -> String {
    let w = px.width, h = px.height
    // Precompute cosine tables.
    let cosX = (0..<xComponents).map { i in
        (0..<w).map { x in cos(Double.pi * Double(i) * Double(x) / Double(w)) }
    }
    let cosY = (0..<yComponents).map { j in
        (0..<h).map { y in cos(Double.pi * Double(j) * Double(y) / Double(h)) }
    }

    var factors = [[Double]](repeating: [0, 0, 0], count: xComponents * yComponents)
    var rowX = [[Double]](repeating: [0, 0, 0], count: xComponents)

    px.data.withUnsafeBufferPointer { buf in
        for y in 0..<h {
            for i in 0..<xComponents { rowX[i] = [0, 0, 0] }
            let rowBase = y * px.bytesPerRow
            for x in 0..<w {
                let idx = rowBase + x * 4
                let r = linearLUT[Int(buf[idx])]
                let g = linearLUT[Int(buf[idx + 1])]
                let b = linearLUT[Int(buf[idx + 2])]
                for i in 0..<xComponents {
                    let cx = cosX[i][x]
                    rowX[i][0] += cx * r
                    rowX[i][1] += cx * g
                    rowX[i][2] += cx * b
                }
            }
            for j in 0..<yComponents {
                let cy = cosY[j][y]
                for i in 0..<xComponents {
                    let f = j * xComponents + i
                    factors[f][0] += cy * rowX[i][0]
                    factors[f][1] += cy * rowX[i][1]
                    factors[f][2] += cy * rowX[i][2]
                }
            }
        }
    }

    let pixelCount = Double(w * h)
    for j in 0..<yComponents {
        for i in 0..<xComponents {
            let f = j * xComponents + i
            let norm = (i == 0 && j == 0) ? 1.0 : 2.0
            let scale = norm / pixelCount
            factors[f] = factors[f].map { $0 * scale }
        }
    }

    let dc = factors[0]
    let ac = Array(factors[1...])

    func encodeDC(_ c: [Double]) -> Int {
        let r = Int(linearToSRGBByte(c[0]))
        let g = Int(linearToSRGBByte(c[1]))
        let b = Int(linearToSRGBByte(c[2]))
        return (r << 16) + (g << 8) + b
    }
    func encodeAC(_ c: [Double], _ maximum: Double) -> Int {
        func q(_ v: Double) -> Int { max(0, min(18, Int(floor(signPow(v / maximum, 0.5) * 9 + 9.5)))) }
        return q(c[0]) * 19 * 19 + q(c[1]) * 19 + q(c[2])
    }

    let sizeFlag = (xComponents - 1) + (yComponents - 1) * 9
    var hash = base83Encode(sizeFlag, 1)

    var maximum = 1.0
    if !ac.isEmpty {
        let actualMax = ac.flatMap { $0.map { abs($0) } }.max() ?? 0
        let quantMax = max(0, min(82, Int(floor(actualMax * 166 - 0.5))))
        maximum = Double(quantMax + 1) / 166.0
        hash += base83Encode(quantMax, 1)
    } else {
        hash += base83Encode(0, 1)
    }
    hash += base83Encode(encodeDC(dc), 4)
    for c in ac { hash += base83Encode(encodeAC(c, maximum), 2) }
    return hash
}

// MARK: - Step 2: decode -> a small sRGB CGImage

func decode(_ blurhash: String, width: Int, height: Int, punch: Double = 1.0) -> CGImage {
    let chars = Array(blurhash)
    func sub(_ lo: Int, _ hi: Int) -> Substring {
        return String(chars[lo..<hi])[...]
    }

    let sizeFlag = base83Decode(sub(0, 1))
    let numX = (sizeFlag % 9) + 1
    let numY = (sizeFlag / 9) + 1
    let quantMax = base83Decode(sub(1, 2))
    let realMax = (Double(quantMax + 1) / 166.0) * punch

    var colors = [[Double]]()
    let dcVal = base83Decode(sub(2, 6))
    colors.append([
        linearLUT[(dcVal >> 16) & 255],
        linearLUT[(dcVal >> 8) & 255],
        linearLUT[dcVal & 255],
    ])
    for comp in 1..<(numX * numY) {
        let val = base83Decode(sub(4 + comp * 2, 6 + comp * 2))
        let qr = val / (19 * 19)
        let qg = (val / 19) % 19
        let qb = val % 19
        colors.append([
            signPow((Double(qr) - 9) / 9.0, 2.0) * realMax,
            signPow((Double(qg) - 9) / 9.0, 2.0) * realMax,
            signPow((Double(qb) - 9) / 9.0, 2.0) * realMax,
        ])
    }

    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
    for y in 0..<height {
        for x in 0..<width {
            var r = 0.0, g = 0.0, b = 0.0
            for j in 0..<numY {
                let cy = cos(Double.pi * Double(y) * Double(j) / Double(height))
                for i in 0..<numX {
                    let cx = cos(Double.pi * Double(x) * Double(i) / Double(width))
                    let basis = cx * cy
                    let c = colors[i + j * numX]
                    r += c[0] * basis
                    g += c[1] * basis
                    b += c[2] * basis
                }
            }
            let idx = y * bytesPerRow + x * 4
            pixels[idx] = linearToSRGBByte(r)
            pixels[idx + 1] = linearToSRGBByte(g)
            pixels[idx + 2] = linearToSRGBByte(b)
            pixels[idx + 3] = 255
        }
    }

    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: &pixels,
        width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return ctx.makeImage()!
}

// MARK: - Step 3: Core Image passes (shared context, sRGB working space)

let ciContext = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    .useSoftwareRenderer: false,
])

// Pass 1 -- tonal compression: out = in * 0.65 + 0.175 per channel (CIColorMatrix).
func compressTones(_ image: CGImage) -> CGImage {
    let ci = CIImage(cgImage: image)
    let f = CIFilter(name: "CIColorMatrix")!
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(CIVector(x: tonalScale, y: 0, z: 0, w: 0), forKey: "inputRVector")
    f.setValue(CIVector(x: 0, y: tonalScale, z: 0, w: 0), forKey: "inputGVector")
    f.setValue(CIVector(x: 0, y: 0, z: tonalScale, w: 0), forKey: "inputBVector")
    f.setValue(CIVector(x: tonalBias, y: tonalBias, z: tonalBias, w: 0), forKey: "inputBiasVector")
    let out = f.outputImage!
    return ciContext.createCGImage(out, from: ci.extent)!
}

// Pass 2 -- Gaussian blur (radius 2), clamped so edges don't darken.
func smoothEdges(_ image: CGImage) -> CGImage {
    let ci = CIImage(cgImage: image)
    let f = CIFilter.gaussianBlur()
    f.inputImage = ci.clampedToExtent()
    f.radius = blurRadius
    let out = f.outputImage!.cropped(to: ci.extent)
    return ciContext.createCGImage(out, from: ci.extent)!
}

// MARK: - Resize + PNG output

func upscale(_ image: CGImage, to width: Int, height: Int) -> CGImage {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil,
        width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fputs("error: could not create PNG destination at \(path)\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("  wrote \(path)")
}

func loadCGImage(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fputs("error: could not read image at \(path)\n", stderr)
        exit(1)
    }
    return image
}

// MARK: - Step 4: reveal animation (GIF)

// One transition frame: cross-dissolve placeholder -> real at `t`, with a Gaussian
// "frosted-glass" shimmer whose radius peaks mid-transition.
func revealFrame(placeholder: CIImage, real: CIImage, rect: CGRect, t: Double) -> CGImage {
    let dissolve = CIFilter.dissolveTransition()
    dissolve.inputImage = placeholder
    dissolve.targetImage = real
    dissolve.time = Float(t)
    var img = dissolve.outputImage!.cropped(to: rect)

    let radius = shimmerMax * sin(Double.pi * t)
    if radius > 0.05 {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = img.clampedToExtent()
        blur.radius = Float(radius)
        img = blur.outputImage!.cropped(to: rect)
    }
    return ciContext.createCGImage(img, from: rect)!
}

func writeGIF(_ frames: [CGImage], frameDelay: Double, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.gif.identifier as CFString, frames.count, nil
    ) else {
        fputs("error: could not create GIF destination at \(path)\n", stderr)
        exit(1)
    }
    let fileProps = [kCGImagePropertyGIFDictionary as String:
        [kCGImagePropertyGIFLoopCount as String: 0]]                 // 0 = loop forever
    CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
    let frameProps = [kCGImagePropertyGIFDictionary as String:
        [kCGImagePropertyGIFDelayTime as String: frameDelay]]
    for frame in frames {
        CGImageDestinationAddImage(dest, frame, frameProps as CFDictionary)
    }
    CGImageDestinationFinalize(dest)
    print("  wrote \(path) (\(frames.count) frames)")
}

// MARK: - Step 3: black-hole artifact demo

// A near-black subject on a white background overshoots the 4x3 DCT and clips the
// center to pure black (a "black hole"); the same tonal + blur passes lift it.
func makeArtifactDemo(inputPath: String, outDir: String, prefix: String) {
    let src = loadCGImage(inputPath)
    let aspect = Double(src.width) / Double(src.height)         // keep the source's own aspect
    let decW = max(1, Int((Double(decodeH) * aspect).rounded()))
    let dispW = max(1, Int((Double(displayH) * aspect).rounded()))

    let h = encode(readPixels(src, width: src.width, height: src.height))
    print("BlurHash [\(prefix)]: \(h)")

    writePNG(upscale(src, to: dispW, height: displayH), to: "\(outDir)/\(prefix)-original.png")
    let dec = decode(h, width: decW, height: decodeH, punch: 1.0)   // raw decode -> the black hole
    writePNG(upscale(dec, to: dispW, height: displayH), to: "\(outDir)/\(prefix)-raw.png")
    let proc = smoothEdges(compressTones(dec))                      // Pass 1 + Pass 2 -> rescued
    writePNG(upscale(proc, to: dispW, height: displayH), to: "\(outDir)/\(prefix)-processed.png")
}

// MARK: - Main

// Resolve the article folder from this script's own location so it runs from any CWD.
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()      // .../scripts
let articleDir = scriptDir.deletingLastPathComponent().path                       // .../blurhash

let args = CommandLine.arguments
let inputPath = args.count > 1 ? args[1] : "\(articleDir)/blurhash_example.jpg"
let outDir = args.count > 2 ? args[2] : articleDir
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let source = loadCGImage(inputPath)

// Step 1 -- encode (full resolution)
let pixels = readPixels(source, width: source.width, height: source.height)
let hash = encode(pixels)
print("BlurHash: \(hash)")

// Step 1/4 -- the source image, downscaled for display
let originalDisplay = upscale(source, to: displayW, height: displayH)
writePNG(originalDisplay, to: "\(outDir)/01-original.png")

// Step 2 -- raw decode at 32x48
let decoded = decode(hash, width: decodeW, height: decodeH, punch: 1.0)
writePNG(upscale(decoded, to: displayW, height: displayH), to: "\(outDir)/02-decoded.png")

// Step 3, Pass 1 -- tonal compression
let tonal = compressTones(decoded)
writePNG(upscale(tonal, to: displayW, height: displayH), to: "\(outDir)/03-tonal.png")

// Step 3, Pass 2 -- Gaussian blur on the compressed image (the final placeholder)
let blurred = smoothEdges(tonal)
let placeholderDisplay = upscale(blurred, to: displayW, height: displayH)
writePNG(placeholderDisplay, to: "\(outDir)/04-blurred.png")

// Step 4 -- the reveal animation: hold placeholder -> dissolve+shimmer -> hold photo, looping.
let rect = CGRect(x: 0, y: 0, width: displayW, height: displayH)
let placeholderCI = CIImage(cgImage: placeholderDisplay)
let realCI = CIImage(cgImage: originalDisplay)
var frames = [CGImage](repeating: placeholderDisplay, count: gifHoldStart)
for k in 1...gifTransition {
    let t = Double(k) / Double(gifTransition + 1)        // (0, 1), endpoints are the holds
    frames.append(revealFrame(placeholder: placeholderCI, real: realCI, rect: rect, t: t))
}
frames += [CGImage](repeating: originalDisplay, count: gifHoldEnd)
writeGIF(frames, frameDelay: gifFrameDelay, to: "\(outDir)/04-reveal.gif")

// Step 3 demo -- the black-hole failure case (only if the t-shirt source is present)
let tshirtPath = "\(articleDir)/tshirt_example.jpg"
if FileManager.default.fileExists(atPath: tshirtPath) {
    makeArtifactDemo(inputPath: tshirtPath, outDir: outDir, prefix: "tshirt")
}

print("Done.")
