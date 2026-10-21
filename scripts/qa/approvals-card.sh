#!/usr/bin/env bash
# Live QA of the approval card (AP2a) in the ISOLATED QA instance only: a worktree daemon plus the
# cloned com.hammer.nostromo.qa app, a temp HOME, the fake CLI. Never the user's app, daemon or sessions.
#
#   scripts/qa/approvals-card.sh [--no-synthetic] [FIXTURE ...]     (default fixtures: simple_rm heredoc_300 bidi)
#
# Synthetic input ON (default): types `FIXTURE:<name>` and Return into the composer, lists the card
#   (`approvals list`), takes `transcript-anchor` before and after, and (simple_rm) clicks "Allow once":
#   the fake CLI's log must show `allow` with the input unchanged.
# --no-synthetic: the same arrival, then synthetic answers must be refused: the card stays and the QA approvals
#   dir has a `refusal` entry with channel app_control. With an enabled Allow once the probe is `click --text
#   "Allow once"`, `key Return`, `key " "`. With a GATED card (Allow once disabled, "Scroll to the end to allow",
#   e.g. heredoc_300) those presses make no answer attempt and so leave no audit entry; the evidence then comes
#   from the card's exact Deny button (click_card_button) and Return/Space with the card text view focused, and
#   the card must still be pending afterwards.
#
# Before the first cue it creates a QA agent session in the QA daemon (`qa-instance.sh focus`: a focus
# whose CLI is the fake claude), selects its sidebar row and waits for the composer ("Message…"). Before EVERY
# cue it waits for no pending card, clicks the "Message…" field and polls the read-only `hittest` until the
# first responder is the chat composer (ChatTextView): up to 3 clicks in 10 s, else the fixture FAILs naming the
# first responder it saw.
#
# EVERY FIXTURE RUNS IN ITS OWN QA INSTANCE, in both modes (composer state and pending cards never leak across
# fixtures): start, fixture, stop (guard run), next. --no-synthetic per-fixture checks: card appears, text drawn,
# synthetic answers refused with a refusal audit entry (see above); heredoc_300 also reports its Allow label as gated.
#
# The fake CLI is started several times by the daemon (catalog probe, session): the allow check reads the
# responses.jsonl of the fake-claude process dir whose stdin.jsonl holds the fixture's cue as a whole word
# (`simple_rm` never matches `simple_rm2`), polled up to 5 s; the LAST behavior must be allow with
# updatedInput.command unchanged. When no stdin holds the cue the newest non-empty log is used ("fallback log
# used") and the allow check FAILs.
#
# Every exit path prints one `SUMMARY` per fixture (`FAILED` for a fixture that ran and failed, `ABORTED: <reason>`
# for those that did not run) and a final
# `RESULT: PASS|FAIL|INCONCLUSIVE` line, then the DEBUG EVIDENCE block.
#
# Cards are matched by content: each fixture waits for the card whose `input` starts with that fixture's
# first command line, cut at its first non-ASCII character (from tests/fixtures/approvals/<name>.json; a
# prefix shorter than 4 characters selects by the exact full input instead), and uses that card's request_id
# throughout. Two matching cards are "ambiguous card selection", never a pick by position. Cards are
# denied with the card's own exact "Deny" button (found in `ctl tree`
# inside the card, clicked by coordinates; never a text search that could hit "Deny & stop"), and after each
# Deny the request must be gone while the QA session's sidebar row survives. Allow once is clicked only once its option is
# `enabled:true` (up to 20 s).
#
# Text-drawn proof (scripts/qa/lib/card_checks.py): the card's text viewport (the NSClipView in its
# ApprovalInputView, taken from `ctl tree`, matched to the card by its first line) is cropped out of
# `ctl screenshot` and must hold glyph pixels, overall and in the first line's band. A blank text area, an
# unreadable PNG or a card text view that cannot be located FAILS. `ctl find` of the card's first rendered
# ASCII characters, inside the card's frame, is a secondary "text in view tree" check. Screenshots, trees and
# listings live in a private `mktemp -d` directory (printed; removed at the end unless KEEP=1). Fixture names
# must match [a-z0-9_]+ (exit 2 otherwise). One SUMMARY line per fixture.
#
# Everything it sees is printed so it can be pasted into the PR. On a FAIL it first prints what there is
# to debug with (windows, a truncated tree, the daemon and placement log tails, the QA approvals dir).
# KEEP=1 keeps the QA root and the scratch directory after the run. Exits 0 PASS, 1 FAIL, 3 INCONCLUSIVE (display locked or
# asleep: the window is not visible).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
instance="$here/qa-instance.sh"
app="$repo/bin/nostromo-app"

synthetic=1
fixtures=()
for a in "$@"; do
  case "$a" in
    --no-synthetic) synthetic=0 ;;
    *) fixtures+=("$a") ;;
  esac
done
[ "${#fixtures[@]}" -gt 0 ] || fixtures=(simple_rm heredoc_300 bidi)
for f in "${fixtures[@]}"; do
  if ! [[ "$f" =~ ^[a-z0-9_]+$ ]]; then
    echo "usage: fixture names match [a-z0-9_]+ (got '$f')" >&2
    exit 2
  fi
  if [ ! -f "$repo/tests/fixtures/approvals/$f.json" ]; then
    echo "usage: no fixture file tests/fixtures/approvals/$f.json" >&2
    exit 2
  fi
done
start_args=()
[ "$synthetic" = 1 ] || start_args+=(--no-synthetic)

# A real focuses.json that already carries a QA marker is the leftover of an earlier breach (the QA app
# once wrote into the user's own ~/.nostromo). Starting on top of it would compound it: refuse, by file
# name only (never the content).
real_focuses="$HOME/.nostromo/focuses.json"
if [ -f "$real_focuses" ] && grep -qE 'FIXTURE:|com\.hammer\.nostromo\.qa|nostromo-qa-|cody-qa-|qa-approvals' "$real_focuses"; then
  echo "REFUSING TO RUN: $real_focuses already carries a QA marker (FIXTURE:, the QA bundle id, a QA root path, cody-qa-, qa-approvals)." >&2
  echo "A QA run once wrote into your real ~/.nostromo. Remove the QA entries from that file, then run again." >&2
  exit 2
fi

# Private scratch directory (mktemp -d: mode 0700) for screenshots, trees and listings of the QA window; nothing
# is written anywhere else. Removed on exit unless KEEP=1.
work="$(mktemp -d "${TMPDIR:-/tmp}/qa-card.XXXXXX")"
# shellcheck disable=SC2329  # invoked by the EXIT trap
remove_work() {
  [ -z "${KEEP:-}" ] || return 0
  case "$work" in */qa-card.*) rm -rf -- "$work" ;; esac
}
echo "scratch directory (screenshots, trees): $work"

root=""
label=""
sock=""
instance_up=0
verdict=PASS
fail_count=0
inst_fail_base=0
abort_reason=""
reported=0
fixtures_done=0
force_evidence=0
evidence_file="$work/debug-evidence.txt"
: >"$evidence_file"
ctl() { "$app" --socket "$sock" "$@"; }

# What there is to debug with, collected into a file (printed after the RESULT line, before the QA root goes
# away). `live`: the app is still up (windows, tree); `files`: only what is on disk (after stop, when the
# isolation guard failed).
debug_evidence() {
  {
    echo
    echo "=== DEBUG EVIDENCE (instance $root; the QA root is deleted at stop; KEEP=1 keeps it) ==="
    if [ "${1:-live}" = live ]; then
      echo "--- ctl windows"; ctl windows 2>&1 || true
      echo "--- ctl tree --depth 3 (first 120 lines)"; { ctl tree --depth 3 2>&1 | head -n 120; } || true
    fi
    echo "--- nostromd.log (last 40 lines)"; tail -n 40 "$root/nostromd.log" 2>/dev/null || echo "(no daemon log)"
    echo "--- window-placement.log (last 40 lines)"
    tail -n 40 "$root/home/.nostromo/logs/window-placement.log" 2>/dev/null || echo "(no placement log)"
    echo "--- QA approvals dir ($root/home/.nostromo/approvals)"
    ls -la "$root/home/.nostromo/approvals" 2>&1 || true
  } >>"$evidence_file" 2>&1
}

fail() { verdict=FAIL; fail_count=$((fail_count + 1)); last_fail="$*"; echo "FAIL: $*"; }
last_fail=""

# Stop the current QA instance (isolation guard run). Collects the debug evidence first when anything failed
# since it started (or the run is aborting). A guard failure is a FAIL.
stop_instance() {
  [ "$instance_up" = 1 ] || return 0
  if [ "$force_evidence" = 1 ] || [ "$fail_count" != "$inst_fail_base" ]; then debug_evidence live; fi
  instance_up=0
  if ! KEEP="${KEEP:-}" "$instance" stop "$root"; then
    fail "isolation guard"
    debug_evidence files
    return 1
  fi
}

# Every exit path: stop the instance, print one SUMMARY per fixture that did not get one (ABORTED: reason),
# the RESULT line, then the collected DEBUG EVIDENCE. Prints the final exit code (0 PASS, 1 FAIL, 3 INCONCLUSIVE;
# an isolation breach or any FAIL outranks inconclusive).
report() {
  local rc="$1" label i
  reported=1
  [ "$rc" = 0 ] || force_evidence=1
  stop_instance || true
  [ "$verdict" = PASS ] || rc=1
  for ((i = fixtures_done; i < ${#fixtures[@]}; i++)); do
    echo "SUMMARY ${fixtures[$i]}: ABORTED: ${abort_reason:-not run}"
  done
  case "$rc" in 0) label=PASS ;; 3) label=INCONCLUSIVE ;; *) label=FAIL ;; esac
  echo "RESULT: $label (synthetic input $([ "$synthetic" = 1 ] && echo on || echo OFF))"
  if [ -s "$evidence_file" ]; then cat "$evidence_file"; fi
  echo "$rc" >"$work/rc"
}
finish() {
  report "$1"
  exit "$(cat "$work/rc" 2>/dev/null || echo 1)"
}
# A failure the run cannot continue past: evidence, stop, RESULT, exit 1.
abort_fail() {
  abort_reason="$*"
  fail "$*"
  finish 1
}
# shellcheck disable=SC2329  # invoked by the EXIT trap
on_exit() {
  local rc=$?
  if [ "$reported" != 1 ]; then
    # set -e, Ctrl-C or an unexpected error: still tear down, end with SUMMARY lines and a RESULT.
    adopt_root
    abort_reason="${abort_reason:-script error (exit $rc)}"
    verdict=FAIL
    report 1
    rc="$(cat "$work/rc")" || rc=1
  fi
  remove_work
  exit "$rc"
}
trap on_exit EXIT

# The control socket answers before the app has placed its windows (they start at alpha 0 and are
# revealed once placement finishes, one per display, each on its own Space). Wait up to 45 s for all of
# them to be visible before calling the run inconclusive.
windows_hidden() { grep -Eq '"(alpha)": *0([^.0-9]|$)|"visible": *false' <<<"$1"; }

# Take QA_ROOT from what `start` has printed so far; from then on the instance counts as up (stop_instance).
adopt_root() {
  local r
  [ "$instance_up" = 0 ] || return 0
  r="$(sed -n 's/^QA_ROOT=//p' "$work/start.out" 2>/dev/null | head -n 1)" || r=""
  [ -n "$r" ] || return 0
  root="$r"
  sock="$root/app-control.sock"
  instance_up=1
}

# Start one QA instance and get it to a focused-able composer: windows visible, a QA agent session created in
# the QA daemon (a focus whose CLI is the fake claude), its sidebar row selected, the composer ("Message…")
# present. Sets root/sock. Aborts the run (finish) on any failure; INCONCLUSIVE when the display is locked.
start_instance() {
  local out windows focus_out
  inst_fail_base=$fail_count
  # root/instance_up are set as soon as QA_ROOT is on disk (adopt_root), also by on_exit, so a Ctrl-C during
  # `start` still tears the instance down.
  : >"$work/start.out"
  "$instance" start "${start_args[@]+"${start_args[@]}"}" >"$work/start.out" || { cat "$work/start.out"; adopt_root; abort_reason="the QA instance failed to start"; fail "$abort_reason"; finish 1; }
  out="$(cat "$work/start.out")"
  echo "$out"
  adopt_root
  [ -n "$root" ] || { abort_reason="no QA_ROOT printed"; fail "$abort_reason"; finish 1; }

  windows="$(ctl windows)"
  for _ in $(seq 1 90); do
    windows_hidden "$windows" || break
    sleep 0.5
    windows="$(ctl windows)"
  done
  if windows_hidden "$windows"; then
    abort_reason="window not visible after 45 s (display locked or asleep, or the QA app never revealed its windows)"
    echo "INCONCLUSIVE: $abort_reason"
    finish 3
  fi

  # The QA app only has the built-in foci (Fred, Mother, Perri, Teri); the composer lives in an agent
  # session view.
  echo "--- QA agent session"
  if ! focus_out="$("$instance" focus "$root" 2>&1)"; then
    echo "$focus_out"
    abort_fail "could not create the QA agent session in the QA daemon"
  fi
  echo "$focus_out"
  label="$(sed -n 's/^QA_FOCUS_LABEL=//p' <<<"$focus_out")"
  [ -n "$label" ] || abort_fail "no QA_FOCUS_LABEL printed by the focus step"
  ctl wait "$label" --timeout 30 || abort_fail "the QA session's sidebar row '$label' did not appear within 30 s"
  ctl click --text "$label" >/dev/null || abort_fail "could not select the QA session's sidebar row '$label'"
  ctl wait "Message…" --timeout 15 || abort_fail "no composer ('Message…') within 15 s of selecting the QA session '$label'"
}

# Poll up to $2 s until the card count is above zero ("present") or zero ("gone").
wait_cards() {
  local want="$1" secs="${2:-10}" n
  for _ in $(seq 1 $((secs * 4))); do
    n="$(ctl approvals list | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["approvals"]))')"
    if [ "$want" = present ] && [ "$n" -gt 0 ]; then return 0; fi
    if [ "$want" = gone ] && [ "$n" -eq 0 ]; then return 0; fi
    sleep 0.25
  done
  return 1
}

# The composer takes the click, then the cue. (Synthetic keys and clicks are not answers.) Before every cue:
# wait until no card is pending (a card blocks the composer), click the "Message…" field and poll the
# read-only hittest until the first responder is the chat composer (ChatTextView); up to 3 clicks, 10 s in all.
# On failure composer_seen is the last first responder observed and composer_why the reason.
composer_seen="none"
composer_why=""
focus_composer() {
  local attempt t0=$SECONDS hit resp
  composer_seen="none"; composer_why=""
  if ! wait_cards gone 10; then composer_why="a card is still pending"; return 1; fi
  for attempt in 1 2 3; do
    ctl click --text "Message…" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      hit="$(ctl hittest 1 1 2>/dev/null)" || hit="{}"
      resp="$(python3 "$checks" responder <<<"$hit" 2>/dev/null || echo none)"
      composer_seen="$resp"
      if python3 "$checks" composer <<<"$hit" 2>/dev/null; then
        echo "composer focused (first responder = $resp, click $attempt)"
        return 0
      fi
      [ $((SECONDS - t0)) -lt 10 ] || break 2
      sleep 0.25
    done
    echo "(composer click $attempt: first responder = $resp; retrying)"
  done
  composer_why="first responder stayed '$composer_seen' after $attempt click(s) in $((SECONDS - t0)) s"
  return 1
}
send_cue() {
  focus_composer || return 1
  ctl type "FIXTURE:$1" >/dev/null
  ctl key $'\r' --key-code 36 >/dev/null
}

# Poll up to 5 s for the fake CLI's answer for fixture $1 (command $2): the responses.jsonl of the fake-claude
# process dir whose stdin has the fixture's cue (see card_checks.py fakelog). Prints the log tail; sets fake_msg.
fake_msg=""
fake_cli_allowed() {
  local rc
  for _ in $(seq 1 20); do
    rc=0; fake_msg="$(python3 "$checks" fakelog "$root" "$1" "$2")" || rc=$?
    [ "$rc" = 0 ] && break
    sleep 0.25
  done
  echo "--- fake CLI log: $fake_msg"
  return "$rc"
}

checks="$here/lib/card_checks.py"
listing_json() { ctl approvals list; }

# The fixture's first tool command, read from tests/fixtures/approvals/<name>.json.
fixture_command() {
  python3 - "$repo/tests/fixtures/approvals/$1.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["tool_uses"][0]["input"]["command"])
PY
}

# Click the button titled exactly $2 inside the card $1: its centre comes from `ctl tree` (the ApprovalButton
# views inside that card's ApprovalCardView), so a "Deny & stop" is never hit by a substring match and a
# button of another card is never hit. $3=quiet suppresses the reason on failure.
click_card_button() {
  local rid="$1" label="$2" quiet="${3:-}" win xy x y
  listing_json >"$work/click.listing.json" 2>/dev/null || return 1
  win="$(python3 "$checks" window "$rid" <"$work/click.listing.json")"
  ctl -w "$win" tree --depth 40 >"$work/click.tree.json" 2>/dev/null || return 1
  if ! xy="$(python3 "$checks" button "$rid" "$label" "$work/click.listing.json" "$work/click.tree.json")"; then
    [ "$quiet" = quiet ] || echo "cannot click '$label': $xy"
    return 1
  fi
  read -r x y <<<"$xy"
  ctl -w "$win" click "$x" "$y" >/dev/null
}

# Poll up to $2 s until request $1 is no longer listed.
wait_request_gone() {
  for _ in $(seq 1 $((${2:-8} * 4))); do
    listing_json | python3 "$checks" present "$1" || return 0
    sleep 0.25
  done
  return 1
}

# The QA session survives a Deny: its sidebar row is still on screen. ("Deny & stop" ends the agent's turn.)
session_survives() {
  ctl find "$label" 2>/dev/null | python3 "$checks" survives
}

# Deny card $1 with its own exact Deny button and assert: the request is gone and the session survived.
deny_and_assert() {
  local rid="$1"
  echo "(denying request $rid with the card's own 'Deny' button)"
  if ! click_card_button "$rid" "Deny"; then
    fail "$fixture: could not click the card's Deny button"; return 1
  fi
  if ! wait_request_gone "$rid" 8; then
    fail "$fixture: request $rid is still listed after Deny (click refused or missed)"; return 1
  fi
  if ! session_survives; then
    fail "$fixture: SESSION DISAPPEARED after Deny (sidebar row '$label' is gone): 'Deny & stop' was hit, not 'Deny'"
    return 1
  fi
  echo "request $rid gone; session '$label' survived"
}

# Wait up to 15 s for the card of the fixture whose first command is $1; prints its request_id. Returns 4 on
# an ambiguous match (more than one card; the reason is printed) and 1 on timeout.
wait_card_for() {
  local out rc
  for _ in $(seq 1 60); do
    rc=0; out="$(listing_json | python3 "$checks" pick "$1")" || rc=$?
    case "$rc" in
      0) echo "$out"; return 0 ;;
      4) echo "$out"; return 4 ;;
    esac
    sleep 0.25
  done
  return 1
}

# Poll up to 20 s until the card's Allow once is enabled or gated. Prints "<state> <secs>" or "waiting:<label>".
wait_allow() {
  local st t0=$SECONDS
  for _ in $(seq 1 80); do
    st="$(listing_json | python3 "$checks" state "$1")"
    case "$st" in ready|gated) echo "$st $((SECONDS - t0))"; return 0 ;; esac
    sleep 0.25
  done
  echo "$st"; return 1
}

# Text-drawn proof for card $1 of fixture $2 (see the header and lib/card_checks.py): the tree, the find hits
# and a window screenshot go to files in the scratch directory; card_checks.py crops the card's text viewport
# out of the PNG and counts glyph pixels. Prints the verdict lines; sets drawn_why on failure. A tree that
# cannot be read, a card that cannot be located, a missing or corrupt screenshot all FAIL.
drawn_why=""
prove_drawn() {
  local rid="$1" base="$work/$2" win probe out rc=0
  listing_json >"$base.listing.json"
  win="$(python3 "$checks" window "$rid" <"$base.listing.json")"
  probe="$(python3 "$checks" probe "$rid" <"$base.listing.json")"
  echo "window $win; find probe: '$probe'"
  if ! ctl -w "$win" tree --depth 40 >"$base.tree.json" 2>"$base.err"; then
    drawn_why="cannot locate the card text area: ctl tree failed: $(head -c 300 "$base.err")"
    echo "$drawn_why"; return 1
  fi
  echo '[]' >"$base.find.json"
  if [ -n "$probe" ]; then
    ctl -w "$win" find "$probe" >"$base.find.json" 2>/dev/null || echo '[]' >"$base.find.json"
  fi
  if ctl -w "$win" screenshot "$base.png" >/dev/null 2>"$base.err"; then
    echo "screenshot: $base.png"
  else
    echo "screenshot: FAILED: $(head -c 300 "$base.err")"; rm -f "$base.png"
  fi
  out="$(python3 "$checks" prove "$rid" "$base.listing.json" "$base.tree.json" "$base.find.json" "$base.png")" || rc=$?
  echo "$out"
  if [ "$rc" != 0 ]; then
    drawn_why="$(tr '\n' ' ' <<<"$out")"
    case "$out" in
      "cannot locate"*) echo "--- tree excerpt (Approval* views)"; python3 "$checks" excerpt "$base.tree.json" ;;
    esac
  fi
  return "$rc"
}

# Focus the card's text view with a click inside it, then report which view would get a key (the first
# responder, from the read-only hittest). Returns 0 only when it is the card's ApprovalTextView.
card_win=0
focus_card_text() {
  local rid="$1" base="$work/$2.focus" win x y resp
  listing_json >"$base.listing.json"
  win="$(python3 "$checks" window "$rid" <"$base.listing.json")"
  card_win="$win"
  ctl -w "$win" tree --depth 40 >"$base.tree.json" 2>/dev/null || { echo "cannot read the tree to focus the card text view"; return 1; }
  if ! python3 "$checks" locate "$rid" "$base.listing.json" "$base.tree.json" >"$base.locate.json"; then
    cat "$base.locate.json"; return 1
  fi
  read -r x y < <(python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["center"]; print(c["x"], c["y"])' "$base.locate.json")
  ctl -w "$win" click "$x" "$y" >/dev/null || { echo "click in the card text view failed"; return 1; }
  ctl -w "$win" hittest "$x" "$y" >"$base.hit.json" 2>/dev/null || { echo "hittest failed"; return 1; }
  resp="$(python3 "$checks" responder <"$base.hit.json")"
  echo "key target: first responder = $resp (hit-tested at $x,$y inside the card's text view)"
  [ "$resp" = ApprovalTextView ]
}

# One fixture against the current instance. Sets `summary`; returns early (after a fail) when it cannot go on.
summary=""
run_fixture() {
  local fixture="$1" rc rid listing before after expected fixture_cmd drawn allow allow_state allow_secs lbl log after_hit probe_note
  summary="$fixture: ran, stopped early"
  echo
  echo "=== FIXTURE:$fixture (synthetic input $([ "$synthetic" = 1 ] && echo on || echo OFF)) ==="
  # (Every fixture has its own fresh instance, so no card is pending and none needs a click.)
  fixture_cmd="$(fixture_command "$fixture")"
  expected="$(python3 "$checks" expected "$fixture_cmd")"
  echo "--- transcript-anchor before"
  before="$(ctl transcript-anchor)"; echo "$before"
  if ! send_cue "$fixture"; then
    fail "$fixture: the composer never became the first responder (last seen: $composer_seen); no cue sent: $composer_why"
    return
  fi
  rc=0; rid="$(wait_card_for "$fixture_cmd")" || rc=$?
  case "$rc" in
    0)
      echo "--- approvals list (card $rid, input starts with: $expected)"
      listing="$(listing_json)"; echo "$listing" ;;
    4)
      echo "$rid"
      fail "$fixture: ambiguous card selection (more than one card starts with '$expected'); not picking one by position"; return ;;
    *)
      fail "$fixture: no card whose input starts with '$expected' (or equals the fixture's input when that prefix is under 4 characters) within 15 s"; return ;;
  esac
  echo "--- transcript-anchor after (card showing)"
  after="$(ctl transcript-anchor)"; echo "$after"
  python3 - "$before" "$after" <<'PY' || fail "$fixture: the transcript moved more than 1 pt"
import json, sys
b, a = (json.loads(x) for x in sys.argv[1:3])
db = abs((a["firstVisible"]["offsetPt"]) - (b["firstVisible"]["offsetPt"])) if a.get("firstVisible") and b.get("firstVisible") else 0
print(f"first-visible drift: {db:.2f} pt; following {b['following']} -> {a['following']}; bottomOffsetPt {a['bottomOffsetPt']}")
sys.exit(0 if db <= 1 and (not b["following"] or a["bottomOffsetPt"] == 0) else 1)
PY

  echo "--- text drawn? (glyph pixels in the card's text area of a screenshot)"
  if prove_drawn "$rid" "$fixture"; then
    drawn="text drawn (glyph pixels in the card's text area), text in view tree"
  else
    drawn="text NOT drawn"
    fail "$fixture: $drawn: $drawn_why"
  fi
  summary="$fixture: card ok, $drawn"

  if [ "$synthetic" = 1 ]; then
    echo "--- waiting for Allow once (up to 20 s)"
    if allow="$(wait_allow "$rid")"; then
      allow_state="${allow% *}"; allow_secs="${allow#* }"
    else
      allow_state="timeout"; allow_secs=20
    fi
    if [ "$fixture" = "simple_rm" ]; then
      if [ "$allow_state" = ready ]; then
        echo "--- click Allow once (enabled after ${allow_secs} s)"
        click_card_button "$rid" "Allow once" || fail "$fixture: could not click the card's Allow once button"
        if wait_cards gone 8; then
          # The daemon starts the fake CLI several times (catalog probe, session): the log is chosen by content
          # (the process dir whose stdin has this fixture's cue), polled up to 5 s (written just after the card goes).
          if fake_cli_allowed "$fixture" "$fixture_cmd"; then
            summary="$summary, Allow enabled after ${allow_secs} s, allowed (input unchanged)"
          else
            fail "$fixture: the fake CLI did not get an allow with the input unchanged: $fake_msg"
          fi
        else
          fail "$fixture: the card did not go away after Allow once"
        fi
      else
        fail "$fixture: Allow once never became enabled within 20 s (last seen: ${allow#waiting:})"
      fi
    else
      lbl="$(listing_json | python3 "$checks" label "$rid")"
      echo "Allow once label before scrolling: $lbl"
      if [ "$fixture" = heredoc_300 ]; then
        # A synthetic End key is not a human scroll: the gate must stay closed. "Stays gated" only proves the
        # gate ignores synthetic scrolls if the key reached the card's text view, and `ctl key` goes to the
        # first responder (by default the composer). So click into the card's text view first, read the first
        # responder with the read-only hittest, send End only if it is the card text view, and print who got it.
        if focus_card_text "$rid" "$fixture"; then
          ctl -w "$card_win" key "$(printf '\357\234\253')" --key-code 119 >/dev/null 2>&1 || true   # U+F72B: NSEndFunctionKey
          sleep 1
          after_hit="$work/$fixture.after-end.hit.json"
          if ctl -w "$card_win" hittest 1 1 >"$after_hit" 2>/dev/null; then
            echo "key target after End: first responder = $(python3 "$checks" responder <"$after_hit")"
          fi
          lbl="$(listing_json | python3 "$checks" label "$rid")"
          echo "Allow once label after a synthetic End key: $lbl"
          [ "$lbl" = "Scroll to the end to allow" ] || fail "$fixture: Allow was not gated on scrolling (label: $lbl)"
          summary="$summary, Allow stays gated (synthetic End key reached the card text view)"
        else
          fail "$fixture: the End key would not reach the card's text view (see the key target above), so 'stays gated' would prove nothing; End key not sent"
        fi
      fi
      deny_and_assert "$rid" || true
    fi
  else
    if [ "$fixture" = heredoc_300 ]; then
      lbl="$(listing_json | python3 "$checks" label "$rid")"
      echo "Allow once label: $lbl"
      [ "$lbl" = "Scroll to the end to allow" ] || fail "$fixture: Allow was not gated on scrolling (label: $lbl)"
      summary="$summary, Allow label gated"
    fi
    if [ "$(listing_json | python3 "$checks" state "$rid")" = gated ]; then
      # A gated Allow once makes no answer attempt when clicked or keyed, hence no audit entry. The refusal
      # evidence comes from the card's exact Deny button and Return/Space with the card text view focused.
      echo "--- gated card: the card's exact Deny button / key Return / key Space must be refused"
      click_card_button "$rid" "Deny" || fail "$fixture: could not click the card's Deny button"
      if focus_card_text "$rid" "$fixture"; then
        ctl -w "$card_win" key $'\r' --key-code 36 >/dev/null || true
        ctl -w "$card_win" key " " --key-code 49 >/dev/null || true
      else
        fail "$fixture: Return/Space would not reach the card's text view (see the key target above)"
      fi
      probe_note="gated: Deny/Return/Space refused (audit entry via the exact Deny button), card still pending"
    else
      echo "--- click Allow once / key Return / key Space must be refused"
      ctl click --text "Allow once" >/dev/null || true
      ctl key $'\r' --key-code 36 >/dev/null || true
      ctl key " " --key-code 49 >/dev/null || true
      probe_note="synthetic answers refused"
    fi
    sleep 1
    wait_cards present 2 || fail "$fixture: the card is gone: a synthetic press answered it"
    listing_json
    log="$(find "$root" -path '*approvals*' -name 'audit-*.jsonl' -print 2>/dev/null | head -1)"
    echo "--- QA approvals audit ($log)"
    if [ -n "$log" ] && grep '"event": *"refusal"' "$log" | grep -q 'app_control'; then
      grep '"event": *"refusal"' "$log" | tail -n 2
    else
      fail "$fixture: no refusal entry with channel app_control in the QA approvals dir"
    fi
    summary="$summary, $probe_note"
  fi
}

# Main loop. One QA instance per fixture in both modes: start, fixture, stop (isolation guard run), next.
for fixture in "${fixtures[@]}"; do
  start_instance
  before_fails=$fail_count
  run_fixture "$fixture"
  [ "$fail_count" = "$before_fails" ] || summary="$summary -- FAILED: $last_fail"
  echo "SUMMARY $summary"
  fixtures_done=$((fixtures_done + 1))
  stop_instance || abort_fail "isolation guard failed after $fixture; not starting another instance"
done
finish 0
