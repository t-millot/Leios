# MousePilot

[![CI](https://github.com/t-millot/MousePilot/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/t-millot/MousePilot/actions/workflows/ci.yml)

Better control for external mice on macOS: smooth scrolling, click-and-drag trackpad gestures
(scroll / navigate, Spaces / Mission Control), and click actions for extra mouse buttons.

MousePilot is a Swift port of the input engine of [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix)
by Noah Nuebling. The engine (`Packages/MousePilotKit/Sources/MousePilotEngine`) is derived from the MMF source
and is used under the [MMF License](https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License).
MousePilot is not sold.

## Installing

Requires macOS 27 or later on Apple silicon.

1. Download `MousePilot-<version>.dmg` from
   [Releases](https://github.com/t-millot/MousePilot/releases) and drag **MousePilot** to Applications.
2. Open it and turn on **Enable MousePilot**.
3. Grant Accessibility to **MousePilotHelper** in System Settings → Privacy & Security → Accessibility.
   The engine starts as soon as permission is granted.

The app and the helper it embeds are both signed with a Developer ID and notarized, so there is no
Gatekeeper warning to click through. Neither is sandboxed: the engine owns `CGEventTap`s, which the
App Sandbox forbids.

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
xcodebuild test -workspace MousePilot.xcworkspace -scheme MousePilot -destination 'platform=macOS'
cd Packages/MousePilotKit && swift test
```

Lint with `swiftlint lint --strict` and check formatting with `swiftformat --lint`
(`brew install swiftlint swiftformat`). Rules the Mac Mouse Fix port does not
fit are relaxed in `Packages/MousePilotKit/.swiftlint.yml` rather than worked around in the source.

Tests live in three targets: `MousePilotTests/` (app-hosted: capture rules and the embedded-helper bundle layout)
and the package's `MousePilotEngineTests` / `MousePilotSharedTests`. Run them through `MousePilot.xcworkspace` —
Xcode leaves a local package's test targets out of a plain project scheme, so `xcodebuild test -project …`
runs only `MousePilotTests`. Everything else, including day-to-day development, works from `MousePilot.xcodeproj`.

The app accepts `--enable-helper` / `--disable-helper` launch arguments for scripted testing.

If you change the bundle identifier or switch signing identities, reset the stale permission with
`tccutil reset Accessibility com.tmillot.MousePilot.Helper`.

### Releasing

`Scripts/release.sh` produces the distributable disk image: it archives Release, exports with the
Developer ID identity, notarizes and staples *both* the app and the image, then re-checks the result
with `spctl` the way a recipient's Mac will. Stapling the app as well as the image is deliberate —
a copy dragged out to `/Applications` carries its own ticket and validates offline. The embedded
helper is checked separately, because launchd loads it rather than the user opening it, so Gatekeeper
assesses it on its own.

It needs a *Developer ID Application* certificate in the login keychain (Xcode → Settings → Accounts →
Manage Certificates) and notarization credentials under a keychain profile:

```bash
xcrun notarytool store-credentials mousepilot-notary --apple-id <apple-id> --team-id WE9Q98XU4V
./Scripts/release.sh
```

The version in the file name comes from `MARKETING_VERSION` in the Xcode project — bump it there,
on every configuration, before cutting a release.

## Architecture notes

- One dedicated engine thread hosts every event tap, timer and display link, so the engine is single-threaded.
- Config changes flow app → `config.json` → helper (file watcher + XPC `reloadConfig`).
- Tap lifetimes are decided by `SwitchMaster`: unused input paths cost nothing.
- The Buttons tab adds a button by capturing a press: the app arms the helper over XPC while the
  pointer is in the capture zone, and the helper swallows the next press and reports its number.
  That is what makes a button whose assignment would otherwise consume the press capturable too.
