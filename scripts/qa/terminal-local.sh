#!/usr/bin/env bash
# Live QA of the terminal pane (slice 1d) in the ISOLATED QA instance only: a worktree nostromd plus a
# com.hammer.nostromo.qa clone of the app, started and stopped by qa-instance.sh. Never the user's app,
# daemon or ~/.nostromo.
#
#   scripts/qa/terminal-local.sh [--skip-negative]
#
# Positive run (synthetic input ON, the QA relaxation): Cmd-T opens a TerminalPaneHostView with the
# keyboard in it; typing echoes; truecolor; seq 1 12000; vim and :q; 200 typed characters give latency
# numbers; `exit 3` shows the overlay; Restart brings the shell back; `exit` removes the pane; a terminal an
# agent opens (the QA daemon's MCP socket, Hello pty_id = a built-in focus tag) does not take the keyboard.
# The terminal's screen text is read through its accessibility value (`nostromo-app ax NostromoTerminalView`).
# Negative run (--no-synthetic): Cmd-T still opens a terminal, but synthesized `type`, the close
# shortcut (shift-cmd-W) and the x button do nothing, and the QA daemon's audit log
# ($QA_ROOT/home/.nostromo/audit/terminal.jsonl) holds `refused` entries with channel app_control.
#
# Needs a logged-in, awake display (the clone's windows must be on screen). Exits 0 PASS, 1 FAIL,
# 3 INCONCLUSIVE (locked or asleep display, or a check this machine cannot read). Screenshots and trees go to a
# private temp directory (printed; removed at the end unless KEEP=1).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
instance="$here/qa-instance.sh"
app="$repo/bin/nostromo-app"
focus_tag="${QA_FOCUS_TAG:-mother}"   # a built-in focus tag: the Hello pty_id of the agent-open check
skip_negative=0
for a in "$@"; do [ "$a" = "--skip-negative" ] && skip_negative=1; done

work="$(mktemp -d "${TMPDIR:-/tmp}/nostromo-terminal-qa.XXXXXX")"
chmod 700 "$work"
echo "evidence directory: $work"
fails=0
inconclusive=0
root=""
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

# Start an instance ("$@" = start flags), set $root and $sock.
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

# The visible windows must be on screen, or nothing below means anything.
require_visible() {
  local windows
  windows="$(ctl windows)"
  if grep -Eq '"(alpha)": *0([^.0-9]|$)|"visible": *false' <<<"$windows" || [ -z "$windows" ] || [ "$windows" = "[]" ]; then
    echo "INCONCLUSIVE: the QA window is not visible (display locked or asleep)"
    stop_instance
    echo "RESULT: INCONCLUSIVE"
    echo "Manual checklist: see the PR body (Cmd-T, vim/less/top/tinker, truecolor, scrollback, Cmd-F, exit 3 overlay)."
    exit 3
  fi
}

panes() { ctl tree --depth 60 2>/dev/null | grep -c 'TerminalPaneHostView' || true; }

# Poll until the number of terminal panes is -ge ("ge") or -eq ("eq") $2, within 20 s.
wait_panes() {
  local op="$1" want="$2" n
  for _ in $(seq 1 40); do
    n="$(panes)"
    case "$op" in
      ge) [ "$n" -ge "$want" ] && return 0 ;;
      eq) [ "$n" -eq "$want" ] && return 0 ;;
    esac
    sleep 0.5
  done
  return 1
}

# The first terminal view's screen text (its accessibility value), newest 20,000 characters.
screen_text() {
  ctl ax NostromoTerminalView 2>/dev/null | python3 -I -c 'import json,sys
try:
    print(json.load(sys.stdin).get("value") or "")
except ValueError:
    pass'
}

# How many times TEXT is on the first terminal's screen.
occurrences() { screen_text | grep -o -- "$1" | wc -l | tr -d ' ' || true; }

# True when the overlay or any other label in the view tree says TEXT.
tree_has() { ctl tree --depth 60 2>/dev/null | grep -q -- "$1"; }

wait_text() {
  local text="$1" tries="${2:-30}"
  for _ in $(seq 1 "$tries"); do
    [ "$(occurrences "$text")" -ge 1 ] && return 0
    sleep 0.5
  done
  return 1
}

wait_tree() {
  local text="$1" tries="${2:-30}"
  for _ in $(seq 1 "$tries"); do
    tree_has "$text" && return 0
    sleep 0.5
  done
  return 1
}

# The class name of the key window's first responder.
first_responder() {
  ctl windows 2>/dev/null | python3 -I -c 'import json,sys
try:
    data = json.load(sys.stdin)
    windows = data if isinstance(data, list) else data.get("windows", [])
    print(next((w.get("firstResponder", "") for w in windows if w.get("isKey") or w.get("key")), (windows[0].get("firstResponder", "") if windows else "")))
except ValueError:
    pass'
}

shot() { ctl screenshot "$work/$1.png" >/dev/null 2>&1 && echo "screenshot: $work/$1.png" || echo "WARN: screenshot $1 failed"; }

audit_file() { echo "$root/home/.nostromo/audit/terminal.jsonl"; }

# ───────────────────────────── positive run ─────────────────────────────

start_instance
require_visible
ctl activate >/dev/null 2>&1 || true

echo "== Cmd-T opens a terminal, with the keyboard in it =="
ctl key t --mod cmd >/dev/null
if wait_panes ge 1; then pass "Cmd-T: a TerminalPaneHostView is in the tree"; else fail "Cmd-T: no TerminalPaneHostView after 20 s"; fi
sleep 1.5   # the shell prints its prompt
fr="$(first_responder)"
if [ "$fr" = "NostromoTerminalView" ]; then pass "the opened terminal holds the keyboard"; else fail "first responder is '$fr', not the new terminal"; fi
shot "01-opened"

echo "== typing echoes =="
ctl type $'echo QA-HELLO\r' >/dev/null
if wait_text "QA-HELLO" 20; then
  n="$(occurrences QA-HELLO)"
  if [ "$n" -ge 2 ]; then pass "QA-HELLO twice (command and output): $n"; else fail "QA-HELLO seen $n time(s), expected the command and its output"; fi
else
  fail "QA-HELLO never reached the terminal's screen text (screenshot 02-echo)"
fi
shot "02-echo"

echo "== truecolor =="
ctl type $'printf \'\\033[38;2;255;100;0mTRUECOLOR-OK\\033[0m\\n\'\r' >/dev/null
if wait_text "TRUECOLOR-OK" 20; then pass "truecolor line printed (look for orange text in 03-truecolor.png)"; else fail "TRUECOLOR-OK missing"; fi
shot "03-truecolor"

echo "== scrollback: seq 1 12000 =="
ctl type $'seq 1 12000\r' >/dev/null
if wait_text "12000" 60; then pass "seq 1 12000 reached its last line"; else fail "12000 never appeared"; fi
shot "04-seq"

echo "== vim =="
ctl type $'vim -u NONE\r' >/dev/null
sleep 2
shot "05-vim"
ctl key escape >/dev/null
ctl type $':q\r' >/dev/null
sleep 1
ctl type $'echo AFTER-VIM\r' >/dev/null
if wait_text "AFTER-VIM" 20; then pass "vim opened and :q returned to the shell"; else fail "the shell did not come back after :q"; fi

echo "== latency: 200 typed characters =="
ctl type "$(printf 'a%.0s' $(seq 1 200))" >/dev/null
sleep 2
ctl key u --mod ctrl >/dev/null   # clear the line
latency="$(/usr/bin/log show --last 3m --style compact --predicate "subsystem == \"com.hammer.nostromo\" AND category == \"terminal\" AND processImagePath CONTAINS \"$root\"" 2>/dev/null | grep 'terminal latency' | tail -1 || true)"
if [ -n "$latency" ]; then
  echo "LATENCY: ${latency#*terminal latency}"
else
  inconc "no latency line in the unified log: read Debug > Copy terminal latency stats by hand (target p95 < 30 ms)"
fi

echo "== exit 3 shows the overlay; Restart; exit closes =="
ctl type $'exit 3\r' >/dev/null
if wait_tree "exited with code 3" 30; then pass "overlay: process exited with code 3"; else fail "no 'exited with code 3' overlay"; fi
shot "06-exited"
ctl click --text "Restart" >/dev/null 2>&1 || fail "could not click Restart"
sleep 2
ctl type $'echo RESTARTED\r' >/dev/null
if wait_text "RESTARTED" 20; then pass "Restart brought the shell back in the same pane"; else fail "the shell did not come back after Restart"; fi
ctl type $'exit\r' >/dev/null
if wait_panes eq 0; then pass "exit 0 closed the pane"; else fail "the pane is still there after exit"; fi
shot "07-after-exit"

echo "== an agent-opened terminal does not take the keyboard =="
before_fr="$(first_responder)"
if out="$(python3 -B "$here/lib/terminal_qa.py" open-terminal "$root" "$focus_tag" 2>&1)"; then
  echo "$out"
  if wait_panes ge 1; then
    sleep 1
    after_fr="$(first_responder)"
    if [ "$after_fr" != "NostromoTerminalView" ]; then
      pass "the agent-opened pane did not take the keyboard (first responder '$before_fr' -> '$after_fr')"
    else
      fail "the agent-opened terminal took the keyboard"
    fi
    shot "08-agent-open"
  else
    fail "the agent-opened terminal did not appear"
  fi
else
  inconc "could not open a terminal through the QA daemon's MCP socket: $out"
fi

stop_instance

# ───────────────────────────── negative run ─────────────────────────────

if [ "$skip_negative" = 0 ]; then
  echo "== negative run: --no-synthetic =="
  start_instance --no-synthetic
  require_visible
  ctl activate >/dev/null 2>&1 || true
  ctl key t --mod cmd >/dev/null
  if wait_panes ge 1; then pass "Cmd-T still opens a terminal without the relaxation"; else fail "Cmd-T did not open a terminal"; fi
  sleep 1.5
  ctl type $'echo SHOULD-NOT-APPEAR\r' >/dev/null
  sleep 2
  shot "09-negative-typed"
  if [ "$(occurrences SHOULD-NOT-APPEAR)" -eq 0 ] && ! tree_has SHOULD-NOT-APPEAR; then pass "synthesized type reached nothing (absent from the screen text and the tree)"; else fail "SHOULD-NOT-APPEAR is on screen: synthetic typing got through"; fi
  before="$(panes)"
  ctl key w --mod cmd,shift >/dev/null
  ctl click --text "Close terminal" >/dev/null 2>&1 || ctl click --text $'×' >/dev/null 2>&1 || echo "note: could not locate the x button to click"
  sleep 1.5
  after="$(panes)"
  if [ "$before" = "$after" ] && [ "$after" -ge 1 ]; then pass "shift-cmd-W and the x left the pane ($after pane(s))"; else fail "the pane count changed from $before to $after"; fi
  audit="$(audit_file)"
  if [ -f "$audit" ] && grep '"refused"' "$audit" | grep -q 'app_control'; then
    pass "the daemon audit has refused {channel: app_control}: $(grep -c 'app_control' "$audit") line(s)"
  else
    fail "no refused/app_control line in $audit"
  fi
  shot "10-negative-after"
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
