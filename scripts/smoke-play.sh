#!/bin/bash
# Play smoke test: does pressing play on a streamed book actually play?
#   ./scripts/smoke-play.sh                 # build Debug, cold-launch, play, measure, close
#   SMOKE_BOOK=<itemID> ./scripts/smoke-play.sh
# The book and the speaker to protect come from scripts/local.env. Always muted (`-muted`): the
# playhead still moves, and nothing comes out of the Mac.
#
# Why this exists (2026-10-31): a cherry-picked upstream change made every streamed book stall and
# pause within a second of play. Nothing caught it, because the simulator protocol opens books
# without autoplay and the post-sync checklist never presses play. This presses play.
#
# Pass: the player reports playing and the playhead moves at least SMOKE_SECONDS - 3 seconds over
# SMOKE_SECONDS, with no stall, stop or player error in the console. Exit 1 on failure.
#
# Side effects, on whichever user the simulator is signed in as (use a low-privilege one): about
# SMOKE_SECONDS of that book's progress (minus the 30 s smart rewind), and one listening session. The
# daemon treats a session that advances as a takeover and would pause the speaker, so with
# SMOKE_DAEMON_STATUS set this refuses to run unless the daemon reports no speaker session at all.
# SMOKE_FORCE=1 skips that check.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/load-env.sh

DEVICE="${AUDIOBOOTH_SIM:-iPhone 17}"
BOOK="${SMOKE_BOOK:-}"
[ -n "$BOOK" ] || { echo "smoke-play: set SMOKE_BOOK in scripts/local.env (see local.env.example)"; exit 2; }
SECONDS_TO_WATCH="${SMOKE_SECONDS:-15}"
STATUS_URL="${SMOKE_DAEMON_STATUS:-}"
PROJECT="AudioBooth/AudioBooth.xcodeproj"

if [ "${SMOKE_FORCE:-0}" != 1 ] && [ -n "$STATUS_URL" ]; then
  state=$(curl -s -m 5 "$STATUS_URL" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state", ""))' 2>/dev/null || true)
  if [ "$state" != "idle" ]; then
    echo "smoke-play: the speaker daemon reports '${state:-unreachable}', not idle."
    echo "  A Test session that advances would take over (pause) the speaker. Run again when it is idle,"
    echo "  or SMOKE_FORCE=1 if you accept that."
    exit 2
  fi
fi

echo "==> Building AudioBooth (Debug) for the simulator"
xcodebuild build -project "$PROJECT" -scheme AudioBooth -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -quiet
APP=$(find ~/Library/Developer/Xcode/DerivedData/AudioBooth-*/Build/Products/Debug-iphonesimulator \
  -maxdepth 1 -name "AudioBooth.app" 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "smoke-play: could not find the built AudioBooth.app"; exit 1; }
BUNDLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")

UDID=$(xcrun simctl list devices available | grep -F "$DEVICE (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$UDID" ] || { echo "smoke-play: no available simulator named '$DEVICE'"; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true

cleanup() { xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true; }
trap cleanup EXIT

failures=0
# One cold launch, measured. $1 names the pass; the rest are extra launch arguments.
run_pass() {
  local label=$1
  shift
  local log
  log=$(mktemp -t audiobooth-smoke-play)
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  echo "==> $label (${SECONDS_TO_WATCH}s; console: $log)"
  xcrun simctl launch --console-pty "$UDID" "$BUNDLE" -muted -smokePlay "$SECONDS_TO_WATCH" "$@" >"$log" 2>&1 &
  local console=$!
  # Up to 30 s for the book to load, 6 s to settle, up to 30 s to start playing, then the watch.
  local deadline=$((SECONDS + 30 + 6 + 30 + SECONDS_TO_WATCH + 10))
  until grep -q "SMOKE-PLAY" "$log"; do
    if [ $SECONDS -ge $deadline ] || ! kill -0 "$console" 2>/dev/null; then break; fi
    sleep 1
  done
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  kill "$console" 2>/dev/null || true

  local result problems source moved playing
  result=$(grep "SMOKE-PLAY" "$log" | tail -1 || true)
  problems=$(grep -E "Playback stalled|State: Stopping playback|Player error|Player item failed|Failed to play to end" "$log" || true)
  source=$(grep -oE "Playing from (remote|local) files" "$log" | head -1 || true)
  echo "    ${source:-no 'Playing from' line}"
  echo "    ${result:-no SMOKE-PLAY line (the app crashed, or no book reached the player)}"
  [ -z "$problems" ] || echo "$problems" | sed 's/^/    /'

  moved=$(echo "$result" | sed -nE 's/.*moved=(-?[0-9.]+).*/\1/p')
  playing=$(echo "$result" | sed -nE 's/.*playing=(true|false).*/\1/p')
  if [ -n "$moved" ] && [ "$playing" = "true" ] && [ -z "$problems" ] &&
    python3 -c "import sys; sys.exit(0 if float('$moved') >= $SECONDS_TO_WATCH - 3 else 1)"; then
    echo "    ok"
  else
    echo "    FAILED"
    failures=$((failures + 1))
  fi
}

# Pass 1 loads the book through the play deep link, so pass 2 starts with it restored in the mini
# player and presses play there: the path that broke on 2026-10-31.
run_pass "Deep link play" -deeplink "audiobooth://play/$BOOK"
run_pass "Cold launch, press play"

if [ $failures -eq 0 ]; then
  echo "OK: playback started and kept playing in both passes"
else
  echo "FAIL: $failures of 2 passes did not keep playing"
  exit 1
fi
