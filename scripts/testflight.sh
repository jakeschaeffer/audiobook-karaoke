#!/bin/bash
# Archive AudioBook Karaoke, sign it for the App Store and upload it to TestFlight, headless.
# The pipeline FORK-NOTES "TestFlight upload pipeline" describes: the archive with the project's
# signing (-allowProvisioningUpdates), then a manual-signing export with the account's Apple
# Distribution certificate and the four "AS <bundle id>*" App Store profiles already installed under
# ~/Library/Developer/Xcode/UserData/Provisioning Profiles/, then altool with the App Manager API key
# at ~/.appstoreconnect/private_keys/. The Set Build Number phase stamps the build number; nothing
# here chooses one. The account's identifiers come from scripts/local.env.
#   ./scripts/testflight.sh            # personal build (SPEAKER_STACK on, the default)
#   PUBLIC_BUILD=1 ./scripts/testflight.sh      # a build for other people: no speaker stack, no
#                                      # companion address baked in (Local.xcconfig's URLs are
#                                      # overridden to empty, so first launch asks nobody)
#   SKIP_PLAY_SMOKE=1 ./scripts/testflight.sh   # skip the play check (say why in the PR or notes)
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/load-env.sh

for name in TEAM_ID APP_BUNDLE_ID ASC_KEY_ID ASC_ISSUER; do
  [ -n "${!name:-}" ] || { echo "testflight: set $name in scripts/local.env (see local.env.example)"; exit 2; }
done

# Nothing reaches the phone unless pressing play plays (2026-10-31: a build that stalled on every
# play shipped because nothing pressed play). See scripts/smoke-play.sh for its side effects.
if [ "${SKIP_PLAY_SMOKE:-0}" != 1 ]; then
  ./scripts/smoke-play.sh || {
    echo "testflight: the play smoke test did not pass; nothing was uploaded."
    exit 1
  }
fi

KEY_ID="$ASC_KEY_ID"
ISSUER="$ASC_ISSUER"
# The internal "Owner" group with access to all builds: without it a processed build reaches nobody
# (2026-10-31). Idempotent.
node scripts/asc.mjs ensure-beta-group >/dev/null
STAMP=$(date -u +%y%m%d%H%M)
OUT="${TMPDIR:-/tmp}/audiobooth-testflight-$STAMP"
mkdir -p "$OUT"

# Command-line settings beat every xcconfig, including Local.xcconfig: this is how one checkout
# produces both the personal build and a build with none of its operator's details in it.
PUBLIC_SETTINGS=()
if [ "${PUBLIC_BUILD:-0}" = 1 ]; then
  PUBLIC_SETTINGS=(AUDIOBOOTH_FEATURES= COMPANION_DAEMON_URL= COMPANION_WORKER_URL=)
  echo "==> Public build: SPEAKER_STACK off, no companion address"
fi

echo "==> Archiving ($OUT)"
xcodebuild archive \
  -project AudioBooth/AudioBooth.xcodeproj -scheme AudioBooth -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/AudioBooth.xcarchive" \
  -allowProvisioningUpdates -quiet "${PUBLIC_SETTINGS[@]}"

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict>
    <key>$APP_BUNDLE_ID</key><string>AS $APP_BUNDLE_ID</string>
    <key>$APP_BUNDLE_ID.widget</key><string>AS $APP_BUNDLE_ID.widget</string>
    <key>$APP_BUNDLE_ID.watchkitapp</key><string>AS $APP_BUNDLE_ID.watchkitapp</string>
    <key>$APP_BUNDLE_ID.watchkitapp.AudioBoothWatchWidget</key><string>AS $APP_BUNDLE_ID.watchkitapp.AudioBoothWatchWidget</string>
  </dict>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST

echo "==> Exporting"
xcodebuild -exportArchive -archivePath "$OUT/AudioBooth.xcarchive" -exportPath "$OUT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -quiet

IPA=$(ls "$OUT"/*.ipa | head -1)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" "$OUT/AudioBooth.xcarchive/Info.plist" 2>/dev/null || echo "?")
echo "==> Uploading $IPA (build $BUILD)"
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER"
echo "OK: build $BUILD uploaded; it shows in TestFlight once App Store Connect finishes processing"
