# MousePilot

Better control for external mice on macOS: smooth scrolling, click-and-drag trackpad gestures
(scroll / navigate, Spaces / Mission Control), and click actions for extra mouse buttons.

MousePilot is a Swift port of the input engine of [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix)
by Noah Nuebling. The engine (`Packages/MousePilotKit/Sources/MousePilotEngine`) is derived from the MMF source
and is used under the [MMF License](https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License).
MousePilot is not sold.

## Layout

- `MousePilot/` — the SwiftUI settings app. Writes `~/Library/Application Support/MousePilot/config.json`,
  enables/disables the helper through `SMAppService`, and shows the helper's status.
- `MousePilotHelper/` — a background login item (`LSUIElement`) launched by launchd. It owns every
  `CGEventTap` and runs the engine. Needs Accessibility permission.
- `Packages/MousePilotKit/` — local Swift package:
  - `MousePilotShared` — config model, constants, XPC protocol.
  - `MousePilotEngine` — the **Engine**: scrolling (`Scroll/`), buttons (`Buttons/`), drag gestures (`Drag/`),
    gesture synthesis (`Touch/`), one-shot actions (`Actions/`), math and curves (`Math/`).
  - `CPrivateShim` — C declarations for the private-but-exported macOS APIs the engine needs.
- `SupportFiles/` — launchd agent plist and entitlements.

## Building

1. Open `MousePilot.xcodeproj` in Xcode 27 and set your Development Team on **both** targets
   (Signing & Capabilities). A stable signing identity keeps the Accessibility permission across rebuilds.
2. Build and run the `MousePilot` scheme. The helper is built automatically and embedded at
   `MousePilot.app/Contents/Library/LoginItems/MousePilotHelper.app`.
3. Turn on **Enable MousePilot**, then grant Accessibility to `MousePilotHelper` in
   System Settings → Privacy & Security → Accessibility. The engine starts as soon as permission is granted.

Command line:

```bash
xcodebuild -project MousePilot.xcodeproj -scheme MousePilot -configuration Debug build
cd Packages/MousePilotKit && swift test
```

The app accepts `--enable-helper` / `--disable-helper` launch arguments for scripted testing.

If you change the bundle identifier or switch signing identities, reset the stale permission with
`tccutil reset Accessibility com.tmillot.MousePilot.Helper`.

## Architecture notes

- One dedicated engine thread hosts every event tap, timer and display link, so the engine is single-threaded.
- Config changes flow app → `config.json` → helper (file watcher + XPC `reloadConfig`).
- Tap lifetimes are decided by `SwitchMaster`: unused input paths cost nothing.
- The Buttons tab adds a button by capturing a press: the app arms the helper over XPC while the
  pointer is in the capture zone, and the helper swallows the next press and reports its number.
  That is what makes a button whose assignment would otherwise consume the press capturable too.
