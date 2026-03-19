#!/bin/bash
set -e

APP_NAME="Lockpaw"
BUNDLE_ID="com.eriknielsen.lockpaw"
SIGNING_IDENTITY="Developer ID Application: Erik Nielsen (78ACS592J2)"
APPLE_ID="${APPLE_ID:-}"
TEAM_ID="78ACS592J2"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Building Release (unsigned)..."
xcodebuild -project ${APP_NAME}.xcodeproj \
  -scheme ${APP_NAME} \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_ALLOWED=NO \
  clean build

APP_PATH="build/DerivedData/Build/Products/Release/${APP_NAME}.app"

echo "==> Preparing clean copy for signing..."
# Copy to /tmp to escape iCloud-managed xattrs that can't be cleared in ~/Documents
SIGN_DIR=$(mktemp -d /tmp/lockpaw-sign.XXXXXX)
ditto --norsrc "${APP_PATH}" "${SIGN_DIR}/${APP_NAME}.app"
APP_PATH="${SIGN_DIR}/${APP_NAME}.app"

echo "==> Signing with Developer ID + hardened runtime..."
SPARKLE_FW="${APP_PATH}/Contents/Frameworks/Sparkle.framework"
SPARKLE_VER="${SPARKLE_FW}/Versions/B"

sign_item() {
  codesign --force --sign "${SIGNING_IDENTITY}" --options runtime --timestamp "$1"
}

# Sign inside-out: Sparkle internals → XPC → framework → app
for xpc in "${SPARKLE_VER}/XPCServices/Downloader.xpc" "${SPARKLE_VER}/XPCServices/Installer.xpc"; do
  [ -d "${xpc}" ] || continue
  sign_item "${xpc}/Contents/MacOS/$(basename "${xpc}" .xpc)"
  sign_item "${xpc}"
done

[ -f "${SPARKLE_VER}/Autoupdate" ] && sign_item "${SPARKLE_VER}/Autoupdate"

if [ -d "${SPARKLE_VER}/Updater.app" ]; then
  sign_item "${SPARKLE_VER}/Updater.app/Contents/MacOS/Updater"
  sign_item "${SPARKLE_VER}/Updater.app"
fi

sign_item "${SPARKLE_FW}"
sign_item "${APP_PATH}"

echo "==> Verifying signature..."
codesign --verify --verbose "${APP_PATH}"
spctl --assess --type exec "${APP_PATH}" && echo "   Gatekeeper: ACCEPTED" || echo "   Gatekeeper: will pass after notarization"

echo "==> Creating DMG..."
DMG_DIR="build/dmg"
DMG_PATH="build/${APP_NAME}.dmg"
rm -rf "${DMG_DIR}" "${DMG_PATH}"
mkdir -p "${DMG_DIR}"
cp -R "${APP_PATH}" "${DMG_DIR}/"
rm -rf "${SIGN_DIR}"

create-dmg \
  --volname "${APP_NAME}" \
  --volicon "scripts/dmg-volume-icon.icns" \
  --background "scripts/dmg-background@2x.png" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 96 \
  --text-size 14 \
  --icon "${APP_NAME}.app" 170 180 \
  --hide-extension "${APP_NAME}.app" \
  --app-drop-link 490 180 \
  --no-internet-enable \
  "${DMG_PATH}" \
  "${DMG_DIR}"

echo "==> Notarizing..."
xcrun notarytool submit "${DMG_PATH}" \
  --keychain-profile "lockpaw-notarize" \
  --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"

# Set custom icon on the DMG file itself (visible in Finder before mounting)
echo "==> Setting DMG file icon..."
osascript -e '
use framework "AppKit"
set theIcon to current application'\''s NSImage'\''s alloc()'\''s initWithContentsOfFile:"'"$(pwd)/scripts/dmg-volume-icon.icns"'"
current application'\''s NSWorkspace'\''s sharedWorkspace()'\''s setIcon:theIcon forFile:"'"$(pwd)/${DMG_PATH}"'" options:0
'

echo ""
echo "==> Done! DMG ready at: ${DMG_PATH}"
echo "    Upload this to getlockpaw.com"

# ==> Sparkle appcast generation
# After uploading the DMG, run generate_appcast to update the appcast XML.
# Install Sparkle tools: https://github.com/sparkle-project/Sparkle/releases
# Then run:
#   generate_appcast /path/to/dmg/directory
# This will create/update appcast.xml with the new release entry.
# Upload the resulting appcast.xml to https://getlockpaw.com/appcast.xml
