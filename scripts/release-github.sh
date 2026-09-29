#!/usr/bin/env bash
# Builds the Developer ID version, has Apple notarize it, and produces build/dist/Apen-<version>.zip (or .dmg)
# plus a .sha256, ready to attach to a GitHub release. Needs a paid Apple Developer team (see release-common.sh).
source "$(dirname "$0")/release-common.sh"
ARCHIVE="$DIST/Apen-$VERSION.xcarchive"
EXPORT="$DIST/export-developer-id"

step "Archiving Apen $VERSION (Release)"
xcodegen generate --quiet
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project Apen.xcodeproj -scheme Apen -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" "${AUTH[@]}" "${SIGNING[@]}" -quiet archive

step "Exporting with Developer ID and uploading it for notarization"
cat > "$DIST/export-developer-id.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$APEN_TEAM_ID</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$DIST/notarization-upload" \
  -exportOptionsPlist "$DIST/export-developer-id.plist" "${AUTH[@]}" -quiet

step "Waiting for Apple's notarization (usually a few minutes)"
for attempt in $(seq 1 60); do
  if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$EXPORT" >"$DIST/notarization.log" 2>&1; then
    break
  fi
  if grep -qiE "invalid|rejected" "$DIST/notarization.log" || (( attempt == 60 )); then
    cat "$DIST/notarization.log" >&2
    exit 1
  fi
  sleep 30
done
APP="$EXPORT/Apen.app"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# A signed, notarized DMG needs a local "Developer ID Application" identity (Xcode › Settings › Accounts ›
# Manage Certificates › + › Developer ID Application) and an API key for notarytool. Otherwise ship the stapled
# app as a ZIP.
notarize() { # $1 = file to submit
  xcrun notarytool submit "$1" --key "$APEN_ASC_KEY_PATH" --key-id "$APEN_ASC_KEY_ID" \
    --issuer "$APEN_ASC_ISSUER_ID" --wait
}
if [[ -n "${APEN_ASC_KEY_ID:-}" ]] && security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
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

(cd "$(dirname "$ARTIFACT")" && shasum -a 256 "$(basename "$ARTIFACT")") | tee "$ARTIFACT.sha256"
echo "Ready: $ARTIFACT"
