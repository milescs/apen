#!/usr/bin/env bash
# Builds the Developer ID version, notarizes it, and produces build/dist/Apen-<version>.dmg (+ .sha256)
# ready to attach to a GitHub release. Needs a paid Apple Developer team and an App Store Connect API key.
source "$(dirname "$0")/release-common.sh"
ARCHIVE="$DIST/Apen-$VERSION.xcarchive"
EXPORT="$DIST/export-developer-id"

step "Archiving Apen $VERSION (Release)"
xcodegen generate --quiet
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project Apen.xcodeproj -scheme Apen -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" "${AUTH[@]}" "${SIGNING[@]}" -quiet archive

step "Exporting with Developer ID"
cat > "$DIST/export-developer-id.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$APEN_TEAM_ID</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$DIST/export-developer-id.plist" "${AUTH[@]}" -quiet
APP="$EXPORT/Apen.app"
codesign --verify --deep --strict "$APP"

notarize() { # $1 = file to submit
  xcrun notarytool submit "$1" --key "$APEN_ASC_KEY_PATH" --key-id "$APEN_ASC_KEY_ID" \
    --issuer "$APEN_ASC_ISSUER_ID" --wait
}

step "Notarizing the app (usually a few minutes)"
ditto -c -k --keepParent "$APP" "$DIST/Apen-notarize.zip"
notarize "$DIST/Apen-notarize.zip"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# A signed, notarized DMG needs a local "Developer ID Application" identity (Xcode › Settings › Accounts ›
# Manage Certificates › + › Developer ID Application). Without one, ship the stapled app as a ZIP.
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  step "Building the disk image"
  ARTIFACT="$DIST/Apen-$VERSION.dmg"
  STAGE="$DIST/dmg-stage"
  rm -rf "$STAGE" "$ARTIFACT"; mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Apen.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Apen $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$ARTIFACT" -quiet
  codesign --sign "Developer ID Application" --timestamp "$ARTIFACT"
  step "Notarizing the disk image"
  notarize "$ARTIFACT"
  xcrun stapler staple "$ARTIFACT"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$ARTIFACT"
else
  step "Packaging the notarized app as a ZIP (no local Developer ID identity for a DMG)"
  ARTIFACT="$DIST/Apen-$VERSION.zip"
  rm -f "$ARTIFACT"
  ditto -c -k --keepParent "$APP" "$ARTIFACT"
fi

shasum -a 256 "$ARTIFACT" | tee "$ARTIFACT.sha256"
echo "Ready: $ARTIFACT"
