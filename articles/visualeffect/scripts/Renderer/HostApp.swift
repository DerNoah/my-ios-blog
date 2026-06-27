import SwiftUI
import UIKit
import CoreImage

// HostApp — renders the article's assets with the REAL swift-visual-effect library.
//
//   MODE=imagerender  -> render every content-applied asset offscreen via SwiftUI
//                        ImageRenderer (the real VisualEffectLayer / .visualEffect),
//                        write PNGs into the app's Documents container, then `_DONE`.
//   MODE=edge         -> display the live-backdrop edge demo (real VisualEffectViewRepresentable
//                        pinned to the safe-area edges) at the static scroll position FRAME/TOTAL,
//                        for an on-screen `simctl io screenshot`.
//
// The library's actual source file is compiled on the same swiftc line (see build_app.sh).

let W: CGFloat = 320, H: CGFloat = 480

func loadPhoto() -> UIImage {
    if let url = Bundle.main.url(forResource: "photo", withExtension: "jpg"),
       let img = UIImage(contentsOfFile: url.path) { return img }
    return UIImage()
}
let photo = loadPhoto()

func smoothstep(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }

// MARK: - App

@main
struct HostApp: App {
    var body: some Scene {
        WindowGroup {
            if (ProcessInfo.processInfo.environment["MODE"] ?? "") == "edge" {
                EdgeDemo(
                    frame: Int(ProcessInfo.processInfo.environment["FRAME"] ?? "0") ?? 0,
                    total: Int(ProcessInfo.processInfo.environment["TOTAL"] ?? "1") ?? 1
                )
                .ignoresSafeArea()
            } else {
                RenderRunner()
            }
        }
    }
}

// MARK: - Photo as fixed-size SwiftUI content

func photoView() -> some View {
    Image(uiImage: photo).resizable().scaledToFill()
        .frame(width: W, height: H).clipped()
}

// A VisualEffectLayer applied full-frame to the photo, clamped to W×H.
@MainActor func effectStill(_ values: VisualEffectValues, overridesOpacity: Bool) -> some View {
    let state = VisualEffectState()
    state.blurOverridesOpacity = overridesOpacity
    state.values = values
    return VisualEffectLayer(state: state) { photoView() }
        .frame(width: W, height: H).clipped()
}

// A frosted-glass card (the real VisualEffectLayer over a copy of the photo, clipped to a
// rounded rect) composited over the sharp photo — pixel-identical to a live backdrop card.
@MainActor func frostedCard(opacity: CGFloat) -> some View {
    let state = VisualEffectState()
    state.blurOverridesOpacity = false
    state.values = VisualEffectValues(blurRadius: 6, brightness: 0.10, saturation: 1.4, opacity: opacity)
    let card = VisualEffectLayer(state: state) { photoView() }
        .frame(width: W, height: H)
        .frame(width: 264, height: 180).clipped()        // window into the blurred photo
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.35), lineWidth: 1))
    return ZStack { photoView(); card }.frame(width: W, height: H)
}

// MARK: - MODE=imagerender

struct RenderRunner: View {
    @State private var status = "rendering…"
    var body: some View { Text(status).onAppear { status = renderAll() } }

    @MainActor func renderAll() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        func write(_ view: some View, _ name: String) {
            let r = ImageRenderer(content: view.frame(width: W, height: H)); r.scale = 1
            if let data = r.uiImage?.pngData() { try? data.write(to: docs.appendingPathComponent(name)) }
        }

        write(photoView(), "01-original.png")
        write(effectStill(VisualEffectValues(blurRadius: 6), overridesOpacity: true), "03-blur.png")
        write(effectStill(VisualEffectValues(brightness: 0.18), overridesOpacity: false), "04-brightness.png")
        write(effectStill(VisualEffectValues(contrast: 1.4), overridesOpacity: false), "05-contrast.png")
        write(effectStill(VisualEffectValues(saturation: 1.8), overridesOpacity: false), "06-saturation.png")
        write(effectStill(VisualEffectValues(grayscale: 0.85), overridesOpacity: false), "07-grayscale.png")
        write(effectStill(VisualEffectValues(hueRotation: 90), overridesOpacity: false), "08-hue.png")
        write(frostedCard(opacity: 0.75), "09-opacity.png")
        write(frostedCard(opacity: 1.0), "10-frosted.png")

        // 11 blur-in: photo blurs 0 -> 6 with a slight spring overshoot (content stays opaque).
        let blurinN = 16
        for f in 0...blurinN {
            let t = Double(f) / Double(blurinN)
            let r = 6.0 * (t >= 1 ? 1 : 1 - exp(-6 * t) * cos(7.5 * t))
            write(effectStill(VisualEffectValues(blurRadius: r), overridesOpacity: false),
                  String(format: "11-blurin-%03d.png", f))
        }
        // 12 scrub: fractionComplete 0 -> 1 -> 0, blur/brightness/saturation interpolate together.
        let scrubN = 24, sb = 6.0, sbr = 0.15, ss = 1.6
        for f in 0...scrubN {
            let p = f <= scrubN / 2 ? smoothstep(Double(f) / Double(scrubN / 2))
                                    : smoothstep(1 - Double(f - scrubN / 2) / Double(scrubN - scrubN / 2))
            let v = VisualEffectValues(blurRadius: sb * (1 - p), brightness: sbr * (1 - p),
                                       saturation: 1 + (ss - 1) * (1 - p))
            write(effectStill(v, overridesOpacity: false), String(format: "12-scrub-%03d.png", f))
        }
        // 13 fade-out: a frosted overlay (blurOverridesOpacity = true) dissolves to reveal the sharp photo.
        let fadeN = 16
        for f in 0...fadeN {
            let t = Double(f) / Double(fadeN)
            let blur = 6.0 * (1 - (1 - (1 - t) * (1 - t)))      // ease-out 6 -> 0
            let overlay = effectStill(VisualEffectValues(blurRadius: blur), overridesOpacity: true)
            write(ZStack { photoView(); overlay }, String(format: "13-fadeout-%03d.png", f))
        }

        try? Data().write(to: docs.appendingPathComponent("_DONE"))
        return "DONE"
    }
}

// MARK: - MODE=edge  (real UIKit VisualEffectView over a UIScrollView, captured on-screen)

let cardPalette: [UIColor] = [
    UIColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), UIColor(red: 1, green: 0.62, blue: 0.26, alpha: 1),
    UIColor(red: 0.28, green: 0.78, blue: 0.56, alpha: 1), UIColor(red: 0.18, green: 0.60, blue: 0.90, alpha: 1),
    UIColor(red: 0.61, green: 0.35, blue: 0.85, alpha: 1), UIColor(red: 1, green: 0.42, blue: 0.62, alpha: 1),
]

func blurred(_ image: UIImage, radius: Double) -> UIImage {
    guard let ci = CIImage(image: image) else { return image }
    let out = ci.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: ci.extent)
    let ctx = CIContext()
    guard let cg = ctx.createCGImage(out, from: ci.extent) else { return image }
    return UIImage(cgImage: cg)
}

// SwiftUI host for the UIKit edge demo (so MODE=imagerender stays SwiftUI/ImageRenderer).
struct EdgeDemo: UIViewControllerRepresentable {
    let frame: Int
    let total: Int
    func makeUIViewController(context: Context) -> EdgeViewController { EdgeViewController(frame: frame, total: total) }
    func updateUIViewController(_ vc: EdgeViewController, context: Context) {}
}

// A real UIScrollView feed under the library's real UIKit VisualEffectView, pinned to the
// safe-area edges as a variable blur. Auto Layout gives symmetric horizontal insets.
final class EdgeViewController: UIViewController {
    private let frameIndex: Int
    private let total: Int

    private let maskedContainer = UIView()           // holds the scroll view; carries the content fade mask
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let contentMask = CAGradientLayer()       // fixed in screen space (container doesn't scroll)

    private let topBlur = VisualEffectView(blurInsets: UIEdgeInsets(top: -40, left: -40, bottom: 0, right: -40),
                                           initialValues: VisualEffectValues(blurRadius: 8))
    private let botBlur = VisualEffectView(blurInsets: UIEdgeInsets(top: 0, left: -40, bottom: -40, right: -40),
                                           initialValues: VisualEffectValues(blurRadius: 8))
    private let topMask = CAGradientLayer()
    private let botMask = CAGradientLayer()

    init(frame: Int, total: Int) { self.frameIndex = frame; self.total = total; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // 1. Blurred + dimmed wallpaper (full screen, behind everything).
        let bg = UIImageView(image: blurred(photo, radius: 32))
        bg.contentMode = .scaleAspectFill
        bg.clipsToBounds = true
        let dim = UIView(); dim.backgroundColor = UIColor.black.withAlphaComponent(0.10)

        // 2. Scroll view + 16 colored cards inside a masked container.
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = false
        stack.axis = .vertical; stack.spacing = 12
        for i in 0..<16 { stack.addArrangedSubview(makeCard(i)) }
        maskedContainer.layer.mask = contentMask
        contentMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor,
                              UIColor.black.cgColor, UIColor.clear.cgColor]
        contentMask.startPoint = CGPoint(x: 0.5, y: 0); contentMask.endPoint = CGPoint(x: 0.5, y: 1)

        // 3. Variable-blur bands: the real UIKit VisualEffectView, gradient-masked across the band.
        topBlur.layer.mask = topMask; botBlur.layer.mask = botMask
        topMask.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]   // full blur at the screen edge → clear inward
        botMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        for m in [topMask, botMask] { m.startPoint = CGPoint(x: 0.5, y: 0); m.endPoint = CGPoint(x: 0.5, y: 1) }

        for v in [bg, dim, maskedContainer, topBlur, botBlur] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        maskedContainer.addSubview(scrollView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        func pin(_ v: UIView, to other: UIView) -> [NSLayoutConstraint] {
            [v.topAnchor.constraint(equalTo: other.topAnchor), v.bottomAnchor.constraint(equalTo: other.bottomAnchor),
             v.leadingAnchor.constraint(equalTo: other.leadingAnchor), v.trailingAnchor.constraint(equalTo: other.trailingAnchor)]
        }
        NSLayoutConstraint.activate(pin(bg, to: view) + pin(dim, to: view) + pin(maskedContainer, to: view)
            + pin(scrollView, to: maskedContainer) + [
            // Canonical scroll-view Auto Layout: pin the stack to the CONTENT guide (which defines
            // contentSize) with a symmetric 16 pt inset, and fix its width to the FRAME guide so it
            // only scrolls vertically and never runs off either edge.
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])
    }

    private static let contentHeight = CGFloat(16) * 96 + CGFloat(15) * 12   // 16 cards (h 96, gap 12)

    private func applyScroll() {
        let maxOff = max(0, Self.contentHeight - view.bounds.height)
        let half = total / 2
        let t = frameIndex <= half ? smoothstep(Double(frameIndex) / Double(max(1, half)))
                                   : smoothstep(1 - Double(frameIndex - half) / Double(max(1, total - half)))
        scrollView.contentOffset = CGPoint(x: 0, y: maxOff * CGFloat(t))
    }

    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); applyScroll() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let topSafe = max(view.safeAreaInsets.top, 48)
        let botSafe = max(view.safeAreaInsets.bottom, 32)
        let w = view.bounds.width, h = view.bounds.height

        CATransaction.begin(); CATransaction.setDisableActions(true)
        topBlur.frame = CGRect(x: 0, y: 0, width: w, height: topSafe);      topMask.frame = topBlur.bounds
        botBlur.frame = CGRect(x: 0, y: h - botSafe, width: w, height: botSafe); botMask.frame = botBlur.bounds
        contentMask.frame = CGRect(x: 0, y: 0, width: w, height: h)
        contentMask.locations = [0, NSNumber(value: Double(topSafe / h)),
                                 NSNumber(value: Double(1 - botSafe / h)), 1]
        CATransaction.commit()

        applyScroll()   // deterministic ping-pong scroll position for this frame
    }

    private func makeCard(_ i: Int) -> UIView {
        let card = UIView()
        card.backgroundColor = cardPalette[i % cardPalette.count]
        card.layer.cornerRadius = 18
        card.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let circle = UIView()
        circle.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        circle.layer.cornerRadius = 24
        circle.widthAnchor.constraint(equalToConstant: 48).isActive = true
        circle.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let title = UILabel(); title.text = "Item \(i + 1)"
        title.font = .systemFont(ofSize: 17, weight: .semibold); title.textColor = .white
        let sub = UILabel(); sub.text = "Tap to open this card"
        sub.font = .systemFont(ofSize: 12); sub.textColor = UIColor.white.withAlphaComponent(0.85)
        let labels = UIStackView(arrangedSubviews: [title, sub]); labels.axis = .vertical; labels.spacing = 4

        let row = UIStackView(arrangedSubviews: [circle, labels])
        row.axis = .horizontal; row.spacing = 12; row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }
}
