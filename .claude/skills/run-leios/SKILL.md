---
name: run-leios
description: Build, launch and drive the Leios settings app on this Mac — including restarting the helper so a rebuilt engine actually takes effect, screenshotting/clicking the window over the accessibility API, and exercising scroll/drag gestures end to end with synthetic input so an engine change can be confirmed without a mouse in hand. Use when asked to run, start, restart or screenshot the app, to reproduce or debug a gesture, or to confirm an engine or UI change works in the real app rather than in tests.
---

# Running Leios

Two processes: the SwiftUI settings app (`Leios.app`) and the embedded
launchd agent (`LeiosHelper`) that owns every event tap. Launching the app
does **not** restart a helper that is already running — see *Picking up a
rebuilt helper*.

## Build

```bash
xcodebuild -project Leios.xcodeproj -scheme Leios -configuration Debug -derivedDataPath build build
```

`build/` is gitignored derived data; the product lands at
`build/Build/Products/Debug/Leios.app` with the helper embedded at
`Contents/Library/LoginItems/LeiosHelper.app`. Takes ~1 min cold, seconds
incrementally. Tests go through the workspace, not the project — see CLAUDE.md.

## Launch

```bash
open build/Build/Products/Debug/Leios.app
```

Use `open <path>`, not `open -a <path>` — `-a` takes an application *name* and
fails on a relative path. For scripted runs the app also takes
`--enable-helper` / `--disable-helper`:

```bash
open build/Build/Products/Debug/Leios.app --args --enable-helper
```

Confirm both processes:

```bash
ps -Ao pid,args | grep -i leios | grep -v grep
launchctl list | grep com.tmillot.Leios.Helper
```

A `launchctl list` line with a PID and status `-15` means the agent is loaded
and running. The toolbar's status dot should be green, with `Running.` as its
tooltip and accessibility value. The other labels come from
`HelperStatus.description` in
[AppModel.swift](../../../Leios/AppModel.swift): `Running, but Accessibility
permission is missing.` (grant it in System Settings → Privacy & Security →
Accessibility), `Waiting for approval in System Settings → General → Login
Items.`, `Helper is enabled but not responding yet…`, and `Helper not found
inside the app bundle. Rebuild the app.`

## Picking up a rebuilt helper

The helper keeps running the binary launchd started, so after a rebuild the app
shows `Running.` while the *old* engine is still live. Restart it in place —
this keeps the same bundle path, so the Accessibility grant survives:

```bash
launchctl kickstart -k "gui/$(id -u)/com.tmillot.Leios.Helper"
```

The PID in `launchctl list` should change. Prefer this over toggling **Enable**
off/on, and never re-register from a different build location unless you intend
to re-grant Accessibility (`tccutil reset Accessibility
com.tmillot.Leios.Helper`).

## Drive the window

The app has no test hooks; drive it over the accessibility API. Nothing here
moves the user's pointer.

Dump the UI tree:

```bash
osascript -e 'tell application "System Events" to tell process "Leios" to get entire contents of window 1'
```

Stable paths as of this writing:

- Tabs, in order Scrolling / Apps / Buttons / Info / General: `radio button N of tab group 1 of group 1 of toolbar 1 of window 1`
- Enable switch: `checkbox 1 of group 2 of toolbar 1 of window 1`
- Status: the toolbar dot, `image 1 of group 2 of toolbar 1 of window 1` — the
  state string is its accessibility *value*, not a visible label
- Action pickers: `pop up button "Click and Drag" of group N of scroll area 1 of group 1 of group 1 of window 1`

Switch tabs and read the status:

```bash
osascript -e 'tell application "System Events" to tell process "Leios" to click radio button 1 of tab group 1 of group 1 of toolbar 1 of window 1'
osascript -e 'tell application "System Events" to tell process "Leios" to get value of image 1 of group 2 of toolbar 1 of window 1'
```

Screenshot just the window (query its frame first, pad by ~10 pt):

```bash
osascript -e 'tell application "System Events" to tell process "Leios" to get {position, size} of window 1'
screencapture -x -o -R <x>,<y>,<w>,<h> /tmp/leios.png
```

`-x` suppresses the shutter sound, `-o` drops the window shadow. **Look at the
PNG** — a blank or missing window is a failed launch. Python has no `Quartz`
module on this machine, so don't reach for `CGWindowListCopyWindowInfo`.

## Check what the engine did

Config the helper is reading:

```bash
cat ~/Library/Application\ Support/Leios/config.json
```

The app debounces writes 100 ms and the helper's `ConfigStore` debounces the
directory watch 150 ms, so wait ~300 ms after a UI change before asserting on
the file.

Live engine logs (the launchd plist sends stdout/stderr to `/dev/null`, so the
unified log is the only view):

```bash
log stream --predicate 'subsystem == "com.tmillot.Leios"' --style compact
```

`log show --last 2m` on the same predicate often comes back empty for a session
that logged nothing at that level — use `log stream` while reproducing, or
`Console.app` filtered on the subsystem.

## Drive the engine with synthetic input

Gestures *can* be exercised end to end without a mouse in hand — a synthetic
button press and drag runs the whole real path (button tap → `ModifiedDrag` →
drag output → `TouchSimulator`).

**Post to `kCGHIDEventTap`, not `kCGSessionEventTap`.** `EventTap` creates every
tap at `.cghidEventTap`, and session-level injection is inserted *after* that
point, so a session-posted event is invisible to the helper and the engine looks
dead when it is fine. This is the single easiest way to waste an hour here.

A button-4 drag is `CGEventCreateMouseEvent` with button number 3 (zero-based —
see *Button numbering* in CLAUDE.md), then `otherMouseDragged` events carrying
`kCGMouseEventDeltaX`/`DeltaY`, then `otherMouseUp`. `ModifiedDrag.handle` reads
the delta fields, not the pointer position, so the deltas are what matter; ~8 ms
between events approximates a real mouse. Drag far enough to clear
`ModifiedDrag.usageThreshold` (7 pt) *and* to produce a meaningful gesture — a
vertical dock swipe scales by `1/screenHeight`, so a few hundred pixels is only
a fraction of a swipe and looks like nothing happening.

## See what the engine emits

To inspect posted gestures, tap `kCGSessionEventTap` listen-only for CGEvent
types 29 and 30 and call `CGEventCopyIOHIDEvent` on each; print it with
`IOHIDEventCopyDescription`. A session tap sees both real device gestures and
what the helper posts, so it is the one place a simulated gesture can be diffed
field-by-field against a real trackpad one. That diff is how the dock-swipe
flavor bug was found — the engine's events looked correct in the log and in the
code, and only a capture showed the one field that differed.

## Verifying a gesture visually

`screencapture -x` works (Screen Recording is granted), so take a screenshot
*during* the gesture — hold the drag before releasing, since the effect may be
transient. Mission Control shows a "Desktop" pill near the top centre.

Two traps:

- **Mission Control stays open between runs.** Reset with a reverse gesture
  before the next trial or every later result is contaminated and everything
  looks like it passes.
- **Horizontal dock swipes need somewhere to go.** With a single Space they are
  a silent no-op that reads as a failure. Check first — `CGSCopySpaces` /
  `CGSGetActiveSpace`, both already declared in `CPrivateShim.h`.

## What you cannot verify from here

Feel and timing — scroll smoothness, momentum, acceleration curves, whether a
click/hold/double-click cycle responds the way a hand expects — are subjective
and need a real mouse. Verify that a gesture *functions*, then hand the feel
check to the user.
