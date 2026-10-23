#!/bin/bash
#
# Publishes a packaged Cue to the public releases repository and points the update
# feed at it, so every installed Cue picks it up.
#
#   xcodebuild -project Cue.xcodeproj -scheme Cue -configuration Release \
#       -derivedDataPath build/release build
#   Scripts/make-dmg.sh
#   Scripts/publish-release.sh [notes.md]
#
# Two releases in mehedihasanhr/cue-releases:
#   mac-<version>  the DMG, with the notes — what people download
#   mac-feed       appcast.xml alone, at a URL that never changes: the SUFeedURL every
#                  installed Cue checks. Rewritten here on each release.
#
# The DMG is signed with the EdDSA key in this Mac's keychain (account "cue", made by
# Sparkle's generate_keys; a backup sits in Config/local/). An update whose signature
# does not match the SUPublicEDKey built into Cue is refused by every installed copy,
# so a lost key means no more updates — keep the backup.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO=mehedihasanhr/cue-releases
FEED_TAG=mac-feed
NOTES=${1:-}
APP="$ROOT/build/release/Build/Products/Release/Cue.app"
SIGN="$ROOT/build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"

[ -d "$APP" ] || { echo "no app at $APP — build Release first"; exit 1; }
[ -x "$SIGN" ] || { echo "no sign_update at $SIGN — build Release first, it resolves Sparkle"; exit 1; }

VERSION="$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
BUILD="$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleVersion)"
MIN_OS="$(/usr/bin/defaults read "$APP/Contents/Info.plist" LSMinimumSystemVersion)"
DMG="$ROOT/dist/Cue-$VERSION.dmg"
TAG="mac-$VERSION"
[ -f "$DMG" ] || { echo "no $DMG — run Scripts/make-dmg.sh"; exit 1; }

# The DMG must hold the app that was just built, or the feed would announce one
# version and install another.
MOUNT="$(mktemp -d)"
WORK="$(mktemp -d)"
cleanup() {
    hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
    rm -rf "$MOUNT" "$WORK"
}
trap cleanup EXIT
hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT"
INSIDE="$(/usr/bin/defaults read "$MOUNT/Cue.app/Contents/Info.plist" CFBundleVersion)"
hdiutil detach "$MOUNT" -quiet
[ "$INSIDE" = "$BUILD" ] || { echo "$DMG holds build $INSIDE, not $BUILD — run Scripts/make-dmg.sh again"; exit 1; }

# `sign_update` prints the attributes the appcast's enclosure needs:
#   sparkle:edSignature="…" length="…"
SIGNATURE="$("$SIGN" --account cue "$DMG")"

DOWNLOAD="https://github.com/$REPO/releases/download/$TAG/Cue-$VERSION.dmg"
PAGE="https://github.com/$REPO/releases/tag/$TAG"
cat > "$WORK/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Cue</title>
    <item>
      <title>Cue $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$PAGE</sparkle:fullReleaseNotesLink>
      <enclosure url="$DOWNLOAD" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$WORK/appcast.xml"

NOTES_ARGS=(--notes "Cue $VERSION (build $BUILD).")
[ -n "$NOTES" ] && NOTES_ARGS=(--notes-file "$NOTES")

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" -R "$REPO" --clobber
else
    gh release create "$TAG" "$DMG" -R "$REPO" --title "Cue $VERSION" "${NOTES_ARGS[@]}"
fi

# The feed last, once the DMG it names is downloadable.
if gh release view "$FEED_TAG" -R "$REPO" >/dev/null 2>&1; then
    gh release upload "$FEED_TAG" "$WORK/appcast.xml" -R "$REPO" --clobber
else
    gh release create "$FEED_TAG" "$WORK/appcast.xml" -R "$REPO" --latest=false \
        --title "Cue for Mac update feed" --notes "The feed installed copies of Cue check for updates. Not a download."
fi

echo "Cue $VERSION (build $BUILD) published"
echo "  download: $DOWNLOAD"
echo "  feed:     https://github.com/$REPO/releases/download/$FEED_TAG/appcast.xml"
