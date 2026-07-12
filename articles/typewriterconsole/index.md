---
layout: post
title: "TypewriterConsole: A Terminal-Style Streaming Console for SwiftUI"
subtitle: "A step-by-step SwiftUI guide to timestamped log lines that type themselves in, a live region for streaming LLM output, and text selection that spans every line and survives the stream — all in one text view."
permalink: /articles/typewriterconsole/
date: 2026-07-07
category: SwiftUI
tags: [SwiftUI, Performance]
signature: typewriter
mock: terminal
excerpt_short: "Timestamped log lines that type themselves in, a live region for streaming LLM output, and selection that survives the stream — all in one text view."
---

## What is TypewriterConsole?

TypewriterConsole is a terminal-style console view for SwiftUI. You hand it an array of timestamped entries and each new line *types itself in* with a per-letter fade; an optional live region at the bottom renders text that is still streaming — coalesced LLM tokens, build output, a download log. And because everything is rendered into a single AppKit/UIKit text view, the whole console is **one selectable surface**: a selection can span any number of lines, ⌘C copies them with their timestamps, and neither streaming appends nor the reveal animation ever reset what you've selected — just like Terminal or Xcode's console. It's open-sourced at [github.com/DerNoah/swift-typewriter-console](https://github.com/DerNoah/swift-typewriter-console) (iOS 17+ / macOS 14+, Swift 6, MIT, no dependencies).

<video src="01-console.mp4" width="560" autoplay loop muted playsinline></video>
*A scripted session: lines type themselves in, a progress line rewrites in place, and a streamed summary graduates seamlessly into the log.*

This article walks through the problem it solves, the two views it ships, and the mechanics that make a typewriter animation coexist with live streaming and text selection.

---

## The problem: consoles built from stacks of Text

The obvious SwiftUI console is a `ScrollView` over a `LazyVStack` of `Text` lines — and it falls apart on exactly the details that make a console feel like a console.

Selection is the first casualty. `.textSelection(.enabled)` works *per view*, so a drag can never cross from one line into the next; copying three lines of a stack trace means three separate copies. Worse, selection lives in view state — the moment your model appends a line and SwiftUI re-renders, whatever the user had selected is gone. A console that streams is a console where selection dies every few hundred milliseconds, precisely when you're trying to copy the error that just scrolled past.

The typewriter effect has its own trap. The classic implementation animates `String.prefix(_:)` into a `Text` — which changes the string every frame, re-layouts the line, shifts every line below it, and re-wraps mid-word as the line grows. And doing anything per-character with view-based animation multiplies view count by string length. `TextRenderer` solves the rendering half elegantly, but only from iOS 18/macOS 15.

Streaming compounds both. LLM tokens arrive in bursts of wildly varying size; naively appending each chunk makes the text stutter — frozen, then a paragraph at once. What you want is for the console to *absorb* the bursts and read as one continuous typing motion.

TypewriterConsole's answer to all three is the same design decision: stop fighting SwiftUI's view-per-line model and render every line into one `NSTextStorage` behind one `NSTextView`/`UITextView`, then treat model changes as *edits* to that storage and the reveal as an *attribute* animation on it.

---

## Installing

```swift
dependencies: [
    .package(url: "https://github.com/DerNoah/swift-typewriter-console", from: "1.0.0")
]
```

The package is named `swift-typewriter-console` and imported as `import TypewriterConsole`. It has no dependencies; the public surface is two views (`ConsoleView`, `TypewriterText`) and two value types (`ConsoleEntry`, `ConsoleLiveStream`).

---

## Minimal usage

State in, console out. You own a plain array of entries; appending one types it in:

```swift
import TypewriterConsole

struct MyConsole: View {
    @State private var lines: [ConsoleEntry] = []

    var body: some View {
        ConsoleView(entries: lines)
    }

    func log(_ text: String) {
        lines.append(ConsoleEntry(text: text))
    }

    func logError(_ text: String) {
        lines.append(ConsoleEntry(text: text, style: .error))
    }
}
```

`ConsoleEntry` needs only `text`; everything else has a sensible default. The full shape:

```swift
ConsoleEntry(
    id: UUID(),           // stable identity — reuse it to rewrite a line in place
    date: Date(),         // rendered as the HH:mm:ss prefix
    text: "Indexing 42 files…",
    style: .standard,     // .standard, .error, .dimmedMonospaced, or your own Style(font:color:)
    revealAt: Date()      // when the typewriter reveal began; nil = appear instantly
)
```

Two entry tricks are worth knowing from day one. Mutating the **last** entry's `text` while keeping its `id` rewrites the line in place without re-typing — that's your progress line (`"pulling… 10%"` → `"pulling… 60%"`) and your repeat counter (`"…  (×3)"`). And dropping entries from the **head** of the array is recognized as a line cap, not a rebuild — so trimming a long-running console to its last thousand lines stays cheap.

---

## One selectable surface

Every line — timestamp prefix, message text, the live streaming region — lives in a single `NSTextStorage` rendered by an `NSTextView` on macOS and a `UITextView` on iOS. That one decision buys the console its Terminal-like feel:

- **Selection spans lines.** It's one text view, so a drag selects across entries, and ⌘C copies the lines with their timestamps.
- **Selection survives streaming.** When the model changes, `ConsoleView` doesn't rebuild the text — it applies an incremental edit (append, rewrite, drop) to the storage, and the platform text system *shifts existing selections through edits* like any editor would.
- **Selection survives the animation.** The typewriter reveal never touches characters at all — it only animates the alpha of the `foregroundColor` attribute, which doesn't intersect with selection state.

<video src="05-selection.mp4" width="560" autoplay loop muted playsinline></video>
*A selection made mid-run: appends, an in-place progress rewrite, and a whole streamed response all arrive after it — the selection never moves.*

One implementation detail matters if you ever build something similar: all offsets into the storage are handled in UTF-16 units throughout, because that's the currency of `NSTextStorage` — mixing in `String.count` off-by-ones around emoji is the classic way these views corrupt themselves.

Scrolling behaves like a terminal too: the console auto-scrolls only while the user is already at the bottom. Scroll up to read history and it stays put while output keeps arriving.

---

## The typewriter reveal

New lines fade in letter by letter. Two parameters on `ConsoleView` shape the effect: `perCharacter` (seconds between successive letters, default `0.0075`) and `fadeWidth` (how many letter-steps each letter's fade spans, default `1.6` — the soft leading edge).

<video src="02-reveal.mp4" width="560" autoplay loop muted playsinline></video>
*Slowed down (`perCharacter: 0.03`) so the soft leading edge is visible — each letter fades in on its own schedule.*

The mechanics are deliberately boring: the reveal is **attribute-only**. A line's characters are all present in the storage from the moment it's appended — layout happens exactly once, at the line's final size — and a single shared timer walks the reveal cursor forward, updating only color alpha. No per-character views, no re-layout per frame, no lines shifting below the one that's typing. When nothing is animating, the timer stops entirely; an idle console costs nothing.

Each entry carries its own `revealAt` anchor — *when this line's reveal began* — rather than an "animate now" flag. That makes the reveal stateless and replayable: a line re-rendered from history (say, after a full rebuild) computes "this reveal finished long ago" and appears instantly, instead of re-typing. Pass `revealAt: nil` for lines that should never type in — you'll want exactly that in the streaming handoff below.

---

## Streaming LLM output

The live region is the feature the package was built around. A generation in progress is not an entry — it's a `ConsoleLiveStream` rendered below the log:

```swift
ConsoleView(
    entries: lines,
    liveStream: ConsoleLiveStream(
        text: streamedText,          // the text so far (or a rolling tail of it)
        startedAt: generationStart,  // timestamp shown on the live line
        revealFrom: previousLength,  // Character offset where the newest chunk begins
        chunkAt: chunkArrivalDate    // when that chunk arrived
    )
)
```

The caller keeps one growing string plus two pieces of chunk bookkeeping: where the newest chunk starts (`revealFrom`) and when it arrived (`chunkAt`). Everything before `revealFrom` renders fully revealed; only the newest chunk animates.

The pacing rule is what makes token streams read well: the newest chunk's fade is paced to finish within roughly one flush interval (~100 ms), *whatever the chunk size*. A three-token flush types in gently; a forty-token burst types in faster but still smoothly — the console absorbs the bursty arrival pattern and produces one continuous typing motion, instead of the freeze-then-paragraph stutter of naive appends.

<video src="03-streaming.mp4" width="560" autoplay loop muted playsinline></video>
*Bursty chunks — including two deliberate stalls — absorbed into one continuous typing motion, then graduated into the log.*

When the generation completes, graduate the stream into the permanent log:

```swift
lines.append(ConsoleEntry(text: fullText, style: .dimmedMonospaced, revealAt: nil))
streamedText = nil     // pass liveStream: nil from now on
```

`revealAt: nil` is the key — the text already typed itself in while streaming, so the permanent entry must appear instantly. Since the live region and entries share styling and rendering, the handoff is pixel-identical: the user cannot tell on which frame the stream became history.

---

## Cheap at scale

`ConsoleView` diffs each new `entries` array against the previous one and classifies the change:

| Change | Storage edit |
|---|---|
| New entries at the end | Append |
| Last entry's `text` mutated (same `id`) | Rewrite the last line in place |
| Entries removed from the head | Drop the head range |
| Everything removed | Clear |
| Anything else | Full rebuild |

The first four are the shapes a real console produces, and they're all incremental — a ten-thousand-line log never re-layouts from scratch because line ten-thousand-and-one arrived. The full rebuild is the correctness backstop: reorder, edit the middle, replace the array wholesale, and the console just rebuilds rather than guessing. You don't opt into any of this; it falls out of the diff.

---

## Standalone TypewriterText

The per-letter fade also ships as a plain SwiftUI view, for typewriter text outside a console — status lines, empty states, a hero caption:

```swift
TypewriterText(text: "Hello, world.", start: revealStart)
```

<video src="04-typewritertext.mp4" width="560" autoplay loop muted playsinline></video>
*The standalone view: one concatenated `Text`, revealing on its own timeline.*

It's pure SwiftUI (`TimelineView(.animation)` driving per-letter opacity in one concatenated `Text` — no `TextRenderer`, hence the macOS 14/iOS 17 floor), it reserves its full final size so a revealing line never shifts its neighbors, and it's built to be cheap in aggregates: only the few letters inside the fade window are rendered individually, and once the reveal has elapsed the view settles into a single static `Text` with no per-frame timeline at all.

The one contract to respect is that `start` — when the reveal began — is **owned by the parent**, not by view state. If the enclosing hierarchy churns and SwiftUI recreates the view, the same `start` flows back in and the reveal *resumes* where it was instead of replaying from the first letter. Advance `start` only when the text genuinely changes; that is what makes a new line type in fresh.

---

## Tips

| Tip | Why |
|---|---|
| Reuse an entry's `id` when updating its text | Same-`id` mutation of the last line is an in-place rewrite — no re-typing, no rebuild |
| Cap the log by dropping from the head | Head drops are incremental edits; the console is built to recognize them |
| Graduate finished streams with `revealAt: nil` | The text already typed in while live — `nil` makes the permanent entry appear instantly for a seamless handoff |
| Coalesce LLM tokens before each flush | The live region paces whatever you flush into ~100 ms of typing; ~10 flushes/second reads as continuous |
| Use `.dimmedMonospaced` for generated output | Keeps model/tool output visually distinct from your own status lines |
| Don't scroll programmatically | Auto-scroll already engages only at the bottom, terminal-style — reading history is never interrupted |
| For standalone `TypewriterText`, let the parent own `start` | View re-creation then resumes the reveal instead of replaying it |

The package, tests, and full API docs live at [github.com/DerNoah/swift-typewriter-console](https://github.com/DerNoah/swift-typewriter-console).
