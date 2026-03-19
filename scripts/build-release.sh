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
  --keychain-profile "lockpaw-notarize" \
  --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"

echo ""
echo "==> Done! DMG ready at: ${DMG_PATH}"
echo "    Upload this to getlockpaw.com"
