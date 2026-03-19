#!/bin/bash
set -e

APP_NAME="Lockpaw"
BUNDLE_ID="com.eriknielsen.lockpaw"
SIGNING_IDENTITY="Developer ID Application: Erik Nielsen (78ACS592J2)"
APPLE_ID="erik@sorkila.com"
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

echo "==> Signing with Developer ID + hardened runtime..."
codesign --force --deep --sign "${SIGNING_IDENTITY}" \
  --options runtime \
  "${APP_PATH}"

echo "==> Verifying signature..."
codesign --verify --verbose "${APP_PATH}"
spctl --assess --type exec "${APP_PATH}" && echo "   Gatekeeper: ACCEPTED" || echo "   Gatekeeper: will pass after notarization"

echo "==> Creating DMG..."
DMG_DIR="build/dmg"
DMG_PATH="build/${APP_NAME}.dmg"
DMG_TEMP="build/${APP_NAME}-temp.dmg"
rm -rf "${DMG_DIR}" "${DMG_PATH}" "${DMG_TEMP}"
mkdir -p "${DMG_DIR}"
cp -R "${APP_PATH}" "${DMG_DIR}/"
ln -s /Applications "${DMG_DIR}/Applications"

# Create writable DMG first for layout customization
hdiutil create -volname "${APP_NAME}" \
  -srcfolder "${DMG_DIR}" \
  -ov -format UDRW \
  "${DMG_TEMP}"

# Mount and customize layout
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "${DMG_TEMP}" | grep "/Volumes/${APP_NAME}" | awk '{print $NF}')
echo "   Mounted at: ${MOUNT_DIR}"

# Copy background
mkdir -p "${MOUNT_DIR}/.background"
cp scripts/dmg-background.png "${MOUNT_DIR}/.background/background.png"
cp scripts/dmg-background@2x.png "${MOUNT_DIR}/.background/background@2x.png"

# Apply Finder layout via AppleScript
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "${APP_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 760, 500}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 80
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "${APP_NAME}.app" of container window to {170, 180}
    set position of item "Applications" of container window to {490, 180}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

# Unmount
hdiutil detach "${MOUNT_DIR}" -quiet

# Convert to compressed read-only DMG
hdiutil convert "${DMG_TEMP}" -format UDZO -o "${DMG_PATH}"
rm -f "${DMG_TEMP}"

echo "==> Notarizing..."
xcrun notarytool submit "${DMG_PATH}" \
  --keychain-profile "lockpaw-notarize" \
  --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"

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
