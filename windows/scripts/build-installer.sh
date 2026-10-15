#!/bin/bash
# Builds the Windows installer on this Mac, by cross-compiling.
#
#   bash windows/scripts/build-installer.sh
#
# Needs, once: brew install llvm nsis; cargo install --locked cargo-xwin;
# rustup target add x86_64-pc-windows-msvc. The updater signing key is read from
# ~/.tauri/klik-windows.key (never committed). The installer and its .sig land in
# windows/src-tauri/target/x86_64-pc-windows-msvc/release/bundle/nsis/.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/llvm/bin:$PATH"
export XWIN_ACCEPT_LICENSE=1
KEY="$HOME/.tauri/klik-windows.key"
if [ -f "$KEY" ]; then
  export TAURI_SIGNING_PRIVATE_KEY="$(cat "$KEY")"
  export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"
  pnpm tauri build --runner cargo-xwin --target x86_64-pc-windows-msvc
else
  echo "No updater key at $KEY: building without an update signature." >&2
  pnpm tauri build --runner cargo-xwin --target x86_64-pc-windows-msvc --config '{"bundle":{"createUpdaterArtifacts":false}}'
fi
ls -la src-tauri/target/x86_64-pc-windows-msvc/release/bundle/nsis/
