#!/usr/bin/env bash
# Live QA of terminal slice 1e (mirroring across windows, app relaunch, daemon stopped) in the ISOLATED QA
# instance only: a worktree nostromd plus a com.hammer.nostromo.qa clone of the app, started and stopped by
# qa-instance.sh. Never the user's app, daemon or ~/.nostromo. Only the QA clone and the QA daemon are killed or
# restarted, each by the pid recorded in $QA_ROOT/state.json (lib/terminal_restart.py checks it is still the process
# the instance started).
#
#   scripts/qa/terminal-mirror-relaunch.sh
#
# (a) mirror:    a terminal and a second window (Debug > Open Second Window (QA), QA builds only) on the same
#                focus. `echo MIRROR-1` in window 0, `echo MIRROR-2` in window 1: both windows show both lines once
#                (a doubled keystroke would change the output line, so an exact-line count of 1 proves one input per
#                key). The window typed in last is the driver: `stty size` there equals the "Mirroring at CxR" hint
#                in the other window, and the sizes follow the driver when the other window types.
# (b) relaunch:  seq 1 3000; echo RELAUNCH-MARK, kill only the QA clone, start it again with the same environment:
#                the pane re-attaches with RELAUNCH-MARK on screen and earlier lines in scrollback. Again with vim open.
# (c) daemon:    SIGTERM only the QA daemon: "Nostromo daemon stopped. This shell has ended."; start it again with the
#                same HOME: the pane says "Nostromo daemon restarted" with Restart; Restart gives a working prompt.
#
# The terminal's screen text is read through its accessibility value (`nostromo-app ax NostromoTerminalView`), which
# carries text only in a QA build with the synthetic-input relaxation (the default for `start`).
# Needs a logged-in, awake display. Exits 0 PASS, 1 FAIL, 3 INCONCLUSIVE. Screenshots go to a private temp
# directory (printed; removed at the end unless KEEP=1).
# shellcheck disable=SC2329  # the predicates below are called through wait_for
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
instance="$here/qa-instance.sh"
restart="$here/lib/terminal_restart.py"
app="$here/../../bin/nostromo-app"

work="$(mktemp -d "${TMPDIR:-/tmp}/nostromo-terminal-mirror-qa.XXXXXX")"
chmod 700 "$work"
echo "evidence directory: $work"
fails=0
inconclusive=0
root=""
sock=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  [ -z "$root" ] || "$instance" stop "$root" >/dev/null 2>&1 || true
  [ "${KEEP:-0}" = 1 ] || rm -rf "$work"
}
trap cleanup EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
inconc() { echo "INCONCLUSIVE: $*"; inconclusive=$((inconclusive + 1)); }

ctl() { "$app" --socket "$sock" "$@"; }
qa_restart() { python3 -B -I "$restart" "$1" "$root"; }

out="$("$instance" start)"
echo "$out"
root="$(sed -n 's/^QA_ROOT=//p' <<<"$out")"
[ -n "$root" ] || { echo "FAIL: no QA_ROOT printed"; exit 1; }
sock="$root/app-control.sock"

require_visible() {
  local windows
  windows="$(ctl windows)"
  if grep -Eq '"(alpha)": *0([^.0-9]|$)|"visible": *false' <<<"$windows" || [ -z "$windows" ] || [ "$windows" = "[]" ]; then
    echo "INCONCLUSIVE: the QA window is not visible (display locked or asleep)"
    echo "RESULT: INCONCLUSIVE"
    echo "Manual checklist: see the PR body (two windows mirror, relaunch with top running, daemon stopped overlay)."
    exit 3
  fi
}

# Screen text of the terminal in window $1 (accessibility value; empty unless a QA build with synthetic input).
screen_text() {
  ctl -w "$1" ax NostromoTerminalView 2>/dev/null | python3 -I -c 'import json,sys
try:
    print(json.load(sys.stdin).get("value") or "")
except ValueError:
    pass'
}

# How many lines of window $1's screen are exactly $2, and how many contain $2.
exact_lines() { screen_text "$1" | grep -c -x -- "$2" || true; }
containing_lines() { screen_text "$1" | grep -c -- "$2" || true; }

tree_has() { ctl -w "$1" tree --depth 60 2>/dev/null | grep -q -- "$2"; }

# Poll (20 s by default) until the command given as the remaining arguments succeeds.
wait_for() {
  local tries="$1"
  shift
  for _ in $(seq 1 "$tries"); do
    "$@" && return 0
    sleep 0.5
  done
  return 1
}

has_line() { [ "$(exact_lines "$1" "$2")" -ge 1 ]; }
has_text() { [ "$(containing_lines "$1" "$2")" -ge 1 ]; }
window_count() { ctl windows 2>/dev/null | grep -c '"frame"' || true; }
pane_count() { ctl -w "$1" tree --depth 60 2>/dev/null | grep -c 'TerminalPaneHostView' || true; }
has_pane() { [ "$(pane_count "$1")" -ge 1 ]; }
has_two_windows() { [ "$(window_count)" -ge 2 ]; }

shot() { ctl -w "$1" screenshot "$work/$2.png" >/dev/null 2>&1 && echo "screenshot: $work/$2.png" || echo "WARN: screenshot $2 failed"; }

# `stty size` in window $1 prints "ROWS COLS"; echo it back as "COLSxROWS" (the form the mirror hint uses).
shell_size() {
  local marker="SIZE-$RANDOM"
  ctl -w "$1" type "echo $marker \$(stty size)"$'\r' >/dev/null
  wait_for 20 has_text "$1" "$marker [0-9]" || return 1
  screen_text "$1" | grep -- "^$marker [0-9]" | tail -1 | awk '{ print $3 "x" $2 }'
}

# The "CxR" in window $1's mirror hint, or nothing when it is not a mirror.
mirror_hint_size() {
  ctl -w "$1" tree --depth 60 2>/dev/null | grep -o 'Mirroring at [0-9]*.[0-9]*' | head -1 | sed 's/^Mirroring at //; s/\xc3\x97/x/'
}

# ───────────────────────────── (a) mirror ─────────────────────────────

require_visible
ctl activate >/dev/null 2>&1 || true

echo "== (a) a terminal in window 0, a second window on the same focus =="
ctl key t --mod cmd >/dev/null
if wait_for 40 has_pane 0; then pass "Cmd-T opened a terminal in window 0"; else fail "no terminal pane in window 0"; fi
sleep 1.5
ctl key n --mod ctrl,alt,cmd >/dev/null
if wait_for 40 has_two_windows; then pass "Debug > Open Second Window (QA) opened window 1"; else fail "no second window"; fi
if wait_for 40 has_pane 1; then pass "window 1 shows the focus's terminal too"; else fail "no terminal pane in window 1"; fi
sleep 1.5
shot 0 "01-window0"
shot 1 "02-window1"

echo "== (a) keystrokes from window 0, then from window 1: each line once in both windows =="
ctl -w 0 type $'echo MIRROR-1\r' >/dev/null
for w in 0 1; do
  if wait_for 30 has_line "$w" MIRROR-1; then
    n="$(exact_lines "$w" MIRROR-1)"; c="$(containing_lines "$w" 'echo MIRROR-1')"
    if [ "$n" -eq 1 ] && [ "$c" -eq 1 ]; then pass "window $w shows echo MIRROR-1 and its output once each"; else fail "window $w: MIRROR-1 output x$n, command x$c (expected 1 and 1: a doubled or lost keystroke)"; fi
  else
    fail "window $w never showed MIRROR-1"
  fi
done
ctl -w 1 click --text "type here to drive" >/dev/null 2>&1 || ctl -w 1 key a >/dev/null   # a click (or a key) in window 1 makes it the driver
ctl -w 1 type $'echo MIRROR-2\r' >/dev/null
for w in 0 1; do
  if wait_for 30 has_line "$w" MIRROR-2; then
    n="$(exact_lines "$w" MIRROR-2)"
    if [ "$n" -eq 1 ]; then pass "window $w shows MIRROR-2 once"; else fail "window $w: MIRROR-2 output x$n (expected 1)"; fi
  else
    fail "window $w never showed MIRROR-2"
  fi
done
shot 0 "03-mirror-window0"
shot 1 "04-driver-window1"

echo "== (a) the window typed in last sets the size; the other shows it without reflow =="
size1="$(shell_size 1 || true)"
hint0="$(mirror_hint_size 0)"
if [ -n "$size1" ] && [ "$size1" = "$hint0" ]; then
  pass "driver window 1 has a ${size1} shell; window 0 says it mirrors at ${hint0}"
else
  fail "window 1 shell size '${size1}' vs window 0 mirror hint '${hint0}'"
fi
if [ -z "$(mirror_hint_size 1)" ]; then pass "the driver window shows no mirror hint"; else fail "window 1 (driver) shows a mirror hint"; fi
ctl -w 0 click --text "type here to drive" >/dev/null 2>&1 || ctl -w 0 key a >/dev/null
size0="$(shell_size 0 || true)"
hint1="$(mirror_hint_size 1)"
if [ -n "$size0" ] && [ "$size0" = "$hint1" ]; then
  pass "window 0 took over: ${size0} shell; window 1 mirrors at ${hint1}"
else
  fail "window 0 shell size '${size0}' vs window 1 mirror hint '${hint1}'"
fi
if [ "$size0" != "$size1" ]; then pass "the two windows give different sizes (${size0} and ${size1}), so the size really followed the typist"; else inconc "both windows have the same size (${size0}); the follow-the-typist check proves nothing here"; fi
shot 0 "05-driver-window0"
shot 1 "06-mirror-window1"

# ───────────────────────────── (b) relaunch ─────────────────────────────

echo "== (b) relaunch the QA clone with output in scrollback =="
ctl -w 0 type $'seq 1 3000; echo RELAUNCH-MARK\r' >/dev/null
if wait_for 80 has_line 0 RELAUNCH-MARK; then pass "RELAUNCH-MARK printed"; else fail "RELAUNCH-MARK never printed"; fi
qa_restart kill-app
qa_restart start-app
require_visible
ctl activate >/dev/null 2>&1 || true
if wait_for 60 has_pane 0; then pass "the pane is back after the relaunch"; else fail "no terminal pane after the relaunch"; fi
if wait_for 60 has_line 0 RELAUNCH-MARK; then pass "re-attached: RELAUNCH-MARK is on screen"; else fail "RELAUNCH-MARK missing after the relaunch"; fi
if has_line 0 1500; then pass "scrollback intact: line 1500 of the seq is there"; else fail "scrollback lost: line 1500 missing after the relaunch"; fi
shot 0 "07-relaunched"

echo "== (b) relaunch with vim open =="
ctl -w 0 click --text "Terminal" >/dev/null 2>&1 || true
ctl -w 0 type $'vim -u NONE\r' >/dev/null
sleep 2
qa_restart kill-app
qa_restart start-app
require_visible
ctl activate >/dev/null 2>&1 || true
wait_for 60 has_pane 0 || fail "no terminal pane after the second relaunch"
sleep 3
tildes="$(exact_lines 0 '~')"
shot 0 "08-vim-relaunched"
if [ "$tildes" -ge 5 ]; then pass "vim redrew after the relaunch ($tildes empty-line tildes on screen)"; else fail "vim did not come back: only $tildes tilde lines on screen (screenshot 08)"; fi
ctl -w 0 key escape >/dev/null
ctl -w 0 type $':q\r' >/dev/null
sleep 1
ctl -w 0 type $'echo AFTER-VIM\r' >/dev/null
if wait_for 30 has_line 0 AFTER-VIM; then pass "vim quit to the shell"; else fail "the shell did not come back after :q"; fi

# ───────────────────────────── (c) daemon stopped ─────────────────────────────

echo "== (c) stop only the QA daemon =="
qa_restart kill-daemon
if wait_for 60 tree_has 0 "Nostromo daemon stopped"; then pass "daemon down: the pane says 'Nostromo daemon stopped. This shell has ended.'"; else fail "no daemon-stopped overlay after the daemon went down"; fi
shot 0 "09-daemon-stopped"
qa_restart start-daemon
if wait_for 200 tree_has 0 "Nostromo daemon restarted"; then pass "daemon back: '[process ended: Nostromo daemon restarted]'"; else fail "no 'daemon restarted' overlay after the daemon came back (the client reconnects within 30 s)"; fi
shot 0 "10-daemon-restarted"
ctl -w 0 click --text "Restart" >/dev/null 2>&1 || fail "could not click Restart"
sleep 2
ctl -w 0 type $'echo RESTART-OK\r' >/dev/null
if wait_for 40 has_line 0 RESTART-OK; then pass "Restart gave a working prompt"; else fail "no working prompt after Restart"; fi
shot 0 "11-restarted"

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
