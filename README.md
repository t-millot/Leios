# Leios

[![CI](https://github.com/t-millot/Leios/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/t-millot/Leios/actions/workflows/ci.yml)

Better control for external mice on macOS: smooth scrolling, click-and-drag trackpad gestures
(scroll / navigate, Spaces / Mission Control), and click actions for extra mouse buttons.
Scrolling can be tuned per application, and the settings you don't change keep following the global ones.

Leios is a Swift port of the input engine of [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix)
by Noah Nuebling. The engine (`Packages/LeiosKit/Sources/LeiosEngine`) is derived from the MMF source
and is used under the [MMF License](https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License).
Leios is not sold.

## Installing

Requires macOS 27 or later on Apple silicon.

1. Download `Leios-<version>.dmg` from
   [Releases](https://github.com/t-millot/Leios/releases) and drag **Leios** to Applications.
2. Open it and turn on **Enable**.
3. Grant Accessibility to **LeiosHelper** in System Settings → Privacy & Security → Accessibility.
   The engine starts as soon as permission is granted.

The app and the helper it embeds are both signed with a Developer ID and notarized, so there is no
Gatekeeper warning to click through. Neither is sandboxed: the engine owns `CGEventTap`s, which the
App Sandbox forbids.

## Layout

- `Leios/` — the SwiftUI settings app. Writes `~/Library/Application Support/Leios/config.json`,
  enables/disables the helper through `SMAppService`, and shows the helper's status.
- `LeiosHelper/` — a background login item (`LSUIElement`) launched by launchd. It owns every
  `CGEventTap` and runs the engine. Needs Accessibility permission.
- `Packages/LeiosKit/` — local Swift package:
  - `LeiosShared` — config model, constants, XPC protocol.
  - `LeiosEngine` — the **Engine**: scrolling (`Scroll/`), buttons (`Buttons/`), drag gestures (`Drag/`),
    gesture synthesis (`Touch/`), one-shot actions (`Actions/`), math and curves (`Math/`).
  - `CPrivateShim` — C declarations for the private-but-exported macOS APIs the engine needs.
- `SupportFiles/` — launchd agent plist and entitlements.

## Building

1. Open `Leios.xcodeproj` in Xcode 27 and set your Development Team on **both** targets
   (Signing & Capabilities). A stable signing identity keeps the Accessibility permission across rebuilds.
2. Build and run the `Leios` scheme. The helper is built automatically and embedded at
   `Leios.app/Contents/Library/LoginItems/LeiosHelper.app`.
3. Turn on **Enable**, then grant Accessibility to `LeiosHelper` in
   System Settings → Privacy & Security → Accessibility. The engine starts as soon as permission is granted.

Command line:

```bash
xcodebuild -project Leios.xcodeproj -scheme Leios -configuration Debug build
xcodebuild test -workspace Leios.xcworkspace -scheme Leios -destination 'platform=macOS'
cd Packages/LeiosKit && swift test
```

Lint with `swiftlint lint --strict` and check formatting with `swiftformat --lint`
(`brew install swiftlint swiftformat`). Rules the Mac Mouse Fix port does not
fit are relaxed in `Packages/LeiosKit/.swiftlint.yml` rather than worked around in the source.

Tests live in three targets: `LeiosTests/` (app-hosted: capture rules and the embedded-helper bundle layout)
and the package's `LeiosEngineTests` / `LeiosSharedTests`. Run them through `Leios.xcworkspace` —
Xcode leaves a local package's test targets out of a plain project scheme, so `xcodebuild test -project …`
runs only `LeiosTests`. Everything else, including day-to-day development, works from `Leios.xcodeproj`.

The app accepts `--enable-helper` / `--disable-helper` launch arguments for scripted testing.

If you change the bundle identifier or switch signing identities, reset the stale permission with
`tccutil reset Accessibility com.tmillot.Leios.Helper`.

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
xcrun notarytool store-credentials leios-notary --apple-id <apple-id> --team-id WE9Q98XU4V
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
