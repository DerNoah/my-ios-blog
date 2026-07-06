---
layout: post
title: "VibeNavigation: Route-Based Modular Navigation for iOS"
subtitle: "A step-by-step guide to decoupling iOS features with routes, macros, and a compile-time screen check — so teams ship screens without ever importing each other's code."
permalink: /articles/vibenavigation/
date: 2026-07-06
---

* TOC
{:toc}

---

## What is VibeNavigation?

VibeNavigation is a route-based, type-safe modular navigation framework for iOS. Every screen in the app is named by a small value type — a *route* — and features navigate to each other's screens by constructing those values, never by importing each other's view controllers. Deep links fall out for free: every registered route is automatically URL-addressable, with zero hand-written URL parsing. It's open-sourced at [github.com/DerNoah/swift-vibe-navigation](https://github.com/DerNoah/swift-vibe-navigation) (iOS 16+, Swift 6, MIT).

This article walks through the problem it solves, the architecture, and each building block — routes, screens, navigation, guards, transitions, and tabs — the way I'd introduce it to a feature team.

---

## The problem: features that import each other

Modular iOS codebases usually start clean: one Swift package per feature, a slim app target on top. The first crack appears the day the Home feature needs to open a Profile screen. The obvious move — `import ProfileFeature` and instantiate the view controller — quietly couples the two packages. A few sprints later Profile needs to open a Post from Home, and now the two packages depend on each other, which SwiftPM flatly refuses to build.

The usual escape hatches all have costs. A central `Destination` enum in a shared package decouples the features from each other but couples *every* feature to the enum — each new screen touches a file every team owns, and every `switch` grows another arm. Stringly-typed URL routers avoid the shared enum but give up the compiler: a typo in `"profile/\(id)"` becomes a runtime mystery. And in both designs, deep linking is a separate, second implementation of the same navigation logic that drifts out of sync with the first.

The insight behind VibeNavigation is that a navigation target is an *interface*, and interfaces belong in interface packages. What Home actually needs from Profile is not the profile view controller — it's a name for "the profile screen of user X" that the compiler can check.

---

## The architecture: interface vs. implementation packages

Every feature is split into two packages:

- **`<Feature>-API-UI`** (module `<Feature>UI`) — the *interface*: a single file of route declarations. Nothing else. It depends only on `VibeNavigationCore`, which is Foundation-only.
- **`<Feature>-Internal`** (module `<Feature>Internal`) — the *implementation*: screens, coordinators, logic. It depends on the runtime, its own interface, and the interfaces of features it navigates to.

The invariant that keeps the graph cycle-free: **interface packages never depend on implementations, and implementations never depend on other implementations.** Home navigating to Profile means `HomeInternal` imports `ProfileUI` — a leaf package of value types. No cycle is possible, and SwiftPM's rejection of package cycles acts as the enforcement backstop: if someone tries to sneak in an implementation import, the build breaks before review does.

```
AuthUI     ─┐
HomeUI     ─┼─▶ VibeNavigationCore          (route declarations only)
ProfileUI  ─┘

AuthInternal    ─▶ VibeNavigation + AuthUI + HomeUI
HomeInternal    ─▶ VibeNavigation + HomeUI + ProfileUI
ProfileInternal ─▶ VibeNavigation + ProfileUI + HomeUI

App (composition root) ─▶ VibeNavigation + the three -Internal packages
```

The host app is the only place features are enumerated. Adding a feature means creating its two packages and adding one line to the app's module list — no other team's code is touched.

---

## Installing

Add the package and pick the right product per target:

```swift
dependencies: [
    .package(url: "https://github.com/DerNoah/swift-vibe-navigation", from: "1.0.0")
]
```

| Product | Who depends on it |
|---|---|
| `VibeNavigationCore` | Feature *interface* packages — UIKit-free route declarations |
| `VibeNavigation` | Feature *implementation* packages and the host app — the UIKit/SwiftUI runtime |
| `VibeNavigationDebug` | The host app — a DEBUG-only debug server (more on this at the end) |
| `RouteRegistrarPlugin` | Optionally applied to implementation targets for build-time screen checks |

The package is imported as `import VibeNavigation` / `import VibeNavigationCore`. Everything is Swift 6 language mode with strict concurrency; UI code is `@MainActor`.

---

## Declaring a route

A route is a struct in the feature's interface package, declared with the `@Route` macro:

```swift
import VibeNavigationCore

@Route("post/:id")
public struct PostRoute {
    public let id: String
    public var parent: (any Route)? { HomeRoute() }
}
```

The macro generates the entire `Route` conformance: the parsed URL pattern, an initializer that maps `:placeholders` onto same-named stored properties, a `pathRepresentation` for logging and tooling, and a memberwise initializer. The part that makes this safe rather than merely convenient is that the macro validates the pattern **at compile time**: a `:id` placeholder without a stored property named `id` is a compile error, not a runtime surprise. The pattern and its parameters can never drift apart.

Two optional declarations shape how a route enters:

- `parent` answers the question every deep link raises: *what should Back go to?* When someone opens `myapp://post/42` cold, the framework builds the stack `[Home, Post]` from the parent chain — parents can carry values, so `EditProfileRoute(userID:)` can declare `ProfileRoute(userID: userID)` as its parent.
- `preferredPresentation` (`.push` by default, or `.present`, `.fullScreenCover`, `.alert`) lets the route itself decide whether it pushes, sheets, covers, or shows as an alert.

Stored properties that aren't in the pattern become query parameters — make them `Optional` and `myapp://reset-password?token=abc` parses them for free.

---

## Registering screens

Declaring a route names a screen; registering binds it to a view. Each feature ships a `FeatureModule` whose `register(in:)` does the wiring — one line per screen, SwiftUI or UIKit, chosen by the builder's return type:

```swift
public struct HomeFeatureModule: FeatureModule {
    public init() {}

    public func register(in context: FeatureRegistrationContext) {
        let coordinator = HomeCoordinator(navigator: context.navigator)

        context.register(PostRoute.self) {                      // SwiftUI — auto-wrapped
            PostDetailView(coordinator: coordinator, postID: $0.id)
        }
        context.register(NotificationsRoute.self) { _ in        // UIKit
            coordinator.makeNotificationsViewController()
        }
    }
}
```

A route with no registration is a runtime `NavigationFailure` — loud (an assertion) in debug builds, a logged no-op in release, so a bad link can crash your debug build by design but never a shipping app.

If you'd rather catch the forgotten registration at *build* time, apply the `RouteRegistrarPlugin` to the target and declare one `RouteScreen` next to each view instead of hand-writing `register(in:)`:

```swift
struct PostDetailScreen: RouteScreen {
    static func make(_ route: PostRoute, _ dependencies: HomeCoordinator) -> some View {
        PostDetailView(coordinator: dependencies, postID: route.id)
    }
}
```

The plugin generates `register(in:)` from the declarations and diffs them against the interface package's `@Route`s — a route without a screen **fails the build**, naming the offender. Pick one style per feature; they can't coexist since both define `register(in:)`.

---

## Navigating

The `Navigator` is the single navigation API — and the single entry point for external links:

```swift
navigator.push(PostRoute(id: "42"))            // one screen onto the current stack
navigator.navigate(to: PostRoute(id: "42"))    // contextual: rebuilds the parent stack [Home, Post]
navigator.present(SettingsRoute())             // modal sheet with its own navigation stack
navigator.presentAlert(SignOutConfirmRoute(userID: "me"))
navigator.setRoot(HomeRoute())
```

`push` and `navigate(to:)` divide the work: `push` always puts exactly one screen on the current stack, while `navigate(to:)` is for jumps — it dispatches on the route's `preferredPresentation` and, for pushes, rebuilds the stack from the parent chain so a cross-feature jump always lands with a sensible back path.

Cross-feature navigation is the payoff of the architecture. Home opens a profile with nothing but the interface import:

```swift
import ProfileUI

navigator.navigate(to: ProfileRoute(userID: "user99"))
```

And because registration already told the framework everything about the route, **deep links need no additional code**. `myapp://post/42` resolves through a trie-based matcher to the same `navigate(to:)` call; a multi-segment URL like `myapp://home/profile/user99/post/42` resolves each segment and *is* the stack. Push notifications funnel through the same door with `navigator.open(pushPayload:)`. One detail worth copying in any router: a URL that fails to resolve *any* segment is rejected wholesale — a broken link never strands the user on a half-built stack.

---

## Guards, transitions, and tabs

**Guards.** Some screens shouldn't always be reachable — a paywall, unsaved changes, "you may only edit your own profile". Registration takes an async `canNavigate:` closure that runs *before* anything appears:

```swift
context.register(
    EditProfileRoute.self,
    canNavigate: { await coordinator.canEditProfile($0.userID) }
) {
    EditProfileView(coordinator: coordinator, userID: $0.userID)
}
```

A single denial aborts the whole navigation — nothing is pushed, presented, or half-applied — and the framework guarantees a slow guard can't apply its result after a newer navigation has superseded it.

**Transitions.** Registrations can attach a `transition:` — `.slideUp`, `.fade`, or `.custom(push:pop:)` with your own animators. The registered transition drives the push *and* the pop, including the interactive edge-swipe, so a screen that slides up also slides back down.

**Tabs.** Features register tabs the same way they register screens, with a `TabSpec` carrying a root route and a priority. The app starts as a single stack (think pre-auth), and the tab bar installs itself the first time navigation enters tab-owned content. A route's owning tab is derived from its parent chain, so deep links select the right tab automatically. Five tabs maximum, highest priority wins the slots — a sixth tab is reported, not silently dropped.

**Alerts.** Even alerts are routes: declare `preferredPresentation = .alert` and either register `AlertContent` (title, message, buttons whose handlers receive the navigator) for a standard `UIAlertController`, or register an ordinary SwiftUI view to have it shown as a centered card over a dimmed backdrop. `myapp://profile/me/signout` opening a confirmation alert is a one-liner.

---

## The Navigation Debug Tool

Everything above describes code, but the part of this project I reach for daily is the tooling it enables. Because features *register* their routes rather than hiding them in view controllers, the app knows its complete navigation surface at runtime — every route, pattern, parent, tab, and guard. In DEBUG builds, the `VibeNavigationDebug` module exposes that manifest over a loopback connection, and a companion macOS app consumes it.

The **Navigation Debug Tool** gives you three things:

- a searchable **navigation graph** of the whole app — every route and its parent chain, exportable as Mermaid or JSON for architecture docs;
- a **link console** that fires deep links straight into the connected simulator, so testing `myapp://profile/user99/edit` doesn't require Safari gymnastics;
- a **live trace** of every navigation event as it happens — pushes, presentations, blocked guards (`event=navigationBlocked`), tab selections.

Because it's driven entirely by the manifest the running app sends, adding a feature requires zero tool changes — relaunch the app and the graph refreshes. The server code ships nowhere: every file in `VibeNavigationDebug` is wrapped in `#if DEBUG`, so Release builds compile an empty module.

The tool is part of the same repository and downloadable as a prebuilt app from the [1.0.0 release](https://github.com/DerNoah/swift-vibe-navigation/releases/download/1.0.0/NavigationDebugTool.zip) (macOS 14+; it's ad-hoc signed, so right-click → Open on first launch). The framework, the demo app, and the tool all live at [github.com/DerNoah/swift-vibe-navigation](https://github.com/DerNoah/swift-vibe-navigation).

---

## Tips

| Tip | Why |
|---|---|
| Depend on other features' `-API-UI` packages only — never `-Internal` | This is the whole architecture; SwiftPM's cycle rejection enforces it for you |
| Use `navigate(to:)` for cross-feature jumps, `push` within a flow | `navigate(to:)` rebuilds the parent stack, so the user always has a sensible Back |
| Give every deep-linkable route a `parent` | A cold deep link without a parent lands on a bare screen with nowhere to go back to |
| Prefer the `RouteRegistrarPlugin` on new features | A forgotten screen becomes a build error naming the route, instead of a runtime log |
| Link `VibeNavigationDebug` unconditionally | Every file is `#if DEBUG` — Release builds compile an empty module, so there's nothing to strip |
| Watch the live trace for `event=navigationBlocked` | A guard returning `false` is silent by design; the trace is where "nothing happened" gets explained |
| Using Tuist? Read `TuistSetup.md` first | The registrar plugin needs a small amount of setup under Tuist's generated projects |
