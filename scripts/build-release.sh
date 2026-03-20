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

# Create a Finder alias to /Applications instead of a symlink.
# Symlinks show a broken/generic icon on macOS Sonoma+ when mounted as read-only DMG.
# Finder aliases always resolve the proper Applications folder icon.
# Step 1: Let create-dmg build with symlink (it handles positioning)
create-dmg \
  --volname "${APP_NAME}" \
  --volicon "scripts/dmg-volume-icon.icns" \
  --background "scripts/dmg-background@2x.png" \
  --window-pos 200 120 \
  --window-size 660 480 \
  --icon-size 96 \
  --text-size 14 \
  --icon "${APP_NAME}.app" 170 170 \
  --hide-extension "${APP_NAME}.app" \
  --app-drop-link 490 170 \
  --no-internet-enable \
  "${DMG_PATH}" \
  "${DMG_DIR}"

# Step 2: Replace symlink with Finder alias (fixes broken icon on Sonoma+)
# Mount the DMG as read-write, swap the symlink, then convert back
RW_DMG="${DMG_PATH%.dmg}-rw.dmg"
hdiutil convert "${DMG_PATH}" -format UDRW -o "${RW_DMG}"
rm "${DMG_PATH}"

MOUNT_DIR=$(hdiutil attach "${RW_DMG}" -readwrite -noverify | grep Apple_HFS | awk '{print $3}')
echo "   Mounted R/W at: ${MOUNT_DIR}"

# Remove symlink, create Finder alias
rm "${MOUNT_DIR}/Applications"
osascript -e "tell application \"Finder\" to make new alias file at POSIX file \"${MOUNT_DIR}\" to POSIX file \"/Applications\""
mv "${MOUNT_DIR}/Applications alias" "${MOUNT_DIR}/Applications" 2>/dev/null || true

# Re-apply Finder window styling after alias creation.
# The Finder alias step regenerates .DS_Store, resetting all icon positions.
# This AppleScript re-positions everything: app + Applications in view,
# all other items pushed far off-screen.
echo "   Re-applying Finder window layout..."
VOLNAME=$(basename "${MOUNT_DIR}")
osascript << APPLESCRIPT
tell application "Finder"
  tell disk "${VOLNAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 600}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set text size of theViewOptions to 14
    set background picture of theViewOptions to file ".background:dmg-background@2x.png"
    -- Position only the two items we want visible
    set position of item "${APP_NAME}.app" to {170, 170}
    set position of item "Applications" to {490, 170}
    -- Push everything else off-screen
    try
      set position of item ".background" to {900, 900}
    end try
    try
      set position of item ".fseventsd" to {900, 900}
    end try
    -- .VolumeIcon.icns must stay — it provides the title bar icon
    try
      set position of item ".DS_Store" to {900, 900}
    end try
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

# Unmount and convert to compressed read-only
sync
hdiutil detach "${MOUNT_DIR}"
hdiutil convert "${RW_DMG}" -format UDZO -o "${DMG_PATH}"
rm "${RW_DMG}"

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
