import AppKit
import AVFoundation
import SwiftUI

/// Records demo clips of TypewriterConsole by driving a scripted scenario in a real window and
/// capturing it frame-by-frame. Usage:
///
///     swift run demo-recorder <hero|reveal|streaming|typewriter|selection> [--out <path>] [--gif <path>]
///     swift run demo-recorder smoke [--out <path>]     # one PNG frame — capture-path pre-flight
///     swift run demo-recorder probe <file.mp4>         # duration / dimensions / fps

func usage() -> Never {
    fputs("""
    usage: demo-recorder <hero|reveal|streaming|typewriter|selection|smoke> [--out <path>] [--gif <path>]
           demo-recorder probe <file>

    """, stderr)
    exit(64)
}

func after(_ seconds: TimeInterval, _ body: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        MainActor.assumeIsolated(body)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

// MARK: - probe

if command == "probe" {
    guard arguments.count >= 2 else { usage() }
    let url = URL(fileURLWithPath: arguments[1])
    Task.detached {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                fputs("no video track in \(url.path)\n", stderr)
                exit(1)
            }
            let (size, fps) = try await track.load(.naturalSize, .nominalFrameRate)
            print(String(format: "%@: %.2f s, %.0fx%.0f, %.1f fps",
                         url.lastPathComponent, duration.seconds, size.width, size.height, fps))
            exit(0)
        } catch {
            fputs("probe failed: \(error)\n", stderr)
            exit(1)
        }
    }
    RunLoop.main.run()
    exit(1)
}

// MARK: - record

guard let scenario = Scenario.named(command) else { usage() }
let outPath = option("--out") ?? "../\(scenario.defaultFileName)"
let gifPath = option("--gif")

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// Defeat App Nap / display sleep so timers and TimelineView keep ticking for the whole take.
let activity = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiated, .idleDisplaySleepDisabled], reason: "recording demo clip")

/// Borderless windows refuse key status by default; the selection scenario needs it.
final class RecorderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

let model = DemoModel()
let window = RecorderWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                            styleMask: [.borderless], backing: .buffered, defer: false)
window.appearance = NSAppearance(named: .darkAqua)
window.level = .floating
window.isOpaque = true
window.backgroundColor = .black
let hosting = NSHostingView(rootView: scenario.makeView(model))
hosting.sizingOptions = []
window.contentView = hosting
window.center()
window.makeKeyAndOrderFront(nil)
window.orderFrontRegardless()
app.activate(ignoringOtherApps: true)

let context = DemoContext(model: model, window: window)
var finished = false

if command == "smoke" {
    after(0.9) {
        for event in scenario.events { event.run(context) }
    }
    after(2.0) {
        do {
            try Recorder.smokePNG(view: hosting, to: URL(fileURLWithPath: outPath))
            print("wrote \(outPath)")
            exit(0)
        } catch {
            fputs("smoke capture failed: \(error)\n", stderr)
            exit(2)
        }
    }
} else {
    // Warm-up: let the window reach the screen so the first captured frame is real content.
    after(0.8) {
        do {
            let gif = gifPath.map { GifWriter(url: URL(fileURLWithPath: $0)) }
            let recorder = try Recorder(view: hosting, outURL: URL(fileURLWithPath: outPath), gif: gif)
            recorder.start(fps: 30)
            for event in scenario.events {
                after(event.at) { event.run(context) }
            }
            after(scenario.duration) {
                Task { @MainActor in
                    do {
                        try await recorder.finish()
                        finished = true
                        print("wrote \(outPath): \(recorder.captured) frames, \(recorder.dropped) dropped")
                        exit(0)
                    } catch {
                        fputs("finalize failed: \(error)\n", stderr)
                        exit(2)
                    }
                }
            }
        } catch {
            fputs("recorder init failed: \(error)\n", stderr)
            exit(2)
        }
    }
    after(0.8 + scenario.duration + 15) {
        if !finished {
            fputs("watchdog: finalize hung\n", stderr)
            exit(3)
        }
    }
}

_ = activity
app.run()
