#!/usr/bin/env bash
# Acceptance run for the bounded-transcript work.
#
# Several of the PRD's criteria are numeric and can only be checked against a
# real app with a real window, a real Auto Layout engine, and a real
# steady-state footprint — the logic test bundle has none of those. This drives
# a Release build under TranscriptLoadHarness (synthetic traffic through the
# production code path, no daemon) and asserts each criterion against the
# diagnostics stream the app writes.
#
#   macOS/scripts/transcript-load-test.sh [turns] [focuses]
#
# A Debug build's numbers are meaningless for this work, so this always builds
# Release. Expect roughly one turn per second of wall clock: the harness runs
# about 40x faster than a real agent, and the limit is genuine rendering work.
#
# The arithmetic lives in transcript-load-report.py — a least-squares fit is not
# something to write in jq and trust.

set -uo pipefail

TURNS="${1:-5000}"
FOCUSES="${2:-1}"
RECONNECTS="${NOSTROMO_LOAD_RECONNECTS:-20}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIAG="$HOME/Library/Application Support/Nostromo/diagnostics.jsonl"
APP="$REPO_ROOT/macOS/build/Build/Products/Release/Nostromo.app"
SAMPLE_OUT="/tmp/nostromo-transcript-sample.txt"
REPORT="$REPO_ROOT/macOS/scripts/transcript-load-report.py"

# Refuse to disturb a Nostromo the operator is actually using. This is their
# primary agent console; the run needs the app to itself (AppDelegate enforces
# a single instance) but taking it without asking is not ours to do.
if pgrep -f 'Nostromo.app/Contents/MacOS/Nostromo' >/dev/null; then
  echo "Nostromo is already running. Quit it first — this run needs the app to"
  echo "itself, and killing your live console is not something this script will"
  echo "do on your behalf."
  exit 2
fi

echo "==> building Release"
make -C "$REPO_ROOT" mac-release >/dev/null || { echo "mac-release failed"; exit 1; }

mkdir -p "$(dirname "$DIAG")"
: > "$DIAG"

echo "==> launching: turns=$TURNS focuses=$FOCUSES reconnects=$RECONNECTS"
NOSTROMO_LOAD_HARNESS=1 \
NOSTROMO_LOAD_TURNS="$TURNS" \
NOSTROMO_LOAD_RECONNECTS="$RECONNECTS" \
NOSTROMO_LOAD_FOCUSES="$FOCUSES" \
NOSTROMO_DIAG_INTERVAL=5 \
  "$APP/Contents/MacOS/Nostromo" >/tmp/nostromo-load.log 2>&1 &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null' EXIT

echo "==> waiting for $TURNS turns"
DEADLINE=$(( $(date +%s) + 7200 ))
while :; do
  reached=$(python3 -c "
import json,os,sys
p=os.path.expanduser('$DIAG')
try:
    rows=[json.loads(l) for l in open(p) if l.strip()]
except Exception:
    rows=[]
print(max([(r.get('turnsProcessed') or 0) for r in rows] or [0]))" 2>/dev/null || echo 0)
  [ "${reached:-0}" -ge "$TURNS" ] && break
  kill -0 $APP_PID 2>/dev/null || { echo "app exited early — see /tmp/nostromo-load.log"; break; }
  [ "$(date +%s)" -gt "$DEADLINE" ] && { echo "timed out at ${reached} turns"; break; }
  printf '\r    %s turns' "${reached:-0}"
  sleep 30
done
echo

# Let the run settle before measuring idle behaviour.
sleep 15

# --- idle CPU over 60 s -----------------------------------------------------
cpu_seconds() { ps -o time= -p "$1" | awk -F: '{print ($1*3600)+($2*60)+$3}'; }
T0=$(cpu_seconds $APP_PID); sleep 60; T1=$(cpu_seconds $APP_PID)
CPU=$(awk "BEGIN{printf \"%.2f\", ($T1 - $T0) / 60 * 100}")

# --- the incident's own signature, inverted ---------------------------------
sample $APP_PID 5 -file "$SAMPLE_OUT" >/dev/null 2>&1

python3 "$REPORT" "$DIAG" --turns "$TURNS" --cpu-percent "$CPU" --sample "$SAMPLE_OUT"
STATUS=$?

cat <<'NOTE'

Not covered here, and not claimed:
  - The 24-hour soak. Run with NOSTROMO_LOAD_DURATION=24h and 8 focuses.
    A flat slope plus a bounded peak with 8 focuses IMPLY the 24-hour claim;
    they do not demonstrate it.
  - The 20-screenshot image drop, which needs a real drag-and-drop.
  - Scroll round trip: run again with NOSTROMO_LOAD_SCROLL=1 and compare the
    footprint before and after the scripted round trip.
NOTE

exit $STATUS
