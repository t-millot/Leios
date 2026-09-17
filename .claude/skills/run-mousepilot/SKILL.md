---
name: run-mousepilot
description: Build, launch and drive the MousePilot settings app on this Mac — including restarting the helper so a rebuilt engine actually takes effect, and screenshotting/clicking the window over the accessibility API. Use when asked to run, start, restart or screenshot the app, or to confirm an engine or UI change works in the real app rather than in tests.
---

# Running MousePilot

Two processes: the SwiftUI settings app (`MousePilot.app`) and the embedded
launchd agent (`MousePilotHelper`) that owns every event tap. Launching the app
does **not** restart a helper that is already running — see *Picking up a
rebuilt helper*.

## Build

```bash
xcodebuild -project MousePilot.xcodeproj -scheme MousePilot -configuration Debug -derivedDataPath build build
```

`build/` is gitignored derived data; the product lands at
`build/Build/Products/Debug/MousePilot.app` with the helper embedded at
`Contents/Library/LoginItems/MousePilotHelper.app`. Takes ~1 min cold, seconds
incrementally. Tests go through the workspace, not the project — see CLAUDE.md.

## Launch

```bash
open build/Build/Products/Debug/MousePilot.app
```

Use `open <path>`, not `open -a <path>` — `-a` takes an application *name* and
fails on a relative path. For scripted runs the app also takes
`--enable-helper` / `--disable-helper`:

```bash
open build/Build/Products/Debug/MousePilot.app --args --enable-helper
```

Confirm both processes:

```bash
ps -Ao pid,args | grep -i mousepilot | grep -v grep
launchctl list | grep com.tmillot.MousePilot.Helper
```

A `launchctl list` line with a PID and status `-15` means the agent is loaded
and running. The app's own status label should read `Running.` with a green
dot. The other labels come from `HelperStatus.description` in
[AppModel.swift](../../../MousePilot/AppModel.swift): `Running, but Accessibility
permission is missing.` (grant it in System Settings → Privacy & Security →
Accessibility), `Waiting for approval in System Settings → General → Login
Items.`, `Helper is enabled but not responding yet…`, and `Helper not found
inside the app bundle. Rebuild the app.`

## Picking up a rebuilt helper

The helper keeps running the binary launchd started, so after a rebuild the app
shows `Running.` while the *old* engine is still live. Restart it in place —
this keeps the same bundle path, so the Accessibility grant survives:

```bash
launchctl kickstart -k "gui/$(id -u)/com.tmillot.MousePilot.Helper"
```

The PID in `launchctl list` should change. Prefer this over toggling **Enable
MousePilot** off/on, and never re-register from a different build location
unless you intend to re-grant Accessibility (`tccutil reset Accessibility
com.tmillot.MousePilot.Helper`).

## Drive the window

The app has no test hooks; drive it over the accessibility API. Nothing here
moves the user's pointer.

Dump the UI tree:

```bash
osascript -e 'tell application "System Events" to tell process "MousePilot" to get entire contents of window 1'
```

Stable paths as of this writing:

- Tabs (Scrolling / Buttons / General): `radio button N of tab group 1 of group 1 of toolbar 1 of window 1`
- Enable switch: `checkbox "Enable MousePilot" of group 1 of window 1`
- Status label: `static text 2 of group 1 of window 1`
- Action pickers: `pop up button "Click and Drag" of group N of scroll area 1 of group 1 of group 1 of window 1`

Switch tabs and read the status:

```bash
osascript -e 'tell application "System Events" to tell process "MousePilot" to click radio button 1 of tab group 1 of group 1 of toolbar 1 of window 1'
osascript -e 'tell application "System Events" to tell process "MousePilot" to get value of static text 2 of group 1 of window 1'
```

Screenshot just the window (query its frame first, pad by ~10 pt):

```bash
osascript -e 'tell application "System Events" to tell process "MousePilot" to get {position, size} of window 1'
screencapture -x -o -R <x>,<y>,<w>,<h> /tmp/mousepilot.png
```

`-x` suppresses the shutter sound, `-o` drops the window shadow. **Look at the
PNG** — a blank or missing window is a failed launch. Python has no `Quartz`
module on this machine, so don't reach for `CGWindowListCopyWindowInfo`.

## Check what the engine did

Config the helper is reading:

```bash
cat ~/Library/Application\ Support/MousePilot/config.json
```

The app debounces writes 100 ms and the helper's `ConfigStore` debounces the
directory watch 150 ms, so wait ~300 ms after a UI change before asserting on
the file.

Live engine logs (the launchd plist sends stdout/stderr to `/dev/null`, so the
unified log is the only view):

```bash
log stream --predicate 'subsystem == "com.tmillot.MousePilot"' --style compact
```

`log show --last 2m` on the same predicate often comes back empty for a session
that logged nothing at that level — use `log stream` while reproducing, or
`Console.app` filtered on the subsystem.

## What you cannot verify from here

Scroll feel, drag gestures and click/hold/double-click cycles need a real mouse
in hand. Verify the app launches, the UI responds and the config/engine wiring
is right, then hand the feel check to the user.
