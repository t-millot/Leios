# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Leios is a Swift port of the input engine of [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix) (MMF License). `README.md` covers the repo layout, build steps and permission setup — read it first; this file covers the invariants that only show up across several files.

## Commands

```bash
# Build app + embedded helper
xcodebuild -project Leios.xcodeproj -scheme Leios -configuration Debug build

# Every test target (app + package) — must go through the workspace, see below
xcodebuild test -workspace Leios.xcworkspace -scheme Leios -destination 'platform=macOS'

# Engine/shared tests on their own
cd Packages/LeiosKit && swift test

# A single case or class
cd Packages/LeiosKit && swift test --filter ClickCycleTests/testDoubleClick
xcodebuild test -workspace Leios.xcworkspace -scheme Leios -destination 'platform=macOS' -only-testing:LeiosEngineTests/RemapTableTests
```

The app target carries a restricted iCloud entitlement, so any build of it needs a provisioning
profile for the `iCloud.com.tmillot.Leios` container. `CODE_SIGN_ENTITLEMENTS` is indirected
through `LEIOS_ENTITLEMENTS` (Debug uses [SupportFiles/Leios.entitlements](SupportFiles/Leios.entitlements),
Release [SupportFiles/Leios-Release.entitlements](SupportFiles/Leios-Release.entitlements), which
is the same set plus `icloud-container-environment = Production`). Without the container
provisioned — or when signing ad-hoc, as CI does — override it:

```bash
xcodebuild -project Leios.xcodeproj -scheme Leios -configuration Debug build \
    LEIOS_ENTITLEMENTS=SupportFiles/Leios-CI.entitlements
```

That file is the old entitlements, sandbox off and nothing else. The indirection is on the Leios
target only, so the override cannot leak onto the helper, which deliberately has no iCloud
entitlement and therefore never needs re-provisioning.

There are three test targets: `LeiosTests` (in the Xcode project, app-hosted) and `LeiosEngineTests` / `LeiosSharedTests` (in the package). **Run them through `Leios.xcworkspace`, not the `.xcodeproj`** — Xcode drops a local package's test targets from a plain project's schemes, so `xcodebuild test -project …` silently runs only `LeiosTests`. The workspace exists solely to make the package tests reachable from the scheme; opening and building `Leios.xcodeproj` directly still works as before.

Tests are XCTest, and the engine ones are not pure unit tests: they start a real `EngineThread`, real run-loop timers and (in `FrameClockTests`) a real `CADisplayLink`, so they need a windowserver session and take wall-clock time. `LeiosTests` is hosted by the app, so running it launches `Leios.app` — harmless, since `AppModel` only reads config and polls unless it gets `--enable-helper`. Nothing in any suite creates an event tap, so no Accessibility permission is needed.

Lint with `swiftlint lint --strict` from the repo root (`brew install swiftlint` — the runner image ships SwiftFormat and xcbeautify, but not SwiftLint). The tree is at zero violations, so anything it reports is new. There are two configs: [.swiftlint.yml](.swiftlint.yml) at the root, and a nested [Packages/LeiosKit/.swiftlint.yml](Packages/LeiosKit/.swiftlint.yml) that switches off the rules which would have us reshape ported code — verbatim curve tables exceeding any column limit, MMF's identifiers (`T`, `D`, `speed_n`), `SwitchMaster`'s name, and the long ported decision trees. Those rules stay on for the app, helper and tests. Prefer relaxing a rule in the nested config over reformatting ported code.

Formatting is checked the same way: `swiftformat Leios LeiosHelper LeiosTests Packages/LeiosKit/Sources Packages/LeiosKit/Tests --lint`, configured by [.swiftformat](.swiftformat) plus a nested [Packages/LeiosKit/.swiftformat](Packages/LeiosKit/.swiftformat), and tuned to the code that is here: stock defaults would rewrite 69 of 75 files. Options are preferred over disabling rules, and each disabled rule carries the reason it does not apply. It also reports zero, so both formatter and linter fail only on what a change introduces.

CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs that same workspace command on GitHub's `xcode-27` image — the only hosted image whose OS is new enough for a macOS 27 deployment target — with ad-hoc signing (`CODE_SIGN_IDENTITY=-`, no team) since the runner has no Developer ID. A second job builds Release (whole-module, assertions off, so it fails where Debug doesn't) and checks the embedded helper and LaunchAgent plist landed in the product. Neither job's output is distributable: ad-hoc signed, and a Release helper refuses XPC without a team identifier.

`LeiosTests` is for what the package tests structurally cannot reach: app-target code, and the bundle layout (`AppBundleLayoutTests` asserts the helper really is embedded where `LeiosConstants` says and that the LaunchAgent plist agrees with it — that catches a broken Embed Helper phase, which no SPM test can see).

Reset a stale Accessibility grant after a bundle-ID or signing change:

```bash
tccutil reset Accessibility com.tmillot.Leios.Helper
```

## Architecture invariants

**One engine thread.** `EngineThread` owns a CFRunLoop that hosts every event tap, timer, animator and display-link callback, so the whole engine is effectively single-threaded and needs no locking. New engine code runs there and should call `thread.assertOnEngineThread()` in anything reachable from the outside. The two documented exceptions: `Engine.status` / `Engine.config` are `NSLock`-guarded for cross-thread reads, and `CADisplayLink`s must be *created* on the main thread (`FrameClockPool`, driven from `Engine.start()`) even though they *fire* on the engine run loop. Everything on `Engine`'s public API hops via `thread.perform` / `performSync`.

**`SwitchMaster` is the only place that decides which taps run.** Unused input paths cost nothing: taps are created disabled in `EngineSubsystems.start()` and `SwitchMaster.reevaluate()` turns each one on or off from the current config, modifier state and capture state. Anything that changes those must end in a `reevaluate()` — never call `setReceiving` on a subsystem from elsewhere.

**iCloud sync is app-only, and it feeds the config rather than bypassing it.** `CloudSync`
([Leios/CloudSync.swift](Leios/CloudSync.swift)) is pure transport — fetch and upload one CloudKit
record — and `AppModel` owns every decision, so a remote payload arrives as an ordinary assignment
to `AppModel.config` and flows to the helper down the usual path. Three things hold it together.
`SyncedConfig` ([Packages/LeiosKit/Sources/LeiosShared/SyncedConfig.swift](Packages/LeiosKit/Sources/LeiosShared/SyncedConfig.swift))
is a projection that structurally cannot touch the kill switches or the menu bar item, which stay
machine-local; a `nil` section in it means "keep mine", which is what stops a payload with no
`buttons` key from resetting mappings the way `LeiosConfig`'s own decoder would. `SyncReconciler`
holds the whole last-writer-wins rule as a pure function, which is where its tests live.
And `lastAgreed` is set *before* the assignment in `applyRemote`, which is the entire loop
suppression: the debounced save that follows finds the projection unchanged and uploads nothing.
There is no push — `aps-environment` is restricted and silent push only arrives while the app runs
— so a remote change lands when the window is next activated. `CKContainer(identifier:)` *traps*
rather than throwing without the entitlement, so `CloudSync.init` is failable and checks
`SecTaskCopyValueForEntitlement` first.

**Config flows one way: app → `config.json` → helper.** The app debounces writes (100 ms) to `~/Library/Application Support/Leios/config.json`; the helper's `ConfigStore` watches the *directory* with a `DispatchSourceFileSystemObject` (150 ms debounce) and the app also pokes `reloadConfig` over XPC, so both paths must stay idempotent. From there: `Engine.apply` → `EngineSubsystems.configChanged` → subsystem updates → `reevaluate()`. A config that fails to decode is never written over: `AppModel.configIsReadable` gates every save
and the helper's `ConfigStore.loadFailed` gates its own, so a file from a newer Leios survives
until the user presses "Discard and Start Fresh". Adding a setting therefore means: field on `LeiosConfig` (+ `decodeIfPresent` default in the hand-written `init(from:)` — the codable conformances exist precisely so an older or newer file never fails to load), a control in `Leios/Views/`, and consumption in `configChanged`. A *scroll* setting also needs an
optional twin on `ScrollOverrides` and a row in `ScrollSettingsForm`, which renders both the global
tab and each app profile from the same code.

**Per-app scroll profiles are chosen by the app under the pointer, and the tap is gated on their
union.** `config.apps` holds a `ScrollOverrides` per bundle ID, where a `nil` field keeps following
the global value; `LeiosConfig.effectiveAppScroll` resolves them and drops any profile that
comes out equal to the global settings, so the engine can skip the lookup entirely. `ScrollController`
keeps one `ScrollConfigResolver` per profiled app and picks one per *scroll sequence* (a gap of
`sequenceGap`), not per tick — `EventUtility.bundleIDOfAppUnderPointer` walks the whole window list
and would time the tap out if called on every tick of a slow scroll. Two invariants follow:
`SwitchMaster` must gate the scroll tap on `LeiosConfig.scrollGating`, which covers the global
settings *and* every profile, because the tap is armed before the target app is known; and because
that arms the tap system-wide, `ScrollController.process` returns false for a config that would
reproduce the event unchanged (`ScrollConfig.isNoOp`) so unprofiled apps still get their original
event rather than a re-synthesized copy.

**XPC is helper-hosted, not an XPC service.** The helper is a launchd agent (`SupportFiles/com.tmillot.Leios.Helper.plist`, `MachServices`), registered by the app through `SMAppService.agent(plistName:)`. `XPCService` rejects connections whose code-signing team doesn't match its own — with a `#if DEBUG` escape hatch for unsigned local builds, so a Release build without a signing team on **both** targets silently refuses to talk to its own app.

**Button capture** is why `ButtonInputReceiver` has a mode where the button tap runs with nothing mapped: the settings app arms `captureNextButton` over XPC while the pointer is inside `ButtonCaptureZone`, the helper swallows the next press (and its release) and replies with the number. That is what makes an already-assigned button capturable. `SwitchMaster` keeps the tap alive for the duration via `buttons.isCapturing`, ignoring the buttons kill switch.

**Button numbering.** The config and the engine count from 1 (middle button = 3, `LeiosConstants.minButton`); `NSEvent.buttonNumber` is zero-based and needs `+1` (see `ButtonCaptureZone.swift`). The engine taps only `otherMouseDown`/`Up`, so buttons 1–2 are never touched.

## Working with the ported code

Files carry a header comment naming the MMF source they came from — keep that provenance when you move or split code. The scroll acceleration/animation tables (`Scroll/ScrollConfig.swift`) and the curve implementations (`Math/Curves/`) are copied verbatim from MMF and tuned by feel: treat the magic numbers as data, not as code to be tidied. `ClickCycle`, `Buttons` and `ModifiedDrag` are close ports of MMF state machines — deviations from the original are noted in their headers and should stay noted.

`CPrivateShim` holds the C declarations for private-but-exported APIs (IOHIDEvent fields, SkyLight via `dlsym`). Private-API use belongs there, not inline in Swift.

Both the package and the Xcode targets build in **Swift 5 language mode** (`swiftLanguageModes: [.v5]`, `SWIFT_VERSION = 5.0`) while using swift-tools 6.0 and targeting macOS 27. The engine deliberately uses `unowned` references and thread confinement instead of actors; the app and helper shells are `@MainActor`. Don't migrate the engine to strict concurrency piecemeal — the thread-confinement model is the design.

Logging is `os.Logger` under subsystem `com.tmillot.Leios` with categories in `Core/Log.swift` (`engine`, `scroll`, `buttons`, `drag`, `touch`, `actions`); the helper's own lifecycle logs use `NSLog`. `Console.app` filtered on that subsystem is the way to watch a live session, since the launchd plist sends stdout/stderr to `/dev/null`.

## Manual verification

Engine behavior that the tests can't reach — real scrolling feel, drag gestures, click/hold/double-click cycles — needs a build running with Accessibility granted to `LeiosHelper`. The app accepts `--enable-helper` / `--disable-helper` launch arguments for scripted runs. `build/` is gitignored derived data.
