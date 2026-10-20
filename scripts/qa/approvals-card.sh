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
# Everything it sees is printed so it can be pasted into the PR. On a FAIL it first prints what there is
# to debug with (windows, a truncated tree, the daemon and placement log tails, the QA approvals dir).
# KEEP=1 keeps the QA root after the run. Exits 0 PASS, 1 FAIL, 3 INCONCLUSIVE (display locked or
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

for fixture in "${fixtures[@]}"; do
  echo
  echo "=== FIXTURE:$fixture (synthetic input $([ "$synthetic" = 1 ] && echo on || echo OFF)) ==="
  echo "--- transcript-anchor before"
  before="$(ctl transcript-anchor)"; echo "$before"
  send_cue "$fixture"
  if wait_cards present 15; then
    echo "--- approvals list"
    listing="$(ctl approvals list)"; echo "$listing"
  else
    fail "$fixture: no card within 15 s"; continue
  fi
  echo "--- transcript-anchor after (card showing)"
  after="$(ctl transcript-anchor)"; echo "$after"
  python3 - "$before" "$after" <<'PY' || fail "$fixture: the transcript moved more than 1 pt"
import json, sys
b, a = (json.loads(x) for x in sys.argv[1:3])
db = abs((a["firstVisible"]["offsetPt"]) - (b["firstVisible"]["offsetPt"])) if a.get("firstVisible") and b.get("firstVisible") else 0
print(f"first-visible drift: {db:.2f} pt; following {b['following']} -> {a['following']}; bottomOffsetPt {a['bottomOffsetPt']}")
sys.exit(0 if db <= 1 and (not b["following"] or a["bottomOffsetPt"] == 0) else 1)
PY

  if [ "$synthetic" = 1 ]; then
    if [ "$fixture" = "simple_rm" ]; then
      echo "--- click Allow once"
      ctl click --text "Allow once" >/dev/null || fail "$fixture: click failed"
      wait_cards gone 8 || fail "$fixture: the card did not go away after Allow once"
      log="$(find "$root" -name responses.jsonl -print 2>/dev/null | head -1)"
      echo "--- fake CLI log ($log)"
      if [ -n "$log" ]; then tail -n 3 "$log"; else fail "no fake CLI log found under the QA root"; fi
      grep -q '"behavior": *"allow"' "$log" 2>/dev/null || fail "$fixture: the fake CLI did not get an allow"
    else
      state="$(python3 -c 'import json,sys; c=json.loads(sys.argv[1])["approvals"][0]; print([o for o in c["options"] if o["id"]=="allow_once"][0]["label"])' "$listing")"
      echo "Allow once label before scrolling: $state"
      case "$fixture" in
        heredoc_300) [ "$state" = "Scroll to the end to allow" ] || fail "$fixture: Allow was not gated on scrolling" ;;
      esac
      echo "(denying to clear the card)"
      ctl click --text "Deny" >/dev/null || true
      wait_cards gone 8 || echo "note: card still showing (deny click refused or not found)"
    fi
  else
    echo "--- click Allow once / key Return / key Space must be refused"
    ctl click --text "Allow once" >/dev/null || true
    ctl key $'\r' --key-code 36 >/dev/null || true
    ctl key " " --key-code 49 >/dev/null || true
    sleep 1
    wait_cards present 2 || fail "$fixture: the card is gone: a synthetic press answered it"
    ctl approvals list
    log="$(find "$root" -path '*approvals*' -name 'audit-*.jsonl' -print 2>/dev/null | head -1)"
    echo "--- QA approvals audit ($log)"
    if [ -n "$log" ] && grep -q '"event": *"refusal"' "$log" && grep -q 'app_control' "$log"; then
      grep '"event": *"refusal"' "$log" | tail -n 2
    else
      fail "$fixture: no refusal entry with channel app_control in the QA approvals dir"
    fi
  fi
done

[ "$verdict" = PASS ] || debug_evidence live
stopped=1
if KEEP="${KEEP:-}" "$instance" stop "$root"; then :; else
  fail "isolation guard"
  debug_evidence files
fi
echo "RESULT: $verdict (synthetic input $([ "$synthetic" = 1 ] && echo on || echo OFF))"
case "$verdict" in PASS) exit 0 ;; *) exit 1 ;; esac
