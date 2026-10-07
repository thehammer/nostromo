#!/usr/bin/env bash
# QA scenario: clicking a Mother job opens it as a closable tab (P2).
# Same setup as mother-queue.sh (fake broker + MOTHER_BROKER_SOCK launch).
# Usage: [QA_SCREEN=Sceptre] mother-tabs.sh   (targets the window on that display)
set -euo pipefail
APP="$(dirname "$0")/../../bin/nostromo-app"
SCREEN="${QA_SCREEN:-Sceptre}"   # the display reserved for QA; set QA_SCREEN to override
export NOSTROMO_QA_SCREEN="$SCREEN"
# Clicks need the app active and the window key. This TAKES keyboard focus for the
# duration of the run and gives it back on exit — run when nobody is typing elsewhere.
"$APP" --screen "$SCREEN" activate >/dev/null
sleep 0.6   # let the window actually become key before the first click
trap '"$APP" restore >/dev/null 2>&1 || true' EXIT
# Scenarios share the fake broker's state (cancel/retry mutate it): start from the scenario's jobs.
ctl_reset() { python3 -c '
import socket
s = socket.socket(socket.AF_UNIX); s.connect("/tmp/fmb-qa.sock.ctl"); s.sendall(b"{\"op\":\"reset\"}\n")
import json, sys
r = json.loads(s.makefile().readline())
sys.exit(0 if r.get("ok") else "fake broker reset failed: %s" % r)'; sleep 4; }
ctl_reset
W=0   # window selection is by display (below), never by index
# Number of closable tabs = ✕ *buttons* (find also reports each button's inner text field).
closers() { "$APP" --screen "$SCREEN" find "✕" | python3 -c 'import json,sys; print(sum(1 for x in json.load(sys.stdin) if x["class"] == "NSButton"))'; }

"$APP" --screen "$SCREEN" click --text "Mother"
"$APP" --screen "$SCREEN" wait "Overview" --timeout 8                 # the fixed first tab
"$APP" --screen "$SCREEN" wait "Add RWX sandbox for agents" --timeout 8

# 1. open one job: its detail shows and a tab appears (no ✕ yet on Overview)
"$APP" --screen "$SCREEN" click --text "Add RWX sandbox for agents"
"$APP" --screen "$SCREEN" wait "Cancel job" --timeout 5               # detail actions for a running job
"$APP" --screen "$SCREEN" expect "✕"                                  # the job tab is closable

# 2. open a second job: another tab; the first stays open
"$APP" --screen "$SCREEN" click --text "Upgrade Laravel"
"$APP" --screen "$SCREEN" wait "Retry" --timeout 5
count=$(closers)
[ "$count" -ge 2 ] || { echo "expected 2 closable tabs, found $count"; exit 1; }

# 3. close one with its ✕; one tab remains
"$APP" --screen "$SCREEN" click --text "✕" --index 0   # first match is the NSButton
sleep 1
count=$(closers)
[ "$count" -eq 1 ] || { echo "expected 1 closable tab after closing, found $count"; exit 1; }

# 4. closing the last job tab returns to the Overview, and the row can be reopened
"$APP" --screen "$SCREEN" click --text "✕"
sleep 1
"$APP" --screen "$SCREEN" expect "✕" --absent
"$APP" --screen "$SCREEN" click --text "Add RWX sandbox for agents"
"$APP" --screen "$SCREEN" wait "Cancel job" --timeout 5

# 5. a long, multi-line question wraps inside the pane instead of running off its right edge
"$APP" --screen "$SCREEN" click --text "Migrate billing job to queues"
"$APP" --screen "$SCREEN" wait "Keep the legacy retry config" --timeout 5
"$APP" --screen "$SCREEN" windows | python3 -c '
import json, subprocess, sys
width = [w for w in json.load(sys.stdin) if "sceptre" in w["screen"].lower()][0]["frame"]["w"]
hits = json.loads(subprocess.check_output(["'"$APP"'", "--screen", "'"$SCREEN"'", "find", "Keep the legacy retry config"]))
over = [h for h in hits if h["frame"]["x"] + h["frame"]["w"] > width + 1]
sys.exit("question runs past the pane edge (%d px window): %s" % (width, over) if over else 0)'

echo "mother-tabs: PASS"
