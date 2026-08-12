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
# A run that delivers nothing must not burn the full two-hour deadline. This is
# the backstop for a harness that could not find a pane to drive: five quiet
# polls (~150 s) with no new turns and we stop, so the failure shows up in
# minutes instead of at the end of an afternoon.
STALL_POLLS=5
stalled=0
last_reached=-1
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
  if [ "${reached:-0}" -gt "$last_reached" ]; then
    last_reached="${reached:-0}"
    stalled=0
  else
    stalled=$(( stalled + 1 ))
    if [ "$stalled" -ge "$STALL_POLLS" ]; then
      echo
      echo "no turn progress for ~150s at ${reached:-0} turns — aborting"
      break
    fi
  fi
  printf '\r    %s turns' "${reached:-0}"
  sleep 30
done
echo

# Let the run settle before measuring idle behaviour.
sleep 15

# --- idle CPU over 60 s -----------------------------------------------------
# NF-aware, because `ps -o time=` prints [[dd-]hh:]mm:ss[.ss] and the field
# count varies with runtime. Returns non-zero on empty output rather than
# emitting an empty string: a process that died during the wait loop used to
# reach here and produce an awk error plus an argparse failure instead of a
# named criterion failure.
cpu_seconds() {
  local raw
  raw=$(ps -o time= -p "$1" 2>/dev/null | awk -f "$REPO_ROOT/macOS/scripts/ps-time-seconds.awk") || return 1
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw"
}

CPU=""
if kill -0 $APP_PID 2>/dev/null && T0=$(cpu_seconds $APP_PID); then
  sleep 60
  if kill -0 $APP_PID 2>/dev/null && T1=$(cpu_seconds $APP_PID); then
    # `awk -v`, not string interpolation into the program body: an empty or
    # unexpected shell value must not become awk source.
    CPU=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.2f", (b - a) / 60 * 100}')
  fi
fi
[ -n "$CPU" ] || echo "warning: could not measure idle CPU — the report will fail that criterion"

# --- the incident's own signature, inverted ---------------------------------
# Clear the stale file first. A sample left behind by a previous run was
# readable as this run's evidence, and `sample`'s own exit status was discarded
# along with its output.
rm -f "$SAMPLE_OUT"
SAMPLE_ARGS=()
if kill -0 $APP_PID 2>/dev/null; then
  if sample $APP_PID 5 -file "$SAMPLE_OUT" >/dev/null 2>&1 && [ -s "$SAMPLE_OUT" ]; then
    SAMPLE_ARGS=(--sample "$SAMPLE_OUT")
  else
    echo "warning: sample failed or produced nothing — the report will fail that criterion"
  fi
else
  echo "warning: app is not running — skipping sample; the report will fail that criterion"
fi

# An unmeasured criterion is omitted from the arguments, never faked. The report
# then prints it as a present, failing row, which is the honest outcome.
CPU_ARGS=()
[ -n "$CPU" ] && CPU_ARGS=(--cpu-percent "$CPU")

python3 "$REPORT" "$DIAG" --turns "$TURNS" "${CPU_ARGS[@]+"${CPU_ARGS[@]}"}" "${SAMPLE_ARGS[@]+"${SAMPLE_ARGS[@]}"}"
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
