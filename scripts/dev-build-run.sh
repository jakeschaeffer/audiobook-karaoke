#!/bin/bash
# Build AudioBooth (iOS) and run it in the simulator.
#   ./scripts/dev-build-run.sh            # build + install + launch
#   ./scripts/dev-build-run.sh --shot     # ...then write a screenshot
#
# Notes on this project's build:
#  - Build the *scheme*, not the target. `-target AudioBooth` skips the scheme's
#    prebuild step that generates Readium's module maps, and the build dies on a
#    missing Minizip.modulemap.
#  - The AudioBooth scheme embeds the Watch app, so a watchOS *simulator runtime*
#    is required even for an iOS-only build (`xcodebuild -downloadPlatform watchOS`).
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="AudioBooth/AudioBooth.xcodeproj"
SCHEME="AudioBooth"
DEVICE="${AUDIOBOOTH_SIM:-iPhone 17}"
# Simulator keeps upstream's bundle id (Local.xcconfig scopes ORG_IDENTIFIER to [sdk=iphoneos*], so
# only *device* builds take your own org id). Read it from the built bundle rather than
# hardcoding, so this survives a future org-id change.

echo "==> Building $SCHEME for the iOS simulator"
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'generic/platform=iOS Simulator' \
  -quiet

APP=$(find ~/Library/Developer/Xcode/DerivedData/AudioBooth-*/Build/Products/Debug-iphonesimulator \
  -maxdepth 1 -name "AudioBooth.app" 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "error: could not locate built AudioBooth.app"; exit 1; }
BUNDLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")

UDID=$(xcrun simctl list devices available \
  | grep -F "$DEVICE (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$UDID" ] || { echo "error: no available simulator named '$DEVICE'"; exit 1; }

echo "==> Booting $DEVICE ($UDID)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
# Xcode 27 ships no standalone Simulator.app; the device boots and runs headless either way.
open -a Simulator 2>/dev/null || true

echo "==> Installing and launching $BUNDLE"
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE" -muted # no sound out of the Mac while testing

if [ "${1:-}" = "--shot" ]; then
  OUT="${TMPDIR:-/tmp}/audiobooth-$(date +%H%M%S).png"
  xcrun simctl io "$UDID" screenshot "$OUT"
  echo "screenshot: $OUT"
fi

echo "OK: $BUNDLE running on $DEVICE"
