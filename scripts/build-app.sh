#!/bin/bash
# Builds PartyPortal.app (the river binary, the test window and the web pages in one bundle)
# and installs it to ~/Applications.
# Signed with your Apple Development certificate when there is one, so macOS keeps the
# Screen Recording and Accessibility permissions across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/PartyPortal.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/partyportal" "$BIN/partyportal-testwin" "$APP/Contents/MacOS/"
cp -R web "$APP/Contents/Resources/web"

# App icon: every size macOS wants, from the one 1024 px source.
ICON=site/assets/icon-1024.png
if [ -f "$ICON" ]; then
  SET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$SET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON" --out "$SET/icon_${size}x${size}.png" > /dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICON" --out "$SET/icon_${size}x${size}@2x.png" > /dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>partyportal</string>
  <key>CFBundleIdentifier</key><string>dev.inchi.partyportal</string>
  <key>CFBundleName</key><string>PartyPortal</string>
  <key>CFBundleDisplayName</key><string>PartyPortal</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

IDENTITY="${PP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/partyportal-testwin" "$APP" 2>/dev/null; then
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP/Contents/MacOS/partyportal-testwin" "$APP"
  echo "Signed ad hoc (no certificate): macOS will ask for the permissions again after every rebuild"
fi

# Install outside ~/Documents. An app that runs from Documents, Desktop or Downloads makes macOS ask for
# access to that folder the first time the video encoder starts, and the picture freezes until you answer.
DEST="${PP_INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$DEST"
rm -rf "$DEST/PartyPortal.app"
mv "$APP" "$DEST/PartyPortal.app"
echo "Done: $DEST/PartyPortal.app"
