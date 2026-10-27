#!/usr/bin/env bash
# Live QA of the remote-pane hazard treatment (slice 2d) in the ISOLATED QA instance only: a worktree nostromd
# plus a com.hammer.nostromo.qa clone of the app (qa-instance.sh). Never the user's app, daemon or ~/.nostromo,
# and never real AWS: the daemon's `aws` is tests/fixtures/fake-aws, its vocabulary tests/fixtures/ecs.
#
#   scripts/qa/terminal-hazard.sh
#
# The QA daemon runs the idle policy at 30 s (NOSTROMO_QA_IDLE_SECS=30: warning at 26 s, close at 30 s).
#  1. connect to the fake "production" target: red frame, red header "PRODUCTION · admin-portal · scheduler ·
#     shell", sidebar badge, a window title containing PRODUCTION (screenshots).
#  2. shrink the split with nostromo.set_pane_layout: the header is still there (screenshot).
#  3. paste: 3 lines -> the confirm sheet names PRODUCTION and "3 lines"; Return sends nothing; paste again and
#     click Paste -> sent; a 1-line paste goes straight through.
#  4. idle: the banner appears; Keep open (the QA instance relaxes the gate) clears it; then no input until the
#     daemon closes the pane; the toast says "idle for 15 minutes".
#  5. the QA audit has connected, idle_warning, idle_kept_open and an idle close, and none of the pasted text.
#
# Needs a logged-in, awake display. Exits 0 PASS, 1 FAIL, 3 INCONCLUSIVE. Screenshots go to a private temp
# directory (printed; removed at the end unless KEEP=1). Dragging a split, the staging picker and the real
# 13-minute idle are in the PR's manual checklist.
# shellcheck disable=SC2329  # functions handed to poll / ok_if / the EXIT trap are not "called" by name
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
instance="$here/qa-instance.sh"
app="$repo/bin/nostromo-app"

work="$(mktemp -d "${TMPDIR:-/tmp}/nostromo-hazard-qa.XXXXXX")"
chmod 700 "$work"
echo "evidence directory: $work"
fails=0
inconclusive=0
root=""
sock=""
cleanup() {
  [ -z "$root" ] || "$instance" stop "$root" >/dev/null 2>&1 || true
  [ "${KEEP:-0}" = 1 ] || rm -rf "$work"
}
trap cleanup EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
inconc() { echo "INCONCLUSIVE: $*"; inconclusive=$((inconclusive + 1)); }

aws_log="$work/aws.log"
: >"$aws_log"
cat >"$work/aws" <<EOF
#!/bin/sh
FAKE_AWS_MODE=ok FAKE_AWS_LOG="$aws_log" exec "$repo/tests/fixtures/fake-aws" "\$@"
EOF
chmod 700 "$work/aws"
export NOSTROMO_AWS_CLI="$work/aws"
export NOSTROMO_QA_ECS_FIXTURES="$repo/tests/fixtures/ecs"
export NOSTROMO_QA_REMOTE_SHELL_TIMEOUT_SECS=30
export NOSTROMO_QA_IDLE_SECS=30

ctl() { "$app" --socket "$sock" "$@"; }
sctl() { ctl --sheet "$@"; }
shot() { ctl screenshot "$work/$1.png" >/dev/null 2>&1 && echo "screenshot: $work/$1.png" || echo "WARN: screenshot $1 failed"; }
sheet_shot() { sctl screenshot "$work/$1.png" >/dev/null 2>&1 && echo "screenshot: $work/$1.png" || echo "WARN: sheet screenshot $1 failed"; }
tree_has() { ctl tree --depth 60 2>/dev/null | grep -q -- "$1"; }
tree_lacks() { ! tree_has "$1"; }
windows_has() { ctl windows 2>/dev/null | grep -q -- "$1"; }
sheet_has() { sctl tree --depth 40 2>/dev/null | grep -q -- "$1"; }
sheet_up() { sctl tree --depth 3 >/dev/null 2>&1; }
poll() { local tries="$1"; shift; for _ in $(seq 1 "$tries"); do "$@" && return 0; sleep 0.5; done; return 1; }
wait_tree() { poll 40 tree_has "$1"; }
wait_sheet() { poll 40 sheet_has "$1"; }
ok_if() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
ok_unless() { local label="$1"; shift; if "$@"; then fail "$label"; else pass "$label"; fi; }

# The terminal's screen text (accessibility value): only a QA build that relaxes the synthetic gate has it.
screen_text() {
  ctl ax NostromoTerminalView 2>/dev/null | python3 -I -c 'import json,sys
try:
    print(json.load(sys.stdin).get("value") or "")
except ValueError:
    pass'
}
screen_has() { screen_text | grep -q -- "$1"; }
wait_screen() { poll 40 screen_has "$1"; }
set_layout() { python3 -B "$here/lib/terminal_qa.py" set-pane-layout "$root" mother "$1" >/dev/null 2>&1; }

out="$("$instance" start)"
echo "$out"
root="$(sed -n 's/^QA_ROOT=//p' <<<"$out")"
[ -n "$root" ] || { echo "FAIL: no QA_ROOT printed"; exit 1; }
sock="$root/app-control.sock"
audit="$root/home/.nostromo/audit/terminal.jsonl"

windows="$(ctl windows)"
if [ -z "$windows" ] || [ "$windows" = "[]" ] || grep -Eq '"(alpha)": *0([^.0-9]|$)|"visible": *false' <<<"$windows"; then
  echo "INCONCLUSIVE: the QA window is not visible (display locked or asleep)"
  echo "RESULT: INCONCLUSIVE"
  exit 3
fi
ctl activate >/dev/null 2>&1 || true
ctl click --text "Mother" >/dev/null 2>&1 || echo "note: could not click the Mother focus"
sleep 1

echo "== 1. connect to the fake production target =="
(python3 -B "$here/lib/terminal_qa.py" request-remote-shell "$root" mother admin-portal production scheduler shell \
  "hazard QA" 90 >"$work/connect.json" 2>&1 || true) &
agent_pid=$!
if wait_sheet "Connect to PRODUCTION"; then
  ctl key tab >/dev/null
  ctl key space >/dev/null
  wait "$agent_pid" || true
  if wait_screen 'remote\$'; then pass "connected: the fake shell's prompt is on screen"; else fail "no remote\$ prompt"; fi
  ok_if "the header names PRODUCTION · admin-portal · scheduler · shell" \
    tree_has "PRODUCTION · admin-portal · scheduler · shell"
  ok_if "the sidebar shows a PRODUCTION badge" tree_has "remote shell open: PRODUCTION"
  ok_if "windows reports a title containing PRODUCTION" windows_has "PRODUCTION"
  shot "1-hazard"
else
  fail "no confirmation sheet"
  wait "$agent_pid" || true
fi

echo "== 2. a tiny split =="
pane_id="$(python3 -I -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("pane_id") or "")
except (OSError, ValueError):
    print("")' "$work/connect.json")"
if [ -n "$pane_id" ]; then
  set_layout "{\"repl\": 0.98, \"$pane_id\": 0.02}" || inconc "set_pane_layout was refused"
  sleep 1
  ok_if "the header is still in the tree at a tiny ratio" tree_has "PRODUCTION · admin-portal"
  shot "2-tiny"
  set_layout "{\"repl\": 0.5, \"$pane_id\": 0.5}" || true
else
  inconc "the connect outcome has no pane_id, so the split was not shrunk"
fi

echo "== 3. paste =="
ctl click --text "PRODUCTION" >/dev/null 2>&1 || true
ctl paste --text $'echo one\necho two\necho three\n' >/dev/null 2>&1 || true
if wait_sheet "3 lines"; then
  pass "a 3-line paste asks first"
  ok_if "the sheet names PRODUCTION" sheet_has "PRODUCTION"
  sheet_shot "3-paste-sheet"
  ctl key return >/dev/null
  sleep 1
  ok_unless "Return cancelled: nothing was sent" screen_has "you said"
  ctl paste --text $'echo one\necho two\necho three\n' >/dev/null 2>&1 || true
  if wait_sheet "3 lines"; then
    sctl click --text "Paste" >/dev/null 2>&1 || fail "could not click Paste"
    if wait_screen "three"; then pass "Paste sent the 3 lines"; else fail "the 3 lines did not arrive after Paste"; fi
  fi
else
  fail "a 3-line paste did not show the confirm sheet"
fi
ctl paste --text "echo single" >/dev/null 2>&1 || true
sleep 1
ok_unless "a 1-line paste is not prompted" sheet_up

echo "== 4. idle: banner, Keep open, then the close =="
if poll 60 tree_has "Closing in"; then
  pass "the idle banner appears"
  shot "4-idle-banner"
  ctl click --text "Keep open" >/dev/null 2>&1 || fail "could not click Keep open"
  if poll 10 tree_lacks "Closing in"; then pass "Keep open cleared the banner"; else fail "the banner is still up after Keep open"; fi
  if wait_tree "idle for 15 minutes"; then
    pass "with no input the pane closed: the toast says idle for 15 minutes"
  else
    fail "no idle toast"
  fi
  shot "4-idle-closed"
else
  fail "no idle banner within 30 s"
fi

echo "== 5. the audit trail =="
if [ -f "$audit" ]; then
  for event in connected idle_warning idle_kept_open; do
    ok_if "audit has $event" grep -q "\"$event\"" "$audit"
  done
  ok_if "audit has an idle close" grep -Eq 'idle_closed|idle_timeout' "$audit"
  ok_unless "audit holds none of the pasted text" grep -Eq 'echo (one|two|three|single)' "$audit"
else
  fail "no audit file at $audit"
fi

if [ "$fails" -gt 0 ]; then
  echo "RESULT: FAIL"
elif [ "$inconclusive" -gt 0 ]; then
  echo "RESULT: PASS with $inconclusive INCONCLUSIVE check(s)"
else
  echo "RESULT: PASS"
fi
[ "$fails" -eq 0 ] || exit 1
[ "$inconclusive" -eq 0 ] || exit 3
exit 0
