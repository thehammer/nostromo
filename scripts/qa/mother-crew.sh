#!/usr/bin/env bash
# QA scenario (the PRD's "gates, lenses, progress"): the Mother panel shows a crew job's progress,
# gate list and lens wave live, and never breaks the layout while they update.
#
# Setup (the script does NOT do this — it relaunches nothing):
#   python3 bin/fake-mother-broker --sock /tmp/fmb-qa.sock --scenario crew_gates &
#   open --env MOTHER_BROKER_SOCK=/tmp/fmb-qa.sock <a QA build of Nostromo.app>
# Needs AppControlEnabled and a visible window. It TAKES keyboard focus for the run (clicks need a
# key window) and gives it back on exit.
#
# It reads the accessibility tree, so what it expects is each row's VoiceOver text ("lint: passed,
# took 42 seconds, ..."), not the on-screen glyphs: the visible forms (`≈70% · gates 1/3 · ETA ~2-8 min`,
# `✓ lint  passed · 42s · blocking`) are the live-QA step of the PR (screenshots).
#
# Env: QA_SCREEN (display to test, default Sceptre), QA_FMB_SOCK (fake broker socket, default
# /tmp/fmb-qa.sock), QA_SETTLE (seconds for the app to reconnect after the broker resets, default 4),
# QA_APP (the app-control CLI; the self-test points it at a fake).
set -euo pipefail
APP="${QA_APP:-$(dirname "$0")/../../bin/nostromo-app}"
SCREEN="${QA_SCREEN:-Sceptre}"
SOCK="${QA_FMB_SOCK:-/tmp/fmb-qa.sock}"
SETTLE="${QA_SETTLE:-4}"
export NOSTROMO_QA_SCREEN="$SCREEN"
app() { "$APP" --screen "$SCREEN" "$@"; }
ctl() { python3 -c '
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1] + ".ctl"); s.sendall((sys.argv[2] + "\n").encode())
r = json.loads(s.makefile().readline())
sys.exit(0 if r.get("ok") else "fake broker: %s" % r)' "$SOCK" "$1"; }

app activate >/dev/null
sleep 0.6   # let the window actually become key before the first click
trap 'app restore >/dev/null 2>&1 || true' EXIT

# Start from the scenario's jobs: dropping the clients makes the app reconnect and re-snapshot.
ctl '{"op":"reset"}'
sleep "$SETTLE"
app click --text "Mother"

# 1. the crew job is in the queue with its progress line (about 55%, no gate signal yet)
app wait "Add facility export endpoint" --timeout 8
app wait "About 55 percent" --timeout 8

# 2. open it: the crew section shows the gates header, waiting for the first result
app click --text "Add facility export endpoint"
app wait "Gates, attempt 1 of 3, running" --timeout 5

# 3. replay the gate run: fail, fix, pass. Each step is read from the accessibility tree as it lands.
ctl '{"op":"replay","file":"gates_fix_pass.ndjson","speed":1}'
app wait "1 of 3 gates passed" --timeout 15          # progress: gates 1/3
app wait "lint: passed" --timeout 10
app wait "unit: failed" --timeout 10
app wait "exit code 1" --timeout 5                   # a failed gate shows its exit code
app wait "3 of 3 gates passed" --timeout 25          # progress: gates 3/3 after the fix
app wait "unit: passed" --timeout 10
app wait "static: passed" --timeout 10
app expect "About 95 percent"

# 4. the lens wave: a second crew job arrives with its lens rows; one lens is skipped
ctl '{"op":"replay","file":"lens_wave.ndjson","speed":2}'
app wait "Rework consent form validation" --timeout 10
app click --text "Rework consent form validation"
app wait "perri:ops-infra: skipped" --timeout 10
app expect "not in scope"                             # the skip reason in words
app wait "perri:correctness: done" --timeout 15
app wait "Citations found 2" --timeout 15            # claims are "citations found", never "verified"
app expect "verified correct" --absent

# 5. no broken layout in the pane
app layout-issues | python3 -c '
import json, sys
# Content area only (x >= 160 skips the sidebar), and not AppKit-internal text plumbing.
bad = [i for i in json.load(sys.stdin)
       if i["ambiguous"] and i["frame"]["x"] >= 160
       and not i["class"].startswith(("_NS", "NSText", "NSStackView"))]
sys.exit("layout issues: %s" % bad if bad else 0)'

echo "mother-crew: PASS"
