import AppKit
import SwiftUI
import TypewriterConsole

/// Demo styles mirror the library's defaults (system text, red errors, dimmed monospaced output)
/// but a few points larger, so the text stays readable at the blog's embed width.
@MainActor
enum DemoStyle {
    static let info = ConsoleEntry.Style(font: .systemFont(ofSize: 13), color: .labelColor)
    static let error = ConsoleEntry.Style(font: .systemFont(ofSize: 13), color: .systemRed)
    static let mono = ConsoleEntry.Style(font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                         color: .secondaryLabelColor)
}

@MainActor
final class DemoModel: ObservableObject {
    @Published var entries: [ConsoleEntry] = []
    @Published var live: ConsoleLiveStream?
    @Published var typewriterStart: Date?

    private var streamText = ""
    private var streamStartedAt: Date?

    func append(_ text: String, style: ConsoleEntry.Style, id: UUID = UUID(), revealAt: Date? = Date()) {
        entries.append(ConsoleEntry(id: id, text: text, style: style, revealAt: revealAt))
    }

    func rewrite(id: UUID, to text: String) {
        guard let i = entries.lastIndex(where: { $0.id == id }) else { return }
        entries[i].text = text
    }

    func stream(_ chunk: String) {
        if streamStartedAt == nil { streamStartedAt = Date() }
        let previousLength = streamText.count
        streamText += chunk
        live = ConsoleLiveStream(text: streamText, startedAt: streamStartedAt,
                                 revealFrom: previousLength, chunkAt: Date(), style: DemoStyle.mono)
    }

    func graduate() {
        guard !streamText.isEmpty else { return }
        entries.append(ConsoleEntry(text: streamText, style: DemoStyle.mono, revealAt: nil))
        streamText = ""
        streamStartedAt = nil
        live = nil
    }
}

@MainActor
struct DemoContext {
    let model: DemoModel
    let window: NSWindow
}

struct TimelineEvent: Sendable {
    let at: TimeInterval
    let run: @MainActor @Sendable (DemoContext) -> Void
}

@MainActor
struct Scenario {
    let name: String
    let defaultFileName: String
    let duration: TimeInterval
    let makeView: (DemoModel) -> AnyView
    let events: [TimelineEvent]
}

// MARK: - Views

struct ConsoleDemoView: View {
    @ObservedObject var model: DemoModel
    var perCharacter: Double = 0.0075

    var body: some View {
        ZStack {
            Color(red: 0.075, green: 0.083, blue: 0.102)
            ConsoleView(entries: model.entries, liveStream: model.live, perCharacter: perCharacter)
                .padding(6)
        }
    }
}

struct TypewriterDemoView: View {
    @ObservedObject var model: DemoModel

    var body: some View {
        ZStack {
            Color(red: 0.075, green: 0.083, blue: 0.102)
            TypewriterText(
                text: "The same per-letter fade, as a plain SwiftUI view — status lines, empty states, a hero caption.",
                start: model.typewriterStart ?? .distantFuture,
                perCharacter: 0.045,
                color: .white.opacity(0.92),
                font: .system(size: 21).italic()
            )
            .multilineTextAlignment(.center)
            .frame(maxWidth: 470)
            .padding(40)
        }
    }
}

// MARK: - Deterministic bursty chunking

/// SplitMix64 — seeded so every re-record produces the identical take.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Splits `full` into LLM-ish bursts (2–9 characters, 70–140 ms apart, optional stalls after
/// given flush indexes) and returns the stream events plus when the stream ends.
@MainActor
private func chunkedStream(_ full: String, from start: TimeInterval, seed: UInt64,
                           stallsAfter: Set<Int> = []) -> (events: [TimelineEvent], endsAt: TimeInterval) {
    var rng = SplitMix64(seed: seed)
    var events: [TimelineEvent] = []
    var t = start
    var rest = Substring(full)
    var flush = 0
    while !rest.isEmpty {
        let n = Int.random(in: 2...9, using: &rng)
        let chunk = String(rest.prefix(n))
        rest = rest.dropFirst(n)
        events.append(TimelineEvent(at: t) { $0.model.stream(chunk) })
        flush += 1
        t += Double.random(in: 0.07...0.14, using: &rng) + (stallsAfter.contains(flush) ? 0.45 : 0)
    }
    return (events, t)
}

// MARK: - Scenarios

extension Scenario {
    static func named(_ name: String) -> Scenario? {
        switch name {
        case "hero": hero()
        case "reveal": reveal()
        case "streaming": streaming()
        case "typewriter": typewriter()
        case "selection": selection()
        case "smoke": smoke()
        default: nil
        }
    }

    /// The full story in one take: mixed styles, an in-place progress rewrite, an error + retry,
    /// then a short LLM-style stream that graduates into the log.
    private static func heroEvents(streamSeed: UInt64) -> (events: [TimelineEvent], streamEndsAt: TimeInterval) {
        let progressID = UUID()
        var events: [TimelineEvent] = [
            TimelineEvent(at: 0.4) { $0.model.append("Connecting to build service…", style: DemoStyle.info) },
            TimelineEvent(at: 1.1) { $0.model.append("Resolving package graph (14 packages)", style: DemoStyle.info) },
            TimelineEvent(at: 1.8) { $0.model.append("swift-collections 1.1.4 ✓ cached", style: DemoStyle.mono) },
            TimelineEvent(at: 2.2) { $0.model.append("swift-syntax 600.0.1 ✓ cached", style: DemoStyle.mono) },
            TimelineEvent(at: 2.9) { $0.model.append("Compiling TypewriterConsole (6 sources)", style: DemoStyle.info) },
            TimelineEvent(at: 3.7) { $0.model.append("Pulling model weights… 12%", style: DemoStyle.info, id: progressID) },
            TimelineEvent(at: 4.4) { $0.model.rewrite(id: progressID, to: "Pulling model weights… 47%") },
            TimelineEvent(at: 5.1) { $0.model.rewrite(id: progressID, to: "Pulling model weights… 83%") },
            TimelineEvent(at: 5.7) { $0.model.rewrite(id: progressID, to: "Pulling model weights… 100% (1.2 GB)") },
            TimelineEvent(at: 6.4) { $0.model.append("error: connection reset by peer — retrying (1/3)", style: DemoStyle.error) },
            TimelineEvent(at: 7.2) { $0.model.append("Retry succeeded — resuming.", style: DemoStyle.info) },
            TimelineEvent(at: 7.9) { $0.model.append("Asking the model to summarize the build…", style: DemoStyle.info) },
        ]
        let stream = chunkedStream(
            "All targets compiled cleanly in 4.2 s. One transient network error was retried automatically. Ready to ship.",
            from: 8.6, seed: streamSeed)
        events += stream.events
        events.append(TimelineEvent(at: stream.endsAt + 0.4) { $0.model.graduate() })
        return (events, stream.endsAt)
    }

    private static func hero() -> Scenario {
        let (events, streamEndsAt) = heroEvents(streamSeed: 0xC0FFEE)
        return Scenario(name: "hero", defaultFileName: "01-console.mp4",
                        duration: streamEndsAt + 1.6,
                        makeView: { AnyView(ConsoleDemoView(model: $0)) },
                        events: events)
    }

    /// Slowed way down (perCharacter 0.03) so the per-letter fade itself is the subject.
    private static func reveal() -> Scenario {
        Scenario(name: "reveal", defaultFileName: "02-reveal.mp4",
                 duration: 8.0,
                 makeView: { AnyView(ConsoleDemoView(model: $0, perCharacter: 0.03)) },
                 events: [
                     TimelineEvent(at: 0.6) { $0.model.append("Deploying typewriter-console to production…", style: DemoStyle.info) },
                     TimelineEvent(at: 2.4) { $0.model.append("upload complete — 128 files, 2.4 MB", style: DemoStyle.mono) },
                     TimelineEvent(at: 4.2) { $0.model.append("Every letter fades in on its own schedule.", style: DemoStyle.info) },
                     TimelineEvent(at: 6.0) { $0.model.append("…even the errors.", style: DemoStyle.error) },
                 ])
    }

    /// Bursty chunks with two deliberate stalls, then the seamless graduation into the log.
    private static func streaming() -> Scenario {
        var events: [TimelineEvent] = [
            TimelineEvent(at: 0.5) { $0.model.append("POST /v1/chat — streaming response…", style: DemoStyle.info) },
        ]
        let stream = chunkedStream(
            "Streaming works by growing one string: each flush advances revealFrom to the start of the newest chunk, and that chunk fades in over ~100 ms — so bursty tokens still read as one continuous typing motion.",
            from: 1.2, seed: 0xDECAF, stallsAfter: [12, 24])
        events += stream.events
        events.append(TimelineEvent(at: stream.endsAt + 0.4) { $0.model.graduate() })
        events.append(TimelineEvent(at: stream.endsAt + 0.9) {
            $0.model.append("✓ stream complete (48 tokens, 4.9 s)", style: DemoStyle.info)
        })
        return Scenario(name: "streaming", defaultFileName: "03-streaming.mp4",
                        duration: stream.endsAt + 2.4,
                        makeView: { AnyView(ConsoleDemoView(model: $0)) },
                        events: events)
    }

    private static func typewriter() -> Scenario {
        Scenario(name: "typewriter", defaultFileName: "04-typewritertext.mp4",
                 duration: 6.5,
                 makeView: { AnyView(TypewriterDemoView(model: $0)) },
                 events: [
                     TimelineEvent(at: 0.6) { $0.model.typewriterStart = Date() },
                 ])
    }

    /// The hero take, plus a multi-line selection made mid-run that survives every append,
    /// rewrite, and streaming flush that follows.
    private static func selection() -> Scenario {
        var (events, streamEndsAt) = heroEvents(streamSeed: 0xC0FFEE)
        events.append(TimelineEvent(at: 4.1) { context in
            guard let textView = findTextView(in: context.window.contentView) else { return }
            context.window.makeFirstResponder(textView)
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: 40, length: min(140, max(0, length - 40))))
        })
        return Scenario(name: "selection", defaultFileName: "05-selection.mp4",
                        duration: streamEndsAt + 1.6,
                        makeView: { AnyView(ConsoleDemoView(model: $0)) },
                        events: events)
    }

    /// One static frame (revealAt: nil everywhere) to validate the capture path before recording.
    private static func smoke() -> Scenario {
        Scenario(name: "smoke", defaultFileName: "smoke.png",
                 duration: 0,
                 makeView: { AnyView(ConsoleDemoView(model: $0)) },
                 events: [
                     TimelineEvent(at: 0.0) { context in
                         context.model.append("Smoke test — capture path check", style: DemoStyle.info, revealAt: nil)
                         context.model.append("monospaced secondary line", style: DemoStyle.mono, revealAt: nil)
                         context.model.append("error: red line renders too", style: DemoStyle.error, revealAt: nil)
                     },
                 ])
    }
}

@MainActor
func findTextView(in view: NSView?) -> NSTextView? {
    guard let view else { return nil }
    if let textView = view as? NSTextView { return textView }
    for subview in view.subviews {
        if let found = findTextView(in: subview) { return found }
    }
    return nil
}
