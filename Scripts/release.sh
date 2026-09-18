#!/bin/bash
#
# Build, notarize and package a distributable Leios.dmg.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in the login keychain.
#      Xcode > Settings > Accounts > <team> > Manage Certificates > + > Developer ID Application
#   2. Notarization credentials stored under a keychain profile:
#      xcrun notarytool store-credentials leios-notary \
#          --apple-id <apple-id> --team-id WE9Q98XU4V
#      (asks for an app-specific password from appleid.apple.com)
#   3. Sparkle's EdDSA signing key, once ever. Sparkle's tools need no install — they ship inside
#      the package the project already depends on, so they always match the framework version the
#      app is built against (the Homebrew cask was withdrawn in September 2026 for failing
#      Gatekeeper, and is not the way in any more):
#      xcodebuild -resolvePackageDependencies -project Leios.xcodeproj -scheme Leios
#      "$(Scripts/release.sh --sparkle-bin)/generate_keys"
#      The private half stays in the login keychain; paste the public half it prints into
#      SupportFiles/Leios-Info.plist as SUPublicEDKey. Back it up (`generate_keys -x`) — losing
#      it means no copy of Leios already installed anywhere can ever be updated again.
#   4. A gh-pages branch serving the appcast, once:
#      git switch --orphan gh-pages && git rm -rf .
#      cp SupportFiles/appcast-template.xml appcast.xml
#      git add appcast.xml && git commit -m "Add the appcast" && git push -u origin gh-pages
#      then turn Pages on for that branch in the repository settings. The feed URL baked into
#      the app is SUFeedURL in SupportFiles/Leios-Info.plist; the two have to agree.
#   5. The CloudKit schema promoted to Production, once per schema change:
#      CloudKit Console > Leios > Development > Deploy Schema Changes.
#      A Developer ID build talks to Production (see SupportFiles/Leios-Release.entitlements);
#      without the promotion every user's first sync fails with an unknown record type. There is
#      no way to check this from here, so it stays a checklist item.
#
# Usage: Scripts/release.sh [--publish] [output-dir]      # output default: build/
#
#   --publish   after building, create the GitHub release, upload the disk image
#               and the update archive to it, and add the release to the appcast.
#               Off by default: building is repeatable, publishing is not, so it
#               has to be asked for.
#
# The tag is derived from MARKETING_VERSION: "1.0 beta 1" -> v1.0-beta.1,
# "1.0" -> v1.0. A version with more than one word is treated as a prerelease.
#
set -euo pipefail

TEAM_ID="WE9Q98XU4V"
NOTARY_PROFILE="${NOTARY_PROFILE:-leios-notary}"
SCHEME="Leios"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# Locate one of Sparkle's command-line tools.
#
# There is nothing to install: the Homebrew cask was withdrawn on 2026-09-01 for failing the
# Gatekeeper check. The tools ship inside the SPM artifact this project already resolves, which is
# better anyway -- they are then guaranteed to match the framework version the app is built
# against. SPARKLE_BIN overrides the search for anyone keeping a copy elsewhere.
sparkle_tool() {
    local name="$1" candidate
    if [ -n "${SPARKLE_BIN:-}" ] && [ -x "$SPARKLE_BIN/$name" ]; then
        echo "$SPARKLE_BIN/$name"; return 0
    fi
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"; return 0
    fi
    # First the derived data this repo's own scripts use, then Xcode's default location. An
    # unmatched glob stays literal, which the -x test then rejects.
    for candidate in "$REPO_ROOT"/build/SourcePackages/artifacts/sparkle/Sparkle/bin/"$name" \
                     "$HOME"/Library/Developer/Xcode/DerivedData/Leios-*/SourcePackages/artifacts/sparkle/Sparkle/bin/"$name"; do
        [ -x "$candidate" ] && { echo "$candidate"; return 0; }
    done
    return 1
}

MISSING_TOOLS_HELP="Resolve the package first, which is what puts them on disk:
           xcodebuild -resolvePackageDependencies -project Leios.xcodeproj -scheme Leios
       or set SPARKLE_BIN to a directory holding them. They are not installable separately --
       the Homebrew cask was withdrawn in September 2026 for failing Gatekeeper."

PUBLISH=0
OUT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --publish) PUBLISH=1 ;;
        # Where generate_keys lives, for the one-time key setup in the prerequisites above.
        --sparkle-bin)
            TOOL="$(sparkle_tool generate_keys)" || die "no Sparkle tools found. $MISSING_TOOLS_HELP"
            dirname "$TOOL"; exit 0 ;;
        -h|--help) sed -n '3,41p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) OUT_DIR="$1" ;;
    esac
    shift
done
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build}"

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

# Sparkle checks every download against the public key baked into the app, so an appcast entry
# that is not signed with the matching private key is an update nobody can install.
SIGN_UPDATE="$(sparkle_tool sign_update)" \
    || die "could not find Sparkle's sign_update.
       $MISSING_TOOLS_HELP"

INFO_PLIST="$REPO_ROOT/SupportFiles/Leios-Info.plist"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$INFO_PLIST" 2>/dev/null || true)"
case "$PUBLIC_KEY" in
    ""|REPLACE_WITH_*)
        die "SUPublicEDKey in SupportFiles/Leios-Info.plist is still a placeholder.
       Run 'generate_keys' and paste the public key it prints there. A build shipped with the
       placeholder can never be updated -- Sparkle would reject every signature." ;;
esac
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$INFO_PLIST" 2>/dev/null || true)"
[ -n "$FEED_URL" ] || die "no SUFeedURL in SupportFiles/Leios-Info.plist"

# Resolve the version up front so a bad tag or an unpushed commit fails now
# rather than after ten minutes of archiving and notarizing.
SETTINGS="$(xcodebuild -project "$REPO_ROOT/Leios.xcodeproj" -target "$SCHEME" \
    -configuration Release -showBuildSettings 2>/dev/null)"
VERSION="$(sed -n 's/^ *MARKETING_VERSION = //p' <<<"$SETTINGS" | head -1)"
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION from the project"
# Sparkle orders updates by CFBundleVersion, not by the marketing string. It is a build counter
# that only ever goes up -- it happens to have tracked the beta number so far, but 1.0 final is
# build 6, not build 1.
BUILD="$(sed -n 's/^ *CURRENT_PROJECT_VERSION = //p' <<<"$SETTINGS" | head -1)"
[ -n "$BUILD" ] || die "could not read CURRENT_PROJECT_VERSION from the project"

# "1.0 beta 1" -> v1.0-beta.1: first word is the version, the rest is the
# prerelease identifier, which semver separates with a dash then dots.
VERSION_TAG="v$(awk '{ t=$1; for (i=2;i<=NF;i++) t = t (i==2 ? "-" : ".") tolower($i); print t }' <<<"$VERSION")"
# The volume name keeps the spaces; the file name does not.
VERSION_SLUG="${VERSION// /-}"
DMG="$OUT_DIR/Leios-$VERSION_SLUG.dmg"
# What Sparkle downloads. The disk image stays the first-time human download.
ZIP="$OUT_DIR/Leios-$VERSION_SLUG.zip"

echo "Version:  $VERSION (build $BUILD)"
echo "Tag:      $VERSION_TAG"
echo "Image:    $DMG"
echo "Archive:  $ZIP"

if [ "$PUBLISH" -eq 1 ]; then
    command -v gh >/dev/null 2>&1 || die "--publish needs the gh CLI (brew install gh)"
    gh auth status >/dev/null 2>&1 || die "--publish needs an authenticated gh (gh auth login)"

    # A release has to point at a commit other people can fetch, and has to
    # describe a tree that matches the image being uploaded.
    [ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] \
        || die "working tree is dirty -- commit or stash before publishing"

    BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
    # A branch that was never pushed makes this fetch fail, which is the same
    # problem as a stale one -- report it as such rather than as a fetch error.
    git -C "$REPO_ROOT" fetch --quiet origin "$BRANCH" 2>/dev/null \
        || die "origin has no branch $BRANCH (or it could not be fetched) -- push before publishing"
    [ "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$(git -C "$REPO_ROOT" rev-parse "origin/$BRANCH")" ] \
        || die "HEAD is not pushed to origin/$BRANCH -- push before publishing"

    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
    gh release view "$VERSION_TAG" --repo "$REPO" >/dev/null 2>&1 \
        && die "release $VERSION_TAG already exists -- bump MARKETING_VERSION first"

    # The appcast lives on its own branch, so a publish touches two branches.
    git -C "$REPO_ROOT" fetch --quiet origin gh-pages 2>/dev/null \
        || die "origin has no gh-pages branch, so there is nowhere to publish the appcast.
       Create it once -- see the prerequisites at the top of this script."

    # An update Sparkle will not offer is worse than no update: every existing install would go
    # on reporting itself current, silently and for good. Check against the feed users read,
    # not against the branch, so a failed push last time shows up here.
    HIGHEST_BUILD="$(curl -fsSL "$FEED_URL" 2>/dev/null \
        | sed -n 's/.*<sparkle:version>\([0-9][0-9]*\)<.*/\1/p' | sort -n | tail -1)"
    HIGHEST_BUILD="${HIGHEST_BUILD:-0}"
    [ "$BUILD" -gt "$HIGHEST_BUILD" ] \
        || die "CURRENT_PROJECT_VERSION is $BUILD but the appcast already offers build $HIGHEST_BUILD.
       Sparkle orders updates by that number; raise it (it is a build counter, not the beta number)."
fi

# --- archive ---------------------------------------------------------------

step "Archiving Release"
# -allowProvisioningUpdates: iCloud is a restricted entitlement, so the app needs a Developer ID
# provisioning profile that authorises it. Without the flag xcodebuild refuses to create or renew
# one and the export fails with "No profiles for 'com.tmillot.Leios' were found". Profiles expire
# after a year, so this also keeps a release twelve months from now from failing the same way.
xcodebuild archive \
    -project "$REPO_ROOT/Leios.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$WORK_DIR/Leios.xcarchive" \
    -destination 'generic/platform=macOS' \
    -allowProvisioningUpdates \
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
    -archivePath "$WORK_DIR/Leios.xcarchive" \
    -exportOptionsPlist "$WORK_DIR/ExportOptions.plist" \
    -exportPath "$WORK_DIR/export" \
    -allowProvisioningUpdates \
    >"$WORK_DIR/export.log" 2>&1 \
    || { tail -40 "$WORK_DIR/export.log"; die "export failed (full log: $WORK_DIR/export.log)"; }

APP="$WORK_DIR/export/Leios.app"
[ -d "$APP" ] || die "expected $APP after export"

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$BUILT_VERSION" = "$VERSION" ] \
    || die "built app reports $BUILT_VERSION but the project says $VERSION"

# The helper is loaded by launchd, not double-clicked, so verify it carries the
# Developer ID and hardened runtime too -- Gatekeeper evaluates it separately.
HELPER="$APP/Contents/Library/LoginItems/LeiosHelper.app"
[ -d "$HELPER" ] || die "helper missing from $APP -- check the Embed Helper build phase"
for bundle in "$APP" "$HELPER"; do
    SIGNATURE="$(codesign -dv --verbose=4 "$bundle" 2>&1)"
    grep -q "Authority=Developer ID Application" <<<"$SIGNATURE" \
        || die "$(basename "$bundle") is not signed with Developer ID"
    grep -q "flags=.*runtime" <<<"$SIGNATURE" \
        || die "$(basename "$bundle") is missing the hardened runtime"
done
codesign --verify --deep --strict "$APP" || die "signature verification failed"

# iCloud is a restricted entitlement, so the app carries a provisioning profile that authorises
# it. Both are easy to lose to a signing mishap and neither shows up until a user's first sync.
[ -f "$APP/Contents/embedded.provisionprofile" ] \
    || die "Leios.app has no embedded provisioning profile -- iCloud sync would not work"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "iCloud.com.tmillot.Leios" \
    || die "Leios.app is missing the iCloud container entitlement"

# --- notarize the app ------------------------------------------------------

step "Notarizing Leios.app ($VERSION)"
ditto -c -k --keepParent "$APP" "$WORK_DIR/Leios.zip"
xcrun notarytool submit "$WORK_DIR/Leios.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait \
    || die "notarization failed -- 'xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE' has the details"

# Staple the app itself so a copy dragged out of the DMG validates offline.
xcrun stapler staple "$APP"

# Zipped after stapling, so the copy Sparkle unpacks into /Applications carries its own
# notarization ticket rather than depending on a round trip to Apple at first launch.
step "Packaging the update archive"
mkdir -p "$OUT_DIR"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# --- package ---------------------------------------------------------------

step "Building $DMG"
mkdir -p "$OUT_DIR" "$WORK_DIR/dmgroot"
cp -R "$APP" "$WORK_DIR/dmgroot/"
ln -s /Applications "$WORK_DIR/dmgroot/Applications"
rm -f "$DMG"
hdiutil create -volname "Leios $VERSION" -srcfolder "$WORK_DIR/dmgroot" \
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
spctl -a -vvv -t exec "$WORK_DIR/dmgroot/Leios.app"

# --- publish ---------------------------------------------------------------

if [ "$PUBLISH" -eq 1 ]; then
    step "Publishing $VERSION_TAG"
    # One word is a final release; anything more ("1.0 beta 1") is a prerelease.
    PRERELEASE=""
    case "$VERSION" in *" "*) PRERELEASE="--prerelease" ;; esac
    gh release create "$VERSION_TAG" "$DMG" "$ZIP" \
        --target "$(git -C "$REPO_ROOT" rev-parse HEAD)" \
        --title "$VERSION" \
        --generate-notes \
        $PRERELEASE \
        || die "could not create the release"
    git -C "$REPO_ROOT" fetch --quiet --tags origin

    step "Adding build $BUILD to the appcast"
    # sign_update prints the two enclosure attributes ready to paste:
    #   sparkle:edSignature="..." length="..."
    SIGNATURE="$("$SIGN_UPDATE" "$ZIP")" || die "sign_update failed -- is the private key in the keychain?"

    RELEASE_URL="$(gh release view "$VERSION_TAG" --repo "$REPO" --json url --jq .url)"
    ENCLOSURE_URL="https://github.com/$REPO/releases/download/$VERSION_TAG/$(basename "$ZIP")"
    # RFC 822, which is what RSS wants. LC_ALL so the month and day are English wherever this runs.
    PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    # The same test that decided --prerelease above, so the channel and the GitHub flag cannot
    # drift apart. An item with no channel reaches every user; this one reaches only opted-in ones.
    CHANNEL=""
    case "$VERSION" in *" "*) CHANNEL=$'\n            <sparkle:channel>beta</sparkle:channel>' ;; esac

    cat > "$WORK_DIR/item.xml" <<ITEM
        <item>
            <title>$VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>$CHANNEL
            <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
            <sparkle:releaseNotesLink>$RELEASE_URL</sparkle:releaseNotesLink>
            <enclosure url="$ENCLOSURE_URL" type="application/octet-stream" $SIGNATURE />
        </item>
ITEM

    FEED_DIR="$WORK_DIR/gh-pages"
    git -C "$REPO_ROOT" worktree add --quiet "$FEED_DIR" gh-pages \
        || die "could not check out gh-pages"
    # The worktree outlives the script's own temp dir cleanup unless it is removed explicitly.
    trap 'git -C "$REPO_ROOT" worktree remove --force "$WORK_DIR/gh-pages" 2>/dev/null; rm -rf "$WORK_DIR"' EXIT

    [ -f "$FEED_DIR/appcast.xml" ] || die "gh-pages has no appcast.xml -- see the prerequisites"
    grep -q "NEW ITEMS GO BELOW THIS LINE" "$FEED_DIR/appcast.xml" \
        || die "the marker comment is gone from appcast.xml; this script inserts new items after it"

    # Newest first, straight under the marker. `r` rather than awk -v: the awk macOS ships
    # rejects a multi-line value passed that way.
    sed -e "/NEW ITEMS GO BELOW THIS LINE/r $WORK_DIR/item.xml" \
        "$FEED_DIR/appcast.xml" > "$FEED_DIR/appcast.xml.new"
    mv "$FEED_DIR/appcast.xml.new" "$FEED_DIR/appcast.xml"
    xmllint --noout "$FEED_DIR/appcast.xml" || die "the generated appcast is not well-formed XML"

    git -C "$FEED_DIR" add appcast.xml
    git -C "$FEED_DIR" commit --quiet -m "Appcast: $VERSION (build $BUILD)"
    git -C "$FEED_DIR" push --quiet origin gh-pages || die "could not push the appcast"
fi

echo
echo "Done: $DMG"
echo "      $ZIP"
echo "Gatekeeper accepts it -- opens on any Mac with no warning."
if [ "$PUBLISH" -eq 1 ]; then
    gh release view "$VERSION_TAG" --json url --jq .url
    echo "Appcast updated; installed copies will offer build $BUILD on their next check."
else
    echo "Not published. Re-run with --publish to cut $VERSION_TAG and add it to the appcast."
fi
