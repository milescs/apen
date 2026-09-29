#!/usr/bin/env bash
# Archives the sandboxed App Store version and uploads it to App Store Connect.
#   APEN_BUILD=<n> overrides the build number (it must increase with every upload).
#   --archive-only  stops after archiving (this also registers the bundle ID, which App Store Connect needs
#                   before it can create the app record)
#   --upload-only   uploads the archive made earlier with the same APEN_BUILD
source "$(dirname "$0")/release-common.sh"
BUILD="${APEN_BUILD:-$(date +%Y%m%d.%H%M)}"
ARCHIVE="$DIST/Apen-$VERSION-$BUILD-AppStore.xcarchive"

if [[ "${1:-}" != "--upload-only" ]]; then
  step "Archiving Apen $VERSION ($BUILD) for the Mac App Store"
  xcodegen generate --quiet
  xcodebuild -project Apen.xcodeproj -scheme Apen -configuration AppStore -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" "${AUTH[@]}" "${SIGNING[@]}" CURRENT_PROJECT_VERSION="$BUILD" -quiet archive
  [[ "${1:-}" == "--archive-only" ]] && { echo "Archived: $ARCHIVE (upload with APEN_BUILD=$BUILD $0 --upload-only)"; exit 0; }
fi
[[ -d "$ARCHIVE" ]] || { echo "No archive at $ARCHIVE" >&2; exit 1; }

step "Uploading to App Store Connect"
cat > "$DIST/export-appstore.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$APEN_TEAM_ID</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$DIST/export-appstore" \
  -exportOptionsPlist "$DIST/export-appstore.plist" "${AUTH[@]}"
echo "Uploaded build $BUILD. It appears in App Store Connect after processing (usually 10-30 minutes)."
