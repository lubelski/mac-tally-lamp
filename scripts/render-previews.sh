#!/usr/bin/env bash
# Draws the lamp and every Settings section to PNG files, in light and dark, with stand-in
# sessions. It never shows a window, takes focus, opens the socket, or touches the real data
# folder or preferences.
#
#   scripts/render-previews.sh            # into build/previews
#   scripts/render-previews.sh <folder>   # into <folder>
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

OUT="${1:-build/previews}"
swift build --product mac-tally-lamp
BIN_DIR="$(swift build --show-bin-path)"

# A copy of the binary stamped with the real SDK, as bundle.sh stamps the app's, or SwiftUI
# draws in the compatibility look for old apps. Sparkle goes next to it so it loads.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$BIN_DIR/mac-tally-lamp" "$WORK/mac-tally-lamp"
ditto "$BIN_DIR/Sparkle.framework" "$WORK/Sparkle.framework"
xcrun vtool -set-build-version macos 27.0 "$(xcrun --sdk macosx --show-sdk-version)" -replace \
  -output "$WORK/mac-tally-lamp" "$WORK/mac-tally-lamp" 2>/dev/null
codesign --force --sign - "$WORK/mac-tally-lamp" 2>/dev/null

mkdir -p "$OUT"
"$WORK/mac-tally-lamp" --render-previews "$OUT"
