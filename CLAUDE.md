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

**Updating the app means restarting the helper, because the helper lives inside the app.**
Sparkle replaces `Leios.app` wholesale, and `LeiosHelper.app` sits in its `Contents/Library/LoginItems`
with launchd holding it `KeepAlive`. Left alone, the swap leaves a new app talking to the old
engine running from a replaced inode, and nothing in the UI says so. Three things in
[Leios/AppModel.swift](Leios/AppModel.swift) cover it, and all three matter: `stopHelperForUpdate()`
unregisters the agent from `updaterWillRelaunchApplication` (unregister, not kill — `KeepAlive`
would restart it); `restoreHelperAfterUpdate()` puts it back on the next launch, because
`isEnabled` is derived from `helperState` and nothing else persists the user's intent, so an
unregistered helper otherwise reads as "the user turned Leios off"; and `restartHelperIfStale`
compares the build number `getStatus()` reports against the app's own and re-registers once, which
is the net for every path the first two miss — a crash, a force-quit, a drag-install over the top.
That is also why updates are notify-and-install-on-click rather than silent: the install-on-quit
path does not reliably reach `updaterWillRelaunchApplication`.

Two settings back it, both machine-local in `UserDefaults` like `AppModel.syncEnabled` and for the
same reason — they never enter `LeiosConfig`, so they never enter `SyncedConfig` or reach the
helper. Sparkle's keys cannot go in `INFOPLIST_KEY_` build settings (Xcode ignores the prefix for
anything outside its own allowlist, silently); they live in
[SupportFiles/Leios-Info.plist](SupportFiles/Leios-Info.plist), which `GENERATE_INFOPLIST_FILE`
merges the generated keys into. `CURRENT_PROJECT_VERSION` is what Sparkle orders updates by, so it
is a build counter that only rises — `Scripts/release.sh` checks it against the live feed before
it will publish.

**Usage statistics are counted on the engine thread and written from another one.** Nothing on a
hot path reads the clock, allocates or locks: `StatsRecorder`
([Packages/LeiosKit/Sources/LeiosEngine/Stats/StatsRecorder.swift](Packages/LeiosKit/Sources/LeiosEngine/Stats/StatsRecorder.swift))
is thread-confined and only ever adds to a `StatsTotals`, and `StatsFlusher` drains it once a
minute onto a `.utility` queue that owns the archive and does every clock read, bucket decision,
prune and file write. Four things hold it together. Raw input is counted by a **listen-only tap of
its own** (`StatsTap`) rather than inside the scroll and button taps, because `SwitchMaster`
disarms those whenever nothing is mapped — and that tap must be created **last** in
`EngineSubsystems.start()`, since `.headInsertEventTap` puts the newest tap at the head and only
from there does it see a scroll event before `ScrollController` swallows it. It sits at
`.cghidEventTap`, upstream of everything the engine posts (all to `.cgSessionEventTap`), so Leios's
own synthesized events are invisible to it. The flush tick also calls `switchMaster.reevaluate()`,
which is the only thing that brings the tap back after macOS disables it on secure input
(`EventTap` deliberately does not re-enable itself). And `Engine.stop()`'s flush is **synchronous**,
because the helper may exit as soon as it returns.

Two traps that already cost a debugging session each, both found by running the thing rather than
by reading it. The `collectStatistics` switch is applied to **`StatsRecorder` as well as the tap**:
scroll output, actions and drags are recorded from inside `ScrollController`, `Buttons` and
`ModifiedDrag`, which keep running whatever the switch says, so gating the tap alone leaves half
the counters live. And nothing on the teardown path may discard the recorder's batch —
`SwitchMaster.disableAll()` runs immediately before the flusher's final write, so a `discard()`
there silently loses every count of any session shorter than one flush interval. `discard()` now
belongs to `reset` and to nothing else. The engine-side hooks are one line each and the
obvious line is the wrong one in most of them — read the comment at each before moving it.

The archive is `~/Library/Application Support/Leios/Statistics/statistics.json`, and the
**subdirectory is load-bearing**: `ConfigStore` watches the config directory itself, so a sibling
file would make the helper re-read `config.json` on its main thread on every flush. Its three tiers
(hourly 30 days, daily a year, monthly forever) are maintained *independently* — every batch is
added to all of them plus the lifetime totals — so maintenance is pruning alone and no tier can
double-count another. Days and months are keyed by calendar date (`yyyyMMdd`, `yyyyMM`), not by an
epoch offset, which is what makes DST and a timezone change non-events. Adding a counter means a
field on `StatsCounters` (+ its `+=`, its zero-omitting coder, and a `decodeIfPresent` default) and
somewhere in `StatsModel` to show it. Action tallies are keyed by `Action.statsKey`, which is
**API**: it is written to disk and travels between Macs, so renaming one forks a lifetime series.

Statistics sync per Mac rather than as one document, because counts are additive: each Mac writes
only its own `LeiosStats` record and `StatsMerge` adds them up, so there is no last-writer-wins
here at all. Peers are found through a roster record at a known name, deliberately not a `CKQuery`
— a query needs an index deployed from the CloudKit dashboard, which record fields do not, and
that would be a manual release step with no build-time signal.

**Event timestamps come in two units, and `timestampSeconds` must read both.** Events from real
hardware carry the IOHIDEvent's mach time, in ticks; events built with `CGEvent(…)` and posted —
every synthetic test, and the engine's own output — are stamped in nanoseconds.
`EventUtility.seconds(fromEventTimestamp:nowTicks:)` picks the unit per event by which reading lands
nearer to now. On Intel the two are the same number (the timebase is 1/1), which is why Mac Mouse Fix
never had to care. On Apple silicon the timebase is 125/3 and the wrong reading is off by 42×, both
ways, and each has already shipped once. Read as mach time, synthetic ticks were never within
`consecutiveScrollTickIntervalMax` of each other: every tick started a new sequence, acceleration
sat at its floor and `ScrollController` re-resolved the app under the pointer on every tick. Read as
nanoseconds, a real wheel paused for eight seconds still looked mid-sequence, so the Quick and
Precise keys — read only at a sequence start — stayed in force after release until a reversal began
a new one. **A timestamp fix verified only with synthetic input proves nothing about a real
mouse:** the two paths do not share a unit, so check with a listen-only tap and a hand on the wheel.

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
