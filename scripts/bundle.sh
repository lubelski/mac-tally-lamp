#!/usr/bin/env bash
# Builds mac-tally-lamp.app into ./build, with the MCP helper agents start,
# mac-tally-lamp-mcp, next to the app in Contents/MacOS. Pass --install to move it to
# ~/Applications and launch it.
#
# Environment, all optional:
#   MAC_TALLY_LAMP_VERSION           The version to show, such as 1.2.0. Defaults to the latest
#                                  v* tag, or 0.1 without one.
#   MAC_TALLY_LAMP_FEED_URL          The Sparkle feed. Set by scripts/release.sh, together with
#   MAC_TALLY_LAMP_PUBLIC_KEY        the public key that updates are signed with. A build
#                                  without these two never updates itself.
#   MAC_TALLY_LAMP_SIGNING_IDENTITY  The signing identity. See "Sign" below for the default.
set -euo pipefail
cd "$(dirname "$0")/.."

# Use full Xcode for SwiftUI without changing the global xcode-select setting.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="$BIN_DIR/mac-tally-lamp"

APP="build/mac-tally-lamp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/mac-tally-lamp"
# The MCP helper. It has no UI, so it needs no SDK stamp, but it is signed below like the app.
cp "$BIN_DIR/mac-tally-lamp-mcp" "$APP/Contents/MacOS/mac-tally-lamp-mcp"

# Sparkle, the updater. SwiftPM builds it next to the binary but does not know about app
# bundles, so copy it in and tell the binary where to find it.
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/mac-tally-lamp"

# SwiftPM writes the deployment target into the binary's SDK field. macOS reads that field
# to decide whether to run the app in a compatibility mode for older apps, so stamp the
# SDK the app was really built with.
MIN_OS=27.0
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/mac-tally-lamp" "$APP/Contents/MacOS/mac-tally-lamp"
STAMPED="$(xcrun vtool -show-build "$APP/Contents/MacOS/mac-tally-lamp" | awk '$1 == "sdk" { print $2 }')"
if [[ "$STAMPED" != "$SDK_VERSION" ]]; then
  echo "error: the binary is stamped with SDK '$STAMPED', expected '$SDK_VERSION'" >&2
  exit 1
fi

# The app icon. actool compiles the Icon Composer file into Assets.car, which macOS draws
# with the system's glass, and AppIcon.icns, a flat copy for places that read only that.
# Info.plist names both below. This runs before signing, so the signature covers the icon.
# scripts/render-icon.sh redraws the icon's artwork.
# actool hands the work to a daemon that may have been started from another folder and
# resolves relative paths against it, so the paths are absolute.
mkdir -p "$APP/Contents/Resources"
ICON_PLIST_DIR="$(mktemp -d)"
ICON_LOG="$ICON_PLIST_DIR/actool.log"
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target "$MIN_OS" --app-icon AppIcon \
  --output-partial-info-plist "$ICON_PLIST_DIR/icon.plist" --errors --warnings \
  --output-format human-readable-text >"$ICON_LOG" 2>&1 || { cat "$ICON_LOG" >&2; exit 1; }
rm -rf "$ICON_PLIST_DIR"
for f in Assets.car AppIcon.icns; do
  if [[ ! -f "$APP/Contents/Resources/$f" ]]; then
    echo "error: actool did not produce $f from Resources/AppIcon.icon" >&2
    exit 1
  fi
done

GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  GIT_COMMIT="$GIT_COMMIT-dirty"
fi
# The version comes from the latest release tag. The build number is the number of commits,
# which only grows on main. Sparkle compares build numbers to find a newer build.
LATEST_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
VERSION="${MAC_TALLY_LAMP_VERSION:-${LATEST_TAG#v}}"
VERSION="${VERSION:-0.1}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

UPDATER_KEYS=""
if [[ -n "${MAC_TALLY_LAMP_FEED_URL:-}" && -n "${MAC_TALLY_LAMP_PUBLIC_KEY:-}" ]]; then
  UPDATER_KEYS="<key>SUFeedURL</key><string>$MAC_TALLY_LAMP_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$MAC_TALLY_LAMP_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>mac-tally-lamp</string>
  <key>CFBundleDisplayName</key><string>Tally Lamp</string>
  <key>CFBundleIdentifier</key><string>dev.lubelski.mac-tally-lamp</string>
  <key>CFBundleExecutable</key><string>mac-tally-lamp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>MacTallyLampGitCommit</key><string>$GIT_COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  $UPDATER_KEYS
</dict>
</plist>
PLIST

# Sign. The identity is the first of these that exists:
#   1. MAC_TALLY_LAMP_SIGNING_IDENTITY, when it is set.
#   2. A Developer ID Application certificate in the keychain, so macOS on another Mac opens
#      the app and notarization accepts it.
#   3. This Mac's self-signed "mac-tally-lamp development" certificate, if the owner made one,
#      so every build has the same identity. The app asks for no permissions, so this matters
#      less here than in mac-os-agent, whose AGENTS.md says how to make one.
#   4. Ad hoc.
DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
if [[ -n "${MAC_TALLY_LAMP_SIGNING_IDENTITY:-}" ]]; then
  IDENTITY="$MAC_TALLY_LAMP_SIGNING_IDENTITY"
elif [[ -n "$DEVELOPER_ID" ]]; then
  IDENTITY="$DEVELOPER_ID"
elif security find-certificate -c "mac-tally-lamp development" >/dev/null 2>&1; then
  IDENTITY="mac-tally-lamp development"
else
  IDENTITY="-"
fi
SIGN=(codesign --force --sign "$IDENTITY")
if [[ "$IDENTITY" == *"Developer ID Application"* ]]; then
  # Notarization needs the hardened runtime and a secure timestamp.
  SIGN+=(--options runtime --timestamp)
fi

# Sparkle's helpers are signed one at a time, innermost first, as its documentation says.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE"
# The MCP helper, then the app around it. The app asks for no protected resources, so it has
# no entitlements file.
"${SIGN[@]}" --identifier dev.lubelski.mac-tally-lamp.mcp "$APP/Contents/MacOS/mac-tally-lamp-mcp"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
if [[ "$IDENTITY" == "-" ]]; then
  echo "Signed ad hoc."
else
  echo "Signed with \"$IDENTITY\""
fi
echo "Built $APP, version $VERSION ($BUILD_NUMBER), commit $GIT_COMMIT"

if [[ "${1:-}" == "--install" ]]; then
  DEST=~/Applications/mac-tally-lamp.app
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

  # Stop the running copy and wait until it has exited, so the old process does not still
  # hold the menu bar item or the socket when the new one starts. Agents' helpers are left
  # running. They connect to the new copy at their next call.
  if pkill -x mac-tally-lamp; then
    for _ in {1..50}; do
      pgrep -x mac-tally-lamp >/dev/null || break
      sleep 0.1
    done
    pkill -9 -x mac-tally-lamp || true
  fi

  mkdir -p ~/Applications
  rm -rf "$DEST"
  # Move instead of copy, so only one bundle with this identifier exists.
  mv "$APP" "$DEST"
  "$LSREGISTER" -f "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
