#!/usr/bin/env bash
# QA scenario: clicking a Mother job opens it as a closable tab (P2).
# Same setup as mother-queue.sh (fake broker + MOTHER_BROKER_SOCK launch).
# Usage: mother-tabs.sh [window-index, default 1]
set -euo pipefail
APP="$(dirname "$0")/../../bin/nostromo-app"
# Clicks need the app active and the window key. This TAKES keyboard focus for the
# duration of the run and gives it back on exit — run when nobody is typing elsewhere.
"$APP" -w "${1:-1}" activate >/dev/null
trap '"$APP" restore >/dev/null 2>&1 || true' EXIT
W="${1:-1}"
# Number of closable tabs = ✕ *buttons* (find also reports each button's inner text field).
closers() { "$APP" -w "$W" find "✕" | python3 -c 'import json,sys; print(sum(1 for x in json.load(sys.stdin) if x["class"] == "NSButton"))'; }

"$APP" -w "$W" click --text "Mother"
"$APP" -w "$W" wait "Overview" --timeout 8                 # the fixed first tab
"$APP" -w "$W" wait "Add RWX sandbox for agents" --timeout 8

# 1. open one job: its detail shows and a tab appears (no ✕ yet on Overview)
"$APP" -w "$W" click --text "Add RWX sandbox for agents"
"$APP" -w "$W" wait "Cancel job" --timeout 5               # detail actions for a running job
"$APP" -w "$W" expect "✕"                                  # the job tab is closable

# 2. open a second job: another tab; the first stays open
"$APP" -w "$W" click --text "Upgrade Laravel"
"$APP" -w "$W" wait "Retry" --timeout 5
count=$(closers)
[ "$count" -ge 2 ] || { echo "expected 2 closable tabs, found $count"; exit 1; }

# 3. close one with its ✕; one tab remains
"$APP" -w "$W" click --text "✕" --index 0   # first match is the NSButton
sleep 1
count=$(closers)
[ "$count" -eq 1 ] || { echo "expected 1 closable tab after closing, found $count"; exit 1; }

# 4. closing the last job tab returns to the Overview, and the row can be reopened
"$APP" -w "$W" click --text "✕"
sleep 1
"$APP" -w "$W" expect "✕" --absent
"$APP" -w "$W" click --text "Add RWX sandbox for agents"
"$APP" -w "$W" wait "Cancel job" --timeout 5

echo "mother-tabs: PASS"
