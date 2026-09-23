#!/bin/bash
#
# Packages a built Klik.app as a DMG people can install from.
#
#   xcodebuild -project Klik.xcodeproj -scheme Klik -configuration Release \
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
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=${1:-"$ROOT/build/release/Build/Products/Release/Klik.app"}
OUT_DIR="$ROOT/dist"

[ -d "$APP" ] || { echo "no app at $APP — build Release first"; exit 1; }

VERSION="$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
BUILD="$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleVersion)"
DMG="$OUT_DIR/Klik-$VERSION.dmg"

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
ditto "$APP" "$STAGE/Klik.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
# `hdiutil create` still works but announces that this form is deprecated, so
# prefer what macOS points at and keep hdiutil for anything older.
if diskutil help image create from >/dev/null 2>&1; then
    diskutil image create from --format UDZO --volumeName "Klik" "$STAGE" "$DMG" >/dev/null 2>"$ERRORS" \
        || { cat "$ERRORS" >&2; exit 1; }
else
    hdiutil create -volname "Klik" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null 2>"$ERRORS" \
        || { cat "$ERRORS" >&2; exit 1; }
fi

echo "Klik $VERSION (build $BUILD)  ->  $DMG  ($(du -h "$DMG" | cut -f1))"

# Check the image rather than trusting it: mount it and look at what is inside.
hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT"
[ -L "$MOUNT/Applications" ] || { echo "the /Applications shortcut is missing"; exit 1; }
codesign --verify --deep --strict "$MOUNT/Klik.app"
STRAY="$(find "$MOUNT" -maxdepth 1 -mindepth 1 ! -name Klik.app ! -name Applications ! -name .fseventsd \
    ! -name .Trashes ! -name .Spotlight-V100 ! -name .DS_Store | wc -l | tr -d ' ')"
[ "$STRAY" = "0" ] || { echo "unexpected files in the image:"; ls -a "$MOUNT"; exit 1; }
echo "  contents: $(ls "$MOUNT" | tr '\n' ' ')"
echo "  signature valid, /Applications shortcut present, nothing stray"
