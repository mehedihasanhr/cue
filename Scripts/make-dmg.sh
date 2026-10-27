#!/bin/bash
#
# Packages a built Cue as a DMG people can install from.
#
#   xcodebuild -project Cue.xcodeproj -scheme Cue -configuration Release \
#       -derivedDataPath build/release build
#   Scripts/make-dmg.sh
#
# The image holds the app beside a shortcut to /Applications, which is what makes
# "drag it across to install" work. Without that shortcut the image opens with
# nothing to drop onto, and no way to install it but to know you can drag the app
# out yourself.
#
# Where the two icons sit, and a background behind them with an arrow, live in a
# .DS_Store — and writing one means driving Finder through AppleScript. That is
# left out on purpose: it needs a logged-in GUI session, it fails in CI, and
# Finder lays two icons out perfectly legibly by itself.
#
# Signed with a Developer ID and notarized, the image opens on any Mac without the
# "Apple could not verify" stop. Both are set up once (README › Releasing ›
# Notarization), then picked up from the environment:
#
#   CUE_DEVELOPER_ID="Developer ID Application: Name (TEAMID)"   re-signs the app for
#                                                                distribution, and the image
#   CUE_NOTARY_PROFILE=cue-notary                                sends the image to Apple and
#                                                                staples the ticket to it
#
# With neither, the app goes in as Xcode signed it, and macOS asks people to allow it
# the first time they open it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=${1:-"$ROOT/build/release/Build/Products/Release/Cue.app"}
OUT_DIR="$ROOT/dist"

[ -d "$APP" ] || { echo "no app at $APP — build Release first"; exit 1; }
# Absolute, because `defaults read` takes a relative path as a domain name.
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

BUNDLE="$(basename "$APP")"
NAME="$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleName 2>/dev/null || basename "$APP" .app)"
VERSION="$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
BUILD="$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleVersion)"
# No spaces in the file name: it ends up in a download URL.
DMG="$OUT_DIR/${NAME// /}-$VERSION.dmg"

DEVELOPER_ID=${CUE_DEVELOPER_ID:-}
NOTARY_PROFILE=${CUE_NOTARY_PROFILE:-}
# Apple notarizes only what a Developer ID signed.
[ -z "$NOTARY_PROFILE" ] || [ -n "$DEVELOPER_ID" ] || { echo "CUE_NOTARY_PROFILE needs CUE_DEVELOPER_ID too"; exit 1; }

# Refuse to ship something the signature does not cover.
codesign --verify --deep --strict "$APP"

# Kept outside the staging folder: anything inside it ends up in the image.
STAGE="$(mktemp -d)"
MOUNT="$(mktemp -d)"
ERRORS="$(mktemp)"
cleanup() {
    hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
    rm -rf "$STAGE" "$MOUNT" "$ERRORS"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"
# ditto rather than cp: it keeps the bundle's symlinks, extended attributes and
# its signature intact.
ditto "$APP" "$STAGE/$BUNDLE"

if [ -n "$DEVELOPER_ID" ]; then
    # Re-signed inside out, as notarization wants: every piece of code with the
    # hardened runtime and a secure timestamp, the app last with its own entitlements
    # (read back from the build, so they stay what the project says).
    codesign -d --entitlements - --xml "$APP" > "$ERRORS.entitlements" 2>/dev/null
    if /usr/bin/plutil -extract com.apple.security.get-task-allow raw "$ERRORS.entitlements" >/dev/null 2>&1; then
        echo "the app is entitled to be debugged (get-task-allow) — notarization refuses that; build Release"; exit 1
    fi
    sign() { codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp "$@"; }
    SPARKLE="$STAGE/$BUNDLE/Contents/Frameworks/Sparkle.framework"
    if [ -d "$SPARKLE" ]; then
        # The order Sparkle documents; the downloader keeps its own (network) entitlement.
        sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
        sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
        sign "$SPARKLE/Versions/B/Autoupdate"
        sign "$SPARKLE/Versions/B/Updater.app"
        sign "$SPARKLE"
    fi
    # Anything else bundled in Frameworks.
    find "$STAGE/$BUNDLE/Contents/Frameworks" -maxdepth 1 \( -name "*.dylib" -o -name "*.framework" \) \
        ! -name Sparkle.framework -print0 2>/dev/null | while IFS= read -r -d '' code; do sign "$code"; done
    sign --entitlements "$ERRORS.entitlements" "$STAGE/$BUNDLE"
    rm -f "$ERRORS.entitlements"
    codesign --verify --deep --strict "$STAGE/$BUNDLE"
    echo "  signed for distribution: $DEVELOPER_ID"
fi

ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
# `hdiutil create` still works but announces that this form is deprecated, so
# prefer what macOS points at and keep hdiutil for anything older.
if diskutil help image create from >/dev/null 2>&1; then
    diskutil image create from --format UDZO --volumeName "$NAME" "$STAGE" "$DMG" >/dev/null 2>"$ERRORS" \
        || { cat "$ERRORS" >&2; exit 1; }
else
    hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null 2>"$ERRORS" \
        || { cat "$ERRORS" >&2; exit 1; }
fi

if [ -n "$DEVELOPER_ID" ]; then
    codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
fi

if [ -n "$NOTARY_PROFILE" ]; then
    # Usually a few minutes. On a refusal Apple's log says which file and why.
    echo "  notarizing (this waits for Apple)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$ERRORS" \
        || { cat "$ERRORS" >&2; exit 1; }
    STATUS="$(/usr/bin/plutil -extract status raw "$ERRORS" 2>/dev/null || echo unknown)"
    if [ "$STATUS" != "Accepted" ]; then
        SUBMISSION="$(/usr/bin/plutil -extract id raw "$ERRORS" 2>/dev/null || true)"
        echo "notarization: $STATUS"
        [ -n "$SUBMISSION" ] && xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" >&2
        exit 1
    fi
    # The ticket goes into the image, so it opens without asking Apple first.
    xcrun stapler staple -q "$DMG"
    xcrun stapler validate -q "$DMG"
    echo "  notarized and stapled"
fi

echo "$NAME $VERSION (build $BUILD)  ->  $DMG  ($(du -h "$DMG" | cut -f1))"

# Check the image rather than trusting it: mount it and look at what is inside.
hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT"
[ -L "$MOUNT/Applications" ] || { echo "the /Applications shortcut is missing"; exit 1; }
codesign --verify --deep --strict "$MOUNT/$BUNDLE"
STRAY="$(find "$MOUNT" -maxdepth 1 -mindepth 1 ! -name "$BUNDLE" ! -name Applications ! -name .fseventsd \
    ! -name .Trashes ! -name .Spotlight-V100 ! -name .DS_Store | wc -l | tr -d ' ')"
[ "$STRAY" = "0" ] || { echo "unexpected files in the image:"; ls -a "$MOUNT"; exit 1; }
echo "  contents: $(ls "$MOUNT" | tr '\n' ' ')"
echo "  signature valid, /Applications shortcut present, nothing stray"
if [ -n "$NOTARY_PROFILE" ]; then
    # What Gatekeeper will say on someone else's Mac.
    spctl --assess --type open --context context:primary-signature "$DMG"
    spctl --assess --type execute "$MOUNT/$BUNDLE"
    echo "  Gatekeeper accepts the image and the app"
fi
