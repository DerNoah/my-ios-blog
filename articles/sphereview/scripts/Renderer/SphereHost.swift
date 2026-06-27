import SwiftUI
import UIKit

// SphereHost — renders the article's media with the REAL swift-sphere-view library.
// SphereElementView.swift is compiled on the same swiftc line (see build_app.sh), so the
// internal `setRotationOffset(xAxis:yAxis:)` is callable to drive a smooth, deterministic
// CADisplayLink spin. Zoom/focus use the public `sphereRadius` / front-item tracking.
//
//   MODE=spin | rotate | momentum | zoom | focus | still   (default: spin)
// Each mode plays a seamless-looping animation, captured on-screen via `simctl io recordVideo`.

// MARK: - Chips (colored circles with white SF Symbol glyphs)

let symbolNames = [
    "star.fill", "heart.fill", "bolt.fill", "flame.fill", "leaf.fill", "drop.fill",
    "moon.fill", "sun.max.fill", "cloud.fill", "snowflake", "camera.fill", "music.note",
    "bell.fill", "gift.fill", "gamecontroller.fill", "paintbrush.fill", "hammer.fill",
    "cart.fill", "bag.fill", "gearshape.fill", "house.fill", "car.fill", "airplane",
    "bicycle", "globe", "map.fill", "flag.fill", "tag.fill", "pencil", "book.fill",
    "lightbulb.fill", "key.fill", "lock.fill", "trophy.fill", "crown.fill", "sparkles",
    "hare.fill", "pawprint.fill", "bolt.heart.fill", "wand.and.stars",
]

let chipColors: [UIColor] = [
    UIColor(red: 1.00, green: 0.37, blue: 0.34, alpha: 1), UIColor(red: 1.00, green: 0.62, blue: 0.26, alpha: 1),
    UIColor(red: 0.99, green: 0.80, blue: 0.22, alpha: 1), UIColor(red: 0.28, green: 0.78, blue: 0.56, alpha: 1),
    UIColor(red: 0.18, green: 0.60, blue: 0.90, alpha: 1), UIColor(red: 0.40, green: 0.47, blue: 0.95, alpha: 1),
    UIColor(red: 0.61, green: 0.35, blue: 0.85, alpha: 1), UIColor(red: 1.00, green: 0.42, blue: 0.62, alpha: 1),
    UIColor(red: 0.20, green: 0.72, blue: 0.78, alpha: 1),
]

final class Chip: UIView {
    init(index i: Int, size: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        backgroundColor = chipColors[i % chipColors.count]
        layer.cornerRadius = size / 2
        layer.borderColor = UIColor.white.cgColor      // ring shown when this is the front item
        let cfg = UIImage.SymbolConfiguration(pointSize: size * 0.40, weight: .semibold)
        let img = UIImage(systemName: symbolNames[i % symbolNames.count], withConfiguration: cfg)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let iv = UIImageView(image: img)
        iv.frame = bounds; iv.contentMode = .center
        addSubview(iv)
    }
    required init?(coder: NSCoder) { fatalError() }
    var isFront = false { didSet { layer.borderWidth = isFront ? 3 : 0 } }
}

// MARK: - View controller

final class SphereViewController: UIViewController {
    private let mode: String
    private let sphere = SphereElementView(frame: .zero)
    private var link: CADisplayLink?
    private var elapsed: CFTimeInterval = 0
    private var didSnap = false

    init(mode: String) { self.mode = mode; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let grad = CAGradientLayer()
        grad.colors = [UIColor(red: 0.08, green: 0.09, blue: 0.16, alpha: 1).cgColor,
                       UIColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1).cgColor]
        view.layer.addSublayer(grad)
        (view.layer.sublayers?.first)?.frame = UIScreen.main.bounds

        sphere.isScrollEnabled = false; sphere.isPinchEnabled = false
        sphere.clipsToBounds = false
        view.addSubview(sphere)
        for i in 0..<40 { sphere.contentView.addSubview(Chip(index: i, size: 56)) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first?.frame = view.bounds
        let side = view.bounds.width
        sphere.frame = CGRect(x: 0, y: (view.bounds.height - side) / 2, width: side, height: side)
        if mode != "zoom" { sphere.sphereRadius = side * 0.40 }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if mode == "still" {
            sphere.setRotationOffset(xAxis: 18, yAxis: 26)   // a pleasing 3/4 orientation for the photo
            updateFocusRing()
            return
        }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common); link = l
    }

    // Angular speed ω (rad/s) → setRotationOffset arg: rotation = arg * 0.01 = ω·dt  ⇒  arg = ω·dt·100.
    private func rot(xSpeed: Double, ySpeed: Double, dt: Double) {
        sphere.setRotationOffset(xAxis: xSpeed * dt * 100, yAxis: ySpeed * dt * 100)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - link.timestamp
        elapsed += dt
        let twoPi = 2 * Double.pi

        switch mode {
        case "rotate":                                   // tilted tumble about a 45° axis (loops ~2.83 s)
            rot(xSpeed: twoPi / 4, ySpeed: twoPi / 4, dt: dt)
        case "zoom":                                     // radius pulse + Y spin, both period 4 s → seamless
            let side = Double(view.bounds.width)
            sphere.sphereRadius = side * (0.40 + 0.13 * sin(twoPi * elapsed / 4))
            rot(xSpeed: 0, ySpeed: twoPi / 4, dt: dt)
        case "momentum":                                 // flick → decay → snap → hold, loop (period 4.2 s)
            let cyc = elapsed.truncatingRemainder(dividingBy: 4.2)
            if cyc < 2.3 {
                didSnap = false
                let v = (twoPi / 1.4) * exp(-1.6 * cyc)   // decaying angular velocity
                rot(xSpeed: 0, ySpeed: v, dt: dt)
            } else if !didSnap {
                didSnap = true; sphere.snapToFrontItem() // real public snap animation
            }
            updateFocusRing()
        case "focus":                                    // slow globe spin, ring tracks the frontmost item
            rot(xSpeed: 0, ySpeed: twoPi / 5, dt: dt)
            updateFocusRing()
        default:                                         // "spin" — steady globe spin (5 s / revolution)
            rot(xSpeed: 0, ySpeed: twoPi / 5, dt: dt)
        }
    }

    // The frontmost chip = the one nearest the viewer = highest layer.zPosition (→ 1.0).
    private func updateFocusRing() {
        var front: Chip?; var maxZ: CGFloat = -1
        for case let chip as Chip in sphere.contentView.subviews where chip.layer.zPosition > maxZ {
            maxZ = chip.layer.zPosition; front = chip
        }
        for case let chip as Chip in sphere.contentView.subviews { chip.isFront = (chip === front) }
    }
}

// MARK: - SwiftUI host

struct SphereHostView: UIViewControllerRepresentable {
    let mode: String
    func makeUIViewController(context: Context) -> SphereViewController { SphereViewController(mode: mode) }
    func updateUIViewController(_ vc: SphereViewController, context: Context) {}
}

@main
struct SphereHost: App {
    var body: some Scene {
        WindowGroup {
            SphereHostView(mode: ProcessInfo.processInfo.environment["MODE"] ?? "spin")
                .ignoresSafeArea()
                .statusBarHidden()
        }
    }
}
