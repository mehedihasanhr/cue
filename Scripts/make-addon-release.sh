#!/bin/bash
# Packs a built Klik Studio for Klik's in-app installer, and writes the feed that lists it.
#
#   Scripts/make-addon-release.sh "<path>/Klik Studio.app" [minimum Klik version]
#
# Produces, in dist/:
#   KlikStudio-<version>.aar   the app as an Apple Archive, which Klik unpacks itself
#   addons.json                the feed Klik reads, naming that archive, its size and SHA-256
#
# Both go on a release of the public releases repository, tagged studio-<version>. Klik
# reads the feed from that repository's newest release, so publishing the release is
# what offers the update.
set -euo pipefail

APP="${1:?usage: make-addon-release.sh <Klik Studio.app> [minimum Klik version]}"
MIN_HOST="${2:-0.5.0}"
REPO="mehedihasanhr/klik-releases"
OUT="dist"

[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }
VERSION=$(defaults read "$(cd "$APP" && pwd)/Contents/Info" CFBundleShortVersionString)
BUNDLE=$(defaults read "$(cd "$APP" && pwd)/Contents/Info" CFBundleIdentifier)
[ "$BUNDLE" = "com.stackrover.klik.studio" ] || { echo "$APP is $BUNDLE, not Klik Studio" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

TAG="studio-$VERSION"
ARCHIVE="$OUT/KlikStudio-$VERSION.aar"
mkdir -p "$OUT"
rm -f "$ARCHIVE"
# The app folder itself at the archive's root, so unpacking yields "Klik Studio.app".
aa archive -d "$(dirname "$APP")" -subdir "$(basename "$APP")" -o "$ARCHIVE" -a lzfse

BYTES=$(stat -f %z "$ARCHIVE")
SHA=$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)

cat > "$OUT/addons.json" <<EOF
{
  "formatVersion": 1,
  "releases": [
    {
      "addOn": "studio",
      "version": "$VERSION",
      "download": "https://github.com/$REPO/releases/download/$TAG/$(basename "$ARCHIVE")",
      "bytes": $BYTES,
      "sha256": "$SHA",
      "minimumHost": "$MIN_HOST",
      "installer": "archive",
      "notes": "https://github.com/$REPO/releases/tag/$TAG"
    }
  ]
}
EOF

echo "$ARCHIVE  ($BYTES bytes, sha256 $SHA)"
echo "$OUT/addons.json"
echo "Publish both on $REPO as $TAG."
