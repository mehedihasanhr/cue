#!/bin/bash
# Publishes a Windows installer to the public releases repository.
#
#   bash windows/scripts/publish-release.sh [folder with Cue_<v>_x64-setup.exe and .sig]
#
# Makes the release `windows-<version>` (never marked latest: Mac Cue reads its add-on
# feed from the latest release), and replaces `latest.json` on the `windows-feed`
# release, which is where the app's updater looks.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="mehedihasanhr/cue-releases"
VERSION=$(node -p "require('./src-tauri/tauri.conf.json').version")
DIR="${1:-src-tauri/target/x86_64-pc-windows-msvc/release/bundle/nsis}"
EXE="$DIR/Cue_${VERSION}_x64-setup.exe"
[ -f "$EXE" ] || { echo "No installer at $EXE" >&2; exit 1; }
[ -f "$EXE.sig" ] || { echo "No updater signature at $EXE.sig — build with the signing key." >&2; exit 1; }

TAG="windows-$VERSION"
NAME="Cue-Setup-$VERSION.exe"
OUT=$(mktemp -d)
cp "$EXE" "$OUT/$NAME"
node -e '
const fs = require("fs");
const [version, tag, name, sig, out] = process.argv.slice(1);
const feed = {
  version,
  notes: `https://github.com/mehedihasanhr/cue-releases/releases/tag/${tag}`,
  pub_date: new Date().toISOString(),
  platforms: {
    "windows-x86_64": {
      signature: fs.readFileSync(sig, "utf8").trim(),
      url: `https://github.com/mehedihasanhr/cue-releases/releases/download/${tag}/${name}`,
    },
  },
};
fs.writeFileSync(`${out}/latest.json`, JSON.stringify(feed, null, 2));
' "$VERSION" "$TAG" "$NAME" "$EXE.sig" "$OUT"

gh release create "$TAG" --repo "$REPO" --title "Cue for Windows $VERSION" --latest=false \
  --notes "Cue for Windows $VERSION. Download **$NAME** and run it. Windows may say it protected your PC: choose **More info › Run anyway** (the installer isn't code-signed yet)." \
  "$OUT/$NAME"
if gh release view windows-feed --repo "$REPO" >/dev/null 2>&1; then
  gh release upload windows-feed "$OUT/latest.json" --repo "$REPO" --clobber
else
  gh release create windows-feed --repo "$REPO" --title "Cue for Windows update feed" --latest=false \
    --notes "Where Cue for Windows looks for updates. Not a download." "$OUT/latest.json"
fi
echo "Published $TAG and updated the feed."
