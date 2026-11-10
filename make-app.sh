#!/bin/bash
# Builds Paneport.app into ./build, ready to move to /Applications.
#
#   ./make-app.sh            release build
#   VERSION=1.2.0 ./make-app.sh
#
# Keep APP_NAME and BUNDLE_ID in sync with Sources/Paneport/App/AppInfo.swift.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Paneport"
BUNDLE_ID="local.paneport"
VERSION="${VERSION:-0.3.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
SIGNING_IDENTITY="Paneport Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
APP="build/$APP_NAME.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# The viewer page; ReceiverAssets.swift looks for it in Contents/Resources/receiver.
cp -R "Sources/$APP_NAME/Resources/receiver" "$APP/Contents/Resources/receiver"

# The Windows receiver, offered to PCs at /download/windows. Release builds put it in
# windows/dist (see .github/workflows/release.yml); set RECEIVER_EXE to use another file.
RECEIVER_EXE="${RECEIVER_EXE:-windows/dist/PaneportReceiver.exe}"
if [ -f "$RECEIVER_EXE" ]; then
  RECEIVER_VERSION="${RECEIVER_VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' windows/Cargo.toml | head -1)}"
  mkdir -p "$APP/Contents/Resources/downloads"
  cp "$RECEIVER_EXE" "$APP/Contents/Resources/downloads/PaneportReceiver.exe"
  echo "$RECEIVER_VERSION" > "$APP/Contents/Resources/downloads/PaneportReceiver.version"
  echo "Included the Windows receiver $RECEIVER_VERSION."
else
  echo "No Windows receiver at $RECEIVER_EXE; PCs can still use the browser page."
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with a permanent local identity so macOS keeps the Screen Recording permission
# across rebuilds. An ad-hoc signature changes on every build, and macOS then treats
# each build as a different app.
has_identity() {
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$SIGNING_IDENTITY"
}

create_identity() {
  echo "Creating a local signing identity \"$SIGNING_IDENTITY\" in your login keychain (one time)..."
  local tmp
  tmp="$(mktemp -d)"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -subj "/CN=$SIGNING_IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1 &&
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/identity.p12" -passout pass:paneport -name "$SIGNING_IDENTITY" >/dev/null 2>&1 &&
  security import "$tmp/identity.p12" -k "$KEYCHAIN" -P paneport -T /usr/bin/codesign >/dev/null ||
    echo "Could not create the signing identity; falling back to an ad-hoc signature."
  rm -rf "$tmp"
}

has_identity || create_identity

if has_identity; then
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP"
  echo "Signed with \"$SIGNING_IDENTITY\" (Screen Recording permission survives rebuilds)."
else
  codesign --force --deep --sign - "$APP"
  echo "Signed ad hoc: macOS may ask for Screen Recording permission again after each rebuild."
fi

echo
echo "Built $APP ($VERSION)"
echo "Move it to /Applications and open it from there. It lives in the menu bar."
