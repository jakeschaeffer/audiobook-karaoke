#!/bin/bash
# Build a public snapshot of this repo: the tracked tree at one revision, with the private literals
# in scripts/public-redactions replaced, as a fresh single-commit git repository. The private repo's
# history never leaves this machine (it carries hostnames, a tailnet address and a team id from
# before the "configuration, not code" rule), and gitignored files (Local.xcconfig, local.env, the
# redaction map itself) are not in `git archive` to begin with.
#
#   ./scripts/public-snapshot.sh                 # snapshot HEAD into $TMPDIR, verify, stop
#   ./scripts/public-snapshot.sh main            # a specific revision
#   ./scripts/public-snapshot.sh --push owner/repo [rev]
#                                                # ...and force-push it as that repo's main branch
#
# The repo to push to must already exist; create it yourself (`gh repo create owner/repo --public`),
# because flipping something public is not a step a script should take on its own. Shipping builds
# to anyone else is also what makes the MPL-2.0 source offer real: the snapshot is that offer.
#
# Verification fails the run when any redacted literal survives, when a tailnet (100.64/10) address
# is left in a text file, or when a *.ts.net hostname remains.
set -euo pipefail
cd "$(dirname "$0")/.."

PUSH_TO=
if [ "${1:-}" = "--push" ]; then
  PUSH_TO="${2:?--push needs owner/repo}"
  shift 2
fi
REV="${1:-HEAD}"
MAP=scripts/public-redactions
[ -f "$MAP" ] || { echo "public-snapshot: no $MAP; copy scripts/public-redactions.example and fill it in"; exit 2; }

SHA=$(git rev-parse --short "$REV")
STAMP=$(date -u +%y%m%d%H%M)
OUT="${TMPDIR:-/tmp}/audiobooth-public-$STAMP"
mkdir -p "$OUT"
echo "==> Exporting $REV ($SHA) to $OUT"
git archive --format=tar "$REV" | tar -x -C "$OUT"

# Longest literals first, so "host.example" wins over "example" when both are listed.
echo "==> Redacting"
REDACTED=0
while IFS=$'\t' read -r literal replacement; do
  [ -n "$literal" ] || continue
  case "$literal" in \#*) continue ;; esac
  files=$(grep -rIlF --exclude-dir=.git -- "$literal" "$OUT" || true)
  [ -n "$files" ] || continue
  n=$(echo "$files" | wc -l | tr -d ' ')
  L="$literal" R="$replacement" perl -pi -e 's/\Q$ENV{L}\E/$ENV{R}/g' $files
  REDACTED=$((REDACTED + n))
  printf '  %-45s -> %-30s %s file(s)\n' "$literal" "$replacement" "$n"
done < <(grep -v '^[[:space:]]*#' "$MAP" | grep -v '^[[:space:]]*$' | awk -F'\t' '{ print length($1) "\t" $0 }' | sort -rn | cut -f2-)
echo "    $REDACTED file replacement(s)"

echo "==> Verifying"
FAIL=0
while IFS=$'\t' read -r literal _; do
  [ -n "$literal" ] || continue
  case "$literal" in \#*) continue ;; esac
  if hits=$(grep -rInF --exclude-dir=.git -- "$literal" "$OUT"); then
    echo "  ✗ literal survived: $literal"; echo "$hits" | head -3 | sed 's/^/      /'; FAIL=1
  fi
done < <(grep -v '^[[:space:]]*#' "$MAP" | grep -v '^[[:space:]]*$')
# The CGNAT range Tailscale hands out (100.64/10), minus the address tests use as an example.
# RFC 1918 addresses are left alone: upstream's previews and the tests use them as placeholders
# and a LAN address identifies nobody.
if hits=$(grep -rInE --exclude-dir=.git \
    '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b' "$OUT" \
    | grep -v -E '100\.64\.0\.1\b'); then
  echo "  ✗ tailnet address left in a text file:"; echo "$hits" | head -5 | sed 's/^/      /'; FAIL=1
fi
if hits=$(grep -rInE --exclude-dir=.git '[A-Za-z0-9-]+\.ts\.net' "$OUT"); then
  echo "  ✗ tailnet hostname left in a text file:"; echo "$hits" | head -5 | sed 's/^/      /'; FAIL=1
fi
for f in AudioBooth/Local.xcconfig scripts/local.env scripts/public-redactions; do
  [ ! -e "$OUT/$f" ] || { echo "  ✗ gitignored file made it into the export: $f"; FAIL=1; }
done
[ "$FAIL" = 0 ] || { echo "public-snapshot: verification failed; nothing was committed. Export left at $OUT"; exit 1; }
echo "  clean"

echo "==> Committing the snapshot"
git -C "$OUT" init -q -b main
git -C "$OUT" add -A
git -C "$OUT" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
  commit -q -m "Public snapshot of AudioBook Karaoke at $SHA

A redacted export of the private working repository at $SHA: the same tree, with the
operator's hostnames, addresses and account identifiers replaced by placeholders. History
is not carried over; each snapshot is one commit. Upstream is AudioBooth
(https://github.com/AudioBooth/AudioBooth), MPL-2.0."
echo "    $(git -C "$OUT" rev-parse --short HEAD) in $OUT"

if [ -n "$PUSH_TO" ]; then
  gh repo view "$PUSH_TO" --json visibility -q .visibility >/dev/null \
    || { echo "public-snapshot: $PUSH_TO does not exist; create it first (gh repo create $PUSH_TO --public)"; exit 1; }
  echo "==> Pushing to $PUSH_TO (main, forced: a snapshot replaces the previous one)"
  git -C "$OUT" remote add origin "https://github.com/$PUSH_TO.git"
  git -C "$OUT" push -q --force origin main
  echo "OK: https://github.com/$PUSH_TO"
else
  echo "Not pushed. Inspect $OUT, then: ./scripts/public-snapshot.sh --push owner/repo $REV"
fi
