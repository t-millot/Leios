# Leios

**Smooth scrolling on macOS**

[![CI](https://github.com/t-millot/Leios/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/t-millot/Leios/actions/workflows/ci.yml)

From *λεῖος* (*leîos*), ancient Greek for **smooth** — said of a polished surface, of level ground, of
anything without a catch in it. Its opposite is *τραχύς* (*trakhús*), rough or jagged. That contrast is
the whole idea: a mouse wheel turns in notches, and the engine's job is to take the notches out.

Better control for external mice: smooth scrolling, click-and-drag trackpad gestures (scroll / navigate,
Spaces / Mission Control), and click actions for extra buttons. Scrolling can be tuned per application,
and the settings you don't change keep following the global ones. Turn on **Sync settings with iCloud**
in General and your scrolling, buttons and per-app profiles follow your Apple Account to your other
Macs; the kill switches and the menu bar item stay on the Mac you set them on.

Leios is a Swift port of the input engine of [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix)
by Noah Nuebling. The engine (`Packages/LeiosKit/Sources/LeiosEngine`) is derived from the MMF source
and is used under the [MMF License](https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License).
Leios is not sold.

## Installing

Requires macOS 27 or later on Apple silicon.

1. Download `Leios-<version>.dmg` from [Releases](https://github.com/t-millot/Leios/releases) and drag
   **Leios** to Applications.
2. Open it and turn on **Enable**.
3. Grant Accessibility to **LeiosHelper** in System Settings → Privacy & Security → Accessibility.
   The engine starts as soon as permission is granted.

The app and its embedded helper are both signed with a Developer ID and notarized, so there is no
Gatekeeper warning to click through. Neither is sandboxed: the engine owns `CGEventTap`s, which the
App Sandbox forbids.

## Layout

- `Leios/` — the SwiftUI settings app. Writes `~/Library/Application Support/Leios/config.json`,
  enables and disables the helper through `SMAppService`, and shows its status.
- `LeiosHelper/` — a background login item (`LSUIElement`) launched by launchd. It owns every
  `CGEventTap` and runs the engine. Needs Accessibility permission.
- `Packages/LeiosKit/` — local Swift package:
  - `LeiosShared` — config model, constants, XPC protocol.
  - `LeiosEngine` — the **Engine**: scrolling (`Scroll/`), buttons (`Buttons/`), drag gestures (`Drag/`),
    gesture synthesis (`Touch/`), one-shot actions (`Actions/`), math and curves (`Math/`).
  - `CPrivateShim` — C declarations for the private-but-exported macOS APIs the engine needs.
- `SupportFiles/` — launchd agent plist and entitlements.

## Building

Open `Leios.xcodeproj` in Xcode 27, set your Development Team on **both** targets, and run the `Leios`
scheme; the helper is built automatically and embedded at
`Leios.app/Contents/Library/LoginItems/LeiosHelper.app`. Then enable it and grant Accessibility as above.
A stable signing identity keeps that permission across rebuilds; after changing the bundle identifier or
switching identities, clear the stale grant with `tccutil reset Accessibility com.tmillot.Leios.Helper`.

```bash
xcodebuild -project Leios.xcodeproj -scheme Leios -configuration Debug build
xcodebuild test -workspace Leios.xcworkspace -scheme Leios -destination 'platform=macOS'
cd Packages/LeiosKit && swift test
```

The app target carries an iCloud entitlement for the `iCloud.com.tmillot.Leios` CloudKit container,
which is restricted and so needs a provisioning profile. In Xcode that means the **iCloud**
capability with **CloudKit** ticked on the `Leios` target. To build without provisioning it —
which is what CI does, signing ad-hoc — swap in the entitlements that leave iCloud out:

```bash
xcodebuild -project Leios.xcodeproj -scheme Leios -configuration Debug build \
    LEIOS_ENTITLEMENTS=SupportFiles/Leios-CI.entitlements
```

The app then reports sync as unavailable instead of offering it. Only the app target is affected;
the helper has no iCloud entitlement, so it never needs re-provisioning.

Tests live in three targets: `LeiosTests` (app-hosted — capture rules and the embedded-helper bundle
layout), plus the package's `LeiosEngineTests` and `LeiosSharedTests`. **Run them through
`Leios.xcworkspace`**, not the project: Xcode leaves a local package's test targets out of a plain
project scheme, so `xcodebuild test -project …` silently runs only `LeiosTests`. Everything else works
from `Leios.xcodeproj`.

Lint with `swiftlint lint --strict` and `swiftformat --lint` (`brew install swiftlint swiftformat`).
Both report zero, so anything they flag is new; rules the Mac Mouse Fix port does not fit are relaxed in
`Packages/LeiosKit/.swiftlint.yml` rather than worked around in the source.

The app accepts `--enable-helper` / `--disable-helper` launch arguments for scripted testing.

### Releasing

`Scripts/release.sh` archives Release, exports with the Developer ID identity, notarizes and staples
*both* the app and the disk image, then re-checks the result with `spctl` the way a recipient's Mac
will. Stapling the app too means a copy dragged to `/Applications` carries its own ticket and validates
offline; the embedded helper is checked separately, since launchd loads it rather than the user opening
it. It needs a *Developer ID Application* certificate in the login keychain (Xcode → Settings → Accounts
→ Manage Certificates) and notarization credentials under a keychain profile:

```bash
xcrun notarytool store-credentials leios-notary --apple-id <apple-id> --team-id WE9Q98XU4V
./Scripts/release.sh --publish
```

Version, tag and image name come from `MARKETING_VERSION` — bump it on every configuration first.
Without `--publish` the script stops at the built image, creating no tag and no release.

## Architecture notes

- One dedicated engine thread hosts every event tap, timer and display link, so the engine is single-threaded.
- Config changes flow app → `config.json` → helper (file watcher + XPC `reloadConfig`).
- Tap lifetimes are decided by `SwitchMaster`: unused input paths cost nothing.
- Adding a button captures a press: the app arms the helper over XPC while the pointer is in the capture
  zone, and the helper swallows the next press and reports its number — which is what makes a button
  already consuming its own press capturable.
