#!/bin/bash
# Sync the fork onto upstream/main, which may have been rebased and force-pushed.
#
#   ./scripts/sync-upstream.sh            # preview → confirm → rebase → verify
#
# The flow is preview-first: before touching anything it shows what's incoming and — the part that
# actually predicts the work — the overlap set: files changed on BOTH sides since the merge-base.
# Per-file conflict strategies live in FORK-NOTES.md § "Tracking upstream over time" (short version:
# xcstrings and pbxproj are taken from upstream wholesale and re-decorated, never hand-merged).
# The force-push at the end is printed, not run: pushing a rebased main is always a human decision.
set -euo pipefail

cd "$(dirname "$0")/.."

git fetch upstream

BASE=$(git merge-base main upstream/main)
AHEAD=$(git rev-list --count upstream/main..main)
BEHIND=$(git rev-list --count main..upstream/main)
echo "==> fork is $AHEAD ahead, $BEHIND behind upstream/main (merge-base ${BASE:0:9})"

if [ "$BEHIND" -eq 0 ]; then
  echo "Nothing to sync."
  exit 0
fi

echo
echo "==> incoming upstream commits"
git log --oneline main..upstream/main

echo
echo "==> conflict-risk preview: files changed on BOTH sides since merge-base"
OVERLAP=$(comm -12 \
  <(git diff --name-only "$BASE"..main | sort) \
  <(git diff --name-only "$BASE"..upstream/main | sort))
if [ -n "$OVERLAP" ]; then
  echo "$OVERLAP" | sed 's/^/  ⚠ /'
else
  echo "  (none — expect a clean replay)"
fi

echo
read -rp "Rebase main onto upstream/main now? [y/N] " answer
[ "${answer:-n}" = "y" ] || { echo "Aborted; nothing changed."; exit 0; }

# Conflicts stop the rebase here; resolve per FORK-NOTES strategies, then `git rebase --continue`
# and re-run this script (it will fast-path to verification once BEHIND is 0... after the rebase
# completes, just run the gauntlet below by hand).
git rebase upstream/main

echo
echo "==> verification gauntlet"
./scripts/dev-build-run.sh
(cd Transcription && swift test)

cat <<'DONE'

==> sync verified (build + package tests)

Manual smoke before pushing — FORK-NOTES § post-sync checklist:
  · karaoke: open Goblet's transcript and cover mode
  · speaker: pill appears against a live/paused daemon session
  · device build, if you plan to install

Then push the rebased main yourself:

  git push --force-with-lease origin main

DONE
