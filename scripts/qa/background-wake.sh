#!/usr/bin/env bash
# Live check of background wake turns (BA6a-BA6c) in the ISOLATED QA instance only: a worktree daemon plus the
# cloned com.hammer.nostromo.qa app, a temp HOME and the fake CLI (no model, no tokens). Never the user's app,
# daemon or sessions. Needs a logged-in, awake display.
#
#   scripts/qa/background-wake.sh
#
# A QA agent session runs the fake CLI's `WAKE:basic:<dir>` cue: turn 1 starts a background shell (`qa-sleep 60`)
# and a Monitor (`qa-ticker`); then, one file at a time (`<dir>/wake-1` .. `wake-5`, created by this script), the
# fake CLI wakes the session with a Monitor event, a shell completion, ONE hostile failed shell (U+202E and
# U+3164 in its title: its marker line must show the sanitised title), two back-to-back notifications and a
# three-element notification. For each wake the script checks:
#   * `transcript-anchor` before and after: following the tail, bottomOffsetPt == 0 after;
#   * the muted marker text (see lib/background_wake.py MARKERS) and the reply `ack <k>`.
# Right after wake 1 (marker 1 and turn 1's rows are still near the bottom, so visible): the marker's
# accessibility label, the row's "background task running" label, and a click on marker 1, which opens the
# Monitor's task window (`tasks list` window_open true); Escape closes it BEFORE wake 2 (INCONCLUSIVE for that
# line if Escape cannot reach the panel, never a FAIL). At the end: no raw notification text, no sentinels, no
# U+202E or U+3164 anywhere in the window.
#
# Output is PASS/FAIL lines with fixed strings: the script never prints transcript text it did not put there.
# Refuses (exit 2) when NOSTROMO_QA_CLAUDE_BIN is set: a real model would spend tokens.
# Exits 0 PASS, 1 FAIL, 2 usage or refused, 3 INCONCLUSIVE (display locked or asleep: the window is not visible).
# KEEP=1 keeps the QA root. QA_INSTANCE / QA_APP override the instance script and the app-control CLI (the
# self-tests point them at fakes).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
instance="${QA_INSTANCE:-$here/qa-instance.sh}"
app="${QA_APP:-$repo/bin/nostromo-app}"
helper="$here/lib/background_wake.py"
checks="$here/lib/card_checks.py"
qa_root_marker=".nostromo-qa-root"

[ "$#" -eq 0 ] || { echo "usage: background-wake.sh (no arguments)" >&2; exit 2; }

# This script promises no tokens: qa-instance.sh would hand a real CLI to the QA daemon when this is set.
if [ -n "${NOSTROMO_QA_CLAUDE_BIN:-}" ]; then
  echo "REFUSING TO RUN: NOSTROMO_QA_CLAUDE_BIN is set, so the QA session would run a real model and spend tokens." >&2
  echo "This script uses the fake CLI only. Unset NOSTROMO_QA_CLAUDE_BIN (it is for tracker-discoverability.sh)." >&2
  exit 2
fi

# A real focuses.json that already carries a QA marker is the leftover of an earlier breach: refuse, by file
# name only (never the content).
real_focuses="$HOME/.nostromo/focuses.json"
if [ -f "$real_focuses" ] && grep -qE 'FIXTURE:|WAKE:basic:|com\.hammer\.nostromo\.qa|nostromo-qa-|cody-qa-|qa-approvals' "$real_focuses"; then
  echo "REFUSING TO RUN: $real_focuses already carries a QA marker (FIXTURE:, WAKE:basic:, the QA bundle id, a QA root path, cody-qa-, qa-approvals)." >&2
  echo "A QA run once wrote into your real ~/.nostromo. Remove the QA entries from that file, then run again." >&2
  exit 2
fi

# A control socket that is not inside a QA root is the user's own app: never talk to it.
if [ -n "${NOSTROMO_APP_CONTROL_SOCKET:-}" ]; then
  if [ ! -f "$(dirname "$NOSTROMO_APP_CONTROL_SOCKET")/$qa_root_marker" ]; then
    echo "REFUSING TO RUN: NOSTROMO_APP_CONTROL_SOCKET points outside a QA root (no $qa_root_marker beside it)." >&2
    echo "This script only talks to the socket of the QA instance it starts itself. Unset the variable." >&2
    exit 2
  fi
  unset NOSTROMO_APP_CONTROL_SOCKET
fi

root=""
sock=""
tag=""
label=""
scratch=""
instance_up=0
reported=0
verdict=PASS
inconclusive=0
fail_count=0
start_out="$(mktemp "${TMPDIR:-/tmp}/qa-wake.XXXXXX")"

# Polling naps; the self-tests set QA_SLEEP_SCALE=0 so a fake app is never waited for.
nap() { [ "${QA_SLEEP_SCALE:-1}" = 0 ] || sleep "$1"; }
tries() { if [ "${QA_SLEEP_SCALE:-1}" = 0 ]; then echo 2; else echo "$1"; fi; }
ctl() { "$app" --socket "$sock" "$@"; }
pass() { echo "PASS $1: $2"; }
fail() { verdict=FAIL; fail_count=$((fail_count + 1)); echo "FAIL $1: $2"; }
# check ID DETAIL CMD...: PASS when CMD succeeds (its output is dropped: it may hold window text), else FAIL.
check() {
  local id="$1" detail="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then pass "$id" "$detail"; else fail "$id" "$detail"; fi
}

# As check, for a look at content that may have scrolled out of a small QA window (estimated row heights, no
# scroll verb): a FAIL says so instead of blaming the app.
check_old() {
  local id="$1" detail="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then pass "$id" "$detail"; else fail "$id" "$detail (may be scrolled out of view: enlarge the QA window)"; fi
}

adopt_root() {
  local r
  [ "$instance_up" = 0 ] || return 0
  r="$(sed -n 's/^QA_ROOT=//p' "$start_out" 2>/dev/null | head -n 1)" || r=""
  [ -n "$r" ] || return 0
  root="$r"
  sock="$root/app-control.sock"
  instance_up=1
}

# Stop the QA instance (the isolation guard runs inside `stop`); a guard failure is a FAIL.
stop_instance() {
  [ "$instance_up" = 1 ] || return 0
  instance_up=0
  local stopped_root="$root"
  root=""
  if ! KEEP="${KEEP:-}" "$instance" stop "$stopped_root"; then fail "isolation-guard" "the isolation guard failed at stop"; fi
}

finish() {
  local rc="$1" name
  reported=1
  stop_instance || true
  [ "$verdict" = PASS ] || rc=1
  case "$rc" in 0) name=PASS ;; 3) name=INCONCLUSIVE ;; *) name=FAIL ;; esac
  echo "RESULT: $name ($fail_count failed)"
  rm -f -- "$start_out"
  exit "$rc"
}
# shellcheck disable=SC2329  # invoked by the EXIT trap
on_exit() {
  local rc=$?
  if [ "$reported" != 1 ]; then
    adopt_root
    fail "script" "unexpected error (exit $rc)"
    finish 1
  fi
}
trap on_exit EXIT

abort_fail() { fail "$1" "$2"; finish 1; }

windows_hidden() { grep -Eq '"(alpha)": *0([^.0-9]|$)|"visible": *false' <<<"$1"; }

# --- start the QA instance, a QA agent session, its composer ------------------------------------------
"$instance" start >"$start_out" || { adopt_root; abort_fail "start" "the QA instance failed to start"; }
cat "$start_out"
adopt_root
[ -n "$root" ] || abort_fail "start" "no QA_ROOT printed"
# Even a script of ours must never drive a socket outside the root it just started.
[ -f "$root/$qa_root_marker" ] || abort_fail "start" "QA_ROOT has no $qa_root_marker marker: refusing to drive it"

windows="$(ctl windows)"
for _ in $(seq 1 "$(tries 90)"); do
  windows_hidden "$windows" || break
  nap 0.5
  windows="$(ctl windows)"
done
if windows_hidden "$windows"; then
  echo "INCONCLUSIVE: window not visible after 45 s (display locked or asleep)"
  finish 3
fi

focus_out="$("$instance" focus "$root" 2>&1)" || { echo "$focus_out"; abort_fail "focus" "could not create the QA agent session"; }
echo "$focus_out"
tag="$(sed -n 's/^QA_FOCUS_TAG=//p' <<<"$focus_out")"
label="$(sed -n 's/^QA_FOCUS_LABEL=//p' <<<"$focus_out")"
[ -n "$label" ] || abort_fail "focus" "no QA_FOCUS_LABEL printed"
focus_args=()
[ -z "$tag" ] || focus_args=(--focus "$tag")
ctl wait "$label" --timeout 30 >/dev/null || abort_fail "focus" "the QA session's sidebar row did not appear within 30 s"
ctl click --text "$label" >/dev/null || abort_fail "focus" "could not select the QA session's sidebar row"
ctl wait "Message…" --timeout 15 >/dev/null || abort_fail "focus" "no composer within 15 s of selecting the QA session"

# The composer takes the click, then the cue: poll the read-only hittest until the first responder is the chat
# composer; up to 3 clicks.
focus_composer() {
  local hit
  for _ in 1 2 3; do
    ctl click --text "Message…" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      hit="$(ctl hittest 1 1 2>/dev/null)" || hit="{}"
      if python3 "$checks" composer <<<"$hit" 2>/dev/null; then return 0; fi
      nap 0.25
    done
  done
  return 1
}

# Scratch directory INSIDE the QA root: the fake CLI polls it for wake-<k>, and it goes away with the root.
scratch="$(mktemp -d "$root/wake.XXXXXX")"

# --- turn 1: a background shell and a Monitor ---------------------------------------------------------
focus_composer || abort_fail "composer" "the chat composer never became the first responder"
ctl type "WAKE:basic:$scratch" >/dev/null
ctl key $'\r' --key-code 36 >/dev/null

chip_seen=0
for _ in $(seq 1 "$(tries 120)"); do
  if ctl tasks chip "${focus_args[@]+"${focus_args[@]}"}" 2>/dev/null | python3 "$helper" chip-running; then chip_seen=1; break; fi
  nap 0.25
done
if [ "$chip_seen" = 1 ]; then pass "chip-running" "the Background activity chip reads running"; else abort_fail "chip-running" "the chip never read running within 30 s"; fi

listing="$(ctl tasks list "${focus_args[@]+"${focus_args[@]}"}")" || abort_fail "tasks-list" "tasks list failed"
check "task-monitor" 'running Monitor "qa-ticker" is listed' python3 "$helper" has-task Monitor qa-ticker <<<"$listing"
check "task-shell" 'running Shell "qa-sleep 60" is listed' python3 "$helper" has-task Shell "qa-sleep 60" <<<"$listing"

# --- helpers: click marker 1 opens the Monitor's task window; Escape closes it (run right after wake 1) ----
marker1="$(python3 "$helper" marker 1)"
window_state() { ctl tasks list --all "${focus_args[@]+"${focus_args[@]}"}" | python3 "$helper" window-open qa-mon1; }
wait_window() {
  local want="$1" state
  for _ in $(seq 1 "$(tries 40)"); do
    state="$(window_state 2>/dev/null)" || state=error
    [ "$state" != "$want" ] || return 0
    nap 0.25
  done
  return 1
}
# --- the five wake groups -----------------------------------------------------------------------------
for k in 1 2 3 4 5; do
  marker="$(python3 "$helper" marker "$k")"
  anchor="$(ctl transcript-anchor "${focus_args[@]+"${focus_args[@]}"}")" || anchor="{}"
  check "wake-$k-anchor-before" "the transcript follows the tail before the wake" python3 "$helper" anchor-before <<<"$anchor"
  : >"$scratch/wake-$k"
  if ctl wait "$marker" --timeout 20 >/dev/null 2>&1; then pass "wake-$k-marker" "marker text shown: $marker"; else fail "wake-$k-marker" "marker text not shown within 20 s: $marker (the new row sits at the bottom; if the window is tiny, enlarge the QA window)"; fi
  if ctl wait "ack $k" --timeout 20 >/dev/null 2>&1; then pass "wake-$k-reply" "reply 'ack $k' shown"; else fail "wake-$k-reply" "reply 'ack $k' not shown within 20 s"; fi
  anchor="$(ctl transcript-anchor "${focus_args[@]+"${focus_args[@]}"}")" || anchor="{}"
  check "wake-$k-anchor-after" "following the tail, bottomOffsetPt == 0 after the wake" python3 "$helper" anchor-after <<<"$anchor"
  if [ "$k" = 1 ]; then
    # Marker 1 and turn 1's tool rows are still near the bottom: check them now, before later wakes scroll them away.
    check_old "ax-marker-label" "marker label 'Background Monitor: new output, qa-ticker.' found" \
      python3 "$helper" found < <(ctl find "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import background_wake as b; print(b.MARKER_AX_LABEL)' "$here/lib")")
    check_old "ax-row-label" "a row labelled 'background task running' found (the Monitor is still running)" \
      python3 "$helper" found < <(ctl find "background task running")
    # Marker 1 is at the bottom and visible now, and nothing has scrolled it away: click it, then close the
    # window again before wake 2.
    if ctl click --text "$marker1" >/dev/null 2>&1 && wait_window true; then
      pass "marker-click-opens-window" "tasks list shows window_open true for the Monitor"
      ctl key $'\e' --key-code 53 >/dev/null 2>&1 || true
      if wait_window false; then
        pass "escape-closes-window" "window_open is false after Escape"
      else
        inconclusive=1
        monitor_window_open=1
        echo "INCONCLUSIVE escape-closes-window: window_open stayed true after Escape (Escape may not reach the panel); the Monitor window stays open, so the 'absent' scan is skipped"
      fi
    else
      fail "marker-click-opens-window" "clicking marker 1 did not make window_open true within 10 s (may be scrolled out of view: enlarge the QA window)"
    fi
  fi
done

# --- nothing raw is drawn ------------------------------------------------------------------------------
while IFS= read -r name; do
  if [ "${monitor_window_open:-0}" = 1 ]; then
    echo "SKIPPED absent-$name: the Monitor window is still open, its text could match"
    continue
  fi
  text="$(python3 "$helper" absent "$name")"
  check "absent-$name" "not drawn anywhere in the window" ctl expect "$text" --absent
done < <(python3 "$helper" absent-names)

if [ "$verdict" = PASS ] && [ "$inconclusive" = 1 ]; then echo "NOTE: one line was inconclusive; the rest passed"; fi
finish 0
