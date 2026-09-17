# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

MousePilot is a Swift port of the input engine of [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix) (MMF License). `README.md` covers the repo layout, build steps and permission setup — read it first; this file covers the invariants that only show up across several files.

## Commands

```bash
# Build app + embedded helper
xcodebuild -project MousePilot.xcodeproj -scheme MousePilot -configuration Debug build

# Every test target (app + package) — must go through the workspace, see below
xcodebuild test -workspace MousePilot.xcworkspace -scheme MousePilot -destination 'platform=macOS'

# Engine/shared tests on their own
cd Packages/MousePilotKit && swift test

# A single case or class
cd Packages/MousePilotKit && swift test --filter ClickCycleTests/testDoubleClick
xcodebuild test -workspace MousePilot.xcworkspace -scheme MousePilot -destination 'platform=macOS' -only-testing:MousePilotEngineTests/RemapTableTests
```

There are three test targets: `MousePilotTests` (in the Xcode project, app-hosted) and `MousePilotEngineTests` / `MousePilotSharedTests` (in the package). **Run them through `MousePilot.xcworkspace`, not the `.xcodeproj`** — Xcode drops a local package's test targets from a plain project's schemes, so `xcodebuild test -project …` silently runs only `MousePilotTests`. The workspace exists solely to make the package tests reachable from the scheme; opening and building `MousePilot.xcodeproj` directly still works as before.

Tests are XCTest, and the engine ones are not pure unit tests: they start a real `EngineThread`, real run-loop timers and (in `FrameClockTests`) a real `CADisplayLink`, so they need a windowserver session and take wall-clock time. `MousePilotTests` is hosted by the app, so running it launches `MousePilot.app` — harmless, since `AppModel` only reads config and polls unless it gets `--enable-helper`. Nothing in any suite creates an event tap, so no Accessibility permission is needed.

CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs that same workspace command on GitHub's `xcode-27` image — the only hosted image whose OS is new enough for a macOS 27 deployment target — with ad-hoc signing (`CODE_SIGN_IDENTITY=-`, no team) since the runner has no Developer ID. A second job builds Release (whole-module, assertions off, so it fails where Debug doesn't) and checks the embedded helper and LaunchAgent plist landed in the product. Neither job's output is distributable: ad-hoc signed, and a Release helper refuses XPC without a team identifier.

`MousePilotTests` is for what the package tests structurally cannot reach: app-target code, and the bundle layout (`AppBundleLayoutTests` asserts the helper really is embedded where `MPConstants` says and that the LaunchAgent plist agrees with it — that catches a broken Embed Helper phase, which no SPM test can see).

Reset a stale Accessibility grant after a bundle-ID or signing change:

```bash
tccutil reset Accessibility com.tmillot.MousePilot.Helper
```

## Architecture invariants

**One engine thread.** `EngineThread` owns a CFRunLoop that hosts every event tap, timer, animator and display-link callback, so the whole engine is effectively single-threaded and needs no locking. New engine code runs there and should call `thread.assertOnEngineThread()` in anything reachable from the outside. The two documented exceptions: `Engine.status` / `Engine.config` are `NSLock`-guarded for cross-thread reads, and `CADisplayLink`s must be *created* on the main thread (`FrameClockPool`, driven from `Engine.start()`) even though they *fire* on the engine run loop. Everything on `Engine`'s public API hops via `thread.perform` / `performSync`.

**`SwitchMaster` is the only place that decides which taps run.** Unused input paths cost nothing: taps are created disabled in `EngineSubsystems.start()` and `SwitchMaster.reevaluate()` turns each one on or off from the current config, modifier state and capture state. Anything that changes those must end in a `reevaluate()` — never call `setReceiving` on a subsystem from elsewhere.

**Config flows one way: app → `config.json` → helper.** The app debounces writes (100 ms) to `~/Library/Application Support/MousePilot/config.json`; the helper's `ConfigStore` watches the *directory* with a `DispatchSourceFileSystemObject` (150 ms debounce) and the app also pokes `reloadConfig` over XPC, so both paths must stay idempotent. From there: `Engine.apply` → `EngineSubsystems.configChanged` → subsystem updates → `reevaluate()`. Adding a setting therefore means: field on `MousePilotConfig` (+ `decodeIfPresent` default in the hand-written `init(from:)` — the codable conformances exist precisely so an older or newer file never fails to load), a control in `MousePilot/Views/`, and consumption in `configChanged`.

**XPC is helper-hosted, not an XPC service.** The helper is a launchd agent (`SupportFiles/com.tmillot.MousePilot.Helper.plist`, `MachServices`), registered by the app through `SMAppService.agent(plistName:)`. `XPCService` rejects connections whose code-signing team doesn't match its own — with a `#if DEBUG` escape hatch for unsigned local builds, so a Release build without a signing team on **both** targets silently refuses to talk to its own app.

**Button capture** is why `ButtonInputReceiver` has a mode where the button tap runs with nothing mapped: the settings app arms `captureNextButton` over XPC while the pointer is inside `ButtonCaptureZone`, the helper swallows the next press (and its release) and replies with the number. That is what makes an already-assigned button capturable. `SwitchMaster` keeps the tap alive for the duration via `buttons.isCapturing`, ignoring the buttons kill switch.

**Button numbering.** The config and the engine count from 1 (middle button = 3, `MPConstants.minButton`); `NSEvent.buttonNumber` is zero-based and needs `+1` (see `ButtonCaptureZone.swift`). The engine taps only `otherMouseDown`/`Up`, so buttons 1–2 are never touched.

## Working with the ported code

Files carry a header comment naming the MMF source they came from — keep that provenance when you move or split code. The scroll acceleration/animation tables (`Scroll/ScrollConfig.swift`) and the curve implementations (`Math/Curves/`) are copied verbatim from MMF and tuned by feel: treat the magic numbers as data, not as code to be tidied. `ClickCycle`, `Buttons` and `ModifiedDrag` are close ports of MMF state machines — deviations from the original are noted in their headers and should stay noted.

`CPrivateShim` holds the C declarations for private-but-exported APIs (IOHIDEvent fields, SkyLight via `dlsym`). Private-API use belongs there, not inline in Swift.

Both the package and the Xcode targets build in **Swift 5 language mode** (`swiftLanguageModes: [.v5]`, `SWIFT_VERSION = 5.0`) while using swift-tools 6.0 and targeting macOS 27. The engine deliberately uses `unowned` references and thread confinement instead of actors; the app and helper shells are `@MainActor`. Don't migrate the engine to strict concurrency piecemeal — the thread-confinement model is the design.

Logging is `os.Logger` under subsystem `com.tmillot.MousePilot` with categories in `Core/Log.swift` (`engine`, `scroll`, `buttons`, `drag`, `touch`, `actions`); the helper's own lifecycle logs use `NSLog`. `Console.app` filtered on that subsystem is the way to watch a live session, since the launchd plist sends stdout/stderr to `/dev/null`.

## Manual verification

Engine behavior that the tests can't reach — real scrolling feel, drag gestures, click/hold/double-click cycles — needs a build running with Accessibility granted to `MousePilotHelper`. The app accepts `--enable-helper` / `--disable-helper` launch arguments for scripted runs. `build/` is gitignored derived data.
