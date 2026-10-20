#!/usr/bin/env bash
# Live QA of the approval card (AP2a) in the ISOLATED QA instance only: a worktree daemon plus the
# cloned com.hammer.nostromo.qa app, a temp HOME, the fake CLI. Never the user's app, daemon or sessions.
#
#   scripts/qa/approvals-card.sh [--no-synthetic] [FIXTURE ...]     (default fixtures: simple_rm heredoc_300 bidi)
#
# Synthetic input ON (default): types `FIXTURE:<name>` and Return into the composer, lists the card
#   (`approvals list`), takes `transcript-anchor` before and after, and (simple_rm) clicks "Allow once":
#   the fake CLI's log must show `allow` with the input unchanged.
# --no-synthetic: the same arrival, then `click --text "Allow once"`, `key Return` and `key " "` must be
#   refused: the card stays and the QA approvals dir has a `refusal` entry with channel app_control.
#
# Before the first cue it creates a QA agent session in the QA daemon (`qa-instance.sh focus`: a focus
# whose CLI is the fake claude), selects its sidebar row and waits for the composer ("Message…").
#
# Cards are matched by content: each fixture waits for the card whose `input` starts with that fixture's
# first command line, cut at its first non-ASCII character (from tests/fixtures/approvals/<name>.json; a
# prefix shorter than 4 characters selects by the exact full input instead), and uses that card's request_id
# throughout. Two matching cards are "ambiguous card selection", never a pick by position. Pending cards are
# denied before each fixture and at the end, with the card's own exact "Deny" button (found in `ctl tree`
# inside the card, clicked by coordinates; never a text search that could hit "Deny & stop"), and after each
# Deny the request must be gone while the QA session's sidebar row survives. A fixture whose stale cards
# could not be cleared is skipped (no cue, no Allow click). Allow once is clicked only once its option is
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
trap remove_work EXIT
echo "scratch directory (screenshots, trees): $work"

out="$("$instance" start "${start_args[@]+"${start_args[@]}"}")"
echo "$out"
root="$(sed -n 's/^QA_ROOT=//p' <<<"$out")"
[ -n "$root" ] || { echo "FAIL: no QA_ROOT printed"; exit 1; }
stopped=0
sock="$root/app-control.sock"
ctl() { "$app" --socket "$sock" "$@"; }
verdict=PASS

# What there is to debug with, printed before the QA root goes away. `live`: the app is still up (windows,
# tree); `files`: only what is on disk (after stop, when the isolation guard failed).
debug_evidence() {
  echo
  echo "=== DEBUG EVIDENCE (the QA root is deleted at stop; KEEP=1 keeps it) ==="
  if [ "${1:-live}" = live ]; then
    echo "--- ctl windows"; ctl windows 2>&1 || true
    echo "--- ctl tree --depth 3 (first 120 lines)"; { ctl tree --depth 3 2>&1 | head -n 120; } || true
  fi
  echo "--- nostromd.log (last 40 lines)"; tail -n 40 "$root/nostromd.log" 2>/dev/null || echo "(no daemon log)"
  echo "--- window-placement.log (last 40 lines)"
  tail -n 40 "$root/home/.nostromo/logs/window-placement.log" 2>/dev/null || echo "(no placement log)"
  echo "--- QA approvals dir ($root/home/.nostromo/approvals)"
  ls -la "$root/home/.nostromo/approvals" 2>&1 || true
}
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  local rc=$?
  remove_work
  [ "$stopped" = 1 ] && return
  [ "$rc" = 0 ] || debug_evidence live
  KEEP="${KEEP:-}" "$instance" stop "$root" || true
}
trap cleanup EXIT
fail() { verdict=FAIL; echo "FAIL: $*"; }
# A failure the run cannot continue past: evidence, stop, exit 1.
abort_fail() {
  fail "$*"
  debug_evidence live
  stopped=1; KEEP="${KEEP:-}" "$instance" stop "$root" || echo "FAIL: isolation guard"
  exit 1
}

# The control socket answers before the app has placed its windows (they start at alpha 0 and are
# revealed once placement finishes, one per display, each on its own Space). Wait up to 45 s for all of
# them to be visible before calling the run inconclusive, and print what was seen when it is.
windows_hidden() { grep -Eq '"(alpha)": *0([^.0-9]|$)|"visible": *false' <<<"$1"; }
windows="$(ctl windows)"
for _ in $(seq 1 90); do
  windows_hidden "$windows" || break
  sleep 0.5
  windows="$(ctl windows)"
done
if windows_hidden "$windows"; then
  echo "INCONCLUSIVE: window not visible after 45 s (display locked or asleep, or the QA app never revealed its windows)"
  debug_evidence live
  stopped=1; KEEP="${KEEP:-}" "$instance" stop "$root" || exit 1   # an isolation breach outranks "inconclusive"
  exit 3
fi

# The QA app only has the built-in foci (Fred, Mother, Perri, Teri); the composer lives in an agent
# session view. Have the QA daemon create a session whose CLI is the fake claude (it announces the
# focus to the app), select its sidebar row, and wait for the composer.
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

# The composer takes the click, then the cue. (Synthetic keys and clicks are not answers.)
send_cue() {
  ctl click --text "Message…" >/dev/null
  ctl type "FIXTURE:$1" >/dev/null
  ctl key $'\r' --key-code 36 >/dev/null
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

# Deny every card still pending (poll until gone, up to 10 s). QSR-4: no card leaks across fixtures.
clear_cards() {
  local ids rid _n
  ids="$(listing_json | python3 "$checks" stale)"
  [ -n "$ids" ] || return 0
  echo "(clearing stale card(s): $(tr '\n' ' ' <<<"$ids"))"
  # One exact Deny click per stale card (each answered card makes the next one the visible one).
  for _n in $ids; do
    for rid in $(listing_json | python3 "$checks" stale); do
      click_card_button "$rid" "Deny" quiet && break
    done
    sleep 0.5
  done
  wait_cards gone 10 && return 0
  echo "note: stale card(s) still showing after Deny"; return 1
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

for fixture in "${fixtures[@]}"; do
  echo
  echo "=== FIXTURE:$fixture (synthetic input $([ "$synthetic" = 1 ] && echo on || echo OFF)) ==="
  if [ "$synthetic" = 1 ]; then
    # A failed clear means a stale card may still be showing: no cue and no Allow click for this fixture.
    if ! clear_cards; then
      fail "$fixture: could not clear stale card(s) before the cue; skipping this fixture (no cue, no clicks)"
      continue
    fi
  else
    # Deny clicks are refused with synthetic input off; matching by input ignores a leftover card.
    clear_cards >/dev/null || echo "note: a card from an earlier fixture remains (expected with --no-synthetic); matching by input"
  fi
  fixture_cmd="$(fixture_command "$fixture")"
  expected="$(python3 "$checks" expected "$fixture_cmd")"
  echo "--- transcript-anchor before"
  before="$(ctl transcript-anchor)"; echo "$before"
  send_cue "$fixture"
  rc=0; rid="$(wait_card_for "$fixture_cmd")" || rc=$?
  case "$rc" in
    0)
      echo "--- approvals list (card $rid, input starts with: $expected)"
      listing="$(listing_json)"; echo "$listing" ;;
    4)
      echo "$rid"
      fail "$fixture: ambiguous card selection (more than one card starts with '$expected'); not picking one by position"; continue ;;
    *)
      fail "$fixture: no card whose input starts with '$expected' (or equals the fixture's input when that prefix is under 4 characters) within 15 s"; continue ;;
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
          log="$(find "$root" -name responses.jsonl -print 2>/dev/null | head -1)"
          echo "--- fake CLI log ($log)"
          if [ -n "$log" ]; then tail -n 3 "$log"; else fail "no fake CLI log found under the QA root"; fi
          grep -q '"behavior": *"allow"' "$log" 2>/dev/null || fail "$fixture: the fake CLI did not get an allow"
          summary="$summary, Allow enabled after ${allow_secs} s, allowed"
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
    echo "--- click Allow once / key Return / key Space must be refused"
    ctl click --text "Allow once" >/dev/null || true
    ctl key $'\r' --key-code 36 >/dev/null || true
    ctl key " " --key-code 49 >/dev/null || true
    sleep 1
    wait_cards present 2 || fail "$fixture: the card is gone: a synthetic press answered it"
    listing_json
    log="$(find "$root" -path '*approvals*' -name 'audit-*.jsonl' -print 2>/dev/null | head -1)"
    echo "--- QA approvals audit ($log)"
    if [ -n "$log" ] && grep -q '"event": *"refusal"' "$log" && grep -q 'app_control' "$log"; then
      grep '"event": *"refusal"' "$log" | tail -n 2
    else
      fail "$fixture: no refusal entry with channel app_control in the QA approvals dir"
    fi
    summary="$summary, synthetic answers refused"
  fi
  echo "SUMMARY $summary"
done

# QSR-4: leave no card behind. With synthetic input off the Deny click is refused; the QA root is deleted at stop.
echo "--- clearing remaining cards"
clear_cards || echo "note: card(s) remain (expected with --no-synthetic; the QA root is deleted at stop)"

[ "$verdict" = PASS ] || debug_evidence live
stopped=1
if KEEP="${KEEP:-}" "$instance" stop "$root"; then :; else
  fail "isolation guard"
  debug_evidence files
fi
echo "RESULT: $verdict (synthetic input $([ "$synthetic" = 1 ] && echo on || echo OFF))"
case "$verdict" in PASS) exit 0 ;; *) exit 1 ;; esac
