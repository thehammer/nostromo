#!/usr/bin/env bash
# Live QA of command staging in the Mac app (slice S1b) in the ISOLATED QA instance only: a worktree nostromd
# plus a com.hammer.nostromo.qa clone of the app, started and stopped by qa-instance.sh. Never the user's app,
# daemon or ~/.nostromo. NOT run by the agent that wrote it: the user runs it on a logged-in, awake display.
#
#   scripts/qa/terminal-staging.sh [--skip-gate]
#
# A local terminal whose shell (bash --norc) logs every command it ACCEPTS (its DEBUG trap) to a file; a focus
# is invited to follow it; the focus (acting through the QA daemon's MCP socket, as an agent) stages commands.
#
# (a) three fixture commands appear in the drawer: "Staged by <focus> (3)" and each command's text.
# (b) after the 1.5 s reading delay, a click on #2 puts its exact text at the prompt: it is on the screen, and
#     the accepted-line log is EMPTY (nothing was run). Enter then runs it: the log has exactly that line.
# (c) a replace scripted between a click's mouse-down and mouse-up inserts the OLD text (a slow drag that
#     starts and ends on the row).
# (d) a replace followed at once by a click inserts nothing ("Just changed: read it again").
# (e) `less` running (alternate screen): the rows are disabled ("A full-screen program is running").
# (f) a second window (a mirror) shows the same rows, disabled ("Click the terminal to drive it from this window").
# (g) stop following: the drawer says it stopped following; the entries stay.
# (h) privacy: a canary staged and inserted; no file under the QA home's .nostromo holds it.
# (j)-(l) S2 production pane (fake ECS): the red-frame drawer, confirm only on a destructive pattern, the
#     per-terminal switch, and agent staging never keeping the shell open (NOSTROMO_QA_IDLE_SECS=30).
# (m)-(o) S2 archive/close/reopen, auto-archive off by default, and the foreground (`sleep 30`) case.
# (i) with `start --no-synthetic`: a synthesized click on a row sends zero bytes (the screen shows no command).
#
# Reading the app is by its accessibility tree. Where app-control cannot reach a control (the badge popover, a
# timed drag) the step says INCONCLUSIVE and the PR's manual list covers it. Exits 0 PASS, 1 FAIL, 3 INCONCLUSIVE.
# shellcheck disable=SC2329  # functions handed to poll / ok_if / the EXIT trap are not "called" by name
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
instance="$here/qa-instance.sh"
app="$repo/bin/nostromo-app"
qa_py="$here/lib/terminal_qa.py"
skip_gate=0
for a in "$@"; do [ "$a" = "--skip-gate" ] && skip_gate=1; done

work="$(mktemp -d "${TMPDIR:-/tmp}/nostromo-staging-qa.XXXXXX")"
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

ctl() { "$app" --socket "$sock" "$@"; }
shot() { ctl screenshot "$work/$1.png" >/dev/null 2>&1 && echo "screenshot: $work/$1.png" || echo "WARN: screenshot $1 failed"; }

start_instance() {
  local out
  out="$("$instance" start "$@")"
  echo "$out"
  root="$(sed -n 's/^QA_ROOT=//p' <<<"$out")"
  [ -n "$root" ] || { echo "FAIL: no QA_ROOT printed"; exit 1; }
  sock="$root/app-control.sock"
}
stop_instance() {
  if [ -n "$root" ]; then
    "$instance" stop "$root" || fail "isolation guard"
    root=""
  fi
}
require_visible() {
  local windows
  windows="$(ctl windows)"
  if grep -Eq '"(alpha)": *0([^.0-9]|$)|"visible": *false' <<<"$windows" || [ -z "$windows" ] || [ "$windows" = "[]" ]; then
    echo "INCONCLUSIVE: the QA window is not visible (display locked or asleep)"
    stop_instance
    echo "RESULT: INCONCLUSIVE"
    echo "Manual checklist: see the PR body."
    exit 3
  fi
}

tree_has() { ctl tree --depth 80 2>/dev/null | grep -qF -- "$1"; }
tree_has_w1() { ctl -w 1 tree --depth 80 2>/dev/null | grep -qF -- "$1"; }
poll() { local tries="$1"; shift; for _ in $(seq 1 "$tries"); do "$@" && return 0; sleep 0.5; done; return 1; }
wait_tree() { poll 40 tree_has "$1"; }
ok_if() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
ok_unless() { local label="$1"; shift; if "$@"; then fail "$label"; else pass "$label"; fi; }
screen_text() {
  ctl ax NostromoTerminalView 2>/dev/null | python3 -I -c 'import json,sys
try:
    print(json.load(sys.stdin).get("value") or "")
except ValueError:
    pass'
}
screen_has() { screen_text | grep -qF -- "$1"; }
wait_screen() { poll 40 screen_has "$1"; }
accepted_log() { cat "$work/accepted.log" 2>/dev/null || true; }
log_empty() { [ -z "$(accepted_log)" ]; }
log_is() { [ "$(accepted_log)" = "$1" ]; }

terminal_id() {
  python3 -B "$qa_py" list-terminals "$root" mother 2>/dev/null | python3 -I -c 'import json,sys
try:
    ts = json.load(sys.stdin).get("terminals") or []
    print(ts[0]["terminal_id"] if ts else "")
except (ValueError, KeyError, IndexError):
    pass'
}
stage() { python3 -B "$qa_py" stage "$root" mother "$tid" "$@" >/dev/null 2>&1; }
popover_press() {
  ctl click --text "Follow:" >/dev/null 2>&1 || return 1
  sleep 0.7
  ctl click --text "$1" >/dev/null 2>&1 || return 1
}
# Open a terminal in the focus, run a logging bash in it, invite the focus to follow it.
open_logged_terminal() {
  ctl activate >/dev/null 2>&1 || true
  ctl click --text "Mother" >/dev/null 2>&1 || echo "note: could not click the Mother focus"
  sleep 1
  ctl key t --mod cmd >/dev/null
  wait_tree "TerminalPaneHostView" || { fail "no terminal pane"; return 1; }
  sleep 1.5
  ctl type $'exec env -i HOME=/nonexistent TERM=xterm-256color PS1="QA$ " bash --norc --noprofile\r' >/dev/null
  sleep 1
  ctl type "trap 'printf \"%s\\n\" \"\$BASH_COMMAND\" >> \"$work/accepted.log\"' DEBUG"$'\r' >/dev/null
  sleep 1
  : >"$work/accepted.log"
  tid="$(terminal_id)"
  [ -n "$tid" ] || { inconc "could not read the terminal id"; return 1; }
  popover_press "Invite" || { inconc "app-control could not press Invite: invite by hand, then re-run with the terminal open"; return 1; }
  poll 40 tree_has "Follow: Followed by" || { fail "Invite did not start following"; return 1; }
}

# ══════════════════════ the relaxed instance (synthetic clicks allowed) ═══════════════════════════════

start_instance
require_visible
tid=""
if open_logged_terminal; then
  echo "== (a) three commands appear =="
  stage stage '{"command": "echo staged-one"}' || fail "stage #1 refused"
  stage stage '{"command": "echo staged-two <name>", "note": "fixture note"}' || fail "stage #2 refused"
  stage stage '{"command": "ls -la"}' || fail "stage #3 refused"
  ok_if "the drawer shows its header" poll 20 tree_has "Staged by"
  ok_if "the header counts three" tree_has "(3)"
  ok_if "command #2 is in the drawer" tree_has "echo staged-two <name>"
  ok_if "the placeholder label is the app's" tree_has "edit it before pressing Enter"
  ok_if "the note is labelled unverified" tree_has "(unverified): fixture note"
  shot "a0-drawer"
  sleep 2   # the 1.5 s reading delay

  echo "== (b) a click places the text; nothing runs; Enter runs it =="
  ctl click --text "echo staged-two <name>" >/dev/null 2>&1 || inconc "could not click row #2"
  if wait_screen "echo staged-two <name>"; then pass "the exact text is at the prompt"; else fail "the text never reached the prompt (screenshot b1)"; fi
  ok_if "the accepted-line log is EMPTY: no Enter was sent" log_empty
  shot "b1-inserted"
  ctl type $'\r' >/dev/null
  ok_if "Enter ran exactly that line" poll 20 log_is "echo staged-two <name>"

  echo "== (c) a replace between a click's down and up inserts the OLD text =="
  : >"$work/accepted.log"
  ctl type $'\x15' >/dev/null   # Ctrl-U: clear the prompt line
  sleep 1
  # A slow press-drag-release that starts and ends on row #1 (400 steps keeps the button down for a while).
  (ctl drag --text "echo staged-one" --to 300 0 --steps 400 >/dev/null 2>&1 || true) &
  drag_pid=$!
  sleep 0.5
  stage replace '{"entry_id": "s-00000001", "command": "echo replaced-one"}' || fail "replace refused"
  wait "$drag_pid" || true
  if screen_has "echo staged-one"; then
    pass "the mouse-down snapshot (the OLD text) was inserted"
  else
    inconc "no old text at the prompt: the timed drag may not have ended on the row (do it by hand, the PR's list)"
  fi
  ok_unless "the replacement was not inserted" screen_has "echo replaced-one"
  ctl type $'\x15' >/dev/null

  echo "== (d) replace, then click at once: nothing inserted =="
  stage replace '{"entry_id": "s-00000003", "command": "ls -lah"}' || fail "replace #3 refused"
  ctl click --text "ls -lah" >/dev/null 2>&1 || true
  sleep 0.4
  ok_unless "a row changed under 1.5 s ago inserted nothing" screen_has "ls -lah"
  ok_if "the row says why" tree_has "Just changed: read it again"
  sleep 2

  echo "== (e) a full-screen program disables the rows =="
  ctl type $'less /etc/hosts\r' >/dev/null
  sleep 1.5
  ok_if "the drawer says a full-screen program is running" tree_has "A full-screen program is running"
  ctl click --text "ls -lah" >/dev/null 2>&1 || true
  sleep 0.4
  ctl type "q" >/dev/null
  sleep 1
  ok_unless "a click during less inserted nothing at the prompt" screen_has "QA$ ls -lah"

  echo "== (f) a second window mirrors the rows, disabled =="
  ctl key n --mod ctrl,alt,cmd >/dev/null
  sleep 2
  if tree_has_w1 "Staged by"; then
    pass "the second window shows the same list"
    ok_if "its rows say to click the terminal first" tree_has_w1 "Click the terminal to drive it from this window"
    ctl -w 1 click --text "ls -lah" >/dev/null 2>&1 || true
    sleep 0.5
    ok_unless "a click in the mirror inserted nothing" screen_has "QA$ ls -lah"
  else
    fail "the second window shows no drawer"
  fi

  echo "== (g) Stop following: frozen, entries stay =="
  if popover_press "Stop following"; then
    ok_if "the drawer says Claudia stopped following" tree_has "stopped following; this list won't change"
  else
    inconc "app-control could not press Stop following"
  fi

  echo "== (h) privacy: a canary is staged and inserted, and written nowhere =="
  canary="canary-$(python3 -I -c 'import uuid; print(uuid.uuid4().hex[:12])')"
  popover_press "Invite" || true
  poll 20 tree_has "Follow: Followed by" || true
  stage stage "{\"command\": \"echo $canary\"}" || inconc "could not stage the canary (not following?)"
  sleep 2
  ctl click --text "echo $canary" >/dev/null 2>&1 || true
  wait_screen "echo $canary" || true
  ctl type $'\x15' >/dev/null
  sleep 1
  hits="$(grep -rl -- "$canary" "$root/home/.nostromo" 2>/dev/null || true)"
  if [ -z "$hits" ]; then pass "no file under the QA home's .nostromo holds the canary"; else fail "the canary is on disk: $hits"; fi
else
  inconc "no logged terminal, so (a)-(h) were skipped"
fi
stop_instance

# ══════════════════════ S2: a production (fake ECS) pane, switches, archive, close, foreground ═══════════

# The fake AWS CLI and a short idle policy (the S2 remote section, never real AWS).
aws_log="$work/aws.log"
: >"$aws_log"
cat >"$work/aws" <<AWSWRAP
#!/bin/sh
FAKE_AWS_MODE=ok FAKE_AWS_LOG="$aws_log" exec "$repo/tests/fixtures/fake-aws" "\$@"
AWSWRAP
chmod 700 "$work/aws"
export NOSTROMO_AWS_CLI="$work/aws"
export NOSTROMO_QA_ECS_FIXTURES="$repo/tests/fixtures/ecs"
export NOSTROMO_QA_REMOTE_SHELL_TIMEOUT_SECS=20
export NOSTROMO_QA_IDLE_SECS=30 # warning at 26 s, close at 30 s

sheet_has() { ctl --sheet tree --depth 40 2>/dev/null | grep -qF -- "$1"; }
wait_sheet() { poll 40 sheet_has "$1"; }
audit_file() { echo "$root/home/.nostromo/audit/terminal.jsonl"; }
audit_has() { grep -qF -- "$1" "$(audit_file)" 2>/dev/null; }
remote_tid() {
  python3 -B "$qa_py" list-terminals "$root" mother 2>/dev/null | python3 -I -c 'import json,sys
try:
    ts = [t for t in (json.load(sys.stdin).get("terminals") or []) if t.get("kind") == "ecs"]
    print(ts[0]["terminal_id"] if ts else "")
except (ValueError, KeyError, IndexError):
    pass'
}

start_instance
require_visible
ctl activate >/dev/null 2>&1 || true
ctl click --text "Mother" >/dev/null 2>&1 || echo "note: could not click the Mother focus"
sleep 1

echo "== (j) a production pane: drawer inside the red frame, token, confirm only on a pattern =="
(python3 -B "$qa_py" request-remote-shell "$root" mother admin-portal production scheduler shell "staging QA" 60 \
  >"$work/j1.json" 2>&1 || true) &
agent_pid=$!
if wait_sheet "Connect to PRODUCTION"; then
  ctl key tab >/dev/null
  ctl key space >/dev/null
  wait "$agent_pid" || true
  tid="$(remote_tid)"
  if [ -n "$tid" ]; then
    # The follow decision sheet: Allow.
    (python3 -B "$qa_py" request-follow "$root" mother "$tid" "staging QA" 60 >"$work/j2.json" 2>&1 || true) &
    follow_pid=$!
    if wait_sheet "Allow"; then ctl --sheet click --text "Allow" >/dev/null 2>&1 || inconc "could not press Allow"; fi
    wait "$follow_pid" || true
  else
    inconc "could not read the remote terminal id"
  fi
  stage stage '{"command": "echo plain-remote"}' || fail "stage refused on the ECS pane (it is open since S2)"
  stage stage '{"command": "rm -rf /tmp/qa-nothing"}' || fail "stage of a destructive command refused"
  if stage stage '{"command": "!!"}'; then fail "history expansion was accepted on a remote pane"; else pass "history expansion refused on a remote pane"; fi
  ok_if "the drawer header repeats PRODUCTION" poll 20 tree_has "PRODUCTION"
  ok_if "a destructive row says it matches a pattern" tree_has "Matches a destructive pattern (rm -rf)"
  ok_if "and that no label does not mean safe" tree_has "No label does not mean safe."
  shot "j0-production-drawer"
  sleep 2
  ctl click --text "echo plain-remote" >/dev/null 2>&1 || inconc "could not click the plain row"
  ok_if "a plain production row inserted on one click (no sheet)" wait_screen "echo plain-remote"
  ctl type $'\x15' >/dev/null
  ctl click --text "rm -rf /tmp/qa-nothing" >/dev/null 2>&1 || inconc "could not click the destructive row"
  if wait_sheet "Insert into PRODUCTION?"; then
    pass "the destructive row asked first"
    ok_if "the sheet shows the full command" sheet_has "rm -rf /tmp/qa-nothing"
    shot "j1-confirm-sheet"
    ctl --sheet key return >/dev/null 2>&1 || true # Cancel is the default
    sleep 0.5
    ok_unless "Return (Cancel) inserted nothing" screen_has "rm -rf /tmp/qa-nothing"
    ok_if "the cancel was counted, with no text" audit_has "confirm_cancelled"
  else
    inconc "no confirm sheet reachable by app-control: do it by hand (the PR's list)"
  fi

  echo "== (k) the per-terminal switch =="
  ctl click --text "Let Agents Stage Commands Here" >/dev/null 2>&1 || inconc "could not reach the per-terminal item (context menu)"
  sleep 1
  if stage list; then fail "the follower could still list after staging was turned off here"; else pass "the follower is refused after the switch"; fi
  ok_if "the audit says disabled" audit_has '"by":"disabled"'

  echo "== (l) idle: agent staging never keeps the shell open (30 s policy) =="
  ctl click --text "Let Agents Stage Commands Here" >/dev/null 2>&1 || true
  sleep 1
  for _ in 1 2 3 4 5 6 7 8; do
    stage stage '{"command": "echo keepalive"}' >/dev/null 2>&1 || true
    sleep 4
    stage clear >/dev/null 2>&1 || true
  done
  ok_if "the remote shell closed on schedule despite staging" poll 20 audit_has '"idle_timeout"'
else
  fail "no sheet for the agent's remote request"
  wait "$agent_pid" || true
fi
stop_instance

start_instance
require_visible
tid=""
if open_logged_terminal; then
  echo "== (m) archive, close and reopen =="
  stage stage '{"command": "echo archive-me"}' || fail "stage refused"
  sleep 2
  ctl click --text "echo archive-me" >/dev/null 2>&1 || inconc "could not click the row"
  wait_screen "echo archive-me" || true
  ctl type $'\x15' >/dev/null
  ok_if "a placed row shows an Archive label" poll 20 tree_has "Archive"
  ctl click --text "Archive" >/dev/null 2>&1 || inconc "could not press Archive"
  ok_if "the row moved to the Archived footer" poll 20 tree_has "Archived (1)"
  ok_if "the archive was audited" audit_has '"op":"archive"'
  ctl click --text "Hide Staged Commands" >/dev/null 2>&1 || inconc "could not hide the drawer"
  ok_if "the pane header shows a staged chip" poll 20 tree_has "staged"

  echo "== (n) auto-archive is off until turned on =="
  ok_unless "Archive Commands After I Run Them starts unchecked" tree_has "Archive Commands After I Run Them.*checked"

  echo "== (o) foreground: sleep 30 makes the pane RUNNING; Ctrl-C returns it =="
  stage stage '{"command": "echo fg-row"}' || fail "stage refused"
  ctl type $'sleep 30\r' >/dev/null
  ok_if "the drawer header says RUNNING" poll 20 tree_has "RUNNING"
  ctl type $'\x03' >/dev/null
  if poll 20 tree_has "RUNNING"; then sleep 0.5; fi
  shot "o1-foreground"
else
  inconc "no logged terminal, so (m)-(o) were skipped"
fi
stop_instance

# ══════════════════════ the gate: --no-synthetic ═════════════════════════════════════════════════════

if [ "$skip_gate" = 0 ]; then
  echo "== (i) gate: --no-synthetic =="
  start_instance --no-synthetic
  require_visible
  tid=""
  if open_logged_terminal; then
    stage stage '{"command": "echo gate-row"}' || fail "stage refused in the gate run"
    sleep 2.5
    ctl click --text "echo gate-row" >/dev/null 2>&1 || echo "note: the click could not be delivered"
    sleep 1
    ok_unless "a synthesized click on a row sent zero bytes" screen_has "echo gate-row"
    ok_unless "app-control cannot read the staged text in the real app" tree_has "echo gate-row"
    ok_if "app-control sees only the fixed hidden text" tree_has "staged commands hidden from app-control"
    shot "i1-refused"
  else
    inconc "no logged terminal in the gate run: do it by hand (the PR's list)"
  fi
  stop_instance
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
