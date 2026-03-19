#!/bin/bash
set -e

# Configuration
APP_NAME="Bevaka"
BUNDLE_ID="com.eriknielsen.bevaka"
# Update this with your Developer ID certificate name:
SIGNING_IDENTITY="Developer ID Application: Erik Nielsen"
# Update with your Apple ID for notarization:
APPLE_ID="erik@sorkila.com"
TEAM_ID="U6YV6THLD7"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Building Release..."
xcodebuild -project ${APP_NAME}.xcodeproj \
  -scheme ${APP_NAME} \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  clean build

APP_PATH="build/DerivedData/Build/Products/Release/${APP_NAME}.app"

echo "==> Signing with Developer ID..."
codesign --force --deep --sign "${SIGNING_IDENTITY}" \
  --options runtime \
  --entitlements ${APP_NAME}/${APP_NAME}.entitlements \
  "${APP_PATH}"

echo "==> Verifying signature..."
codesign --verify --verbose "${APP_PATH}"

echo "==> Creating DMG..."
DMG_DIR="build/dmg"
DMG_PATH="build/${APP_NAME}.dmg"
rm -rf "${DMG_DIR}" "${DMG_PATH}"
mkdir -p "${DMG_DIR}"
cp -R "${APP_PATH}" "${DMG_DIR}/"
ln -s /Applications "${DMG_DIR}/Applications"

hdiutil create -volname "${APP_NAME}" \
  -srcfolder "${DMG_DIR}" \
  -ov -format UDZO \
  "${DMG_PATH}"

echo "==> Notarizing..."
xcrun notarytool submit "${DMG_PATH}" \
  --apple-id "${APPLE_ID}" \
  --team-id "${TEAM_ID}" \
  --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"

echo ""
echo "==> Done! DMG ready at: ${DMG_PATH}"
echo "    Upload this file to your website."
