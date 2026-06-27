#!/usr/bin/env swift
//
//  generate_visualeffect.swift
//
//  Generate the step-by-step output images used in the VisualEffect article
//  (index.md), on macOS, with the *real* Core Image filters that correspond to
//  SwiftUI's `.visualEffect { ... }` chain in swift-visual-effect.
//
//      01-original.png ... the source photo, no effect
//      02-blur.png ....... CIGaussianBlur  radius 6
//      03-brightness.png . CIColorControls brightness +0.18 (additive)
//      04-contrast.png ... CIColorControls contrast 1.4
//      05-saturation.png . CIColorControls saturation 1.8
//      06-grayscale.png .. blend toward a saturation-0 copy by 0.85
//      07-hue.png ........ CIHueAdjust 90 degrees
//      08-opacity.png .... a frosted card at opacity 0.75 over the sharp photo
//      09-frosted.png .... the composed frosted-glass card
//      10-blurin.gif ..... implicit spring blur-in (blurRadius 0 -> 6)
//      11-scrub.gif ...... interactive scrub: fractionComplete 0 -> 1 -> 0
//      12-fadeout.gif .... blurOverridesOpacity dismissal (alpha = min(1, blur))
//
//  This is the higher-fidelity companion to generate_visualeffect.py: it drives
//  the same Core Image filters the library relies on, on a single shared
//  CIContext working in sRGB. The committed article assets are the Pillow
//  output; run this with an output dir of your choice to compare.
//
//  Usage:
//      swift articles/visualeffect/scripts/generate_visualeffect.swift [input.jpg] [output_dir]
//  Defaults (resolved from this script's location, so it runs from any directory):
//      input = ../../blurhash/blurhash_example.jpg, output_dir = ../  (articles/visualeffect)
//

import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - Article parameters

let W = 320, H = 480
let workingRect = CGRect(x: 0, y: 0, width: W, height: H)

let blurRadius = 6.0          // .blurredIn
let brightnessAmt = 0.18      // additive
let contrastAmt = 1.4
let saturationAmt = 1.8
let grayscaleAmt = 0.85
let hueDegrees = 90.0
let opacityAmt = 0.75

let cardBox = CGRect(x: 28, y: 150, width: 264, height: 180)   // centered panel
let cardBlur = 6.0, cardBright = 0.10, cardSat = 1.4
let cardRadius: CGFloat = 28

let scrubBlur = 6.0, scrubBright = 0.15, scrubSat = 1.6

// MARK: - Shared Core Image context (sRGB working + output space)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ciContext = CIContext(options: [
    .workingColorSpace: srgb,
    .outputColorSpace: srgb,
    .useSoftwareRenderer: false,
])

func ci(_ img: CGImage) -> CIImage { CIImage(cgImage: img) }
func toCG(_ image: CIImage, _ rect: CGRect = workingRect) -> CGImage {
    ciContext.createCGImage(image, from: rect)!
}

// MARK: - The seven effects (the SwiftUI .visualEffect chain, via Core Image)

func fxBlur(_ img: CGImage, _ radius: Double) -> CGImage {
    if radius <= 0.01 { return img }
    let f = CIFilter.gaussianBlur()
    f.inputImage = ci(img).clampedToExtent()
    f.radius = Float(radius)
    return toCG(f.outputImage!.cropped(to: ci(img).extent), ci(img).extent)
}

func fxColorControls(_ img: CGImage, brightness: Double = 0, contrast: Double = 1, saturation: Double = 1) -> CGImage {
    let f = CIFilter.colorControls()
    f.inputImage = ci(img)
    f.brightness = Float(brightness)   // additive, like SwiftUI .brightness
    f.contrast = Float(contrast)
    f.saturation = Float(saturation)
    return toCG(f.outputImage!.cropped(to: ci(img).extent), ci(img).extent)
}

func fxBrightness(_ img: CGImage, _ a: Double) -> CGImage { fxColorControls(img, brightness: a) }
func fxContrast(_ img: CGImage, _ a: Double) -> CGImage { fxColorControls(img, contrast: a) }
func fxSaturation(_ img: CGImage, _ a: Double) -> CGImage { fxColorControls(img, saturation: a) }

func fxGrayscale(_ img: CGImage, _ amount: Double) -> CGImage {
    let gray = fxColorControls(img, saturation: 0)
    let d = CIFilter.dissolveTransition()
    d.inputImage = ci(img)
    d.targetImage = ci(gray)
    d.time = Float(amount)
    return toCG(d.outputImage!.cropped(to: ci(img).extent), ci(img).extent)
}

func fxHue(_ img: CGImage, _ degrees: Double) -> CGImage {
    let f = CIFilter.hueAdjust()
    f.inputImage = ci(img)
    f.angle = Float(degrees * .pi / 180.0)
    return toCG(f.outputImage!.cropped(to: ci(img).extent), ci(img).extent)
}

// MARK: - Frosted-glass card

// A grayscale mask: `opacity` inside the rounded card box, 0 outside (full frame).
func roundedMask(opacity: Double) -> CGImage {
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: W, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(workingRect)
    ctx.addPath(CGPath(roundedRect: cardBox, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil))
    ctx.setFillColor(gray: CGFloat(opacity), alpha: 1)
    ctx.fillPath()
    return ctx.makeImage()!
}

func strokeRim(_ image: CGImage) -> CGImage {
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: workingRect)
    ctx.addPath(CGPath(roundedRect: cardBox, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil))
    ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.35)
    ctx.setLineWidth(1)
    ctx.strokePath()
    return ctx.makeImage()!
}

func makeCard(_ photo: CGImage, opacity: Double = 1.0) -> CGImage {
    var fx = fxBlur(photo, cardBlur)
    fx = fxBrightness(fx, cardBright)
    fx = fxSaturation(fx, cardSat)

    let blend = CIFilter.blendWithMask()
    blend.inputImage = ci(fx)
    blend.backgroundImage = ci(photo)
    blend.maskImage = ci(roundedMask(opacity: opacity))
    return strokeRim(toCG(blend.outputImage!.cropped(to: workingRect)))
}

// MARK: - Easing (matches the Python generator)

func smoothstep(_ t: Double) -> Double { let c = min(1, max(0, t)); return c * c * (3 - 2 * c) }
func easeOut(_ t: Double) -> Double { 1 - (1 - t) * (1 - t) }
func springEase(_ t: Double) -> Double { t >= 1 ? 1 : 1 - exp(-6 * t) * cos(7.5 * t) }

// MARK: - Resize / PNG / GIF I/O

func resize(_ image: CGImage, _ width: Int, _ height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

func loadCGImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fputs("error: could not read image at \(path)\n", stderr); exit(1)
    }
    return image
}

func writePNG(_ image: CGImage, to path: String) {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else {
        fputs("error: PNG destination at \(path)\n", stderr); exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("  wrote \(path)")
}

func writeGIF(_ frames: [CGImage], frameDelay: Double, to path: String) {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.gif.identifier as CFString, frames.count, nil) else {
        fputs("error: GIF destination at \(path)\n", stderr); exit(1)
    }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String:
        [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
    let frameProps = [kCGImagePropertyGIFDictionary as String:
        [kCGImagePropertyGIFDelayTime as String: frameDelay]] as CFDictionary
    for f in frames { CGImageDestinationAddImage(dest, f, frameProps) }
    CGImageDestinationFinalize(dest)
    print("  wrote \(path) (\(frames.count) frames)")
}

// MARK: - GIF builders

func makeBlurInGIF(_ photo: CGImage, to path: String) {
    var frames = [CGImage](repeating: photo, count: 3)
    let trans = 20
    for k in 1...trans { frames.append(fxBlur(photo, blurRadius * springEase(Double(k) / Double(trans)))) }
    frames += [CGImage](repeating: fxBlur(photo, blurRadius), count: 6)
    writeGIF(frames, frameDelay: 0.04, to: path)
}

// Draw the progress bar + `fractionComplete` label onto a frame (bottom of the image).
func scrubOverlay(_ image: CGImage, _ p: Double) -> CGImage {
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: workingRect)
    let x = 22.0, y = 24.0, bw = Double(W) - 44, bh = 7.0
    func bar(_ width: Double, _ alpha: Double) {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: bh),
                           cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: CGFloat(alpha)); ctx.fillPath()
    }
    bar(bw, 0.31)
    bar(bw * p, 0.92)

    let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
    let text = String(format: "fractionComplete %.2f", p)
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 0.92),
    ]
    let attr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = CGPoint(x: x, y: y + bh + 6)
    CTLineDraw(line, ctx)
    return ctx.makeImage()!
}

func scrubFrame(_ photo: CGImage, _ p: Double) -> CGImage {
    var f = fxBlur(photo, scrubBlur * (1 - p))
    f = fxBrightness(f, scrubBright * (1 - p))
    f = fxSaturation(f, 1 + (scrubSat - 1) * (1 - p))
    return scrubOverlay(f, p)
}

func makeScrubGIF(_ photo: CGImage, to path: String) {
    let steps = 16, hold = 4
    var frames = [CGImage](repeating: scrubFrame(photo, 0), count: hold)
    for k in 1...steps { frames.append(scrubFrame(photo, smoothstep(Double(k) / Double(steps)))) }
    frames += [CGImage](repeating: scrubFrame(photo, 1), count: hold)
    for k in 1...steps { frames.append(scrubFrame(photo, smoothstep(1 - Double(k) / Double(steps)))) }
    writeGIF(frames, frameDelay: 0.045, to: path)
}

func makeFadeOutGIF(_ photo: CGImage, to path: String) {
    let trans = 18
    var frames = [CGImage](repeating: fxBlur(photo, blurRadius), count: 3)
    for k in 1...trans {
        let blur = blurRadius * (1 - easeOut(Double(k) / Double(trans)))   // 6 -> 0
        let eff = max(1.0, blur), alpha = min(1.0, blur)
        let surf = ci(fxBlur(photo, eff)).applyingFilter("CIColorMatrix",
            parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = surf
        over.backgroundImage = ci(photo)
        frames.append(toCG(over.outputImage!.cropped(to: workingRect)))
    }
    frames += [CGImage](repeating: photo, count: 8)
    writeGIF(frames, frameDelay: 0.045, to: path)
}

// MARK: - Main

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // .../scripts
let articleDir = scriptDir.deletingLastPathComponent().path                    // .../visualeffect

let args = CommandLine.arguments
let inputPath = args.count > 1 ? args[1] : "\(articleDir)/../blurhash/blurhash_example.jpg"
let outDir = args.count > 2 ? args[2] : articleDir
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let photo = resize(loadCGImage(inputPath), W, H)
print("source: \(inputPath) -> \(W)x\(H)")

writePNG(photo, to: "\(outDir)/01-original.png")
writePNG(fxBlur(photo, blurRadius), to: "\(outDir)/02-blur.png")
writePNG(fxBrightness(photo, brightnessAmt), to: "\(outDir)/03-brightness.png")
writePNG(fxContrast(photo, contrastAmt), to: "\(outDir)/04-contrast.png")
writePNG(fxSaturation(photo, saturationAmt), to: "\(outDir)/05-saturation.png")
writePNG(fxGrayscale(photo, grayscaleAmt), to: "\(outDir)/06-grayscale.png")
writePNG(fxHue(photo, hueDegrees), to: "\(outDir)/07-hue.png")
writePNG(makeCard(photo, opacity: opacityAmt), to: "\(outDir)/08-opacity.png")
writePNG(makeCard(photo), to: "\(outDir)/09-frosted.png")

makeBlurInGIF(photo, to: "\(outDir)/10-blurin.gif")
makeScrubGIF(photo, to: "\(outDir)/11-scrub.gif")
makeFadeOutGIF(photo, to: "\(outDir)/12-fadeout.gif")

print("Done.")
