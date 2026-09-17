#!/usr/bin/env bash
# Wrap the SwiftPM FederationTray executable in a .app bundle and (optionally)
# install it into /Applications.
#
#   app/scripts/bundle-tray.sh            build app/tray/.build/FederationTray.app
#   app/scripts/bundle-tray.sh install    ... then copy to /Applications and relaunch
#
# LSUIElement, so it is menu-bar only with no Dock icon, and ad-hoc signed so
# Gatekeeper on this Mac accepts a locally built binary.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$APP_DIR/.." && pwd)"
TRAY="$APP_DIR/tray"
BUNDLE="$TRAY/.build/FederationTray.app"
DEST="${DEST:-/Applications/FederationTray.app}"
VERSION="$(git -C "$REPO" describe --tags --always --dirty 2>/dev/null || echo dev)"

(cd "$TRAY" && swift build -c release 2>&1 | tail -1)

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$TRAY/.build/release/FederationTray" "$BUNDLE/Contents/MacOS/FederationTray"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>      <string>en</string>
  <key>CFBundleExecutable</key>             <string>FederationTray</string>
  <key>CFBundleIdentifier</key>             <string>studio.soulbrews.herdrfederation.tray</string>
  <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
  <key>CFBundleName</key>                   <string>FederationTray</string>
  <key>CFBundleDisplayName</key>            <string>Federation Tray</string>
  <key>CFBundlePackageType</key>            <string>APPL</string>
  <key>CFBundleShortVersionString</key>     <string>${VERSION}</string>
  <key>CFBundleVersion</key>                <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>         <string>13.0</string>
  <key>LSUIElement</key>                    <true/>
  <key>NSHighResolutionCapable</key>        <true/>
  <key>NSHumanReadableCopyright</key>       <string>Soul Brews Studio</string>
  <!-- the repo's app/ directory; the tray derives the repo root from it to run \`just node start\` -->
  <key>FederationAppDir</key>               <string>${APP_DIR}</string>
</dict>
</plist>
PLIST

echo 'APPL????' > "$BUNDLE/Contents/PkgInfo"
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || echo "warn: ad-hoc codesign failed (continuing)"
echo "bundle: $BUNDLE ($VERSION)"

if [ "${1:-}" = "install" ]; then
  AGENT="gui/$(id -u)/studio.soulbrews.herdrfederation.tray"
  if launchctl print "$AGENT" >/dev/null 2>&1; then
    rm -rf "$DEST"; ditto "$BUNDLE" "$DEST"; launchctl kickstart -k "$AGENT"
  else
    pkill -x FederationTray 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"; ditto "$BUNDLE" "$DEST"
    open -a "$DEST"
  fi
  sleep 2
  n=$(pgrep -x FederationTray | wc -l | tr -d ' ')
  case "$n" in
    1) echo "installed and running: $DEST" ;;
    0) echo "installed but not running: $DEST — try: open -a '$DEST'"; exit 1 ;;
    *) echo "installed, but $n copies are running — quit the extra one"; exit 1 ;;
  esac
fi
