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
and running. The status dot at the head of the sidebar should be green, with
`Running` as its tooltip and accessibility value. The other labels come from
`HelperState.description` in
[AppModel.swift](../../../Leios/AppModel.swift): `Running, but Accessibility
permission is missing` (grant it in System Settings → Privacy & Security →
Accessibility), `Waiting for approval in System Settings → General → Login
Items`, `Helper is enabled but not responding yet…`, `Helper not found inside
the app bundle — rebuild the app`, and `Leios is off`.

## Picking up a rebuilt helper

The helper keeps running the binary launchd started, so after a rebuild the app
shows `Running` while the *old* engine is still live. Restart it in place —
this keeps the same bundle path, so the Accessibility grant survives:

```bash
launchctl kickstart -k "gui/$(id -u)/com.tmillot.Leios.Helper"
```

The PID in `launchctl list` should change.

**A Debug build cannot host the launchd agent at all.** Registering it — via the Enable switch or
`--enable-helper` — leaves the job at `last exit code = 78: EX_CONFIG` forever, because launchd
refuses to spawn a login-item agent out of a build directory. Signing the build with Developer ID
does not help; the location is the problem. To run a rebuilt *engine*, launch the helper binary
directly instead:

```bash
open build/Build/Products/Debug/Leios.app/Contents/Library/LoginItems/LeiosHelper.app
```

It gets Accessibility from the existing grant as long as it is signed with the same Developer ID
and bundle identifier. The targets use automatic signing, which refuses a Developer ID identity on
its own, so the signing style has to be overridden too:

```bash
xcodebuild -project Leios.xcodeproj -scheme Leios -configuration Debug -derivedDataPath build build \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application: Thomas Millot (WE9Q98XU4V)" \
    PROVISIONING_PROFILE_SPECIFIER= LEIOS_ENTITLEMENTS=SupportFiles/Leios-CI.entitlements
```

The installed helper can keep running: taps are inserted at the head, so the helper started last
sees every event first and the older one only gets what it passes through. What
it does *not* get is XPC: `NSXPCListener(machServiceName:)` needs launchd to own the name, so the
settings app will show `Helper is enabled but not responding yet…` and anything that goes over XPC
— status, `reloadConfig`, `flushStatistics` — will not work. Verify through `config.json`,
`statistics.json` and the unified log instead. Send it `SIGTERM` rather than `SIGKILL` to shut it
down, so `applicationWillTerminate` runs and the engine's final flush happens.

**Registering a Debug build also poisons the installed one.** LaunchServices resolves
`com.tmillot.Leios` to whichever bundle it saw last, so after the Debug app has been opened, `smd`
resolves the agent's relative executable path against the build directory and `/Applications` keeps
failing to spawn even after toggling Enable off and on. Point LaunchServices back before retrying:

```bash
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -u build/Build/Products/Debug/Leios.app
```

then toggle Enable off, wait for the job to leave `launchctl list`, and toggle it back on.

**Do not reach for the Enable switch instead.** It unregisters the launchd agent
and re-registers it from whichever bundle is running — so flipping it in a Debug
build moves the agent to `build/Build/Products/Debug/`, where it fails to spawn
(`last exit code = 78: EX_CONFIG` in `launchctl print
"gui/$(id -u)/com.tmillot.Leios.Helper"`) and the helper stays down. To recover,
quit the Debug app, open the installed one, turn Enable **off**, wait until the
job is gone from `launchctl list` — a fast off/on does not work, the unregister
has not finished — then turn it back on. Also never re-register from a different
build location unless you intend to re-grant Accessibility (`tccutil reset
Accessibility com.tmillot.Leios.Helper`).

## Drive the window

The app has no test hooks; drive it over the accessibility API. Nothing here
moves the user's pointer.

Dump the UI tree:

```bash
osascript -e 'tell application "System Events" to tell process "Leios" to get entire contents of window 1'
```

Navigation is a `NavigationSplitView`: a sidebar of rows, not tabs. The two
columns are `group 1` (sidebar) and `group 2` (detail) `of splitter group 1 of
group 1 of window 1`, abbreviated `<sidebar>` and `<detail>` below.

Stable paths as of this writing:

- Sidebar list: `outline 1 of scroll area 1 of <sidebar>`
- Enable switch: `checkbox "Enable Leios" of <sidebar>`
- Status: `image 1 of <sidebar>` — the state string is its accessibility
  *value*, not a visible label
- Action pickers: `pop up button "Click and Drag" of group N of scroll area 1 of <detail>`
- Add an app (only while the Apps row is selected): `menu button "Add App…" of scroll area 1 of <detail>`
- Remove an app (only while a profile is selected): `button 1 of toolbar 1 of window 1`

Rows are addressed by index, because the Apps row is a `DisclosureGroup` whose
label reads back as `missing value`. Read the labels first rather than assuming
a count — app profiles are rows too, and they sit *between* Apps and Buttons:

```bash
osascript -e 'tell application "System Events" to tell process "Leios" to get value of static text 1 of UI element 1 of every row of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1'
# → Scrolling, missing value, Claude, Buttons, Devices, Statistics, Settings
```

Select a row and read the status:

```bash
osascript -e 'tell application "System Events" to tell process "Leios" to set selected of item 1 of (rows of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1) to true'
osascript -e 'tell application "System Events" to tell process "Leios" to get value of image 1 of group 1 of splitter group 1 of group 1 of window 1'
```

Two traps:

- **The window's name is the selected section**, never "Leios": `Scrolling`,
  `Apps`, `Buttons`, `Devices`, `Statistics`, `Settings`, or — on an app profile, where the
  bundle ID is the window's subtitle — `Claude – com.anthropic.claudefordesktop`.
  A path that names the window breaks as soon as the selection moves, so always
  say `window 1`.
- **Read the row labels in a separate `osascript` call from the one that selects a
  row.** Doing both in one `tell` block re-evaluates `rows of outline 1` and can
  raise `Invalid index` when the Apps disclosure settles between the two
  statements.
- **SwiftUI context menus ignore `perform action "AXShowMenu"`**, silently. The
  app-row "Remove" item only opens under a real `rightMouseDown`/`Up` posted to
  `kCGHIDEventTap`. Removing a profile then raises a confirmation sheet whose
  buttons carry no titles: `button 1 of sheet 1 of window 1` is Cancel,
  `button 2` is Remove.

Screenshot just the window (query its frame first, pad by ~10 pt):

```bash
osascript -e 'tell application "System Events" to tell process "Leios" to get {position, size} of window 1'
screencapture -x -o -R <x>,<y>,<w>,<h> /tmp/leios.png
```

`-x` suppresses the shutter sound, `-o` drops the window shadow. **Look at the
PNG** — a blank or missing window is a failed launch. Python has no `Quartz`
module on this machine, so don't reach for `CGWindowListCopyWindowInfo`; to
measure pixels, convert with `sips -s format bmp` and parse the header, since
PIL is not there either.

Anything translucent — the title bar, the sidebar — takes its colour from what
is *behind* the window, so a capture taken over another dark window proves
nothing. Hide the other apps first (`set visible of process "X" to false`,
restoring them from a `trap`) so the wallpaper is the backdrop. The title bar
also lights on hover, which a screenshot alone will not show: warp the pointer
with `CGWarpMouseCursorPosition` and post a `mouseMoved` to `kCGHIDEventTap`
before capturing, and put it back afterwards.

The Statistics pane is the one screen that draws rather than lists. Its range
picker is `radio group 1 of scroll area 1 of <detail>` (`radio button 4` is All
Time), and the charts themselves are opaque to the accessibility API beyond the
label on each `Chart`, so verifying them means looking at a screenshot. It reads
`~/Library/Application Support/Leios/Statistics/statistics.json`; writing a
fixture there is the way to see the charts with a year of history behind them
without waiting a year. The pane only *shows* counts — **Collect usage
statistics** and **Reset Statistics…** are in the Settings pane, under
Statistics.

A plain SwiftUI `Button` inside a `Form` reports `name` as `missing value` to
System Events even though its title is drawn and an `.accessibilityLabel` makes
no difference, so address those by index (`button 1 of group N of scroll area 1
of <detail>`) rather than by title. `confirmationDialog` opens as `sheet 1 of
window 1`, whose buttons are likewise untitled — dismiss it with
`key code 53` when the point was only to see that it opened.

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

To measure smooth scrolling frame by frame, post wheel ticks
(`CGEvent(scrollWheelEvent2Source:…)`) to `kCGHIDEventTap` and run an *active* tap at
`kCGSessionEventTap` that records every scroll event whose `eventSourceUnixProcessID` is the
helper's and returns nil, so nothing on screen scrolls. The helper stamps each output event with
`CACurrentMediaTime()`, so the gaps between `event.timestamp`s are its true posting cadence; receive
times measured in the tap pick up jitter of their own and are not. The engine picks its frame clock
from the *posted event's* `location`, so setting it steers a test onto a given display without
moving the pointer. Synthetic ticks are counted by the statistics tap like real ones.

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
