#!/bin/bash
#
# Build, notarize and package a distributable MousePilot.dmg.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in the login keychain.
#      Xcode > Settings > Accounts > <team> > Manage Certificates > + > Developer ID Application
#   2. Notarization credentials stored under a keychain profile:
#      xcrun notarytool store-credentials mousepilot-notary \
#          --apple-id <apple-id> --team-id WE9Q98XU4V
#      (asks for an app-specific password from appleid.apple.com)
#
# Usage: Scripts/release.sh [output-dir]        # default: build/
#
set -euo pipefail

TEAM_ID="WE9Q98XU4V"
NOTARY_PROFILE="${NOTARY_PROFILE:-mousepilot-notary}"
SCHEME="MousePilot"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$REPO_ROOT/build}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# --- preflight -------------------------------------------------------------

# Read command output into a variable before grepping it: piping into `grep -q`
# lets grep exit on the first match and kill the writer with SIGPIPE, which
# `set -o pipefail` would then report as a failure of the check itself.
IDENTITIES="$(security find-identity -v -p codesigning 2>&1)"
grep -q "Developer ID Application.*($TEAM_ID)" <<<"$IDENTITIES" \
    || die "no 'Developer ID Application' certificate for team $TEAM_ID in the keychain.
       Create one: Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "no notarization credentials under keychain profile '$NOTARY_PROFILE'.
       Create them: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id $TEAM_ID"

# --- archive ---------------------------------------------------------------

step "Archiving Release"
xcodebuild archive \
    -project "$REPO_ROOT/MousePilot.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$WORK_DIR/MousePilot.xcarchive" \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    >"$WORK_DIR/archive.log" 2>&1 \
    || { tail -40 "$WORK_DIR/archive.log"; die "archive failed (full log: $WORK_DIR/archive.log)"; }

# --- export with Developer ID ----------------------------------------------

step "Exporting with Developer ID"
cat > "$WORK_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$WORK_DIR/MousePilot.xcarchive" \
    -exportOptionsPlist "$WORK_DIR/ExportOptions.plist" \
    -exportPath "$WORK_DIR/export" \
    >"$WORK_DIR/export.log" 2>&1 \
    || { tail -40 "$WORK_DIR/export.log"; die "export failed (full log: $WORK_DIR/export.log)"; }

APP="$WORK_DIR/export/MousePilot.app"
[ -d "$APP" ] || die "expected $APP after export"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
# The volume name keeps the version as-is; the file name loses the spaces,
# so "1.0 beta 1" ships as MousePilot-1.0-beta-1.dmg.
VERSION_SLUG="${VERSION// /-}"
DMG="$OUT_DIR/MousePilot-$VERSION_SLUG.dmg"

# The helper is loaded by launchd, not double-clicked, so verify it carries the
# Developer ID and hardened runtime too -- Gatekeeper evaluates it separately.
HELPER="$APP/Contents/Library/LoginItems/MousePilotHelper.app"
[ -d "$HELPER" ] || die "helper missing from $APP -- check the Embed Helper build phase"
for bundle in "$APP" "$HELPER"; do
    SIGNATURE="$(codesign -dv --verbose=4 "$bundle" 2>&1)"
    grep -q "Authority=Developer ID Application" <<<"$SIGNATURE" \
        || die "$(basename "$bundle") is not signed with Developer ID"
    grep -q "flags=.*runtime" <<<"$SIGNATURE" \
        || die "$(basename "$bundle") is missing the hardened runtime"
done
codesign --verify --deep --strict "$APP" || die "signature verification failed"

# --- notarize the app ------------------------------------------------------

step "Notarizing MousePilot.app ($VERSION)"
ditto -c -k --keepParent "$APP" "$WORK_DIR/MousePilot.zip"
xcrun notarytool submit "$WORK_DIR/MousePilot.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait \
    || die "notarization failed -- 'xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE' has the details"

# Staple the app itself so a copy dragged out of the DMG validates offline.
xcrun stapler staple "$APP"

# --- package ---------------------------------------------------------------

step "Building $DMG"
mkdir -p "$OUT_DIR" "$WORK_DIR/dmgroot"
cp -R "$APP" "$WORK_DIR/dmgroot/"
ln -s /Applications "$WORK_DIR/dmgroot/Applications"
rm -f "$DMG"
hdiutil create -volname "MousePilot $VERSION" -srcfolder "$WORK_DIR/dmgroot" \
    -ov -format UDZO "$DMG" >/dev/null

codesign --sign "Developer ID Application" --timestamp "$DMG"

step "Notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
    || die "DMG notarization failed"
xcrun stapler staple "$DMG"

# --- verify like a recipient ----------------------------------------------

step "Verifying"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG"
spctl -a -vvv -t exec "$WORK_DIR/dmgroot/MousePilot.app"

echo
echo "Done: $DMG"
echo "Gatekeeper accepts it -- opens on any Mac with no warning."
